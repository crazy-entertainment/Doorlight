using System;
using System.Threading.Tasks;

namespace WidgetSampleCS
{
    static class DesktopOnboarding
    {
        static readonly object gate = new object();
        static readonly DesktopStatus status = new DesktopStatus();
        static bool started, busy, installing;
        static DateTime actionDeadline, statusDeadline;
        static bool awaitingStatus;
        static string feedback;
        public static event Action Changed;
        public static bool Ready => Link.HelperVersion != null;
        public static string State { get { lock (gate) return status.State; } }
        public static bool CanInstall { get { lock (gate) return status.CanInstall; } }
        public static bool Busy { get { lock (gate) return busy; } }
        public static string Feedback { get { lock (gate) return feedback; } }

        public static void Start()
        {
            lock (gate) { if (started) return; started = true; }
            Link.Received += Receive;
            Link.HelperVersionChanged += () => {
                if (Link.HelperVersion == null) { lock (gate) { status.Reset(); busy = false; awaitingStatus = false; feedback = null; } Changed?.Invoke(); }
                else Refresh();
            };
            AppearanceSync.Changed += () => {
                if (AppearanceSync.Connected) { lock (gate) { busy = false; feedback = null; } }
                else Refresh();
                Changed?.Invoke();
            };
            _ = Task.Run(async () => {
                while (true) {
                    await Task.Delay(5000);
                    bool expired = false;
                    lock (gate) {
                        if (busy && DateTime.UtcNow >= actionDeadline) { busy = false; feedback = installing ? "Couldn’t open the download page. Try again." : "Doorlight hasn’t connected yet. Try opening it again."; expired = true; }
                        if (!Ready && status.State == "checking") { status.Unavailable(); expired = true; }
                        if (awaitingStatus && DateTime.UtcNow >= statusDeadline) {
                            awaitingStatus = false;
                            if (status.State != "unknown") { status.Unavailable(); expired = true; }
                        }
                    }
                    if (expired) Changed?.Invoke();
                    if (!AppearanceSync.Connected) Refresh();
                }
            });
            Refresh();
        }
        public static void Refresh(bool manual = false) {
            if (manual) { lock (gate) { if (!busy) feedback = null; } Changed?.Invoke(); }
            if (Ready) {
                lock (gate) {
                    if (awaitingStatus) return;
                    awaitingStatus = true; statusDeadline = DateTime.UtcNow.AddSeconds(5);
                }
                Link.Send("DESKTOP_STATUS");
            }
            else if (manual) _ = Task.Run(async () => {
                try { await Windows.ApplicationModel.FullTrustProcessLauncher.LaunchFullTrustProcessForCurrentAppAsync(); }
                catch (Exception ex) { Log.Write("desktop check: " + ex.GetType().Name); }
            });
        }
        public static void Open(bool install)
        {
            bool connected = AppearanceSync.Connected;
            lock (gate) {
                if (busy || !Ready || (install ? !status.CanInstall : !connected && status.State != "closed" && status.State != "running")) return;
                busy = true; installing = install; feedback = install ? "Opening the download page…" : "Opening Doorlight…"; actionDeadline = DateTime.UtcNow.AddSeconds(10);
            }
            Changed?.Invoke(); Link.Send(install ? "DESKTOP_INSTALL" : "DESKTOP_OPEN");
        }
        static void Receive(string line)
        {
            bool connected = AppearanceSync.Connected;
            bool changed = false;
            lock (gate) {
                if (line.StartsWith("DESKTOP|")) {
                    string before = status.State; bool install = status.CanInstall;
                    if (status.Receive(line)) {
                        awaitingStatus = false;
                        changed = before != status.State || install != status.CanInstall;
                        if (changed) Log.Write("desktop setup: " + line);
                    }
                } else if (line.StartsWith("DESKTOP_ACTION|")) {
                    switch (line) {
                        case "DESKTOP_ACTION|opened": feedback = connected ? null : "Opening Doorlight…"; if (connected) busy = false; break;
                        case "DESKTOP_ACTION|installed": feedback = null; busy = false; break;
                        case "DESKTOP_ACTION|download_opened": busy = false; feedback = "Download opened in your browser."; break;
                        case "DESKTOP_ACTION|unavailable": busy = false; feedback = installing ? "Couldn’t open the download page. Try again." : "Doorlight couldn’t be found. Check again."; break;
                        case "DESKTOP_ACTION|failed": busy = false; feedback = "Couldn’t open Doorlight. Check again and retry."; break;
                        default: return;
                    }
                    changed = true;
                }
            }
            if (changed) Changed?.Invoke();
        }
    }
}
