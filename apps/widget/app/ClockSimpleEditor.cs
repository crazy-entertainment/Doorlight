using System;
using System.Linq;
using Windows.UI.Xaml;
using Windows.UI.Xaml.Controls;
using Windows.UI.Xaml.Automation;
using Windows.UI.Xaml.Media;

namespace WidgetSampleCS
{
    public sealed partial class HelperWidget
    {
        void ClockEditorLink(bool advanced)
        {
            Body.Children.Add(EditorModeButton(advanced, () => Cfg.Set("helper.clockEditorMode", advanced ? "advanced" : "simple")));
        }

        ComboBox SimpleTimeKind(string active)
        {
            var kind = CompactDropdown(112);
            foreach (var text in new[] { "Clock", "Stopwatch", "Countdown" }) kind.Items.Add(text);
            kind.SelectedItem = active;
            AutomationProperties.SetName(kind, "Clock, stopwatch or countdown");
            kind.SelectionChanged += async (s, e) => {
                string selection = kind.SelectedItem as string;
                if (selection == active || selection == null) return;
                bool created = false;
                string timerId = null;
                if (selection == "Clock") {
                    selectedClock = Clocks.Ids.FirstOrDefault();
                    if (selectedClock == null) {
                        created = true;
                        selectedClock = Guid.NewGuid().ToString("N");
                        Cfg.Set(Clocks.Key(selectedClock) + "name", "Clock");
                        Cfg.Set("clock.ids", selectedClock);
                    }
                    Cfg.Set("time.kind", "clock");
                } else {
                    var timer = TimerState.Records.FirstOrDefault(t => t.Mode == selection);
                    if (timer == null) {
                        created = true;
                        TimerState.Create(selection); TimerState.SetMode(selection);
                        Cfg.Set("timer.simpleEmptyDuration." + TimerState.ActiveId, true);
                        SetDefaultTimerShortcuts(TimerState.ActiveId);
                    } else TimerState.Select(timer.Id);
                    timerId = TimerState.ActiveId;
                    Cfg.Set("time.kind", "timer");
                }
                Show(tabs[2]);
                if (created) {
                    try { await ShowWidget(selection == "Clock" ? "clock" : "timer", selection == "Clock" ? "Clock" : "Timer", timerId); }
                    catch (Exception ex) { Status.Text = "Could not show " + selection.ToLowerInvariant() + ": " + ex.Message; }
                }
            };
            return kind;
        }

        static void SetDefaultTimerShortcuts(string id)
        {
            foreach (var action in new[] { ("toggle", "Ctrl+Alt+T"), ("reset", "Ctrl+Alt+R") }) {
                string key = "hotkey.timer." + id + "." + action.Item1;
                // A shortcut belongs to one timer; never replace an owner's assignment.
                bool taken = Cfg.HotkeyInUse(action.Item2);
                if (!taken && Cfg.Get(key, (string)null) == null) Cfg.Set(key, action.Item2);
            }
        }

        void BuildSimpleClock(string key)
        {
            var formats = CompactDropdown(168);
            formats.HorizontalAlignment = HorizontalAlignment.Stretch;
            AutomationProperties.SetName(formats, "Time and date layout");
            var hours = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 2 };
            var hour24 = new Windows.UI.Xaml.Controls.Primitives.ToggleButton { Content = "24h", MinWidth = 0, Padding = new Thickness(7, 6, 7, 6), MinHeight = 36 };
            var hour12 = new Windows.UI.Xaml.Controls.Primitives.ToggleButton { Content = "AM/PM", MinWidth = 0, Padding = new Thickness(7, 6, 7, 6), MinHeight = 36 };
            hours.Children.Add(hour24); hours.Children.Add(hour12);
            bool ampm = Cfg.Get(key + "format", "HH:mm").Contains("tt");
            bool filling = false;
            var sample = new DateTimeOffset(2026, 10, 20, 21, 47, 8, TimeSpan.Zero);
            string TimePattern(bool seconds) => Clocks.SimpleTimeFormat(ampm, seconds);
            void Fill() {
                filling = true; formats.Items.Clear();
                AutomationProperties.SetName(hours, "Hour format");
                string savedFormat = Cfg.Get(key + "format", "HH:mm");
                ampm = savedFormat.Contains("tt"); hour24.IsChecked = !ampm; hour12.IsChecked = ampm;
                hour24.IsEnabled = hour12.IsEnabled = Clocks.TryHourFormat(savedFormat, ampm, out _);
                bool date = Cfg.Get(key + "date", false), dateOnly = Cfg.Get(key + "dateOnly", false);
                string savedDate = Cfg.Get(key + "dateFormat", "ddd d MMM"), savedLayout = Cfg.Get(key + "layout", "stacked");
                void Add(string label, bool secs, string datePattern, string layout, bool only = false) {
                    var item = new ComboBoxItem { Content = label, Tag = new object[] { secs, datePattern, layout, only } };
                    formats.Items.Add(item);
                    if (dateOnly == only && (only || savedFormat == TimePattern(secs)) && date == (datePattern != "") && (!date || (savedDate == datePattern && (only || savedLayout == layout)))) formats.SelectedItem = item;
                }
                foreach (bool secs in new[] { false, true }) Add(sample.ToString(TimePattern(secs)), secs, "", "single");
                foreach (var group in new[] { ("Time + date · one line", "dd.MM.yyyy", "single"), ("Time + date · year first", "yyyy-MM-dd", "single"), ("Time + date · two lines", "ddd d MMM", "stacked") }) {
                    foreach (bool secs in new[] { false, true }) Add(sample.ToString(TimePattern(secs)) + (group.Item3 == "single" ? " · " : " / ") + sample.ToString(group.Item2), secs, group.Item2, group.Item3);
                }
                Add(sample.ToString("ddd d MMM yyyy"), false, "ddd d MMM yyyy", "single", true);
                if (formats.SelectedIndex < 0) {
                    var custom = new ComboBoxItem { Content = "Custom · " + Clocks.Text(selectedClock, sample).Replace("\n", " / ") };
                    formats.Items.Add(custom); formats.SelectedItem = custom;
                }
                filling = false;
            }
            formats.SelectionChanged += (s, e) => {
                if (filling || !((formats.SelectedItem as ComboBoxItem)?.Tag is object[] values)) return;
                Cfg.Set(key + "format", TimePattern((bool)values[0]));
                Cfg.Set(key + "date", (string)values[1] != "");
                Cfg.Set(key + "dateOnly", (bool)values[3]);
                if ((string)values[1] != "") Cfg.Set(key + "dateFormat", (string)values[1]);
                Cfg.Set(key + "layout", (string)values[2]);
                Fill();
            };
            void SetHours(bool value) {
                string pattern = Cfg.Get(key + "format", "HH:mm");
                if (Clocks.TryHourFormat(pattern, value, out string converted)) Cfg.Set(key + "format", converted);
                Fill();
            }
            hour24.Click += (s, e) => SetHours(false);
            hour12.Click += (s, e) => SetHours(true);
            Fill();
            var row = new Grid { ColumnSpacing = 6 };
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.ColumnDefinitions.Add(new ColumnDefinition());
            row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            row.Children.Add(SimpleTimeKind("Clock")); Grid.SetColumn(formats, 1); row.Children.Add(formats); Grid.SetColumn(hours, 2); row.Children.Add(hours);
            Body.Children.Add(row);
        }

        void BuildSimpleTimer(Func<System.Threading.Tasks.Task> ensure)
        {
            var record = TimerState.Active;
            Func<bool> commit = () => true;
            var play = TimerIcon("\uE768", "Start"); var reset = TimerIcon("\uE777", "Reset");
            play.Background = new SolidColorBrush(Rgb(Palette.Fill)); play.Foreground = new SolidColorBrush(Rgb(Palette.OnAccent));
            var controls = Row(play, reset);
            Body.Children.Add(Pair(SimpleTimeKind(record.Mode), controls, false, 8));
            if (record.Mode == "Countdown" && record.Kind == "Until") {
                Note("Scheduled countdown. Use Advanced to change the end time.");
            } else if (record.Mode == "Countdown") {
                double total = record.DurationMilliseconds / 1000;
                var minutes = new TextBox { Text = Cfg.Get("timer.simpleEmptyDuration." + record.Id, false) ? "" : ((int)(total / 60)).ToString(), PlaceholderText = "05", Width = 76, MinWidth = 0, MaxLength = 7, InputScope = new Windows.UI.Xaml.Input.InputScope { Names = { new Windows.UI.Xaml.Input.InputScopeName { NameValue = Windows.UI.Xaml.Input.InputScopeNameValue.Number } } } };
                var seconds = new TextBox { Text = Cfg.Get("timer.simpleEmptyDuration." + record.Id, false) ? "" : (total % 60).ToString(System.Globalization.CultureInfo.InvariantCulture), PlaceholderText = "00", Width = 64, MinWidth = 0, MaxLength = 6 };
                AutomationProperties.SetName(minutes, "Countdown minutes"); AutomationProperties.SetName(seconds, "Countdown seconds");
                var fields = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
                fields.Children.Add(minutes); fields.Children.Add(new TextBlock { Text = "min", VerticalAlignment = VerticalAlignment.Center });
                fields.Children.Add(seconds); fields.Children.Add(new TextBlock { Text = "sec", VerticalAlignment = VerticalAlignment.Center });
                Body.Children.Add(fields);
                bool edited = false;
                minutes.TextChanged += (s, e) => edited = true; seconds.TextChanged += (s, e) => edited = true;
                commit = () => {
                    if (TimerState.ActiveId != record.Id) return false;
                    if (!edited) {
                        if (Cfg.Get("timer.simpleEmptyDuration." + record.Id, false)) { Status.Text = "Enter minutes or seconds."; return false; }
                        return true;
                    }
                    double min = 0, sec = 0;
                    if ((!string.IsNullOrWhiteSpace(minutes.Text) && !double.TryParse(minutes.Text, System.Globalization.NumberStyles.AllowDecimalPoint, System.Globalization.CultureInfo.InvariantCulture, out min)) || (!string.IsNullOrWhiteSpace(seconds.Text) && !double.TryParse(seconds.Text, System.Globalization.NumberStyles.AllowDecimalPoint, System.Globalization.CultureInfo.InvariantCulture, out sec)) || min < 0 || sec < 0 || sec >= 60 || min * 60 + sec <= 0 || min * 60 + sec > TimerState.MaxSeconds) { Status.Text = "Enter minutes and 0–59 seconds."; return false; }
                    double duration = min * 60 + sec;
                    if (Cfg.Get("timer.simpleEmptyDuration." + record.Id, false) || Math.Abs(TimerState.Total - duration) > .0001) TimerState.SetDuration(duration);
                    edited = false; Status.Text = ""; return true;
                };
                minutes.LostFocus += (s, e) => commit(); seconds.LostFocus += (s, e) => commit();
            }
            play.Click += async (s, e) => {
                if (TimerState.ActiveId != record.Id || !commit()) return;
                try { await TimerState.ToggleAfterActivationAsync(record.Id, ensure); }
                catch (Exception ex) { Status.Text = "Could not open timer: " + ex.Message; }
            };
            reset.Click += (s, e) => { if (commit()) TimerState.Reset(); };
            void Refresh() { ((FontIcon)play.Content).Glyph = TimerState.Running ? "\uE769" : "\uE768"; AutomationProperties.SetName(play, TimerState.Running ? "Pause" : "Start"); }
            Action<string> changed = key => { if (key == "timer.records.v2") Ui(Refresh); };
            Cfg.Changed += changed; timerEditorCleanup += () => Cfg.Changed -= changed; Refresh();
            foreach (var action in new[] { ("Start / pause", "toggle"), ("Reset", "reset") }) {
                string name = "timer." + record.Id + "." + action.Item2;
                var assign = TimerButton("", () => {
                    if (Link.HelperVersion == null) { Status.Text = "Background part not running."; return; }
                    Status.Text = "Press shortcut keys (Esc clears)."; Link.Send("CAPTURE|" + name);
                });
                void RefreshKey() { string keys = Cfg.Get("hotkey." + name, ""); assign.Content = keys.Length == 0 ? "Set…" : keys; }
                RefreshKey(); AutomationProperties.SetName(assign, action.Item1 + " shortcut");
                Body.Children.Add(Pair(new TextBlock { Text = action.Item1, VerticalAlignment = VerticalAlignment.Center }, assign, false, 8));
                Action<string> keyChanged = key => { if (key == "hotkey." + name) Ui(RefreshKey); };
                Cfg.Changed += keyChanged; timerEditorCleanup += () => Cfg.Changed -= keyChanged;
            }
        }
    }
}
