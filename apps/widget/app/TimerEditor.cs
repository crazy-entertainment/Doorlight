using System;
using System.Linq;
using Windows.UI.Xaml;
using Windows.UI.Xaml.Controls;
using Windows.UI.Xaml.Media;
using Windows.UI.Xaml.Automation;

namespace WidgetSampleCS
{
    public sealed partial class HelperWidget
    {
        Action timerEditorCleanup;
        int settingsResizeGeneration;
        double settingsTargetHeight = -1;
        async void FitTimerSettings()
        {
            if (current == null || !IsLoaded || pageClosed) return;
            try {
                double width = widget == null ? Math.Max(420, ActualWidth) : 420;
                var measure = new Windows.Foundation.Size(width, double.PositiveInfinity);
                Body.Measure(measure); Tabs.Measure(measure); DesktopSetupNotice.Measure(measure); PageHeader.Measure(measure); Footer.Measure(measure);
                double height = Body.DesiredSize.Height + Tabs.DesiredSize.Height + DesktopSetupNotice.DesiredSize.Height + PageHeader.DesiredSize.Height + Footer.DesiredSize.Height;
                var display = Windows.Graphics.Display.DisplayInformation.GetForCurrentView();
                double maximum = Math.Min(980, display.ScreenHeightInRawPixels / display.RawPixelsPerViewPixel - 100);
                height = Math.Max(180, Math.Min(maximum, Math.Ceiling(height)));
                Scroller.VerticalScrollBarVisibility = ScrollBarVisibility.Auto;
                if (Math.Abs(settingsTargetHeight - height) < 1) return;
                settingsTargetHeight = height;
                int generation = ++settingsResizeGeneration;
                var view = Windows.UI.ViewManagement.ApplicationView.GetForCurrentView();
                if (widget != null) widget.MinWindowSize = new Windows.Foundation.Size(420, 180);
                else view.SetPreferredMinSize(new Windows.Foundation.Size(420, 180));
                double from = widget == null ? ActualHeight : widget.WindowBounds.Height;
                var elapsed = System.Diagnostics.Stopwatch.StartNew();
                while (!pageClosed && generation == settingsResizeGeneration) {
                    double progress = WidgetTheme.AnimationsEnabled ? Math.Min(1, elapsed.Elapsed.TotalMilliseconds / 180) : 1;
                    double eased = 1 - Math.Pow(1 - progress, 3);
                    var size = new Windows.Foundation.Size(width, Math.Round(from + (height - from) * eased));
                    bool resized = widget == null ? view.TryResizeView(size) : await widget.TryResizeWindowAsync(size);
                    if (!resized || progress >= 1) break;
                    await System.Threading.Tasks.Task.Delay(16);
                }
            } catch (Exception ex) { settingsTargetHeight = -1; Log.Write("settings size: " + ex.Message); }
        }
        void TimerDivider() => Body.Children.Add(new Border {
            Height = 1, Background = new SolidColorBrush(Rgb(Palette.Border)),
            Margin = new Thickness(0, 4, 0, 0), HorizontalAlignment = HorizontalAlignment.Stretch
        });
        void CompactTimer()
        {

            Scroller.VerticalScrollBarVisibility = ScrollBarVisibility.Hidden;


            TimerNames();
            if (TimerState.Active == null) { EmptyWidget("clocks or timers"); return; }
            string timerId = TimerState.ActiveId;
            System.Threading.Tasks.Task EnsureTimer() => ShowWidget("timer", "Timer", timerId);
            if (Cfg.Get("helper.clockEditorMode", "simple") != "advanced") { BuildSimpleTimer(EnsureTimer); return; }
            var buttons = AdvancedTimerControls(EnsureTimer);
            var play = buttons[0]; var visible = buttons[1]; var reset = buttons[2];
            var shortcutPanel = new StackPanel { Spacing = 6 };
            var shortcutHelp = new TextBlock { Text = "", TextWrapping = TextWrapping.Wrap, FontSize = 12, Visibility = Visibility.Collapsed };
            TimerDivider();
            Section("Controls & alerts");
            ((FrameworkElement)Body.Children[Body.Children.Count - 1]).Margin = new Thickness(0, 4, 0, 0);
            foreach (var shortcut in new[] { ("Start / pause", "timer." + TimerState.ActiveId + ".toggle", play), ("Show / hide", "timer." + TimerState.ActiveId + ".visibility", visible), ("Reset", "timer." + TimerState.ActiveId + ".reset", reset) }) {
                var assign = new Button { MinWidth = 120, MinHeight = 36, Padding = new Thickness(8, 3, 8, 3), HorizontalAlignment = HorizontalAlignment.Stretch };
                void RefreshShortcut() {
                    var key = Cfg.Get("hotkey." + shortcut.Item2, "");
                    assign.Content = string.IsNullOrEmpty(key) ? "Set…" : key;

                }
                assign.Click += (s, e) => {
                    shortcutHelp.Visibility = Visibility.Visible;
                    if (Link.HelperVersion == null) { shortcutHelp.Text = "Background part not running."; return; }
                    shortcutHelp.Text = shortcut.Item1 + ": press keys (Esc clears).";
                    assign.Content = "Press keys…"; Link.Send("CAPTURE|" + shortcut.Item2);
                };
                AutomationProperties.SetName(assign, shortcut.Item1 + " shortcut");
                shortcutPanel.Children.Add(Pair(new TextBlock { Text = shortcut.Item1, VerticalAlignment = VerticalAlignment.Center }, assign, false, 12));
                RefreshShortcut();
                Action<string> changed = key => { if (key == "hotkey." + shortcut.Item2) Ui(() => { RefreshShortcut(); shortcutHelp.Text = ""; shortcutHelp.Visibility = Visibility.Collapsed; }); };
                Cfg.Changed += changed; timerEditorCleanup += () => Cfg.Changed -= changed;
            }
            shortcutPanel.Children.Add(shortcutHelp); Body.Children.Add(shortcutPanel);
            int effectsStart = Body.Children.Count;
            var effects = new Grid { ColumnSpacing = 6 };
            foreach (var effect in new[] { ("Confetti", "timer.confetti", true), ("Flash timer", "timer.flash", false) }) {
                var b = new CheckBox { Content = effect.Item1, IsChecked = Cfg.Get(effect.Item2, effect.Item3), MinWidth = 0, MinHeight = 32, FontSize = 12 };
                b.Checked += (s, e) => Cfg.Set(effect.Item2, true);
                b.Unchecked += (s, e) => Cfg.Set(effect.Item2, false);
                effects.ColumnDefinitions.Add(new ColumnDefinition()); Grid.SetColumn(b, effects.Children.Count); effects.Children.Add(b);
            }
            Body.Children.Add(Pair(new TextBlock { Text = "When finished", VerticalAlignment = VerticalAlignment.Center }, effects, false, 16));
            var sounds = new Grid { ColumnSpacing = 8 };
            var volume = TakeSlider("Volume", "timer.volume", 0, 1, .5, .05);
            bool syncingSound = false;
            void SoundStyle() {
                syncingSound = true;
                foreach (RadioButton b in sounds.Children) b.IsChecked = (string)b.Content == Cfg.Get("timer.sound", "Silent");
                syncingSound = false;
            }
            var customFile = new Button { Content = Cfg.Get("timer.soundName", "Choose audio…"), HorizontalAlignment = HorizontalAlignment.Stretch, MaxWidth = 360 };

            async System.Threading.Tasks.Task PickSound() {
                try {
                    var picker = new Windows.Storage.Pickers.FileOpenPicker();
                    foreach (var extension in new[] { ".wav", ".mp3", ".m4a", ".flac" }) picker.FileTypeFilter.Add(extension);
                    var file = await picker.PickSingleFileAsync();
                    if (file == null) return;
                    var properties = await file.GetBasicPropertiesAsync();
                    if (properties.Size > 20 * 1024 * 1024) { Status.Text = "Choose an audio file smaller than 20 MB."; return; }
                    var name = "timer-custom-" + TimerState.ActiveId + file.FileType.ToLowerInvariant();
                    await file.CopyAsync(Windows.Storage.ApplicationData.Current.LocalFolder, name, Windows.Storage.NameCollisionOption.ReplaceExisting);
                    Cfg.Set("timer.soundFile", name); Cfg.Set("timer.soundName", file.Name); Cfg.Set("timer.sound", "Custom");
                    customFile.Content = file.Name; customFile.Visibility = Visibility.Visible; volume.Visibility = Visibility.Visible; SoundStyle(); FitTimerSettings();
                } catch (Exception ex) { Status.Text = "Could not load sound: " + ex.Message; }
            }
            customFile.Click += async (s, e) => await PickSound();
            foreach (var sound in new[] { "Silent", "Chime", "Bell", "Custom" }) {
                var b = new RadioButton { Content = sound, GroupName = "TimerSound", MinWidth = 0, MinHeight = 32, FontSize = 12 };
                b.Checked += async (s, e) => { if (syncingSound) return; if (sound == "Custom" && string.IsNullOrEmpty(Cfg.Get("timer.soundFile", ""))) { await PickSound(); SoundStyle(); return; } Cfg.Set("timer.sound", sound); customFile.Visibility = sound == "Custom" ? Visibility.Visible : Visibility.Collapsed; volume.Visibility = sound == "Silent" ? Visibility.Collapsed : Visibility.Visible; SoundStyle(); FitTimerSettings(); };
                sounds.ColumnDefinitions.Add(new ColumnDefinition()); Grid.SetColumn(b, sounds.Children.Count); sounds.Children.Add(b);
            }
            SoundStyle();
            Body.Children.Add(Pair(new TextBlock { Text = "Sound", VerticalAlignment = VerticalAlignment.Center }, sounds, false, 16));
            var soundDetails = new StackPanel { Spacing = 6 };
            volume.Visibility = Cfg.Get("timer.sound", "Silent") == "Silent" ? Visibility.Collapsed : Visibility.Visible; soundDetails.Children.Add(volume);
            customFile.Visibility = Cfg.Get("timer.sound", "Silent") == "Custom" ? Visibility.Visible : Visibility.Collapsed; soundDetails.Children.Add(customFile);
            soundDetails.Visibility = Cfg.Get("timer.sound", "Silent") == "Silent" ? Visibility.Collapsed : Visibility.Visible;
            Body.Children.Add(soundDetails);
            Action<string> soundDetailsChanged = key => { if (key == "timer.sound") Ui(() => { soundDetails.Visibility = Cfg.Get("timer.sound", "Silent") == "Silent" ? Visibility.Collapsed : Visibility.Visible; FitTimerSettings(); }); };
            Cfg.Changed += soundDetailsChanged; timerEditorCleanup += () => Cfg.Changed -= soundDetailsChanged;
            if (TimerState.Active.Mode == "Stopwatch") for (int i = effectsStart; i < Body.Children.Count; i++) Body.Children[i].Visibility = Visibility.Collapsed;
            TimerDivider();
            Section("Appearance");
            ((FrameworkElement)Body.Children[Body.Children.Count - 1]).Margin = new Thickness(0);
            Body.Children.Add(Pair(new TextBlock { Text = "Color", VerticalAlignment = VerticalAlignment.Center }, ColorChip("timer.color", "#FFFFFF", "Timer color"), false));
            Toggle("Progress bar", "timer.progress", false);
            var progress = (FrameworkElement)Body.Children[Body.Children.Count - 1]; Body.Children.Remove(progress);
            var color = (FrameworkElement)Body.Children[Body.Children.Count - 1]; Body.Children.Remove(color);
            if (TimerState.Active.Mode == "Stopwatch") progress.Visibility = Visibility.Collapsed;
            Body.Children.Add(Pair(color, progress));
            RoutedEventHandler unloaded = null;
            unloaded = (s, e) => { timerEditorCleanup?.Invoke(); timerEditorCleanup = null; Unloaded -= unloaded; };
            Unloaded += unloaded;
            timerEditorCleanup += () => Unloaded -= unloaded;
        }
    }
}
