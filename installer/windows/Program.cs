using System.Diagnostics;
using System.Text.RegularExpressions;

namespace Doorlight.Setup;

internal static class Program
{
    [STAThread]
    private static void Main(string[] args)
    {
        NativeUi.Initialize();
        try
        {
            var options = SetupOptions.Parse(args);
            if (options.CleanupPid is int cleanupPid)
            {
                try { using var process = Process.GetProcessById(cleanupPid); if (!process.WaitForExit(60000)) return; }
                catch (ArgumentException) { }
                try { SetupSession.Cleanup(options.Session!); }
                catch (IOException) { /* A session still in use can be pruned later. */ }
                catch (UnauthorizedAccessException) { /* Cleanup must not interrupt the app. */ }
                return;
            }
            if (options.Launch && !File.Exists(Path.Combine(InstalledApp.Root, "install-pending.json")))
            {
                InstalledApp.RecoverAndLaunch();
                return;
            }
            var session = new SetupSession(options.Session);
            if (!options.Worker)
            {
                SetupSession.Prune();
                // Run outside current and the stable launcher so both can be replaced.
                var source = Environment.ProcessPath ?? throw new IOException("Setup executable is missing.");
                PackageStage.RejectLinkedAncestors(source);
                File.Copy(source, session.WorkerPath, false);
                var start = new ProcessStartInfo(session.WorkerPath) { UseShellExecute = false, WorkingDirectory = session.DirectoryPath };
                foreach (var arg in args) start.ArgumentList.Add(arg);
                if (options.Session is null) { start.ArgumentList.Add("--session"); start.ArgumentList.Add(session.Id); }
                start.ArgumentList.Add("--worker");
                start.ArgumentList.Add("--bootstrap-pid");
                start.ArgumentList.Add(Environment.ProcessId.ToString());
                using var worker = Process.Start(start) ?? throw new IOException("Setup could not start.");
                return;
            }
            if (!string.Equals(Path.GetFullPath(Environment.ProcessPath!), session.WorkerPath, StringComparison.OrdinalIgnoreCase))
                throw new IOException("The setup worker is outside its session.");
            if (options.BootstrapPid is int bootstrapPid)
            {
                try { using var bootstrap = Process.GetProcessById(bootstrapPid); if (!bootstrap.WaitForExit(10000)) throw new IOException("The setup bootstrap is still open."); }
                catch (ArgumentException) { }
            }
            if (options.Check)
            {
                CheckRelease(options).GetAwaiter().GetResult();
                return;
            }
            if (options.Launch)
            {
                InstalledApp.RecoverAndLaunch();
                ScheduleCleanup(session);
                return;
            }
            using (var window = new SetupWindow(options, session)) window.RunMessageLoop();
            if (Environment.ExitCode == 0) ScheduleCleanup(session);
        }
        catch (Exception exception)
        {
            if (!args.Contains("--check", StringComparer.Ordinal)) NativeUi.ShowError(exception is IOException ? "Doorlight could not finish setup. Close other installers and try again. Your profile was kept." : exception.Message);
            Environment.ExitCode = 1;
        }
    }

    private static async Task CheckRelease(SetupOptions options)
    {
        var session = new SetupSession(options.Session);
        UpdateCheck result;
        try
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(75));
            var runtime = DistributionRuntime.Load();
            var decision = await runtime.Check(options.CurrentVersion!, options.Manual, timeout.Token);
            result = decision is null
                ? new(1, Environment.ProcessId, "", false, 0, "", "Updates are not configured.", "checked")
                : new(1, Environment.ProcessId, decision.Release.Policy.Version, decision.Eligible,
                    decision.Release.Policy.ReleaseSequence, decision.Release.Policy.Manifest.Sha256,
                    decision.Reason, "checked");
        }
        catch (Exception)
        {
            result = new(1, Environment.ProcessId, "", false, 0, "", "Could not check for updates.", "error");
            Environment.ExitCode = 1;
        }
        session.Write("check.json", result, WindowsJsonContext.Default.UpdateCheck);
    }

    private static void ScheduleCleanup(SetupSession session)
    {
        var helper = Path.Combine(InstalledApp.Root, "DoorlightUpdater.exe");
        if (!File.Exists(helper)) return;
        try
        {
            var start = new ProcessStartInfo(helper) { UseShellExecute = false, CreateNoWindow = true };
            foreach (var argument in new[] { "--cleanup", Environment.ProcessId.ToString(), "--session", session.Id }) start.ArgumentList.Add(argument);
            using var cleanup = Process.Start(start);
        }
        catch (System.ComponentModel.Win32Exception) { /* A locked session remains local for repair. */ }
    }
}

internal sealed record SetupOptions(string? Package, string? Manifest, bool Silent, bool Motion,
    string? Release, int? WaitPid, bool Launch, bool Install, string? Session,
    bool Worker, int? EnginePid, long? EngineWindow, string? Stage, int? CleanupPid, int? BootstrapPid,
    bool Check = false, string? CurrentVersion = null, bool Manual = false, bool Online = false)
{
    internal static SetupOptions Parse(string[] args)
    {
        string? package = null, manifest = null, release = null, session = null, stage = null;
        int? waitPid = null, enginePid = null, cleanupPid = null, bootstrapPid = null;
        long? engineWindow = null;
        var update = false; var install = false; var launch = false;
        var check = false; var manual = false; var online = false; string? currentVersion = null;
        var silent = false; var motion = true; var worker = false;
        string Value(ref int i) => ++i < args.Length ? args[i] : throw new ArgumentException("Incomplete setup command.");
        for (var i = 0; i < args.Length; i++)
        {
            switch (args[i])
            {
                case "--package": package = Path.GetFullPath(Value(ref i)); break;
                case "--manifest": manifest = Path.GetFullPath(Value(ref i)); break;
                case "--release": release = Value(ref i); break;
                case "--session": session = Value(ref i); break;
                case "--stage": stage = Value(ref i); break;
                case "--wait-pid": waitPid = int.Parse(Value(ref i)); break;
                case "--engine-pid": enginePid = int.Parse(Value(ref i)); break;
                case "--engine-window": engineWindow = long.Parse(Value(ref i)); break;
                case "--cleanup": cleanupPid = int.Parse(Value(ref i)); break;
                case "--bootstrap-pid": bootstrapPid = int.Parse(Value(ref i)); break;
                case "--handoff-window": engineWindow = long.Parse(Value(ref i)); break;
                case "--check": check = true; break;
                case "--current-version": currentVersion = Value(ref i); break;
                case "--manual": manual = true; break;
                case "--online": online = true; break;
                case "--update": update = true; break;
                case "--install": install = true; break;
                case "--launch": launch = true; break;
                case "--silent": silent = true; break;
                case "--no-motion": motion = false; break;
                case "--worker": worker = true; break;
                default: throw new ArgumentException("This setup command is not supported.");
            }
        }
        if (cleanupPid is not null)
        {
            if (cleanupPid <= 0 || session is null || launch || install || update || worker || check) throw new ArgumentException("Invalid cleanup command.");
        }
        else if ((launch ? 1 : 0) + (install ? 1 : 0) + (update ? 1 : 0) + (check ? 1 : 0) != 1)
            throw new ArgumentException("Start updates from Doorlight, or run the Doorlight installer.");
        if ((package is null) != (manifest is null) && !install) throw new ArgumentException("The update package is incomplete.");
        if (release is not null && (package is not null || !Regex.IsMatch(release, @"^\d+\.\d+\.\d+\z"))) throw new ArgumentException("Invalid release selection.");
        if (waitPid is <= 0 || enginePid is <= 0) throw new ArgumentException("Invalid application process.");
        if (install && (session is null || enginePid is null || engineWindow is null || stage is null || (!online && manifest is null) || !Regex.IsMatch(stage, @"^\.stage-[0-9a-f]{32}\z")))
            throw new ArgumentException("The installation session is incomplete.");
        if (online && (!install || package is not null || manifest is not null)) throw new ArgumentException("Invalid online installation command.");
        if (check && (session is null || currentVersion is null || !Regex.IsMatch(currentVersion, @"^\d+\.\d+\.\d+\z") ||
            !Version.TryParse(currentVersion, out _) || package is not null || manifest is not null || release is not null || waitPid is not null || enginePid is not null))
            throw new ArgumentException("Invalid update check.");
        if (!check && (currentVersion is not null || manual)) throw new ArgumentException("Invalid update check options.");
        return new(package, manifest, silent, motion, release, waitPid, launch, install, session, worker, enginePid, engineWindow, stage, cleanupPid, bootstrapPid, check, currentVersion, manual, online);
    }
}
