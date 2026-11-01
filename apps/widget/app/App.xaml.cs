using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.IO.Pipes;
using System.Text;
using System.Threading.Tasks;
using Microsoft.Gaming.XboxGameBar;
using Windows.ApplicationModel.Activation;
using Windows.Storage;
using Windows.UI.Xaml;
using Windows.UI.Xaml.Controls;

namespace WidgetSampleCS
{
    sealed partial class App : Application
    {
        // Each open widget's XboxGameBarWidget must be held for its lifetime.
        static readonly Dictionary<string, XboxGameBarWidget> widgets = new Dictionary<string, XboxGameBarWidget>();
        static readonly Dictionary<string, Action<string>> timerActions = new Dictionary<string, Action<string>>();
        static readonly Dictionary<string, Type> pages = new Dictionary<string, Type>
        {
            ["Helper"] = typeof(HelperWidget), ["Clock"] = typeof(ClockWidget), ["Weather"] = typeof(WeatherWidget),
            ["Voice"] = typeof(VoiceWidget), ["Timer"] = typeof(TimerWidget), ["Cross"] = typeof(CrossWidget), ["Chat"] = typeof(ChatWidget),
        };

#if DEBUG
        static readonly Dictionary<string, Windows.UI.Core.CoreDispatcher> widgetDispatchers = new Dictionary<string, Windows.UI.Core.CoreDispatcher>();
        internal sealed class WidgetProbe { public Windows.Foundation.Rect Bounds; public string State; }
        internal static async Task<WidgetProbe> ProbeWidget(string extension)
        {
            XboxGameBarWidget target; Windows.UI.Core.CoreDispatcher dispatcher;
            lock (widgets) { target = widgets[extension]; dispatcher = widgetDispatchers[extension]; }
            var result = new TaskCompletionSource<WidgetProbe>();
            await dispatcher.RunAsync(Windows.UI.Core.CoreDispatcherPriority.Normal, () => {
                try { result.SetResult(new WidgetProbe { Bounds = target.WindowBounds, State = target.WindowState.ToString() }); }
                catch (Exception ex) { result.SetException(ex); }
            });
            return await result.Task;
        }
#endif
        public static event Action OpenChanged;
        public static bool IsOpen(string ext) { lock (widgets) return ext != null && widgets.ContainsKey(ext); }
        public static void TimerCommand(string command)
        {
            Action<string> run = null;
            lock (widgets) foreach (var action in timerActions.Values) { run = action; break; }
            run?.Invoke(command);
        }

        public App()
        {
            InitializeComponent();
            for (int i = 2; i <= Cfg.CrossWindowLimit; i++) pages["Cross" + i] = typeof(CrossWidget);
            for (int i = 2; i <= Cfg.WeatherWindowLimit; i++) pages["Weather" + i] = typeof(WeatherWidget);
            UnhandledException += (s, e) => Log.Write("unhandled: " + e.Exception);
            Suspending += (s, e) => Log.Write("app suspending");
        }

        protected override void OnActivated(IActivatedEventArgs args)
        {
            var w = args as XboxGameBarWidgetActivatedEventArgs;
            if (args.Kind != ActivationKind.Protocol || w == null) return;
            Log.Write($"activated id={w.AppExtensionId} launch={w.IsLaunchActivation}");
            if (!w.IsLaunchActivation || !pages.TryGetValue(w.AppExtensionId, out var page)) return;

            // Reset the persisted UWP title-bar experiment; Game Bar supplies its own chrome.
            Windows.ApplicationModel.Core.CoreApplication.GetCurrentView().TitleBar.ExtendViewIntoTitleBar = false;
            var frame = new Frame();
            Window.Current.Content = frame;
            var widget = new XboxGameBarWidget(w, Window.Current.CoreWindow, frame);
            lock (widgets) widgets[w.AppExtensionId] = widget;
            var id = w.AppExtensionId;
            var dispatcher = Window.Current.Dispatcher;
#if DEBUG
            lock (widgets) widgetDispatchers[id] = dispatcher;
#endif
            lock (widgets) timerActions[id] = command => {
                _ = dispatcher.RunAsync(Windows.UI.Core.CoreDispatcherPriority.Normal, async () => {
                    try {
                        var commandParts = command.Split('.');
                        var timerId = commandParts.Length == 3 ? commandParts[1] : TimerState.ActiveId;
                        var actionName = commandParts[commandParts.Length - 1];
                        if (!TimerState.Records.Any(t => t.Id == timerId)) return;
                        if (actionName == "visibility") {
                            bool show = !IsOpen("Timer") || !TimerState.Records.First(t => t.Id == timerId).Visible;
                            TimerState.SetVisible(timerId, show);
                            if (show) Cfg.Set("timer.visible", true);
                            if (show && !IsOpen("Timer")) await new XboxGameBarWidgetControl(widget).ActivateAsync("Timer");
                        } else if (actionName == "reset") TimerState.Reset(timerId);
                        else {
                            if (!IsOpen("Timer")) await new XboxGameBarWidgetControl(widget).ActivateAsync("Timer");
                            TimerState.Toggle(timerId);
                        }
                    } catch (Exception ex) { Log.Write("timer command failed: " + ex.Message); }
                });
            };
            Window.Current.Closed += (s, e) => {
                lock (widgets) { widgets.Remove(id); timerActions.Remove(id); }
#if DEBUG
                lock (widgets) widgetDispatchers.Remove(id);
#endif
                Log.Write("closed " + id);
                OpenChanged?.Invoke();
            };
            if (page == typeof(CrossWidget)) frame.Navigate(page, new CrossWindowContext { Widget = widget, Id = Cfg.CrossForExtension(id), Extension = id });
            else if (page == typeof(WeatherWidget)) frame.Navigate(page, new WeatherWindowContext { Widget = widget, Id = Cfg.WeatherForExtension(id), Extension = id });
            else frame.Navigate(page, widget);
            if (page != typeof(HelperWidget)) PinHint.Attach(widget, (Page)frame.Content);
            OpenChanged?.Invoke();
            Window.Current.Activate();
            Link.Start();
            AppearanceSync.Start(); OverlaySync.Start();
            DesktopOnboarding.Start();
        }

        protected override void OnLaunched(LaunchActivatedEventArgs e)
        {
            var frame = Window.Current.Content as Frame ?? new Frame();
            Window.Current.Content = frame;
#if DEBUG
            // Opt-in desktop host for inspecting the real settings UI without Game Bar.
            bool inspectHelper = File.Exists(Path.Combine(ApplicationData.Current.LocalFolder.Path, "inspect-helper"));
            if (inspectHelper) {
                Windows.UI.ViewManagement.ApplicationView.PreferredLaunchViewSize = new Windows.Foundation.Size(420, 800);
                Windows.UI.ViewManagement.ApplicationView.PreferredLaunchWindowingMode = Windows.UI.ViewManagement.ApplicationViewWindowingMode.PreferredLaunchViewSize;
                frame.Navigate(typeof(HelperWidget));
            } else
#endif
            if (frame.Content == null) frame.Navigate(typeof(MainPage));
            Window.Current.Activate();
            Link.Start(); AppearanceSync.Start(); OverlaySync.Start(); DesktopOnboarding.Start();
        }
    }

    static class Log
    {
        static readonly object gate = new object();
        static readonly string path = Path.Combine(ApplicationData.Current.LocalFolder.Path, "log.txt");

        public static void Write(string line)
        {
            line = DateTime.Now.ToString("HH:mm:ss.fff") + " " + line;
            lock (gate) File.AppendAllText(path, line + "\r\n");

        }
    }

    // Fixed install/open bootstrap only. Application state uses OverlaySync.
    static class Link
    {
        public static event Action<string> Received;
        public static event Action HelperVersionChanged;
        public static string HelperVersion;
        public static string[] Hotkeys => new[] { "chat.quick", "cross.toggle", "timer.toggle", "timer.visibility", "timer.reset" }.Concat(TimerState.Records.SelectMany(t => new[] { "timer." + t.Id + ".toggle", "timer." + t.Id + ".visibility", "timer." + t.Id + ".reset" })).ToArray();
        static StreamWriter writer;
        static bool started;
        static readonly object gate = new object();

        public static void Start()
        {
            lock (gate) { if (started) return; started = true; }
            Task.Run(async () =>
            {
                DateTime nextHelperLaunch = DateTime.MinValue;
                while (true)
                {
                    try
                    {
                        if (HelperVersion == null && DateTime.UtcNow >= nextHelperLaunch) {
                            nextHelperLaunch = DateTime.UtcNow.AddSeconds(30);
                            try { await Windows.ApplicationModel.FullTrustProcessLauncher.LaunchFullTrustProcessForCurrentAppAsync(); }
                            catch (Exception launchError) { Log.Write("helper launch failed: " + launchError.Message); }
                        }
                        using (var pipe = new NamedPipeClientStream(".", @"LOCAL\doorlight-proto", PipeDirection.InOut, PipeOptions.Asynchronous))
                        {
                            pipe.Connect(2000);
                            var reader = new StreamReader(pipe, new UTF8Encoding(false, true));
                            lock (gate) writer = new StreamWriter(pipe, new UTF8Encoding(false)) { AutoFlush = true };
                            Log.Write("pipe connected");

                            var buffer = new char[128]; var line = new StringBuilder(); int count;
                            while ((count = await reader.ReadAsync(buffer, 0, buffer.Length)) != 0) {
                                for (int i = 0; i < count; i++) {
                                    if (buffer[i] == '\n') {
                                        string frame = line.ToString(); line.Clear();
                                        if (frame.EndsWith("\r", StringComparison.Ordinal)) frame = frame.Substring(0, frame.Length - 1);
                                        Handle(frame);
                                    } else {
                                        line.Append(buffer[i]);
                                        if (line.Length > BootstrapProtocol.MaxLine + 1) throw new InvalidDataException("Bootstrap frame too large");
                                    }
                                }
                            }
                        }
                    }
                    catch (Exception ex) { File.AppendAllText(Path.Combine(ApplicationData.Current.LocalFolder.Path, "log.txt"), $"{DateTime.Now:HH:mm:ss.fff} pipe: {ex.GetType().Name} {ex.Message}\r\n"); }
                    lock (gate) writer = null;
                    HelperVersion = null; HelperVersionChanged?.Invoke();
                    await Task.Delay(3000);
                }
            });
        }

        static long inputSequence = -1;
        internal static void Input(Windows.Data.Json.JsonObject input) {
            long sequence=(long)input.GetNamedNumber("sequence",0); if(sequence==inputSequence)return;inputSequence=sequence;
            var e=input.GetNamedObject("event",new Windows.Data.Json.JsonObject()); string type=e.GetNamedString("type","");
            if(type=="compose"||type=="submit"||type=="cancel"||type=="blocked"||type=="sendResult") { Received?.Invoke("INPUT|"+e.Stringify());return; }
            switch(type) {
            case "cursor": Received?.Invoke(string.Format(System.Globalization.CultureInfo.InvariantCulture,"MOUSE|{0}|{1}|{2}",e.GetNamedNumber("x",0),e.GetNamedNumber("y",0),e.GetNamedBoolean("eligible",false)?"1":"0")); Received?.Invoke("AIMSTATE|"+e.GetNamedNumber("mask",0)); break;
            case "aim": Received?.Invoke("AIM|"+e.GetNamedString("button","")+"|"+(e.GetNamedBoolean("down",false)?"1":"0"));break;
            case "aimReset": Received?.Invoke("AIMRESET");break;
            case "capture": Cfg.Set("hotkey."+e.GetNamedString("action"), e.GetNamedString("text",""));break;
            case "hotkey": break; // Desktop already committed the action to canonical state.
            }
        }
        static void Handle(string line)
        {
            if (!BootstrapProtocol.TryParse(line, out var version)) return;
            if (version != null) { HelperVersion = version; HelperVersionChanged?.Invoke(); return; }
            Received?.Invoke(line);
        }

        public static void Send(string line)
        {
            if (line.StartsWith("CAPTURE|")) { OverlaySync.Request("input.capture", OverlaySync.Args("action",line.Substring(8))); return; }
            if (!BootstrapProtocol.IsCommand(line)) return;
            lock (gate) { try { writer?.WriteLine(line); } catch { writer = null; } }
        }
    }
}
