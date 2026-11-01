using System;
using System.Linq;
using Microsoft.Gaming.XboxGameBar;
using Windows.Storage;
using Windows.Storage.Pickers;
using Windows.UI;
using Windows.UI.Core;
using Windows.UI.Xaml;
using Windows.UI.Xaml.Controls;
using Windows.UI.Xaml.Controls.Primitives;
using Windows.UI.Xaml.Media;
using Windows.UI.Xaml.Navigation;
using Windows.UI.Xaml.Shapes;

namespace WidgetSampleCS
{
    // The one Game Bar menu entry: icon tabs across the top, one page of settings per element.
    public sealed partial class HelperWidget : Page
    {
        sealed class Tab { public string Id, Ext, Title, Glyph; public Action Build; public Button Button; }

        XboxGameBarWidget widget;
        WidgetVibe vibe;
        Tab[] tabs;
        Tab current;
        bool syncing, pageClosed;
        static WidgetPalette Palette => WidgetTheme.Current;
        static readonly string[] Swatches = { "#EFE6DC", "#FFFFFF", "#F2B775", "#7BD88F", "#FF5C8A", "#5CC8FF", "#000000" };

        public HelperWidget() { WidgetTheme.Attach(this); InitializeComponent(); Loaded += (s, e) => { FitTimerSettings(); FitEmptyWidget(); }; Body.SizeChanged += (s, e) => FitTimerSettings(); }

        protected override void OnNavigatedTo(NavigationEventArgs e)
        {
            widget = (XboxGameBarWidget)e.Parameter;
            vibe = new WidgetVibe(VibeCanvas, () => widget != null && widget.Visible && widget.GameBarDisplayMode == XboxGameBarDisplayMode.Foreground);
            Action overlayChanged = () => Ui(() => {
                Scroller.IsEnabled = OverlaySettings.Editable;
                VisibleSwitch.IsEnabled = OverlaySettings.Editable;
                if (OverlaySync.Error != null) Status.Text = OverlaySync.Error;
                RetrySettings.Visibility=OverlaySettings.RetryRequired?Visibility.Visible:Visibility.Collapsed;
                RetrySettings.IsEnabled=OverlaySync.Writable;
                UpdateDesktopSetup();
            });
            OverlaySync.Changed += overlayChanged;
            Window.Current.Closed += (s, a) => OverlaySync.Changed -= overlayChanged;
            overlayChanged();
            if (widget != null) {
                widget.VisibleChanged += (s, args) => Ui(vibe.Refresh);
                widget.GameBarDisplayModeChanged += (s, args) => Ui(vibe.Refresh);
            }
            Window.Current.Closed += (s, args) => vibe.Dispose();
#if DEBUG
            Loaded += async (s, args) => await CaptureDesktopSetup();
            Loaded += async (s, args) => await CaptureWeatherSearch();
            Loaded += async (s, args) => await ProbeAppearance();
            Loaded += async (s, args) => {
                var marker = await ApplicationData.Current.LocalFolder.TryGetItemAsync("verify-cross-windows");
                if (widget == null || marker == null) return;
                await marker.DeleteAsync();
                await VerifyCrossWindows();
            };
#endif
            Action<string> crossRefresh = command => { if (command == "cross.refreshEditor" && current?.Id == "cross") Ui(() => Show(current)); };
            Cfg.Command += crossRefresh;
            Window.Current.Closed += (s, a) => Cfg.Command -= crossRefresh;
            tabs = new[]
            {
                new Tab { Id = "chat", Ext = "Chat", Title = "Chat", Glyph = "\uE8BD", Build = BuildChat },
                new Tab { Id = "cross", Ext = "Cross", Title = "Crosshair", Build = BuildCross },
                new Tab { Id = "time", Ext = "Timer", Title = "Clock", Glyph = "\uE916", Build = BuildTimer },
                new Tab { Id = "weather", Ext = "Weather", Title = "Weather", Glyph = "\uE753", Build = BuildWeather },
                new Tab { Id = "voice", Ext = "Voice", Title = "Voice", Glyph = "\uE720", Build = BuildVoice },
                new Tab { Id = "settings", Ext = "Helper", Title = "Settings", Glyph = "\uE713", Build = BuildGeneral },
            };
            foreach (var t in tabs)
            {
                var b = new Button
                {
                    Height = 48, CornerRadius = new CornerRadius(10), Padding = new Thickness(2),
                    HorizontalAlignment = HorizontalAlignment.Stretch, BorderThickness = new Thickness(0),
                    Content = new StackPanel { Spacing = 5, Children = {
                        t.Id == "cross" ? (IconElement)CrosshairTabIcon() : new FontIcon { Glyph = t.Glyph, FontFamily = new FontFamily("Segoe MDL2 Assets"), FontSize = 18 },
                        new TextBlock { Text = t.Title, FontSize = 12, HorizontalAlignment = HorizontalAlignment.Center }
                    } },
                };

                Windows.UI.Xaml.Automation.AutomationProperties.SetName(b, t.Title);
                b.Click += (s, a) => Show(t);
                t.Button = b;
                Tabs.ColumnDefinitions.Add(new ColumnDefinition());
                Grid.SetColumn(b, Tabs.Children.Count);
                Tabs.Children.Add(b);
            }
            Action versionChanged = () => Ui(ShowVersions);
            Action desktopChanged = () => Ui(UpdateDesktopSetup);
            DesktopOnboarding.Changed += desktopChanged;
            AppearanceSync.Changed += desktopChanged;
            Window.Current.Closed += (s, args) => { DesktopOnboarding.Changed -= desktopChanged; AppearanceSync.Changed -= desktopChanged; };
            UpdateDesktopSetup();
            Action openChanged = () => Ui(SyncVisible);
            Action<string> visibleChanged = key => {
                if ((key == WidgetTheme.Setting || key == "helper.appearance") && current != null) Ui(() => Show(current));
                if (key == "helper.vibe" && current?.Id == "settings") Ui(() => Show(current));
                if (current != null && key == current.Id + ".visible") Ui(SyncVisible);
                if ((key == "helper.clockEditorMode" && (current?.Id == "clock" || current?.Id == "timer")) ||
                    (key == "helper.weatherEditorMode" && current?.Id == "weather")) Ui(() => Show(current));
            };
            Link.HelperVersionChanged += versionChanged; App.OpenChanged += openChanged; Cfg.Changed += visibleChanged;
            Window.Current.Closed += (s, args) => { pageClosed = true; Link.HelperVersionChanged -= versionChanged; App.OpenChanged -= openChanged; Cfg.Changed -= visibleChanged; timerEditorCleanup?.Invoke(); timerEditorCleanup = null; };
            ShowVersions();
            var saved = Cfg.Get("helper.tab", "time"); Show(tabs.FirstOrDefault(t => t.Id == saved) ?? tabs[2]);
        }

#if DEBUG
        string setupCaptureState;
        async System.Threading.Tasks.Task CaptureDesktopSetup()
        {
            var folder = ApplicationData.Current.LocalFolder;
            var marker = await folder.TryGetItemAsync("capture-desktop-setup");
            if (widget == null || marker == null) return;
            await marker.DeleteAsync();
            try {
                foreach (var state in new[] { "missing", "closed" }) {
                    setupCaptureState = state;
                    UpdateDesktopSetup();
                    await System.Threading.Tasks.Task.Delay(700);
                    UpdateLayout();
                    var bitmap = new Windows.UI.Xaml.Media.Imaging.RenderTargetBitmap();
                    await bitmap.RenderAsync(DesktopSetupNotice);
                    if (bitmap.PixelWidth == 0 || bitmap.PixelHeight == 0) throw new Exception("Empty onboarding capture");
                    var pixels = await bitmap.GetPixelsAsync();
                    var bytes = new byte[pixels.Length];
                    using (var reader = Windows.Storage.Streams.DataReader.FromBuffer(pixels)) reader.ReadBytes(bytes);
                    var file = await folder.CreateFileAsync("widget-desktop-" + state + ".png", CreationCollisionOption.ReplaceExisting);
                    using (var stream = await file.OpenAsync(FileAccessMode.ReadWrite)) {
                        var encoder = await Windows.Graphics.Imaging.BitmapEncoder.CreateAsync(Windows.Graphics.Imaging.BitmapEncoder.PngEncoderId, stream);
                        encoder.SetPixelData(Windows.Graphics.Imaging.BitmapPixelFormat.Bgra8, Windows.Graphics.Imaging.BitmapAlphaMode.Premultiplied,
                            (uint)bitmap.PixelWidth, (uint)bitmap.PixelHeight, 96, 96, bytes);
                        await encoder.FlushAsync();
                    }
                }
                await FileIO.WriteTextAsync(await folder.CreateFileAsync("capture-desktop-setup-result.txt", CreationCollisionOption.ReplaceExisting), "PASS real onboarding controls rendered with simulated missing/closed installation states; no settings changed");
            } catch (Exception ex) {
                await FileIO.WriteTextAsync(await folder.CreateFileAsync("capture-desktop-setup-result.txt", CreationCollisionOption.ReplaceExisting), "FAIL " + ex);
            } finally {
                setupCaptureState = null;
                UpdateDesktopSetup();
            }
        }

        Func<string, System.Threading.Tasks.Task<bool>> weatherSearchForCapture;
        async System.Threading.Tasks.Task CaptureWeatherSearch()
        {
            var folder = ApplicationData.Current.LocalFolder;
            var marker = await folder.TryGetItemAsync("capture-weather-search.txt") as StorageFile;
            if (widget == null || marker == null) return;
            string query = (await FileIO.ReadTextAsync(marker)).Trim();
            await marker.DeleteAsync();
            string savedTab = Cfg.Get("helper.tab", "time"), scratch = null;
            try {
                if (Cfg.WeatherActive == null) scratch = Cfg.CreateWeather();
                Show(tabs.First(t => t.Id == "weather"));
                if (weatherSearchForCapture == null || !await weatherSearchForCapture(query)) throw new Exception("Weather search returned no visible results: " + Status.Text);
                await System.Threading.Tasks.Task.Delay(500);
                UpdateLayout();
                var bitmap = new Windows.UI.Xaml.Media.Imaging.RenderTargetBitmap();
                await bitmap.RenderAsync(this);
                var pixels = await bitmap.GetPixelsAsync();
                var bytes = new byte[pixels.Length];
                using (var reader = Windows.Storage.Streams.DataReader.FromBuffer(pixels)) reader.ReadBytes(bytes);
                var file = await folder.CreateFileAsync("weather-search-capture.png", CreationCollisionOption.ReplaceExisting);
                using (var stream = await file.OpenAsync(FileAccessMode.ReadWrite)) {
                    var encoder = await Windows.Graphics.Imaging.BitmapEncoder.CreateAsync(Windows.Graphics.Imaging.BitmapEncoder.PngEncoderId, stream);
                    encoder.SetPixelData(Windows.Graphics.Imaging.BitmapPixelFormat.Bgra8, Windows.Graphics.Imaging.BitmapAlphaMode.Premultiplied,
                        (uint)bitmap.PixelWidth, (uint)bitmap.PixelHeight, 96, 96, bytes);
                    await encoder.FlushAsync();
                }
                await FileIO.WriteTextAsync(await folder.CreateFileAsync("weather-search-capture-result.txt", CreationCollisionOption.ReplaceExisting), "PASS query=" + query + " pixels=" + bitmap.PixelWidth + "x" + bitmap.PixelHeight);
            } catch (Exception ex) {
                await FileIO.WriteTextAsync(await folder.CreateFileAsync("weather-search-capture-result.txt", CreationCollisionOption.ReplaceExisting), "FAIL " + ex);
            } finally {
                if (scratch != null) Cfg.DeleteWeather(scratch);
                Cfg.Set("helper.tab", savedTab);
            }
        }

        async System.Threading.Tasks.Task VerifyCrossWindows()
        {
            string selected = Cfg.CrossActive;
            try {
                while (Cfg.CrossIds.Length < 2) Cfg.CreateCross();
                var ids = Cfg.CrossIds.Take(2).ToArray();
                var ext = ids.Select(Cfg.CrossExtension).ToArray();
                var control = new XboxGameBarWidgetControl(widget);
                foreach (var id in ids) Cfg.SetCrossVisible(id, true);
                foreach (var extension in ext) await control.ActivateAsync(extension);
                await System.Threading.Tasks.Task.Delay(1200);
                var first = await App.ProbeWidget(ext[0]); var second = await App.ProbeWidget(ext[1]);
                Log.Write("CROSS WINDOWS before " + ext[0] + "=" + first.State + " " + first.Bounds + "; " + ext[1] + "=" + second.State + " " + second.Bounds);
                await control.MinimizeAsync(ext[0]); Cfg.SetCrossVisible(ids[0], false);
                await System.Threading.Tasks.Task.Delay(400);
                var hidden = await App.ProbeWidget(ext[0]); var unaffected = await App.ProbeWidget(ext[1]);
                if (first.State == hidden.State || second.State != unaffected.State || !second.Bounds.Equals(unaffected.Bounds)) throw new Exception("Hide changed the wrong window or did not minimize the target");
                await control.RestoreAsync(ext[0]); Cfg.SetCrossVisible(ids[0], true);
                await System.Threading.Tasks.Task.Delay(400);
                var restored = await App.ProbeWidget(ext[0]);
                if (restored.State != first.State || !restored.Bounds.Equals(first.Bounds)) throw new Exception("Restore did not preserve position/state");
                Log.Write("CROSS WINDOWS PASS two independent hosts; hide=" + hidden.State + "; restored=" + restored.State + " " + restored.Bounds + "; second unchanged=" + unaffected.Bounds);
            } catch (Exception ex) { Log.Write("CROSS WINDOWS FAIL " + ex); }
            finally { if (selected != null) Cfg.SelectCross(selected); }
        }
#endif

        static PathIcon CrosshairTabIcon() => new PathIcon {
            Width = 18, Height = 18,
            Data = new GeometryGroup { Children = {
                new RectangleGeometry { Rect = new Windows.Foundation.Rect(8, 0, 2, 5) },
                new RectangleGeometry { Rect = new Windows.Foundation.Rect(8, 13, 2, 5) },
                new RectangleGeometry { Rect = new Windows.Foundation.Rect(0, 8, 5, 2) },
                new RectangleGeometry { Rect = new Windows.Foundation.Rect(13, 8, 5, 2) },
                new EllipseGeometry { Center = new Windows.Foundation.Point(9, 9), RadiusX = 1.5, RadiusY = 1.5 }
            } }
        };

        void Ui(Action a) { if (!pageClosed) _ = Dispatcher.RunAsync(CoreDispatcherPriority.Normal, () => { if (!pageClosed) a(); }); }

        void ShowVersions()
        {
            var v = Windows.ApplicationModel.Package.Current.Id.Version;
            var mine = $"{v.Major}.{v.Minor}.{v.Build}";
            Versions.Text = "v" + mine +
                (Link.HelperVersion != null && Link.HelperVersion != mine ? $" · background part is v{Link.HelperVersion}, update incomplete" : "");
        }

        void Show(Tab t)
        {
            if (t.Id == "time" || t.Id == "clock" || t.Id == "timer") { bool clock = Cfg.Get("time.kind", "timer") == "clock";
                if (clock && Clocks.Ids.Length == 0) clock = TimerState.Active == null;
                if (!clock && TimerState.Active == null && Clocks.Ids.Length > 0) clock = true;
                Cfg.Set("time.kind", clock ? "clock" : "timer"); t = new Tab { Id = clock ? "clock" : "timer", Ext = clock ? "Clock" : "Timer", Title = "Clock", Button = t.Button, Build = clock ? (Action)BuildClock : BuildTimer }; }
            foreach (var old in VisibilityControls.Children.OfType<Button>().ToArray()) VisibilityControls.Children.Remove(old);
            timerEditorCleanup?.Invoke(); timerEditorCleanup = null;
            current = t;
            if (widget != null) widget.MinWindowSize = new Windows.Foundation.Size(420, 180);
            foreach (var x in tabs)
            {
                x.Button.Background = new SolidColorBrush(x.Button == t.Button ? Rgb(Palette.ActiveTab) : Rgb(Palette.ButtonFill));
                x.Button.Foreground = new SolidColorBrush(x.Button == t.Button ? Rgb(Palette.ActiveTabInk) : Rgb(Palette.Muted));
                x.Button.BorderBrush = new SolidColorBrush(x.Button == t.Button ? Rgb(Palette.Fill) : Rgb(Palette.Border));
            }
            Cfg.Set("helper.tab", t.Id == "clock" || t.Id == "timer" ? "time" : t.Id);
            { PageHeader.Margin = new Thickness(20,12,20,12); Body.Margin = new Thickness(20,0,20,8); Body.Spacing = 8; foreach (var tab in tabs) tab.Button.Height = 48; Scroller.VerticalScrollBarVisibility = ScrollBarVisibility.Hidden; }
            Title.Text = t.Title;
            Title.FontFamily = WidgetTheme.Heading;
            Grid.SetRow(VisibilityControls, t.Id == "clock" ? 1 : 0); VisibilityControls.Margin = new Thickness(0, t.Id == "clock" ? 8 : 0, 0, 0);
            { VisibilityControls.Visibility = Visibility.Collapsed; Title.FontSize = Palette.HeadingSize; }
            Scroller.ChangeView(null, 0, null, true);
            Body.Children.Clear();
            Status.Text = "";

            t.Build();
            if (t.Id == "chat" ||
                (t.Id == "clock" && Clocks.Ids.Length > 0 && Cfg.Get("helper.clockEditorMode", "simple") == "advanced") ||
                (t.Id == "timer" && TimerState.Active != null && Cfg.Get("helper.clockEditorMode", "simple") == "advanced")) AddWidgetAppearance(t.Id);

            if ((t.Id == "clock" && Clocks.Ids.Length > 0) || (t.Id == "timer" && TimerState.Active != null))
                ClockEditorLink(Cfg.Get("helper.clockEditorMode", "simple") != "advanced");

            SyncVisible();
            UpdateDesktopSetup();
            AnimateHelperEntry(Body);
            Ui(FitTimerSettings);
        }

        static void AnimateHelperEntry(FrameworkElement content)
        {
            if (!WidgetTheme.AnimationsEnabled) { content.Opacity = 1; return; }
            var transform = new TranslateTransform(); content.RenderTransform = transform;
            var storyboard = new Windows.UI.Xaml.Media.Animation.Storyboard();
            var duration = new Duration(TimeSpan.FromMilliseconds(200));
            var fade = new Windows.UI.Xaml.Media.Animation.DoubleAnimation { From = .35, To = 1, Duration = duration };
            var slide = new Windows.UI.Xaml.Media.Animation.DoubleAnimation { From = 7, To = 0, Duration = duration,
                EasingFunction = new Windows.UI.Xaml.Media.Animation.CubicEase { EasingMode = Windows.UI.Xaml.Media.Animation.EasingMode.EaseOut } };
            Windows.UI.Xaml.Media.Animation.Storyboard.SetTarget(fade, content);
            Windows.UI.Xaml.Media.Animation.Storyboard.SetTargetProperty(fade, "Opacity");
            Windows.UI.Xaml.Media.Animation.Storyboard.SetTarget(slide, transform);
            Windows.UI.Xaml.Media.Animation.Storyboard.SetTargetProperty(slide, "Y");
            storyboard.Children.Add(fade); storyboard.Children.Add(slide); storyboard.Begin();
        }

        void UpdateDesktopSetup()
        {
            bool visible = OverlaySync.State==null && (current?.Id=="chat" || current?.Id=="voice");
            bool wasVisible = DesktopSetupNotice.Visibility == Visibility.Visible;
            string state = DesktopOnboarding.State;
            bool canInstall = DesktopOnboarding.CanInstall;
#if DEBUG
            if (setupCaptureState != null) { visible = true; state = setupCaptureState; canInstall = true; }
#endif
            bool install = state == "missing";
            DesktopSetupTitle.Text = "Chat and voice use Doorlight";
            DesktopSetupText.Text = DesktopOnboarding.Feedback ?? (install
                ? "Install Doorlight to use chat and calls here."
                : state == "unknown" ? "Check again to find Doorlight for chat and calls." : "Open Doorlight to use chat and calls here.");
            DesktopSetupAction.Content = install ? "Install Doorlight" : "Open Doorlight";
            DesktopSetupAction.Tag = install;
            DesktopSetupAction.Visibility = install || state == "closed" || state == "running" ? Visibility.Visible : Visibility.Collapsed;
            DesktopSetupAction.IsEnabled = !DesktopOnboarding.Busy && (!install || canInstall);
            DesktopSetupNotice.Visibility = visible ? Visibility.Visible : Visibility.Collapsed;
            if (visible && !wasVisible) AnimateHelperEntry(DesktopSetupNotice);
            if (visible != wasVisible || visible) Ui(FitTimerSettings);
        }
        void DesktopSetupAction_Click(object sender, RoutedEventArgs e) => DesktopOnboarding.Open(DesktopSetupAction.Tag is bool install && install);
        void DesktopSetupRefresh_Click(object sender, RoutedEventArgs e) => DesktopOnboarding.Refresh(true);

        void SyncVisible()
        {
            syncing = true;
            VisibleSwitch.IsOn = Cfg.Get(current.Id + ".visible", true) && App.IsOpen(current.Ext);
            VisibilityLabel.Text = VisibleSwitch.IsOn ? "Shown" : "Hidden";
            syncing = false;
        }

        async void VisibleSwitch_Toggled(object sender, RoutedEventArgs e)
        {
            if (syncing || current == null) return;
            var selected = current;
            bool show = VisibleSwitch.IsOn;
            VisibilityLabel.Text = show ? "Shown" : "Hidden";
            Cfg.Set(selected.Id + ".visible", show);
            if (!show) return;
            VisibleSwitch.IsEnabled = false;
            try {
                var control = new XboxGameBarWidgetControl(widget);
                if (App.IsOpen(selected.Ext)) await control.RestoreAsync(selected.Ext);
                else await control.ActivateAsync(selected.Ext);
                Status.Text = "Pin the widget to keep it visible during play."; }
            catch (Exception ex) { Cfg.Set(selected.Id + ".visible", false); Status.Text = "Could not open: " + ex.Message; }
            finally { VisibleSwitch.IsEnabled = true; SyncVisible(); }
        }

        // ---------- pages ----------

        void BuildClock() => BuildClockOptions();

        void BuildWeather() => CompactWeather();

        void BuildTimer() => CompactTimer();

        void RetrySettings_Click(object sender,RoutedEventArgs e)=>OverlaySettings.Retry();
        void BuildCross() => CompactCross();

        void BuildVoice() {
            var more=TimerIcon("\uE712", "Voice actions"); var menu=new MenuFlyout(); more.Flyout=menu; WidgetMenu(menu,"voice","Voice");
            var actions=WidgetActions(more,"voice","Voice"); Grid.SetColumn(actions,1); PageHeader.Children.Add(actions); timerEditorCleanup+=()=>PageHeader.Children.Remove(actions);
        }
        void BuildChat()
        {
            var more = TimerIcon("\uE712", "Chat actions");
            var menu = new MenuFlyout(); more.Flyout = menu; WidgetMenu(menu, "chat", "Chat");
            var actions = WidgetActions(more, "chat", "Chat"); Grid.SetColumn(actions, 1);
            PageHeader.Children.Add(actions); timerEditorCleanup += () => PageHeader.Children.Remove(actions);

            Section("Input");
            Toggle("Allow writing (quick chat)", "chat.writable", true);
            Hotkey("Quick chat hotkey", "chat.quick", "Ctrl+Alt+C");
            Section("Size");
            Slider("Width", "chat.width", 200, 900, 400, 10);
            Slider("Height", "chat.height", 120, 900, 300, 10);
            Section("Timing");
            Slider("Minimum seconds on screen", "chat.minSeconds", 1, 30, 5, 1);
            Slider("Fade after seconds (0 = never)", "chat.fadeSeconds", 0, 300, 30, 5);
            Section("Look");
            Slider("Text size", "chat.textSize", 10, 24, 14, 1);
            Slider("Background opacity", "chat.bgOpacity", 0, 1, 0, 0.05);
            Toggle("Show names", "chat.names", true);
            Toggle("Show avatars", "chat.avatars", true); Toggle("Show message text", "chat.text", true);
        }

        // ---------- crosshair helpers ----------

        void PixelEditor()
        {
            const double cell = 16;
            int n = CrossWidget.Grid;
            string preset = Cfg.CrossActive;
            var saved = Cfg.Get("cross.pixels", CrossWidget.DefaultPixels());
            var bits = (saved.Length == n * n ? saved : CrossWidget.DefaultPixels()).ToCharArray();
            var history = new System.Collections.Generic.Stack<string>();
            var canvas = new Canvas { Width = n * cell, Height = n * cell, Background = new SolidColorBrush(Rgb(Palette.Border)) };
            var on = new SolidColorBrush(Cfg.Color("cross.color", "#7BD88F"));
            var off = new SolidColorBrush(Rgb(Palette.High));
            var guide = new SolidColorBrush(Rgb(Palette.Top));
            var guides = new bool[n * n];
            var rects = new Rectangle[n * n];
            for (int i = 0; i < n * n; i++) {
                int dx = i % n - n / 2, dy = i / n - n / 2;
                double radius = Math.Sqrt(dx * dx + dy * dy);
                guides[i] = dx == 0 || dy == 0 || new[] { 3, 6, 9 }.Any(r => Math.Abs(radius - r) < .45);
                rects[i] = new Rectangle { Width = cell - 1, Height = cell - 1 };
                Canvas.SetLeft(rects[i], i % n * cell); Canvas.SetTop(rects[i], i / n * cell);
                canvas.Children.Add(rects[i]);
            }
            Button DrawingButton(string glyph, string name, string hint) {
                var button = TimerIcon(glyph, name);
                ToolTipService.SetToolTip(button, hint);
                return button;
            }
            var draw = DrawingButton("\uE70F", "Draw", "Draw · Left mouse button");
            var erase = DrawingButton("\uE75C", "Erase", "Erase · Left mouse button when selected; right mouse button anytime");
            var undo = DrawingButton("\uE7A7", "Undo", "Undo · Ctrl+Z"); undo.IsEnabled = false;
            void Refresh() {
                for (int i = 0; i < bits.Length; i++) rects[i].Fill = bits[i] == '1' ? on : (guides[i] ? guide : off);
                undo.IsEnabled = history.Count > 0;
            }
            void Save() { if (preset == Cfg.CrossActive) Cfg.Set("cross.pixels", new string(bits)); }
            char paint = '1', selectedTool = '1'; bool down = false;
            string before = null;
            Windows.Foundation.Point last = new Windows.Foundation.Point();
            void Paint(Windows.Foundation.Point point) {
                int steps = Math.Max(1, (int)Math.Ceiling(Math.Max(Math.Abs(point.X - last.X), Math.Abs(point.Y - last.Y)) / (cell / 2)));
                for (int j = 1; j <= steps; j++) {
                    double px = last.X + (point.X - last.X) * j / steps, py = last.Y + (point.Y - last.Y) * j / steps;
                    int x = (int)Math.Floor(px / cell), y = (int)Math.Floor(py / cell);
                    if (x >= 0 && y >= 0 && x < n && y < n) bits[y * n + x] = paint;
                }
                last = point; Refresh();
            }
            void Finish() {
                if (!down) return;
                down = false;
                if (before != new string(bits)) { history.Push(before); Save(); }
                Refresh();
            }
            canvas.PointerPressed += (s, e) => {
                var point = e.GetCurrentPoint(canvas);
                if (down) return;
                if (e.Pointer.PointerDeviceType == Windows.Devices.Input.PointerDeviceType.Mouse) {
                    if (!point.Properties.IsLeftButtonPressed && !point.Properties.IsRightButtonPressed) return;
                    paint = point.Properties.IsRightButtonPressed ? '0' : selectedTool;
                } else paint = selectedTool;
                draw.Focus(FocusState.Programmatic);
                down = true; before = new string(bits); last = point.Position;
                canvas.CapturePointer(e.Pointer); Paint(last); e.Handled = true;
            };
            canvas.PointerMoved += (s, e) => { if (down) Paint(e.GetCurrentPoint(canvas).Position); };
            canvas.PointerReleased += (s, e) => { Finish(); canvas.ReleasePointerCapture(e.Pointer); };
            canvas.PointerCaptureLost += (s, e) => Finish();
            canvas.RightTapped += (s, e) => e.Handled = true;
            void Mode(char value) {
                selectedTool = value;
                draw.Background = new SolidColorBrush(Rgb(value == '1' ? Palette.Selected : Palette.High));
                erase.Background = new SolidColorBrush(Rgb(value == '0' ? Palette.Selected : Palette.High));
            }
            draw.Click += (s, e) => Mode('1'); erase.Click += (s, e) => Mode('0'); Mode('1');
            void Undo() {
                Finish(); canvas.ReleasePointerCaptures();
                if (history.Count > 0) { bits = history.Pop().ToCharArray(); Save(); Refresh(); }
            }
            undo.Click += (s, e) => Undo();
            void Replace(string value) { if (value == new string(bits)) return; history.Push(new string(bits)); bits = value.ToCharArray(); Save(); Refresh(); }
            var clear = DrawingButton("\uE74D", "Clear drawing", "Clear drawing"); clear.Click += (s, e) => Replace(new string('0', n * n));
            var done = DrawingButton("\uE73E", "Done", "Done");
            var editor = new StackPanel { Spacing = 10 };
            editor.Children.Add(new TextBlock { Text = "Draw crosshair", FontSize = 18, FontWeight = Windows.UI.Text.FontWeights.SemiBold });
            var toolbar = Row(draw, erase, undo, clear, done);
            toolbar.HorizontalAlignment = HorizontalAlignment.Center;
            editor.Children.Add(toolbar);
            editor.Children.Add(canvas);
            editor.AddHandler(UIElement.KeyDownEvent, new Windows.UI.Xaml.Input.KeyEventHandler((s, e) => {
                if (e.Key == Windows.System.VirtualKey.Z &&
                    (Window.Current.CoreWindow.GetKeyState(Windows.System.VirtualKey.Control) & CoreVirtualKeyStates.Down) != 0) {
                    Undo(); e.Handled = true;
                }
            }), true);
            Refresh();
            var flyout = new Flyout { Content = editor, Placement = FlyoutPlacementMode.LeftEdgeAlignedTop, ShouldConstrainToRootBounds = false };
            done.Click += (s, e) => { Finish(); flyout.Hide(); };
            flyout.Closed += (s, e) => Finish();
            var edit = new Button { Content = "Edit drawing…" };
            // Anchor to the page edge so the editor sits beside the settings window.
            edit.Click += (s, e) => flyout.ShowAt(this);
            Body.Children.Add(Pair(edit, ColorChip("cross.color", "#7BD88F", "Crosshair color"), false));
        }

        async System.Threading.Tasks.Task PickImage()
        {
            try
            {
                var picker = new FileOpenPicker { SuggestedStartLocation = PickerLocationId.PicturesLibrary };
                picker.FileTypeFilter.Add(".png");
                var file = await picker.PickSingleFileAsync();
                if (file == null) return;
                string preset = Cfg.CrossActive;
                string imageFile = "crosshair-" + Guid.NewGuid().ToString("N") + ".png";
                await file.CopyAsync(ApplicationData.Current.LocalFolder, imageFile, NameCollisionOption.FailIfExists);
                if (preset != Cfg.CrossActive) { Status.Text = "Crosshair changed. Choose the image again."; return; }
                Cfg.Set("cross.imageFile", imageFile);
                Cfg.Set("cross.imageName", file.Name);
                Cfg.Set("cross.imageVersion", DateTime.Now.Ticks);
                Show(current);
                Status.Text = "Using " + file.Name;
            }
            catch (Exception ex) { Status.Text = "Could not open the picker: " + ex.Message; }
        }

        // ---------- control builders ----------

        static Color Rgb(string hex) => WidgetTheme.Color(hex);

        void Section(string text) => Body.Children.Add(new TextBlock
        {
            Text = text, FontSize = 15, FontWeight = Windows.UI.Text.FontWeights.SemiBold,
            Foreground = new SolidColorBrush(Rgb(Palette.Muted)), Margin = new Thickness(0, 16, 0, 0),
        });

        void Note(string text) => Body.Children.Add(new TextBlock { Text = text, FontSize = 12, TextWrapping = TextWrapping.Wrap, Foreground = new SolidColorBrush(Rgb(Palette.Muted)) });

        static FrameworkElement Row(params FrameworkElement[] items)
        {
            var g = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
            foreach (var i in items) g.Children.Add(i);
            if (items[0] is TextBox t) t.Width = 220;
            return g;
        }

        FrameworkElement Labeled(string label, FrameworkElement control)
        {
            Windows.UI.Xaml.Automation.AutomationProperties.SetName(control, label);
            var g = new StackPanel { Spacing = 6 };
            g.Children.Add(new TextBlock { Text = label, FontSize = 14, Foreground = new SolidColorBrush(Rgb(Palette.Ink)), TextWrapping = TextWrapping.Wrap });
            control.HorizontalAlignment = HorizontalAlignment.Stretch;
            g.Children.Add(control);
            Body.Children.Add(g);
            return g;
        }

        void Toggle(string label, string key, bool def)
        {
            var t = new ToggleSwitch { IsOn = Cfg.Get(key, def), OnContent = "", OffContent = "", MinWidth = 0, Width = 44, Padding = new Thickness(0) };
            t.Toggled += (s, a) => Cfg.Set(key, t.IsOn);
            Windows.UI.Xaml.Automation.AutomationProperties.SetName(t, label);
            var row = new Grid { ColumnSpacing = 16 };
            row.ColumnDefinitions.Add(new ColumnDefinition());
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.Children.Add(new TextBlock { Text = label, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center });
            Grid.SetColumn(t, 1); row.Children.Add(t); Body.Children.Add(row);
        }

        void Slider(string label, string key, double min, double max, double def, double step)
        {
            var s = new Slider { Minimum = min, Maximum = max, StepFrequency = step, Value = Cfg.Get(key, def) };
            var value = new TextBlock { Foreground = new SolidColorBrush(Rgb(Palette.Ink)), HorizontalAlignment = HorizontalAlignment.Right };
            Func<double, string> format = v => max == 1 ? v.ToString("P0") : v.ToString("0.##") + (key.EndsWith("Ms") ? " ms" : "");
            value.Text = format(s.Value);
            bool syncing = false;
            s.ValueChanged += (o, a) => {
                if (syncing) return;
                if (key == "cross.opacity" || key == "cross.outlineOpacity") Cfg.SetCrossOpacity(a.NewValue, key == "cross.outlineOpacity");
                else Cfg.Set(key, a.NewValue);
                value.Text = format(a.NewValue);
            };
            if (key == "cross.outlineOpacity") {
                Action<string> changed = option => {
                    if (option != key) return;
                    syncing = true; s.Value = Cfg.Get(key, def); value.Text = format(s.Value); syncing = false;
                };
                Cfg.Changed += changed; timerEditorCleanup += () => Cfg.Changed -= changed;
            }
            Windows.UI.Xaml.Automation.AutomationProperties.SetName(s, label);
            var group = new Grid();
            group.Children.Add(new TextBlock { Text = label, Margin = new Thickness(0, 0, 65, 0), TextWrapping = TextWrapping.Wrap });
            group.Children.Add(value);
            var panel = new StackPanel { Spacing = 0 };
            panel.Children.Add(group); panel.Children.Add(s); Body.Children.Add(panel);
        }

        // Measure only the selected label, not the longest item in the popup.
        static ComboBox CompactDropdown(double maximumWidth = 380, string placeholder = "", HorizontalAlignment alignment = HorizontalAlignment.Left)
        {
            var box = new ComboBox {
                MinWidth = 0, MaxWidth = maximumWidth, PlaceholderText = placeholder,
                HorizontalAlignment = alignment, HorizontalContentAlignment = HorizontalAlignment.Left,
                Padding = new Thickness(10, 5, 0, 5)
            };
            Action fit = () => {
                var content = (box.SelectedItem as ComboBoxItem)?.Content ?? box.SelectedItem;
                string label = content?.ToString() ?? box.PlaceholderText;
                var text = new TextBlock { Text = label, FontFamily = box.FontFamily,
                    FontSize = box.FontSize, FontWeight = box.FontWeight, FontStyle = box.FontStyle,
                    CharacterSpacing = box.CharacterSpacing };
                text.Measure(new Windows.Foundation.Size(double.PositiveInfinity, double.PositiveInfinity));
                // The native template gives the arrow its own 32px column, outside Padding.
                box.Width = Math.Min(maximumWidth, Math.Max(64, Math.Ceiling(text.DesiredSize.Width) + 32 +
                    box.Padding.Left + box.Padding.Right + box.BorderThickness.Left + box.BorderThickness.Right));

            };
            box.Loaded += (s, e) => fit();
            box.SelectionChanged += (s, e) => fit();
            return box;
        }

        void Choice(string label, string key, string def, params (string value, string text)[] options)
        {
            var c = CompactDropdown();
            foreach (var o in options) c.Items.Add(new ComboBoxItem { Content = o.text, Tag = o.value });
            c.SelectedIndex = Math.Max(0, Array.FindIndex(options, o => o.value == Cfg.Get(key, def)));
            c.SelectionChanged += (s, a) =>
            {
                Cfg.Set(key, (string)((ComboBoxItem)c.SelectedItem).Tag);
                if (key == "cross.mode") Show(current); // the page's controls depend on the type
            };
            Labeled(label, c);
        }

        void Colors(string label, string key, string def)
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4 };
            var hex = new TextBox { Text = Cfg.Get(key, def), Width = 84, FontSize = 12 };
            foreach (var sw in Swatches)
            {
                var b = new Button { Width = 32, Height = 32, MinWidth = 0, MinHeight = 32, Padding = new Thickness(0), CornerRadius = new CornerRadius(6), Background = new SolidColorBrush(Rgb(sw)), BorderBrush = new SolidColorBrush(Rgb(Palette.Border)), BorderThickness = new Thickness(1) };
                Windows.UI.Xaml.Automation.AutomationProperties.SetName(b, sw);
                b.Click += (s, a) => { Cfg.Set(key, sw); hex.Text = sw; };
                row.Children.Add(b);
            }
            hex.LostFocus += (s, a) => { if (Cfg.Parse(hex.Text) != null) Cfg.Set(key, hex.Text.ToUpper()); else hex.Text = Cfg.Get(key, def); };
            Labeled(label, hex);
            Body.Children.Add(row);
        }

        void Hotkey(string label, string name, string def = "")
        {
            var b = new Button { MinWidth = 120 };
            void Refresh() { var k = Cfg.Get("hotkey." + name, def); b.Content = string.IsNullOrEmpty(k) ? "Set…" : k; }
            Refresh();
            b.Click += (s, a) =>
            {
                if (!OverlaySync.Writable) { Status.Text = "Shortcuts use the Doorlight desktop app."; return; }
                b.Content = "Press keys… (Esc clears)";
                Link.Send("CAPTURE|" + name);
            };
            // ponytail: handlers from earlier page builds stay subscribed (harmless, tiny); unsubscribe on rebuild if it ever matters.
            Cfg.Changed += key => { if (key == "hotkey." + name) Ui(Refresh); };
            Labeled(label, b);
        }
    }
}
