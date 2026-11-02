; Build only from a release-qualified bundle, never from a source directory.
#ifndef OnlineBootstrap
  #ifndef BundleDir
    #error BundleDir must name the complete qualified Windows bundle
  #endif
#endif
#ifndef AppVersion
  #error AppVersion is required
#endif
#ifndef OutputDir
  #error OutputDir is required
#endif
#ifndef UpdaterExe
  #error UpdaterExe must name the self-contained Windows updater
#endif
#ifndef UpdaterNoticesDir
  #error UpdaterNoticesDir must name the updater dependency notices
#endif
#ifndef OnlineBootstrap
  #ifndef ManifestFile
    #error ManifestFile must name the complete staged bundle manifest
  #endif
  #if !FileExists(BundleDir + "\sybl.exe")
    #error The bundle must contain sybl.exe
  #endif
#endif
#if !FileExists(UpdaterExe)
  #error The updater executable does not exist
#endif
#ifdef FixtureBuild
  #define ArtifactLabel "-Fixture"
#else
  #define ArtifactLabel ""
#endif

[Setup]
AppId={{0B81A9C9-C64B-4C0D-B30B-43381DA5525E}
AppName=Doorlight
AppVersion={#AppVersion}
AppPublisher=Crazy Entertainment
DefaultDirName={localappdata}\Programs\Doorlight
DisableDirPage=yes
DisableProgramGroupPage=yes
UsePreviousAppDir=no
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0
WizardStyle=modern
SetupIconFile=..\..\apps\doorlight\windows\runner\resources\app_icon.ico
DisableWelcomePage=yes
DisableFinishedPage=yes
DisableReadyMemo=yes
OutputDir={#OutputDir}
#ifdef OnlineBootstrap
OutputBaseFilename=Doorlight-{#AppVersion}{#ArtifactLabel}-Online-Setup
#else
OutputBaseFilename=Doorlight-{#AppVersion}{#ArtifactLabel}-Setup
#endif
Compression=lzma2
SolidCompression=yes
CloseApplications=no
RestartApplications=no
SetupMutex=DoorlightSetupWizard
UninstallDisplayIcon={app}\current\sybl.exe

[Tasks]
Name: desktopicon; Description: "Create a &desktop shortcut"; GroupDescription: "Shortcuts:"; Flags: unchecked

[Files]
; Bootstrap files precede the solid payload so its UI does not wait for extraction.
Source: "{#UpdaterExe}"; DestName: "DoorlightSetupWorker.exe"; Flags: dontcopy
#ifndef OnlineBootstrap
Source: "{#ManifestFile}"; DestName: "Doorlight.Package.json"; Flags: dontcopy
Source: "{#BundleDir}\*"; DestDir: "{app}\{code:GetStageLeaf}"; Flags: ignoreversion recursesubdirs createallsubdirs uninsneveruninstall solidbreak
#endif
Source: "{#UpdaterExe}"; DestDir: "{app}"; DestName: "DoorlightUpdater.exe"; Flags: onlyifdoesntexist
Source: "..\..\LICENSE"; DestDir: "{app}"; DestName: "LICENSE.txt"; Flags: ignoreversion
Source: "{#UpdaterNoticesDir}\*"; DestDir: "{app}\licenses"; Flags: ignoreversion

[Icons]
Name: "{autoprograms}\Doorlight"; Filename: "{app}\DoorlightUpdater.exe"; Parameters: "--launch"; WorkingDir: "{app}"; IconFilename: "{app}\current\sybl.exe"
Name: "{autodesktop}\Doorlight"; Filename: "{app}\DoorlightUpdater.exe"; Parameters: "--launch"; WorkingDir: "{app}"; IconFilename: "{app}\current\sybl.exe"; Tasks: desktopicon

[Code]
const
  InvalidHandle = -1;
  GenericReadWrite = $C0000000;
  OpenAlways = 4;
  FileAttributeHidden = 2;
  FileAttributeReparsePoint = $400;
  FileFlagOpenReparsePoint = $00200000;

var
  SetupLock, PreparationLock, ProfileLock, LegacyProfileLock: THandle;

function HasLinkedAncestor(Path: String): Boolean; forward;

function CreateFile(Name: String; Access, Sharing: LongWord;
  Security: LongWord; Disposition, Attributes: LongWord; Template: THandle): THandle;
  external 'CreateFileW@kernel32.dll stdcall';
function CloseHandle(Handle: THandle): Boolean;
  external 'CloseHandle@kernel32.dll stdcall';
function GetFileAttributes(Name: String): LongWord;
  external 'GetFileAttributesW@kernel32.dll stdcall';

procedure ReleaseLock(var Handle: THandle);
begin
  if (Handle <> 0) and (Handle <> InvalidHandle) then CloseHandle(Handle);
  Handle := 0;
end;

procedure ReleaseLocks;
begin
  ReleaseLock(LegacyProfileLock);
  ReleaseLock(ProfileLock);
  ReleaseLock(PreparationLock);
  ReleaseLock(SetupLock);
end;

function HasLinkedAncestor(Path: String): Boolean;
var
  Parent: String;
  Attributes: LongWord;
begin
  Result := False;
  while Path <> '' do begin
    Attributes := GetFileAttributes(Path);
    if (Attributes <> $FFFFFFFF) and
       ((Attributes and FileAttributeReparsePoint) <> 0) then begin
      Result := True;
      Exit;
    end;
    Parent := ExtractFileDir(Path);
    if Parent = Path then Exit;
    Path := Parent;
  end;
end;

function AcquireLock(Directory, Filename: String; var Handle: THandle): Boolean;
var
  Path: String;
begin
  Result := False;
  Path := AddBackslash(Directory) + Filename;
  if HasLinkedAncestor(Path) then Exit;
  if not ForceDirectories(Directory) then Exit;
  if HasLinkedAncestor(Path) then Exit;
  Handle := CreateFile(Path, GenericReadWrite, 0, 0, OpenAlways,
    FileAttributeHidden or FileFlagOpenReparsePoint, 0);
  Result := Handle <> InvalidHandle;
end;

function AcquireLocks: Boolean;
begin
  ReleaseLocks;
  Result := AcquireLock(ExpandConstant('{app}'), 'setup.lock', SetupLock);
  if Result then
    Result := AcquireLock(ExpandConstant('{app}'), 'prepare.lock', PreparationLock);
  if Result then
    Result := AcquireLock(ExpandConstant('{localappdata}\Doorlight'), 'instance.lock', ProfileLock);
  if Result then
    Result := AcquireLock(ExpandConstant('{localappdata}\Syb-L'), 'instance.lock', LegacyProfileLock);
  if not Result then ReleaseLocks;
end;

#include "InstallEngine.iss"

function SafeBundleTree(Path: String): Boolean; forward;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if not AcquireLocks then begin
    Result := 'Close Doorlight and any other Doorlight installer, then try again.';
    PublishEngine('blocked', Result);
    Exit;
  end;
  // Online stages are already downloaded and verified by the shared frontend.
  // Offline stages are new directories populated solely by Inno extraction.
  if HasLinkedAncestor(ExpandConstant('{app}\') + EngineStage) or
#ifdef OnlineBootstrap
     not DirExists(ExpandConstant('{app}\') + EngineStage) or
     not FileExists(ExpandConstant('{app}\') + EngineStage + '\sybl.exe') or
     not SafeBundleTree(ExpandConstant('{app}\') + EngineStage) then begin
#else
     DirExists(ExpandConstant('{app}\') + EngineStage) then begin
#endif
    ReleaseLocks;
    Result := 'The installation stage is unavailable. Start a fresh installer.';
    PublishEngine('blocked', Result);
  end;
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then begin
    ReleaseLocks;
    EngineComplete := True;
    PublishEngine('complete', '');
  end;
end;

procedure DeinitializeSetup;
begin
  ReleaseEngine;
  ReleaseLocks;
end;

function InitializeUninstall: Boolean;
begin
  Result := AcquireLocks;
  if Result then Result := SafeBundleTree(ExpandConstant('{app}'));
  if not Result then
    SuppressibleMsgBox('Close Doorlight and any other Doorlight installer, then try again. Linked installation folders need manual inspection.', mbError, MB_OK, IDOK);
end;

function SafeBundleTree(Path: String): Boolean;
var
  Entry: TFindRec;
begin
  Result := not HasLinkedAncestor(Path);
  if not Result then Exit;
  if FindFirst(AddBackslash(Path) + '*', Entry) then begin
    try
      repeat
        if (Entry.Name <> '.') and (Entry.Name <> '..') then begin
          if (Entry.Attributes and FileAttributeReparsePoint) <> 0 then begin
            Result := False;
            Exit;
          end;
          if (Entry.Attributes and FILE_ATTRIBUTE_DIRECTORY) <> 0 then
            if not SafeBundleTree(AddBackslash(Path) + Entry.Name) then begin
              Result := False;
              Exit;
            end;
        end;
      until not FindNext(Entry);
    finally
      FindClose(Entry);
    end;
  end;
end;

function OwnedTransactionFile(Name: String): Boolean;
var
  I: Integer;
begin
  Result := (Name = 'install-pending.json') or (Name = 'rejected-versions.json');
  if Result then Exit;
  Result := (Length(Name) = 44) and (Copy(Name, 1, 6) = '.full-') and
    (Copy(Name, 39, 6) = '.nupkg');
  if Result then begin
    for I := 7 to 38 do
      if Pos(Name[I], '0123456789abcdef') = 0 then begin
        Result := False;
        Exit;
      end;
    Exit;
  end;
  Result := (Length(Name) = 44) and (Copy(Name, 1, 8) = '.helper-') and
    ((Copy(Name, 41, 4) = '.bak') or (Copy(Name, 41, 4) = '.tmp'));
  if Result then
    for I := 9 to 40 do
      if Pos(Name[I], '0123456789abcdef') = 0 then begin
        Result := False;
        Exit;
      end;
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Entry: TFindRec;
  Path: String;
begin
  if CurUninstallStep <> usPostUninstall then Exit;
  // Only executable bundles owned by this installation. Profiles live elsewhere.
  if FindFirst(ExpandConstant('{app}\*'), Entry) then begin
    try
      repeat
        if ((Entry.Attributes and FILE_ATTRIBUTE_DIRECTORY) <> 0) and
           ((Entry.Name = 'current') or
            (Copy(Entry.Name, 1, 9) = 'previous-') or
            (Copy(Entry.Name, 1, 7) = '.stage-') or
            (Copy(Entry.Name, 1, 10) = '.download-')) then begin
          Path := ExpandConstant('{app}\') + Entry.Name;
          if SafeBundleTree(Path) then DelTree(Path, True, True, True);
        end else if ((Entry.Attributes and FILE_ATTRIBUTE_DIRECTORY) = 0) and
          OwnedTransactionFile(Entry.Name) then
          DeleteFile(ExpandConstant('{app}\') + Entry.Name);
      until not FindNext(Entry);
    finally
      FindClose(Entry);
    end;
  end;
end;

procedure DeinitializeUninstall;
begin
  ReleaseLocks;
  if not HasLinkedAncestor(ExpandConstant('{app}\setup.lock')) then
    DeleteFile(ExpandConstant('{app}\setup.lock'));
  if not HasLinkedAncestor(ExpandConstant('{app}\prepare.lock')) then
    DeleteFile(ExpandConstant('{app}\prepare.lock'));
  if not HasLinkedAncestor(ExpandConstant('{app}')) then
    RemoveDir(ExpandConstant('{app}'));
end;
