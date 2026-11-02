// The shared native window owns presentation. Inno extracts offline payloads or
// registers a stage already downloaded and verified by the online worker.
type
  TSessionGuid = record
    A: LongWord;
    B, C: Word;
    D: array[0..7] of Byte;
  end;

var
  EngineSession, EngineStage, EngineDirectory, EngineState: String;
  EngineTimer, EngineStartedAt, EngineProgressPublishedAt: LongWord;
  EngineCompletedBytes, EngineTotalBytes: Integer;
  EngineFile: String;
  EngineComplete, EngineClosing, EngineStarting: Boolean;
  EnginePublishing, EnginePublicationPending: Boolean;
  EngineAdvancing: Boolean;
  EngineMessage: String;
  EngineWorker: THandle;

function CoCreateGuid(var Guid: TSessionGuid): LongInt;
  external 'CoCreateGuid@ole32.dll stdcall';
function EngineProcessID: LongWord;
  external 'GetCurrentProcessId@kernel32.dll stdcall';
function EngineTickCount: LongWord;
  external 'GetTickCount@kernel32.dll stdcall';
function SetEngineTimer(Window, ID, Interval, Callback: LongWord): LongWord;
  external 'SetTimer@user32.dll stdcall';
function KillEngineTimer(Window, ID: LongWord): Boolean;
  external 'KillTimer@user32.dll stdcall';
function EnginePostMessage(Window: HWND; Message: LongWord; WParam, LParam: LongInt): Boolean;
  external 'PostMessageW@user32.dll stdcall';
function HideEngineWindow(Window: HWND; Command: Integer): Boolean;
  external 'ShowWindow@user32.dll stdcall';
function MoveEngineStatus(Source, Destination: String; Flags: LongWord): Boolean;
  external 'MoveFileExW@kernel32.dll stdcall';
function OpenEngineWorker(Access: LongWord; Inherit: LongInt; ProcessID: LongWord): THandle;
  external 'OpenProcess@kernel32.dll stdcall';
function EngineWorkerWait(Worker: THandle; Milliseconds: LongWord): LongWord;
  external 'WaitForSingleObject@kernel32.dll stdcall';

function EngineHex(Value: LongWord; Digits: Integer): String;
var
  HexDigits: String;
begin
  HexDigits := '0123456789abcdef';
  Result := '';
  while Digits > 0 do begin
    Result := HexDigits[(Value and 15) + 1] + Result;
    Value := Value div 16;
    Digits := Digits - 1;
  end;
end;

function JsonEngineString(Value: String): String;
var
  I: Integer;
begin
  Result := '"';
  for I := 1 to Length(Value) do begin
    case Value[I] of
      '"': Result := Result + '\"';
      '\': Result := Result + '\\';
    else
      if Ord(Value[I]) < 32 then Result := Result + '\u' + EngineHex(Ord(Value[I]), 4)
      else Result := Result + Value[I];
    end;
  end;
  Result := Result + '"';
end;

procedure PublishEngine(State, Message: String);
var
  Lines: TArrayOfString;
  Temporary, Destination: String;
  Attempt, ErrorCode: Integer;
begin
  if EngineDirectory = '' then Exit;
  if EnginePublishing then Exit;
  EnginePublishing := True;
  EnginePublicationPending := True;
  EngineState := State;
  EngineMessage := Message;
  try
  Temporary := EngineDirectory + '\engine-new.json';
  Destination := EngineDirectory + '\engine.json';
  if HasLinkedAncestor(Temporary) or HasLinkedAncestor(Destination) then
    RaiseException('The setup session is unavailable.');
  SetArrayLength(Lines, 1);
  Lines[0] := '{"schema":1,"state":' + JsonEngineString(State) +
    ',"stage":' + JsonEngineString(EngineStage) +
    ',"completed":' + IntToStr(EngineCompletedBytes) +
    ',"total":' + IntToStr(EngineTotalBytes) +
    ',"file":' + JsonEngineString(Copy(ExtractFileName(EngineFile), 1, 220)) +
    ',"message":' + JsonEngineString(Message) + '}';
  if not SaveStringsToUTF8File(Temporary, Lines, False) then begin
    Log('Setup status write deferred.');
    Exit;
  end;
  // Readers and scanners may briefly prevent replacement on Windows. Keep the
  // previous complete status, retry boundedly, then retry on the next timer.
  for Attempt := 1 to 10 do begin
    if MoveEngineStatus(Temporary, Destination, 9) then begin
      EnginePublicationPending := False;
      Exit;
    end;
    ErrorCode := DLLGetLastError;
    Sleep(20);
  end;
  Log('Setup status replacement deferred; Windows error ' + IntToStr(ErrorCode) + '.');
  finally
    EnginePublishing := False;
  end;
end;

function GetStageLeaf(Parameter: String): String;
begin
  if EngineStage = '' then RaiseException('The installation stage is missing.');
  Result := EngineStage;
end;

procedure CloseEngine;
begin
  EngineClosing := True;
  // Inno ignores ordinary cancellation while its wizard is hidden. Make the
  // offscreen wizard visible without activation, then use its normal close path.
  WizardForm.Left := -32000;
  WizardForm.Top := -32000;
  HideEngineWindow(WizardForm.Handle, 4);
  EnginePostMessage(WizardForm.Handle, $0010, 0, 0);
end;

procedure HideEngine(Sender: TObject);
begin
  if not EngineClosing then HideEngineWindow(WizardForm.Handle, 0);
end;

function ReadEngineCommand: String;
var
  Path, Claimed, Json: String;
  Bytes: AnsiString;
  Size: Integer;
  I: Integer;
begin
  Result := '';
  Path := EngineDirectory + '\engine-command.json';
  if not FileExists(Path) then Exit;
  Claimed := EngineDirectory + '\engine-command-reading.json';
  if HasLinkedAncestor(Path) or HasLinkedAncestor(Claimed) then
    RaiseException('The setup command is invalid.');
  // Claim this exact command so a newer cancellation cannot be deleted with it.
  if not MoveEngineStatus(Path, Claimed, 8) then Exit;
  if not FileSize(Claimed, Size) or (Size < 0) or (Size > 1024) then
    RaiseException('The setup command is invalid.');
  if not LoadStringFromFile(Claimed, Bytes) then
    RaiseException('The setup command could not be read.');
  Json := '';
  // Commands are bounded ASCII JSON. Whitespace and an optional UTF-8 BOM are allowed.
  if Copy(Bytes, 1, 3) = #$EF#$BB#$BF then Delete(Bytes, 1, 3);
  for I := 1 to Length(Bytes) do
    if Ord(Bytes[I]) > 32 then Json := Json + Chr(Ord(Bytes[I]));
  if Json = '{"schema":1,"action":"start"}' then Result := 'start'
  else if Json = '{"schema":1,"action":"open"}' then Result := 'open'
  else if Json = '{"schema":1,"action":"cancel"}' then Result := 'cancel'
  else RaiseException('The setup command is invalid.');
  if not DeleteFile(Claimed) then RaiseException('The setup command could not be consumed.');
end;

procedure ObserveEngineWorker;
var
  Path, Json, Prefix, Number: String;
  Bytes: AnsiString;
  Size: Integer;
  I, ProcessID: Integer;
begin
  if EngineWorker <> 0 then Exit;
  Path := EngineDirectory + '\engine-worker.json';
  if not FileExists(Path) then Exit;
  if HasLinkedAncestor(Path) or not FileSize(Path, Size) or (Size < 1) or (Size > 128) then
    RaiseException('The setup worker is invalid.');
  if not LoadStringFromFile(Path, Bytes) then Exit;
  if Copy(Bytes, 1, 3) = #$EF#$BB#$BF then Delete(Bytes, 1, 3);
  Json := '';
  for I := 1 to Length(Bytes) do
    if Ord(Bytes[I]) > 32 then Json := Json + Chr(Ord(Bytes[I]));
  Prefix := '{"schema":1,"pid":';
  if (Copy(Json, 1, Length(Prefix)) <> Prefix) or (Copy(Json, Length(Json), 1) <> '}') then
    RaiseException('The setup worker is invalid.');
  Number := Copy(Json, Length(Prefix) + 1, Length(Json) - Length(Prefix) - 1);
  ProcessID := StrToIntDef(Number, 0);
  if ProcessID <= 0 then RaiseException('The setup worker is invalid.');
  EngineWorker := OpenEngineWorker($00100000, 0, ProcessID);
  if EngineWorker = 0 then RaiseException('The setup worker closed.');
end;

procedure PollEngine(Window, Message, ID, Tick: LongWord);
var
  Action: String;
begin
  if EngineClosing then Exit;
  if EnginePublicationPending then PublishEngine(EngineState, EngineMessage);
  if EngineComplete then Exit;
  HideEngineWindow(WizardForm.Handle, 0);
  try
    ObserveEngineWorker;
    if (EngineWorker <> 0) and (EngineWorkerWait(EngineWorker, 0) <> 258) then begin
      Log('The setup window exited before the engine finished.');
      PublishEngine('error', 'The setup window closed. Run the installer again.');
      CloseEngine;
      Exit;
    end;
    if not EngineAdvancing and (WizardForm.CurPageID = wpPreparing) and
       (WizardForm.PreparingMemo.Text <> '') and (EngineState <> 'blocked') then
      PublishEngine('blocked', 'Installation is blocked. Close Doorlight and check free space, then try again.');
    Action := ReadEngineCommand;
    if Action = 'cancel' then begin
      PublishEngine('error', 'Installation cancelled.');
      CloseEngine;
    end else if (Action = 'open') and not EngineStarting then begin
      PublishEngine('waiting', 'Opening existing installation.');
      CloseEngine;
    end else if (Action = 'start') and not EngineAdvancing and
      ((WizardForm.CurPageID = wpReady) or (WizardForm.CurPageID = wpPreparing)) then begin
      EngineAdvancing := True;
      try
        // Inno disables Next on a failed preparation page. Its normal retry
        // route is Back to Ready, then Next; hidden-dialog BM_CLICK is unreliable.
        if (WizardForm.CurPageID = wpPreparing) and (WizardForm.PreparingMemo.Text <> '') then
          WizardForm.BackButton.OnClick(WizardForm.BackButton);
        if (WizardForm.CurPageID = wpReady) and WizardForm.NextButton.Enabled then begin
          EngineStarting := True;
          PublishEngine('waiting', 'Preparing installation.');
          WizardForm.NextButton.OnClick(WizardForm.NextButton);
        end;
      finally
        EngineAdvancing := False;
      end;
    end;
    if (EngineWorker = 0) and (EngineTickCount - EngineStartedAt > 20000) then begin
      PublishEngine('error', 'The setup window did not start. Run the installer again.');
      CloseEngine;
    end;
  except
    try
      PublishEngine('error', 'The setup session failed. Run the installer again.');
    except
      // IPC failure still exits through the engine's ordinary cleanup.
    end;
    CloseEngine;
  end;
end;

procedure InitializeWizard;
var
  Guid: TSessionGuid;
  I, ExitCode: Integer;
  Worker, Arguments: String;
#ifndef OnlineBootstrap
  Manifest: String;
#endif
begin
  WizardForm.CenterOnShow := False;
  WizardForm.Left := -32000;
  WizardForm.Top := -32000;
  WizardForm.OnShow := @HideEngine;
  if CoCreateGuid(Guid) <> 0 then RaiseException('The setup session could not be created.');
  EngineSession := EngineHex(Guid.A, 8) + EngineHex(Guid.B, 4) + EngineHex(Guid.C, 4);
  for I := 0 to 7 do EngineSession := EngineSession + EngineHex(Guid.D[I], 2);
  EngineSession := Lowercase(EngineSession);
  EngineStage := '.stage-' + EngineSession;
  EngineDirectory := ExpandConstant('{localappdata}\Doorlight\setup-sessions\') + EngineSession;
  if HasLinkedAncestor(EngineDirectory) or not ForceDirectories(EngineDirectory) or
     HasLinkedAncestor(EngineDirectory) then RaiseException('The setup session is unavailable.');
  ExtractTemporaryFile('DoorlightSetupWorker.exe');
#ifndef OnlineBootstrap
  ExtractTemporaryFile('Doorlight.Package.json');
#endif
  Worker := ExpandConstant('{tmp}\DoorlightSetupWorker.exe');
#ifndef OnlineBootstrap
  Manifest := ExpandConstant('{tmp}\Doorlight.Package.json');
#endif
  PublishEngine('waiting', '');
  ExitCode := -1;
  Arguments := '--install --session ' + EngineSession +
    ' --engine-pid ' + IntToStr(EngineProcessID) +
    ' --engine-window ' + IntToStr(WizardForm.Handle) +
    ' --stage ' + EngineStage;
#ifdef OnlineBootstrap
  Arguments := Arguments + ' --online';
#else
  Arguments := Arguments + ' --manifest "' + Manifest + '"';
#endif
  if not Exec(Worker, Arguments,
    ExpandConstant('{tmp}'), SW_SHOWNORMAL, ewNoWait, ExitCode) then begin
    PublishEngine('error', 'The setup window could not open. Run the installer again.');
    RaiseException('The setup window could not open.');
  end;
  EngineStartedAt := EngineTickCount;
  EngineTimer := SetEngineTimer(0, 0, 100, CreateCallback(@PollEngine));
  if EngineTimer = 0 then RaiseException('The setup session could not start.');
end;

function ShouldSkipPage(PageID: Integer): Boolean;
begin
  Result := PageID = wpSelectTasks;
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  HideEngineWindow(WizardForm.Handle, 0);
end;

procedure CurInstallProgressChanged(CurProgress, MaxProgress: Integer);
begin
  EngineCompletedBytes := CurProgress;
  EngineTotalBytes := MaxProgress;
  EngineFile := WizardForm.FilenameLabel.Caption;
  if (EngineState <> 'installing') or (CurProgress = MaxProgress) or
     (EngineTickCount - EngineProgressPublishedAt >= 100) then begin
    PublishEngine('installing', '');
    EngineProgressPublishedAt := EngineTickCount;
  end;
end;

procedure CancelButtonClick(CurPageID: Integer; var Cancel, Confirm: Boolean);
begin
  // Cancellation still passes through Inno's rollback rather than terminating it.
  Confirm := False;
end;

procedure ReleaseEngine;
begin
  if EngineTimer <> 0 then KillEngineTimer(0, EngineTimer);
  if EngineWorker <> 0 then begin
    CloseHandle(EngineWorker);
    EngineWorker := 0;
  end;
  if EnginePublicationPending then PublishEngine(EngineState, EngineMessage);
  if (EngineDirectory <> '') and not EngineComplete and (EngineState <> 'error') and
     (EngineState <> 'waiting') then PublishEngine('error', 'Installation did not complete.');
end;
