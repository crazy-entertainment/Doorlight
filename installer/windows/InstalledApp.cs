using System.Diagnostics;

namespace Doorlight.Setup;

internal static class InstalledApp
{
    internal static string Root => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "Doorlight");

    internal static FileStream Lock(string directory, string name)
    {
        PackageStage.RejectLinkedAncestors(directory);
        Directory.CreateDirectory(directory);
        var path = Path.Combine(directory, name);
        PackageStage.RejectLinkedAncestors(path);
        return new FileStream(path, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
    }

    internal static void ValidateLocation()
    {
        PackageStage.RejectLinkedAncestors(Root);
    }

    internal static Process Start(SetupSession? session = null)
    {
        var current = Path.Combine(Root, "current");
        var executable = Path.Combine(current, "sybl.exe");
        PackageStage.RejectLinkedAncestors(executable);
        var start = new ProcessStartInfo(executable) { WorkingDirectory = current, UseShellExecute = false };
        start.Environment.Remove("DOORLIGHT_SETUP_SESSION");
        if (session is not null) start.Environment["DOORLIGHT_SETUP_SESSION"] = session.Id;
        return Process.Start(start)
            ?? throw new IOException("Doorlight could not start.");
    }

    internal static void RecoverAndLaunch()
    {
        ValidateLocation();
        using (var setup = Lock(Root, "setup.lock"))
        {
            // A running app holds the profile lock. Normal launches still forward
            // to that instance; only interrupted transactions require exclusivity.
            if (File.Exists(Path.Combine(Root, "install-pending.json")))
            {
                var local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
                using var profile = Lock(Path.Combine(local, "Syb-L"), "instance.lock");
                var recovered = BundleInstall.Recover(Root);
                if (recovered?.FirstInstall == true)
                    throw new InvalidOperationException("The interrupted installation was preserved. Run the Doorlight installer again to finish.");
            }
            if (!File.Exists(Path.Combine(Root, "current", "sybl.exe")))
                throw new InvalidOperationException("Doorlight is not installed completely. Run the installer again. Your profile was kept.");
            using var app = Start();
            try { app.WaitForInputIdle(10000); }
            catch (InvalidOperationException) when (app.HasExited) {
                // A second-instance launch forwards to the already running app.
            }
        }
    }
}
