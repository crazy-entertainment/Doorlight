using System;
using System.Globalization;
using System.Linq;
using Microsoft.Gaming.XboxGameBar;
using Windows.Foundation;
using Windows.Graphics.Display;
using Windows.UI.Core;
using Windows.UI.Xaml;

namespace WidgetSampleCS
{
    // Behaviour every on-screen element shares: Visible switch, opacity, fade near the mouse,
    // and resizing its Game Bar window to fit its content.
    sealed class Element
    {
        public readonly string Id;
        public readonly XboxGameBarWidget Widget;
        readonly FrameworkElement root, opacityRoot;
        readonly CoreDispatcher ui;
        readonly double scale;
        bool aiming, cursorEligible, closed, aimInputDown;
        readonly string crossId;
        readonly string settingsId;
        string SettingKey(string option) => settingsId + "." + option;
        T Setting<T>(string key, T fallback) => Id == "cross" ? Cfg.ForCross(crossId, key, fallback) : Cfg.Get(key, fallback);
        T Appearance<T>(string option, T fallback) => Id == "cross" ? Cfg.CrossAppearance(crossId, option, fallback) : Cfg.Appearance(settingsId, option, fallback);
        double cursorX, cursorY;
        double aimFrom = 1;
        double AimDuration => Setting(aiming ? "cross.aimFadeMs" : "cross.aimFadeInMs", 0.0);
        double AimOpacity => CrossMath.AimTransition(aimElapsed.Elapsed.TotalMilliseconds, AimDuration, aimFrom, aiming);
        DateTime telemetryAt;
        readonly System.Diagnostics.Stopwatch aimElapsed = new System.Diagnostics.Stopwatch();
        DispatcherTimer watchdog;
        readonly bool resizableContent;
        bool sizeRestored;
#if DEBUG
        bool traceFade;
        DateTime lastFadeTrace;
#endif
        DispatcherTimer saveSize;
        public void Refresh() => Apply();

        public Element(string id, XboxGameBarWidget widget, FrameworkElement root, FrameworkElement viewport = null, string crossId = null, string settingsId = null)
        {
            this.crossId = crossId;
            this.settingsId = settingsId ?? id;
            Id = id; Widget = widget; this.root = root; opacityRoot = viewport ?? root; ui = root.Dispatcher;
            resizableContent = id == "clock" || id == "timer" || id == "weather";
            if (resizableContent) Widget.MinWindowSize = new Size(1, 1);
            scale = DisplayInformation.GetForCurrentView().RawPixelsPerViewPixel;
            Action<string> changed = key => { if (key.StartsWith(this.settingsId + ".") || key.StartsWith("general.") || (Id == "cross" && key.StartsWith("crossPresets."))) Ui(Apply); };
            Cfg.Changed += changed;
            Widget.GameBarDisplayModeChanged += (s, e) => Ui(Apply);
            Link.Received += OnLine;
            Cfg.Command += OnCommand;
            // Game Bar restores placement; loading must not center or restore the window.
            root.Loaded += (s, e) => { if (Id != "cross" && Id != "chat") Fit(); };
            if (resizableContent)
            {
                saveSize = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(250) };
                saveSize.Tick += (s, e) => {
                    saveSize.Stop();
                    // WindowBounds includes Game Bar's title strip; resize requests use content size.
                    if (!sizeRestored || viewport.ActualWidth <= 1 || viewport.ActualHeight <= 1) return;
                    Cfg.Set(SettingKey("contentWidth"), viewport.ActualWidth);
                    Cfg.Set(SettingKey("contentHeight"), viewport.ActualHeight);
                };
                // Observe the viewport, not the content: text changes must not save a new size.
                viewport.SizeChanged += (s, e) => {
                    if (!sizeRestored) return;
                    saveSize.Stop(); saveSize.Start();
                };
            }
            Window.Current.Closed += (s, e) => {
                closed = true;
                Cfg.Changed -= changed;
                Cfg.Command -= OnCommand;
                Link.Received -= OnLine;
                watchdog?.Stop();
                saveSize?.Stop();
            };
            {
                watchdog = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(16) };
                watchdog.Tick += (s, e) => { if ((DateTime.UtcNow - telemetryAt).TotalSeconds > 1) { if (aiming || cursorEligible) { aiming = false; aimFrom = 1; aimElapsed.Reset(); cursorEligible = false; Apply(); } } else if (Id == "cross" && aimElapsed.IsRunning && aimElapsed.Elapsed.TotalMilliseconds <= AimDuration + 32) Apply(); };
                watchdog.Start();
                root.Unloaded += (s, e) => watchdog.Stop();
            }
            Apply();
#if DEBUG
            root.Loaded += async (s, e) => {
                traceFade = await Windows.Storage.ApplicationData.Current.LocalFolder.TryGetItemAsync("trace-fade") != null;
                if (await Windows.Storage.ApplicationData.Current.LocalFolder.TryGetItemAsync("verify-fade") == null) return;
                await System.Threading.Tasks.Task.Delay(1000);
                VerifyFade();
            };
#endif
        }

        public void Ui(Action a)
        {
            if (!closed) _ = ui.RunAsync(CoreDispatcherPriority.Normal, () => { if (!closed) a(); });
        }

        void OnCommand(string command)
        {
            if (command == (Id == "cross" ? "cross.resetPlacement:" + crossId : settingsId + ".resetPlacement")) Ui(ResetPlacement);
        }

        async void ResetPlacement()
        {
            try
            {
                await Widget.RestoreAsync();
                if (Id == "chat") await Widget.TryResizeWindowAsync(new Size(400, 300));
                else await FitAsync();
                await Widget.CenterWindowAsync();
                Log.Write($"{Id} placement reset: {Widget.WindowBounds}");
            }
            catch (Exception ex) { Log.Write($"{Id} placement reset failed: {ex.Message}"); }
        }

        public bool Visible => Id == "cross" ? Cfg.CrossIds.Contains(crossId) && Cfg.CrossVisible(crossId) : Cfg.Get(SettingKey("visible"), true);

        void Apply()
        {
            if (Id == "cross" && !Visible) { aiming = false; aimInputDown = false; aimFrom = 1; aimElapsed.Reset(); }
            // Keep layout measurable while hidden; collapsed content shrinks the host window.
            opacityRoot.IsHitTestVisible = Visible;
            double full = Appearance("opacity", 1.0);
            var b = Widget.WindowBounds;
            var bounds = root.TransformToVisual(null).TransformBounds(new Rect(0, 0, root.ActualWidth, root.ActualHeight));
            double x = cursorX / scale - b.X, y = cursorY / scale - b.Y;
            double dx = Id == "cross" ? x - (bounds.X + bounds.Width / 2) : Math.Max(Math.Max(bounds.Left - x, x - bounds.Right), 0);
            double dy = Id == "cross" ? y - (bounds.Y + bounds.Height / 2) : Math.Max(Math.Max(bounds.Top - y, y - bounds.Bottom), 0);
            double factor = CrossMath.Fade(Math.Sqrt(dx * dx + dy * dy) * scale, Appearance("fadeStart", 0.0), Appearance("fadeEnd", 0.0), cursorEligible && Widget.GameBarDisplayMode != XboxGameBarDisplayMode.Foreground);
            double aimFactor = Id == "cross" && Widget.GameBarDisplayMode != XboxGameBarDisplayMode.Foreground ? AimOpacity : 1;
            opacityRoot.Opacity = !Visible ? 0 : CrossMath.Clamp(full, 0, 1) * factor * aimFactor;
#if DEBUG
            if (traceFade && (DateTime.UtcNow - lastFadeTrace).TotalMilliseconds >= 500) {
                lastFadeTrace = DateTime.UtcNow;
                Log.Write($"FADE LIVE {Id} mode={Widget.GameBarDisplayMode} cursor={cursorX},{cursorY} eligible={cursorEligible} bounds={b} content={bounds} distance={Math.Sqrt(dx*dx+dy*dy)*scale:F1} start={Appearance("fadeStart", 0.0)} end={Appearance("fadeEnd", 0.0)} opacity={opacityRoot.Opacity:F3}");
            }
#endif
        }

        void OnLine(string line)
        {
            if (Id == "cross" && !Visible) return;
            if (Id == "cross" && line.StartsWith("AIM")) {
                Ui(() => {
                    var input = line.Split('|');
                    string hold = Setting("cross.hold", "off");
                    bool reset = input[0] == "AIMRESET" || Widget.GameBarDisplayMode == XboxGameBarDisplayMode.Foreground || hold == "off";
                    bool? pressed = null;
                    if (input.Length == 3 && input[0] == "AIM" && input[1] == hold) pressed = input[2] == "1";
                    if (input.Length == 2 && input[0] == "AIMSTATE" && int.TryParse(input[1], out var mask)) {
                        int index = Array.IndexOf(new[] { "left", "right", "middle", "x1", "x2", "shift", "ctrl" }, hold);
                        if (index >= 0 && (mask & (1 << index)) == 0) pressed = false;
                    }
                    bool next = aiming;
                    if (reset) { next = false; aimInputDown = pressed ?? false; }
                    else if (pressed.HasValue) {
                        next = Setting("cross.aimToggle", false) ? (pressed.Value && !aimInputDown ? !aiming : aiming) : pressed.Value;
                        aimInputDown = pressed.Value;
                    }
                    if (next != aiming) { aimFrom = AimOpacity; aiming = next; aimElapsed.Restart(); }
                    Apply();
                }); return;
            }
            if (!line.StartsWith("MOUSE|")) return;
            var p = line.Split('|');
            if (p.Length < 3 || !double.TryParse(p[1], NumberStyles.Float, CultureInfo.InvariantCulture, out var x) || !double.TryParse(p[2], NumberStyles.Float, CultureInfo.InvariantCulture, out var y)) return;
            Ui(() => {
                cursorX = x; cursorY = y; cursorEligible = p.Length > 3 && p[3] == "1";
                telemetryAt = DateTime.UtcNow; Apply();
            });
        }

#if DEBUG
        // Opt-in installed-widget check. Restore all touched settings and input state afterward.
        void VerifyFade()
        {
            var store = OverlaySettings.Values;
            string prefix = settingsId + ".appearance.";
            var keys = new[] { "general.fadeStart", "general.fadeEnd", prefix + "opacity", settingsId + ".appearanceOverride", settingsId + ".visible" };
            var saved = new System.Collections.Generic.Dictionary<string, object>();
            foreach (var key in keys) if (store.ContainsKey(key)) saved[key] = store[key];
            double oldX = cursorX, oldY = cursorY, oldAimFrom = aimFrom; bool oldEligible = cursorEligible, oldAiming = aiming;
            try {
                store[settingsId + ".appearanceOverride"] = true; store[settingsId + ".visible"] = true;
                store[prefix + "opacity"] = .37; store["general.fadeStart"] = 120.0; store["general.fadeEnd"] = 20.0;
                aiming = false; aimFrom = 1; cursorEligible = true;
                var b = Widget.WindowBounds;
                var r = root.TransformToVisual(null).TransformBounds(new Rect(0, 0, root.ActualWidth, root.ActualHeight));
                if (r.Width <= 0 || r.Height <= 0) throw new Exception("unmeasured widget");
                double origin = Id == "cross" ? r.X + r.Width / 2 : r.Right;
                cursorY = (b.Y + r.Y + r.Height / 2) * scale;
                double expected = Id == "cross" ? 1 : .37;
                Action<double, double> check = (distance, factor) => {
                    cursorX = (b.X + origin) * scale + distance;
                    Apply();
                    if (Math.Abs(opacityRoot.Opacity - expected * factor) > .0001)
                        throw new Exception("distance=" + distance + " opacity=" + opacityRoot.Opacity);
                };
                bool editing = Widget.GameBarDisplayMode == XboxGameBarDisplayMode.Foreground;
                check(140, 1); check(120, 1); check(70, editing ? 1 : .5); check(20, editing ? 1 : 0); check(0, editing ? 1 : 0);
                store["general.fadeStart"] = 0.0; store["general.fadeEnd"] = 0.0;
                check(0, 1); check(70, 1); check(140, 1);
                store["general.fadeStart"] = 120.0; store["general.fadeEnd"] = 20.0;
                cursorEligible = false; check(0, 1);
                if ((double)store[prefix + "opacity"] != .37) throw new Exception("opacity setting changed");
                Log.Write("FADE VERIFY PASS " + Id + " far/start/mid/end/inside; zero disables; ineligible cursor; own opacity preserved; bounds=" + r);
            } catch (Exception ex) { Log.Write("FADE VERIFY FAIL " + Id + " " + ex); }
            finally {
                foreach (var key in keys) { if (saved.TryGetValue(key, out var value)) store[key] = value; else store.Remove(key); }
                cursorX = oldX; cursorY = oldY; cursorEligible = oldEligible; aiming = oldAiming; aimFrom = oldAimFrom; Apply();
            }
        }
#endif

        // Game Bar only resizes while it is open; outside it the request is ignored.
        public async void Fit(double extraW = 0, double extraH = 0) => await FitAsync(extraW, extraH);

        public async System.Threading.Tasks.Task FitAsync(double extraW = 0, double extraH = 0)
        {
            // Crosshair owns its setup window size; async image decoding may still measure zero.
            // Fitting to the image would also move the crosshair away from its chosen placement.
            if (Id == "cross") return;
            // The Viewbox handles subsequent layout. Never fight a user's resize on each tick.
            if (resizableContent && (sizeRestored || !root.IsLoaded)) return;
            root.Measure(new Size(double.PositiveInfinity, double.PositiveInfinity));
            var d = root.DesiredSize;
            System.Diagnostics.Debug.Assert(d.Width > 0 && d.Height > 0, "Hidden widgets must retain measurable content.");
            var size = new Size(Math.Max(Math.Ceiling(d.Width + extraW), Widget.MinWindowSize.Width), Math.Max(Math.Ceiling(d.Height + extraH), Widget.MinWindowSize.Height));
            if (resizableContent)
            {
                size.Width = Math.Max(1, Cfg.Get(SettingKey("contentWidth"), Id == "weather" ? 100.0 : size.Width));
                size.Height = Math.Max(1, Cfg.Get(SettingKey("contentHeight"), Id == "weather" ? 40.0 : size.Height));
            }
            size.Width = Math.Min(size.Width, Widget.MaxWindowSize.Width);
            size.Height = Math.Min(size.Height, Widget.MaxWindowSize.Height);
            try {
                if (!await Widget.TryResizeWindowAsync(size)) Log.Write($"{Id} resize deferred: {size}");
                if (resizableContent) sizeRestored = true;
            } catch (Exception ex) { Log.Write($"{Id} resize failed: {ex.Message}"); }
        }
    }
}
