using System.Diagnostics;
using System.Security.Cryptography;
using System.Text.Json;

namespace Doorlight.Setup;

internal sealed class SetupWindow : DoorlightWindow
{
    private readonly SetupOptions options;
    private readonly SetupSession session;
    private readonly NativeText heading;
    private readonly NativeText status;
    private readonly NativeText filename;
    private readonly NativeButton action;
    private readonly NativeButton cancel;
    private readonly NativeProgress visual;
    private readonly CancellationTokenSource cancellation = new();
    private bool running, applying, completed, appExited, appRestored;
    private bool needsInstaller;
    private bool presentationShown;
    private Process? candidate;
    private InstallTransaction? pending;
    private readonly UiTimer heartbeat;

    internal SetupWindow(SetupOptions options, SetupSession session) : base(options.Motion)
    {
        heading = new(this, 1); status = new(this, 2); filename = new(this, 3);
        action = new(this, 4); cancel = new(this, 5); visual = new(this);
        heartbeat = new() { Interval = 2000 };
        heading.Text = "Doorlight"; action.Text = "Try again"; action.Visible = false; cancel.Text = "Cancel";
        this.options = options;
        this.session = session;
        presentationShown = !options.Silent;
        heartbeat.Tick += async (_, _) => {
            try
            {
                session.Heartbeat();
                var command = session.Read("window-command.json", WindowsJsonContext.Default.UpdateCommand);
                if (command?.Schema == 1 && command.Action is "show" or "retry" or "close")
                {
                    File.Delete(Path.Combine(session.DirectoryPath, "window-command.json"));
                    if (command.Action == "close" && !running && pending is null) { Close(); return; }
                    presentationShown = true;
                    NativeWindow.ShowWindow(Handle, 5);
                    if (command.Action == "retry" && !running && pending is null) await Run();
                }
            }
            catch (Exception io) when (io is IOException or UnauthorizedAccessException) { /* A short-lived reader can temporarily hold a protocol file. */ }
            catch (JsonException) { /* Invalid window commands cannot interrupt a transaction. */ }
        };
        heartbeat.Start();
        action.Click += async (_, _) => {
            if (pending is not null) await RestoreAndOpen();
            else if (completed) await OpenExisting();
            else await Run();
        };
        cancel.Click += (_, _) => { if (running) cancellation.Cancel(); else Close(); };
        Licenses += (_, _) => {
            var path = Path.Combine(InstalledApp.Root, "LICENSE.txt");
            try { Process.Start(new ProcessStartInfo(path) { UseShellExecute = true }); }
            catch (Exception e) when (e is IOException or System.ComponentModel.Win32Exception) { status.Text = "The license is included with your installer."; }
        };
        Started += async (_, _) => {
            if (options.Silent) Hide();
            else NativeWindow.ShowWindow(Handle, 5);
            await Run();
        };
        CloseRequested = () => {
            if (!running && !applying) return false;
            if (!applying) cancellation.Cancel();
            return true;
        };
        ActionClicked += (_, _) => action.InvokeClick();
        CancelClicked += (_, _) => cancel.InvokeClick();
    }

    private void Report(string phase, string text, string version = "", InstallProgress? value = null)
    {
        status.Text = text;
        if (value is not null) {
            filename.Text = Path.GetFileName(value.File);
            var fraction = value.TotalBytes <= 0 ? 0 : Math.Clamp((double)value.CompletedBytes / value.TotalBytes, 0, 1);
            visual.Fraction = phase switch {
                "downloading" => value.File.EndsWith(".json", StringComparison.OrdinalIgnoreCase) ? 0 : .65 * fraction,
                "installing" => .85 * fraction,
                "verifying" => (options.Install ? .85 : .65) + (options.Install ? .10 : .30) * fraction,
                _ => visual.Fraction,
            };
        }
        if (phase is "applying" or "starting") visual.Fraction = .95;
        if (value is null && phase is "ready" or "applying" or "starting" or "done" or "cancelled") filename.Text = "";
        if (phase == "done") visual.Fraction = 1;
        try { session.Publish(phase, version, value, text); }
        catch (Exception io) when ((value is not null || phase is "done" or "error" or "cancelled") &&
            io is IOException or UnauthorizedAccessException)
        {
            // Progress callbacks run outside Run's awaited error handler.
            // A temporary reader lock must not become an unhandled UI error.
            // Heartbeat retries the latest status; handoff writes stay strict.
        }
    }

    private async Task Run()
    {
        if (running) return;
        running = true; action.Visible = false; cancel.Enabled = true; cancel.Text = "Cancel";
        visual.Active = true;
        try
        {
            InstalledApp.ValidateLocation();
            session.Publish("preparing");
            if (options.Install) await InstallFromEngine();
            else await RunUpdate();
            completed = true;
            Environment.ExitCode = 0;
            Report("done", "Opening Doorlight…");
            CloseAfterRun = true;
        }
        catch (OperationCanceledException)
        {
            if (options.Install) TryEngineCommand("cancel");
            Report("cancelled", "Cancelled. Your profile was kept.");
            Environment.ExitCode = 2;
            action.Visible = false;
            cancel.Text = "Close";
        }
        catch (Exception exception)
        {
            try {
                var details = exception.ToString();
                session.Write("failure.json", new SetupFailure(exception.GetType().Name, details[..Math.Min(details.Length, 16384)],
                    exception.HResult, exception.Data["BundleMove"] as string), WindowsJsonContext.Default.SetupFailure);
            }
            catch (Exception diagnostic) when (diagnostic is IOException or UnauthorizedAccessException) { /* Recovery must remain available if diagnostics cannot be saved. */ }
            if (options.Install) TryEngineCommand("cancel");
            needsInstaller = options.Install && pending is null;
            if (appExited && pending is null && !appRestored)
            {
                try
                {
                    using (InstalledApp.Lock(InstalledApp.Root, "setup.lock"))
                    using (InstalledApp.Lock(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Syb-L"), "instance.lock"))
                        await Task.Run(() => BundleInstall.Recover(InstalledApp.Root));
                    using var restored = InstalledApp.Start();
                    appRestored = true;
                }
                catch (Exception recovery) when (recovery is IOException or InvalidDataException or System.ComponentModel.Win32Exception) { }
            }
            var message = appRestored
                ? "The update could not start. Your previous version is open."
                : needsInstaller
                ? "Setup could not finish. Run the downloaded installer again. Your profile was kept."
                : pending is not null
                ? pending.Previous is null
                    ? "Doorlight could not confirm startup. Quit it, then run the installer again."
                    : "Doorlight could not confirm startup. Quit it, then restore the previous version."
                : exception is TimeoutException
                    ? "The update timed out. Try again."
                : exception is InvalidDataException
                    ? "This package could not be verified. Download a fresh installer."
                    : "Could not finish. Close other installers, check free space and try again.";
            Report("error", message);
            Environment.ExitCode = 1;
            cancel.Text = "Close";
            action.Text = pending is null ? "Try again" : "Restore previous version";
            action.Visible = !needsInstaller && !cancellation.IsCancellationRequested && pending?.Previous is not null;
            if (!options.Install && pending is null)
                action.Visible = !appExited && !appRestored && !cancellation.IsCancellationRequested;
        }
        finally
        {
            running = false; applying = false; visual.Active = false;
            cancel.Enabled = true;
            if (CloseAfterRun || !presentationShown) Close();
        }
    }

    private bool CloseAfterRun;

    private async Task InstallFromEngine()
    {
        session.Write("engine-worker.json", new EngineWorker(1, Environment.ProcessId), WindowsJsonContext.Default.EngineWorker);
        using var engine = Process.GetProcessById(options.EnginePid!.Value);
        // Keep the external process handle open so .NET can read its exit code
        // after Inno exits; a PID-only Process loses that information.
        using var engineHandle = engine.SafeHandle;
        PackageManifest manifest;
        DistributionRuntime? runtime = null;
        DistributionPrepared? prepared = null;
        try
        {
            if (options.Online)
            {
                using var preparation = InstalledApp.Lock(InstalledApp.Root, "prepare.lock");
                runtime = DistributionRuntime.Load();
                Report("downloading", "Downloading Doorlight…");
                var decision = await runtime.Check("0.0.0", true, cancellation.Token);
                if (decision?.Eligible != true) throw new InvalidDataException("No eligible installation is available.");
                var currentPath = Path.Combine(InstalledApp.Root, "current");
                var currentVersion = Directory.Exists(currentPath) ? PackageStage.ReadVersion(currentPath) : "0.0.0";
                using var progress = new SetupProgress(value => Report("downloading", "Downloading Doorlight…", decision.Release.Policy.Version, value));
                prepared = await runtime.Prepare(decision, currentVersion, progress, cancellation.Token);
                manifest = prepared.Manifest;
            }
            else
            {
                using var metadata = File.OpenRead(options.Manifest!);
                manifest = PackageManifest.Read(metadata);
            }
            if (File.Exists(Path.Combine(InstalledApp.Root, "install-pending.json")))
            {
                using (InstalledApp.Lock(InstalledApp.Root, "setup.lock"))
                using (InstalledApp.Lock(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Syb-L"), "instance.lock"))
                    await Task.Run(() => BundleInstall.Recover(InstalledApp.Root));
            }
            var existing = Path.Combine(InstalledApp.Root, "current");
            var open = false;
            if (Directory.Exists(existing))
            {
                try
                {
                    var installed = PackageStage.ReadVersion(existing);
                    if (Version.Parse(installed) > Version.Parse(manifest.Version)) open = true;
                    else if (installed == manifest.Version)
                    {
                        Report("verifying", "Checking Doorlight…", installed);
                        await Task.Run(() => PackageStage.VerifyDirectory(manifest, existing, null, cancellation.Token));
                        var bundled = Path.Combine(existing, "_setup", "DoorlightUpdater.exe");
                        var stable = Path.Combine(InstalledApp.Root, "DoorlightUpdater.exe");
                        using var a = File.OpenRead(bundled); using var b = File.OpenRead(stable);
                        open = CryptographicOperations.FixedTimeEquals(SHA256.HashData(a), SHA256.HashData(b));
                    }
                }
                catch (Exception e) when (e is IOException or InvalidDataException) { open = false; }
            }
            if (prepared is not null)
            {
                var refreshed = await runtime!.Refresh(prepared, "0.0.0", true, cancellation.Token);
                if (!refreshed.Eligible) throw new InvalidDataException("This installation is no longer available.");
                if (!open)
                {
                    var destination = Path.Combine(InstalledApp.Root, options.Stage!);
                    PackageStage.RejectLinkedAncestors(destination);
                    Directory.Move(prepared.StageDirectory, destination);
                    prepared = prepared with { StageDirectory = destination };
                }
                else RemovePreparedStage(prepared.Manifest, prepared.StageDirectory);
            }
            engine.Refresh();
            if (engine.HasExited) throw new IOException("The installation engine closed.");
            TryEngineCommand(open ? "open" : "start");
            while (!engine.HasExited)
            {
                cancellation.Token.ThrowIfCancellationRequested();
                var state = TryReadEngine();
                if (state is not null)
                {
                    if (state.Schema != 1 || state.Stage != options.Stage) throw new InvalidDataException("Installation session changed.");
                    if (state.State == "blocked")
                    {
                        Report("blocked", state.Message);
                        action.Text = "Try again"; action.Visible = true;
                        action.Click -= RetryEngine;
                        action.Click += RetryEngine;
                    }
                    else
                    {
                        action.Visible = false;
                        Report("installing", open ? "Opening Doorlight…" : "Installing Doorlight…", manifest.Version,
                            new(state.File, state.Completed, state.Total));
                    }
                    if (state.State == "error") throw new IOException("Installation engine failed.");
                }
                await Task.Delay(100, cancellation.Token);
                engine.Refresh();
            }
            action.Click -= RetryEngine;
            if (open)
            {
                if (engine.ExitCode is not (0 or 2)) throw new IOException("Installation could not close.");
                await OpenExisting();
                return;
            }
            if (engine.ExitCode != 0 || TryReadEngine()?.State != "complete") throw new IOException("Installation did not finish.");
            var stage = Path.Combine(InstalledApp.Root, options.Stage!);
            Report("verifying", "Checking the installation…", manifest.Version);
            using (var progress = new SetupProgress(value => Report("verifying", "Checking the installation…", manifest.Version, value)))
                await Task.Run(() => PackageStage.VerifyDirectory(manifest, stage, progress.Report, cancellation.Token));
            WindowsExecutable.Validate(Path.Combine(stage, "sybl.exe"));
            WindowsExecutable.Validate(Path.Combine(stage, "_setup", "DoorlightUpdater.exe"));
            if (prepared is not null && !(await runtime!.Refresh(prepared, "0.0.0", true, cancellation.Token)).Eligible)
                throw new InvalidDataException("This installation is no longer available.");
            await ApplyAndOpen(stage, manifest.Version, null, allowRepair: true, runtime: runtime, prepared: prepared);
        }
        finally
        {
            try
            {
                if (prepared is not null && Directory.Exists(prepared.StageDirectory) &&
                    !File.Exists(Path.Combine(InstalledApp.Root, "install-pending.json")))
                {
                    try { RemovePreparedStage(prepared.Manifest, prepared.StageDirectory); }
                    catch (Exception cleanup) when (cleanup is IOException or UnauthorizedAccessException or InvalidDataException)
                    { Trace.TraceWarning("Keeping the unverifiable or locked installation stage: {0}", cleanup.Message); }
                }
            }
            finally
            {
                if (prepared is not null) DistributionRuntime.Discard(prepared);
            }
        }
    }

    private void RetryEngine(object? sender, EventArgs args)
    {
        action.Visible = false;
        TryEngineCommand("start");
    }

    private EngineStatus? TryReadEngine()
    {
        try { return session.Read("engine.json", WindowsJsonContext.Default.EngineStatus); }
        catch (JsonException) { return null; }
        catch (IOException) { return null; }
    }

    private void TryEngineCommand(string action)
    {
        try { session.Write("engine-command.json", new UpdateCommand(1, action), WindowsJsonContext.Default.UpdateCommand); }
        catch (Exception io) when (io is IOException or UnauthorizedAccessException) { if (action != "cancel") throw; }
    }

    private async Task RunUpdate()
    {
        var request = session.Read("request.json", WindowsJsonContext.Default.UpdateRequest);
        if (options.Package is null && request is null) throw new InvalidDataException("The update request is missing.");
        if (request is not null && (request.Schema != 1 || request.AppPid <= 0 ||
            !System.Text.RegularExpressions.Regex.IsMatch(request.Version, @"^\d+\.\d+\.\d+\z") ||
            (request.Identity != "" && !System.Text.RegularExpressions.Regex.IsMatch(request.Identity, @"^[0-9a-f]{40}\z"))))
            throw new InvalidDataException("Invalid update request.");
        // Pin this process instance before preparing. Reopening its PID after a
        // long download could observe an unrelated process that reused the ID.
        using var requestApp = request is null ? null : TryProcess(request.AppPid);
        using var requestAppHandle = requestApp?.SafeHandle;
        if (request is not null)
        {
            if (requestApp is null || requestApp.HasExited) throw new OperationCanceledException();
            var ui = SynchronizationContext.Current!;
            requestApp.Exited += (_, _) => {
                ui.Post(_ => { if (!applying && !IsDisposed) cancellation.Cancel(); }, null);
            };
            requestApp.EnableRaisingEvents = true;
        }
        if (request?.Automatic == true && BundleInstall.IsRejected(InstalledApp.Root, request.Version))
            throw new InvalidDataException("This release requires an explicit retry.");
        if (File.Exists(Path.Combine(InstalledApp.Root, "install-pending.json")))
            throw new IOException("Recover the unfinished update before starting another.");
        var version = request?.Version ?? options.Release;
        var installed = PackageStage.ReadVersion(Path.Combine(InstalledApp.Root, "current"));
        using var preparation = InstalledApp.Lock(InstalledApp.Root, "prepare.lock");
        DistributionRuntime? runtime = null;
        DistributionPrepared? prepared = null;
        try
        {
            PackageManifest manifest;
            string stage;
            if (options.Package is null)
            {
                if (request?.ReleaseSequence is null or <= 0 || request.ManifestSha256 is null ||
                    !System.Text.RegularExpressions.Regex.IsMatch(request.ManifestSha256, @"^[0-9a-f]{64}\z"))
                    throw new InvalidDataException("The signed update selection is missing.");
                runtime = DistributionRuntime.Load();
                var decision = await runtime.Check(installed, !request.Automatic, cancellation.Token);
                if (decision?.Eligible != true || decision.Release.Policy.Version != version ||
                    decision.Release.Policy.ReleaseSequence != request.ReleaseSequence ||
                    decision.Release.Policy.Manifest.Sha256 != request.ManifestSha256)
                    throw new InvalidDataException("The selected update is no longer available.");
                Report("downloading", "Downloading your update…", version!);
                using var progress = new SetupProgress(value => Report("downloading", "Downloading your update…", version!, value));
                prepared = await runtime.Prepare(decision, installed, progress, cancellation.Token);
                manifest = prepared.Manifest;
                stage = prepared.StageDirectory;
            }
            else
            {
                using var metadata = File.OpenRead(options.Manifest!);
                manifest = PackageManifest.Read(metadata);
                if (version is not null && manifest.Version != version) throw new InvalidDataException("The release version changed.");
                if (Version.Parse(manifest.Version) <= Version.Parse(installed)) throw new InvalidDataException("Only newer updates can be installed.");
                Report("verifying", "Checking your update…", manifest.Version);
                using var progress = new SetupProgress(value => Report("verifying", "Checking your update…", manifest.Version, value));
                stage = await Task.Run(() => {
                    using var archive = File.OpenRead(options.Package);
                    return PackageStage.Extract(archive, manifest, InstalledApp.Root, progress.Report, cancellation.Token);
                });
            }
            FileStream? commitLease = null;
            string? shutdownIdentity = null;
            try
            {
            WindowsExecutable.Validate(Path.Combine(stage, "sybl.exe"));
            WindowsExecutable.Validate(Path.Combine(stage, "_setup", "DoorlightUpdater.exe"));
            if (request is not null)
            {
                Report("ready", "Ready when Doorlight is idle.", manifest.Version);
                while (true)
                {
                    cancellation.Token.ThrowIfCancellationRequested();
                    var parent = requestApp!;
                    parent.Refresh();
                    // A normal quit is not permission to install against an old
                    // identity snapshot. Only the reserved handoff may apply it.
                    if (parent.HasExited) throw new OperationCanceledException();
                    var command = session.Read("command.json", WindowsJsonContext.Default.UpdateCommand);
                    if (command?.Schema == 1 && command.Action == "cancel") throw new OperationCanceledException();
                    if (command?.Schema == 1 && command.Action == "apply")
                    {
                        if (command.Identity is null || !System.Text.RegularExpressions.Regex.IsMatch(command.Identity, @"^[0-9a-f]{40}\z"))
                            throw new InvalidDataException("The update identity is missing.");
                        if (prepared is not null)
                        {
                            // Stay within the app's ten-second reservation. A slow
                            // feed leaves Doorlight open; cached policy cannot bypass it.
                            using var refreshDeadline = CancellationTokenSource.CreateLinkedTokenSource(cancellation.Token);
                            refreshDeadline.CancelAfter(TimeSpan.FromSeconds(8));
                            if (!(await runtime!.Refresh(prepared, installed, !request.Automatic, refreshDeadline.Token)).Eligible)
                                throw new InvalidDataException("This update is no longer available.");
                        }
                        var confirmed = session.Read("command.json", WindowsJsonContext.Default.UpdateCommand);
                        parent.Refresh();
                        if (parent.HasExited || confirmed?.Schema != 1 || confirmed.Action != "apply" || confirmed.Identity != command.Identity)
                            throw new OperationCanceledException();
                        shutdownIdentity = command.Identity;
                        commitLease = InstalledApp.Lock(InstalledApp.Root, "setup.lock");
                        presentationShown = true;
                        applying = true;
                        cancel.Enabled = false;
                        NativeWindow.ShowWindow(Handle, 5);
                        Report("shutdownReady", "Waiting for Doorlight to close…", manifest.Version);
                        var deadline = Stopwatch.StartNew();
                        while (!parent.HasExited && deadline.Elapsed < TimeSpan.FromSeconds(60))
                        {
                            if (session.Read("command.json", WindowsJsonContext.Default.UpdateCommand)?.Action == "cancel") throw new OperationCanceledException();
                            await Task.Delay(100, cancellation.Token); parent.Refresh();
                        }
                        if (!parent.HasExited) throw new IOException("Doorlight did not close.");
                        appExited = true;
                        break;
                    }
                    await Task.Delay(100, cancellation.Token);
                }
            }
            else if (options.WaitPid is int pid)
            {
                using var parent = TryProcess(pid);
                if (parent is not null) await parent.WaitForExitAsync(cancellation.Token).WaitAsync(TimeSpan.FromSeconds(60), cancellation.Token);
                appExited = true;
            }
            if (request is null && prepared is not null && !(await runtime!.Refresh(prepared, installed, true, cancellation.Token)).Eligible)
                throw new InvalidDataException("This update is no longer available.");
            commitLease ??= InstalledApp.Lock(InstalledApp.Root, "setup.lock");
            await ApplyAndOpen(stage, manifest.Version, shutdownIdentity, allowRepair: false, setupHeld: true, runtime: runtime, prepared: prepared);
            }
            catch
            {
                if (!File.Exists(Path.Combine(InstalledApp.Root, "install-pending.json")) && Directory.Exists(stage))
                {
                    // Delete only the complete, verified bundle this worker created.
                    // Failed preparation, including a failed readiness publication,
                    // must not accumulate a full bundle on every retry.
                    try
                    {
                        PackageStage.VerifyDirectory(manifest, stage);
                        Directory.Delete(stage, recursive: true);
                    }
                    catch (Exception cleanup) when (cleanup is IOException or UnauthorizedAccessException or InvalidDataException)
                    {
                        Trace.TraceWarning("Keeping the unverifiable or locked preparation stage: {0}", cleanup.Message);
                    }
                }
                throw;
            }
            finally { commitLease?.Dispose(); }
        }
        finally
        {
            if (prepared is not null) DistributionRuntime.Discard(prepared);
        }
    }

    private static void RemovePreparedStage(PackageManifest manifest, string stage)
    {
        PackageStage.VerifyDirectory(manifest, stage);
        Directory.Delete(stage, recursive: true);
    }

    private static Process? TryProcess(int pid)
    {
        try { return Process.GetProcessById(pid); }
        catch (ArgumentException) { return null; }
    }

    private async Task ApplyAndOpen(string stage, string version, string? identity, bool allowRepair, bool setupHeld = false,
        DistributionRuntime? runtime = null, DistributionPrepared? prepared = null)
    {
        using var setup = setupHeld ? null : InstalledApp.Lock(InstalledApp.Root, "setup.lock");
        applying = true; cancel.Enabled = false;
        Report("applying", "Installing Doorlight…", version);
        using (InstalledApp.Lock(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Syb-L"), "instance.lock"))
        {
            pending = await Task.Run(() => {
                BundleInstall.Recover(InstalledApp.Root);
                return BundleInstall.Apply(InstalledApp.Root, stage, version, allowRepair);
            });
        }
        Report("starting", "Opening Doorlight…", version);
        var readyPath = Path.Combine(session.DirectoryPath, "ready.json");
        if (File.Exists(readyPath)) File.Delete(readyPath);
        try { candidate = InstalledApp.Start(session); }
        catch (Exception startFailure) when (startFailure is IOException or System.ComponentModel.Win32Exception)
        {
            await RollbackExitedCandidate();
            throw;
        }
        var deadline = Stopwatch.StartNew();
        while (!candidate.HasExited && deadline.Elapsed < TimeSpan.FromSeconds(45))
        {
            var ready = session.Read("ready.json", WindowsJsonContext.Default.StartupReady);
            if (ready?.Schema == 1 && ready.Pid == candidate.Id && ready.Version == version && ready.Ready &&
                (string.IsNullOrEmpty(identity) || ready.Identity == identity))
            {
                if (!await Task.Run(() => NativeWindow.WaitForVisible(candidate, Handle, TimeSpan.FromSeconds(5))))
                    throw new IOException("Doorlight did not present its window.");
                candidate.Refresh();
                if (candidate.HasExited) throw new IOException("Doorlight exited before startup acceptance.");
                BundleInstall.Accept(InstalledApp.Root, pending.Id);
                pending = null;
                if (prepared is not null) await runtime!.Accept(prepared, CancellationToken.None);
                visual.Fraction = 1;
                // Present the completed door before removing the setup surface.
                await Task.Delay(180);
                return;
            }
            await Task.Delay(100); candidate.Refresh();
        }
        if (candidate.HasExited)
            await RollbackExitedCandidate();
        throw new IOException("Doorlight did not acknowledge startup.");
    }

    private async Task RollbackExitedCandidate()
    {
        if (pending is null) return;
        var firstInstall = pending.Previous is null;
        var transactionId = pending.Id;
        using (InstalledApp.Lock(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Syb-L"), "instance.lock"))
            await Task.Run(() => BundleInstall.Rollback(InstalledApp.Root, transactionId));
        pending = null;
        if (firstInstall) { needsInstaller = true; return; }
        using var restored = InstalledApp.Start();
        appRestored = await Task.Run(() => NativeWindow.WaitForVisible(restored, IntPtr.Zero, TimeSpan.FromSeconds(20), true));
    }

    private async Task OpenExisting()
    {
        try
        {
            using var setup = InstalledApp.Lock(InstalledApp.Root, "setup.lock");
            using var app = InstalledApp.Start();
            if (!await Task.Run(() => NativeWindow.WaitForVisible(app, Handle, TimeSpan.FromSeconds(20), true)))
                throw new IOException("Doorlight did not open.");
            completed = true; CloseAfterRun = true;
        }
        catch (Exception e) when (e is IOException or System.ComponentModel.Win32Exception)
        {
            status.Text = "Doorlight could not open. Close other installers and try again.";
            action.Text = "Open Doorlight"; action.Visible = true;
            throw;
        }
    }

    private async Task RestoreAndOpen()
    {
        if (pending is null || running) return;
        if (candidate is not null && !candidate.HasExited) {
            status.Text = "Quit Doorlight from its tray menu, then restore the previous version.";
            return;
        }
        var transactionId = pending.Id;
        running = applying = true;
        action.Enabled = cancel.Enabled = false;
        visual.Active = true;
        try
        {
            using (InstalledApp.Lock(InstalledApp.Root, "setup.lock"))
            using (InstalledApp.Lock(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Syb-L"), "instance.lock"))
                await Task.Run(() => BundleInstall.Rollback(InstalledApp.Root, transactionId));
            pending = null;
            await OpenExisting();
        }
        catch (Exception e) when (e is IOException or InvalidDataException or System.ComponentModel.Win32Exception) {
            status.Text = "Recovery is waiting. Close Doorlight and other installers, then try again.";
        }
        finally
        {
            running = applying = false;
            if (!IsDisposed) { action.Enabled = cancel.Enabled = true; visual.Active = false; }
            if (CloseAfterRun) Close();
        }
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) { heartbeat.Dispose(); cancellation.Dispose(); candidate?.Dispose(); }
        base.Dispose(disposing);
    }
}
