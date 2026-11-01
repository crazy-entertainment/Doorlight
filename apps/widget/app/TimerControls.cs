using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
using Windows.Foundation;
using Windows.UI.Xaml;
using Windows.UI.Xaml.Controls;
using Windows.UI.Xaml.Controls.Primitives;
using Windows.UI.Xaml.Media;
using Windows.UI.Xaml.Automation;

namespace WidgetSampleCS
{
    // Content-sized chips wrap without giving punctuation the width of a whole time field.
    sealed class TimerFlow : Panel
    {
        protected override Size MeasureOverride(Size available)
        {
            double x = 0, y = 0, row = 0, width = 0;
            foreach (FrameworkElement c in Children) {
                c.Measure(new Size(available.Width, double.PositiveInfinity));
                if (x > 0 && x + c.DesiredSize.Width > available.Width) { y += row + 6; x = row = 0; }
                width = Math.Max(width, x + c.DesiredSize.Width); x += c.DesiredSize.Width + 6; row = Math.Max(row, c.DesiredSize.Height);
            }
            return new Size(width, y + row);
        }
        protected override Size ArrangeOverride(Size final)
        {
            double x = 0, y = 0, row = 0;
            foreach (FrameworkElement c in Children) {
                if (x > 0 && x + c.DesiredSize.Width > final.Width) { y += row + 6; x = row = 0; }
                c.Arrange(new Rect(x, y, c.DesiredSize.Width, c.DesiredSize.Height)); x += c.DesiredSize.Width + 6; row = Math.Max(row, c.DesiredSize.Height);
            }
            return final;
        }
    }

    public sealed partial class HelperWidget
    {
        static readonly string[] TimerUnits = { "Days", "Hours", "Minutes", "Seconds", "Milliseconds" };
        Button TimerButton(string text, Action action)
        {
            var b = new Button { Content = text, MinWidth = 0, Padding = new Thickness(8, 4, 8, 4), FontSize = 12 };
            b.Click += (s, e) => { try { action(); } catch (ArgumentException ex) { Status.Text = ex.Message; } }; return b;
        }
        Button TimerIcon(string glyph, string name)
        {
            var b = new Button { Width = 36, Height = 36, MinWidth = 0, Padding = new Thickness(0), Content = new FontIcon { FontFamily = new FontFamily("Segoe MDL2 Assets"), Glyph = glyph, FontSize = 16 } };
            AutomationProperties.SetName(b, name); return b;
        }
        void TimerNames()
        {
            var names = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center };
            Grid.SetColumn(names, 1); PageHeader.Children.Add(names);
            timerEditorCleanup += () => PageHeader.Children.Remove(names);
            var records = TimerState.Records;
            names.Children.Add(TimeSelector());
            var more = TimerIcon("\uE712", "Time actions"); var menu = new MenuFlyout(); more.Flyout = menu; names.Children.Add(WidgetActions(more, "timer", "Timer"));
            AddTimeActions(menu);
            var delete = new MenuFlyoutItem { Text = "Delete", Icon = new SymbolIcon(Symbol.Delete), IsEnabled = records.Count > 0 };
            var rename = new MenuFlyoutItem { Text = "Rename", Icon = new SymbolIcon(Symbol.Edit), IsEnabled = records.Count > 0 }; menu.Items.Add(rename); menu.Items.Add(delete); WidgetMenu(menu, "timer", "Timer");            rename.Click += (s, e) => {
                var input = new TextBox { Text = TimerState.Active.Name, MaxLength = 32, Width = 230 }; AutomationProperties.SetName(input, "Timer name");
                var panel = new StackPanel { Spacing = 8 }; panel.Children.Add(input);
                var flyout = new Flyout { Content = panel, Placement = Windows.UI.Xaml.Controls.Primitives.FlyoutPlacementMode.BottomEdgeAlignedRight, ShouldConstrainToRootBounds = false };
                panel.Children.Add(TimerButton("Save", () => { TimerState.Rename(TimerState.ActiveId, input.Text); flyout.Hide(); Show(current); }));
                flyout.ShowAt(more); input.SelectAll(); input.Focus(FocusState.Programmatic);
            };

            delete.Click += (s, e) => { TimerState.Delete(TimerState.ActiveId); Show(current); };
        }

        Button[] AdvancedTimerControls(Func<Task> ensure)
        {
            var record = TimerState.Active;
            var visible = TimerButton(record.Visible ? "Visible" : "Hidden", () => {});
            visible.Background = new SolidColorBrush(Windows.UI.Colors.Transparent); visible.BorderThickness = new Thickness(0);
            visible.Click += async (s, e) => {
                var target = TimerState.Records.FirstOrDefault(item => item.Id == record.Id); if (target == null) return;
                bool show = !target.Visible; TimerState.SetVisible(record.Id, show); visible.Content = show ? "Visible" : "Hidden";
                try { if (show) await ensure(); } catch (Exception ex) { Status.Text = "Could not open timer: " + ex.Message; }
            };
            var inputArea = new StackPanel { Spacing = 8 };
            var play = TimerIcon("\uE768", "Start"); var reset = TimerIcon("\uE777", "Reset");
            play.Background = new SolidColorBrush(Rgb(Palette.Fill)); play.Foreground = new SolidColorBrush(Rgb(Palette.OnAccent));
            var controls = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center }; controls.Children.Add(play); controls.Children.Add(reset);
            Func<bool> commit = () => true;
            if (record.Mode == "Countdown") {
                var kinds = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 12 };
                foreach (var kind in new[] { "Duration", "Until" }) {
                    var radio = new RadioButton { Content = kind, IsChecked = record.Kind == kind, GroupName = "TimerKind", MinWidth = 0 };
                    radio.Checked += (s, e) => { if (TimerState.Active.Kind != kind) { TimerState.SetKind(kind); Show(current); } }; kinds.Children.Add(radio);
                }
                Body.Children.Add(kinds);
                if (record.Kind == "Until") {
                    var deadline = record.UntilUtcTicks > 0 ? new DateTime(record.UntilUtcTicks, DateTimeKind.Utc).ToLocalTime() : DateTime.Now.AddHours(1);
                    var date = new CalendarDatePicker { Date = deadline, MinWidth = 130, MaxWidth = 170, DateFormat = "{day.integer} {month.abbreviated} {year.full}" };
                    var time = new TimePicker { Time = deadline.TimeOfDay, ClockIdentifier = "24HourClock", MinWidth = 110 };
                    AutomationProperties.SetName(date, "End date"); AutomationProperties.SetName(time, "End time");
                    inputArea.Children.Add(date); inputArea.Children.Add(time);
                    commit = () => { if (TimerState.ActiveId != record.Id) return false; if (!date.Date.HasValue) { Status.Text = "Choose an end date."; return false; } var end = date.Date.Value.Date + time.Time; if (end <= DateTime.Now) { Status.Text = "Choose a time in the future."; return false; } if (TimerState.Active.UntilUtcTicks != end.ToUniversalTime().Ticks) TimerState.SetUntil(end.ToUniversalTime()); Status.Text = ""; return true; };
                } else {
                    var values = new Dictionary<string, TextBox>();
                    var duration = TimeSpan.FromMilliseconds(record.DurationMilliseconds);
                    var initial = new[] { duration.Days, duration.Hours, duration.Minutes, duration.Seconds, duration.Milliseconds };
                    var fields = new TimerFlow();
                    for (int i = 0; i < TimerUnits.Length; i++) {
                        string unit = TimerUnits[i];
                        var box = new TextBox { Text = initial[i].ToString(), Width = unit == "Milliseconds" ? 76 : 62, MinWidth = 0, MaxLength = i == 0 || i == 4 ? 3 : 2, FontSize = 20, TextAlignment = TextAlignment.Center, Padding = new Thickness(3) };
                        AutomationProperties.SetName(box, unit); values.Add(unit, box);
                        var group = new StackPanel { Spacing = 3, Visibility = i == 2 || i == 3 || initial[i] > 0 ? Visibility.Visible : Visibility.Collapsed };
                        group.Children.Add(new TextBlock { Text = unit == "Milliseconds" ? "Millisec." : unit, FontSize = 12 }); group.Children.Add(box); fields.Children.Add(group);
                    }
                    commit = () => {
                        if (TimerState.ActiveId != record.Id) return false;
                        var nums = new int[5]; int[] max = { 999, 23, 59, 59, 999 };
                        for (int i = 0; i < 5; i++) if (!int.TryParse(values[TimerUnits[i]].Text, out nums[i]) || nums[i] < 0 || nums[i] > max[i]) { Status.Text = TimerUnits[i] + ": enter 0–" + max[i] + "."; return false; }
                        double seconds = nums[0] * 86400.0 + nums[1] * 3600 + nums[2] * 60 + nums[3] + nums[4] / 1000.0;
                        if (seconds <= 0) { Status.Text = "Enter a duration greater than zero."; return false; }
                        if (Cfg.Get("timer.simpleEmptyDuration." + TimerState.ActiveId, false) || Math.Abs(seconds - TimerState.Total) > .0001) TimerState.SetDuration(seconds); Status.Text = ""; return true;
                    };
                    foreach (var box in values.Values) box.LostFocus += (s, e) => commit();
                    inputArea.Children.Add(fields);
                    var unitsButton = TimerButton("+ Units", () => {}); var unitMenu = new MenuFlyout(); unitsButton.Flyout = unitMenu;
                    for (int i = 0; i < 5; i++) { int index = i; if (i == 2 || i == 3) continue;
                        var item = new ToggleMenuFlyoutItem { Text = TimerUnits[i], IsChecked = fields.Children[i].Visibility == Visibility.Visible };
                        item.Click += (s, e) => { fields.Children[index].Visibility = item.IsChecked ? Visibility.Visible : Visibility.Collapsed; if (!item.IsChecked) { values[TimerUnits[index]].Text = "0"; commit(); } FitTimerSettings(); }; unitMenu.Items.Add(item);
                    }
                    var suggestions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 5 };
                    foreach (var seconds in TimerState.Suggestions()) {
                        var b = TimerButton(seconds % 60 == 0 ? seconds / 60 + " min" : TimerState.Format(seconds), () => { TimerState.SetDuration(seconds); Show(current); }); suggestions.Children.Add(b);
                    }
                    // Suggestions follow the duration controls below.
                    inputArea.Tag = Pair(suggestions, unitsButton, false);
                }
            }
            if (inputArea.Children.Count > 0) Body.Children.Add(inputArea);
            if (inputArea.Tag is FrameworkElement quick) Body.Children.Add(quick);
            play.Click += async (s, e) => {
                if (TimerState.ActiveId != record.Id || !commit()) return;
                try { await TimerState.ToggleAfterActivationAsync(record.Id, ensure); Refresh(); }
                catch (Exception ex) { Status.Text = "Could not open timer: " + ex.Message; }
            };
            reset.Click += (s, e) => { if (TimerState.ActiveId == record.Id && commit()) { TimerState.Reset(record.Id); Refresh(); } };
            void Refresh() { visible.Content = TimerState.Active?.Visible == true ? "Visible" : "Hidden"; ((FontIcon)play.Content).Glyph = TimerState.Running ? "\uE769" : "\uE768"; AutomationProperties.SetName(play, TimerState.Running ? "Pause" : "Start"); }
            Action<string> changed = key => { if (key == "timer.records.v2" || key == "timer.activeId") Ui(Refresh); };
            Cfg.Changed += changed; timerEditorCleanup += () => Cfg.Changed -= changed; Refresh();
            TimerDisplayEditor(controls);
            return new[] { play, visible, reset };
        }

        void TimerDisplayEditor(FrameworkElement controls)
        {
            TimerDivider();
            var formats = TimerButton("Choose a format", () => {}); formats.Background = new SolidColorBrush(Windows.UI.Colors.Transparent); formats.BorderThickness = new Thickness(0);
            Body.Children.Add(Pair(new TextBlock { Text = "Display", FontWeight = Windows.UI.Text.FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center }, Row(formats, controls), false, 8));
            var chips = new TimerFlow();
            Body.Children.Add(new Border { Background = new SolidColorBrush(Rgb(Palette.Desk)), BorderBrush = new SolidColorBrush(Rgb(Palette.Border)), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(8), Padding = new Thickness(10), Child = chips });
            var parts = TimerState.Active.Parts.ToList();
            var live = new Dictionary<Button, TimerDisplayPart>();
            var update = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(100) };
            update.Tick += (s, e) => { foreach (var pair in live) pair.Key.Content = TimerState.FormatPart(TimerState.ActiveId, pair.Value); }; update.Start(); timerEditorCleanup += () => update.Stop();
            void Save() { TimerState.SetParts(parts); }
            void Draw() {
                chips.Children.Clear(); live.Clear();
                foreach (var part in parts.ToArray()) {
                    var stack = new StackPanel { Spacing = 3 };
                    var caption = new TextBlock { Text = string.IsNullOrEmpty(part.Unit) ? "Text" : (string.IsNullOrEmpty(part.SourceId) ? "" : (TimerState.Records.FirstOrDefault(t => t.Id == part.SourceId)?.Name ?? "Deleted timer") + " · ") + part.Unit, FontSize = 12, Foreground = new SolidColorBrush(Rgb(Palette.Muted)), HorizontalAlignment = HorizontalAlignment.Center };
                    var actions = new MenuFlyout();
                    if (string.IsNullOrEmpty(part.Unit)) {
                        var text = new TextBox { Text = part.Text ?? "", MaxLength = 60, MinWidth = 24, MaxWidth = 300, BorderThickness = new Thickness(0), Padding = new Thickness(2), FontSize = 18, Background = new SolidColorBrush(Windows.UI.Colors.Transparent) };
                        AutomationProperties.SetName(text, "Display text");
                        text.Width = Math.Max(24, Math.Min(290, (text.Text.Length + 1) * 9)); text.TextChanged += (s, e) => { part.Text = text.Text; text.Width = Math.Max(24, Math.Min(290, (text.Text.Length + 1) * 9)); Save(); }; stack.Children.Add(text);
                    } else {
                        string source = string.IsNullOrEmpty(part.SourceId) ? TimerState.ActiveId : part.SourceId;
                        var value = TimeSpan.FromSeconds(TimerState.Value(source));
                        int n = part.Unit == "Days" ? value.Days : part.Unit == "Hours" ? value.Hours : part.Unit == "Minutes" ? value.Minutes : part.Unit == "Seconds" ? value.Seconds : value.Milliseconds;
                        var number = TimerButton(TimerState.FormatPart(TimerState.ActiveId, part), () => {}); number.FontSize = 22; number.BorderThickness = new Thickness(0); number.Padding = new Thickness(2); number.Flyout = actions; live[number] = part; stack.Children.Add(number);
                        foreach (var unit in TimerUnits) { var item = new MenuFlyoutItem { Text = unit }; item.Click += (s, e) => { part.Unit = unit; Save(); Draw(); }; actions.Items.Add(item); }
                        actions.Items.Add(new MenuFlyoutSeparator());
                    }
                    foreach (int direction in new[] { -1, 1 }) { var move = new MenuFlyoutItem { Text = direction < 0 ? "Move left" : "Move right", IsEnabled = direction < 0 ? parts.IndexOf(part) > 0 : parts.IndexOf(part) < parts.Count - 1 }; move.Click += (s, e) => { int i = parts.IndexOf(part); parts.RemoveAt(i); parts.Insert(i + direction, part); Save(); Draw(); }; actions.Items.Add(move); }
                    var remove = new MenuFlyoutItem { Text = "Remove" }; remove.Click += (s, e) => { parts.Remove(part); Save(); Draw(); }; actions.Items.Add(remove);
                    var label = new Button { Content = caption, MinHeight = 20, MinWidth = 0, Padding = new Thickness(2, 0, 2, 0), BorderThickness = new Thickness(0), Background = new SolidColorBrush(Windows.UI.Colors.Transparent), Flyout = actions };
                    AutomationProperties.SetName(label, caption.Text + " options"); stack.Children.Add(label);
                    chips.Children.Add(new Border { Child = stack, Background = new SolidColorBrush(Rgb(Palette.High)), BorderBrush = new SolidColorBrush(Rgb(Palette.Border)), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(6), Padding = new Thickness(6) });
                }
                FitTimerSettings();
            }
            var presets = new MenuFlyout(); formats.Flyout = presets;
            void Preset(string title, params string[] fields) {
                var item = new MenuFlyoutItem { Text = title }; item.Click += (s, e) => { parts = fields.Select(f => TimerUnits.Contains(f) ? new TimerDisplayPart { Unit = f } : new TimerDisplayPart { Text = f }).ToList(); Save(); Draw(); }; presets.Items.Add(item);
            }
            Preset("15:00", "Minutes", ":", "Seconds"); Preset("Days + time", "Days", " days ", "Hours", ":", "Minutes", " left"); Preset("Full precision", "Days", ":", "Hours", ":", "Minutes", ":", "Seconds", ".", "Milliseconds"); Preset("Back in…", "Back in ", "Minutes", ":", "Seconds");
            var add = TimerButton("+ Add", () => {}); add.HorizontalAlignment = HorizontalAlignment.Left; add.Background = new SolidColorBrush(Windows.UI.Colors.Transparent); add.BorderThickness = new Thickness(0);
            var menu = new MenuFlyout(); add.Flyout = menu;
            void Add(TimerDisplayPart part) { if (parts.Count >= 24) { Status.Text = "Use up to 24 display pieces."; return; } parts.Add(part); Save(); Draw(); }
            foreach (var unit in TimerUnits) { var item = new MenuFlyoutItem { Text = unit }; item.Click += (s, e) => Add(new TimerDisplayPart { Unit = unit }); menu.Items.Add(item); }
            var textItem = new MenuFlyoutItem { Text = "Text" }; textItem.Click += (s, e) => Add(new TimerDisplayPart { Text = "Text" }); menu.Items.Add(textItem);
            var others = new MenuFlyoutSubItem { Text = "Another timer" };
            foreach (var timer in TimerState.Records.Where(t => t.Id != TimerState.ActiveId)) { var source = new MenuFlyoutSubItem { Text = timer.Name }; foreach (var unit in TimerUnits) { var item = new MenuFlyoutItem { Text = unit }; item.Click += (s, e) => Add(new TimerDisplayPart { Unit = unit, SourceId = timer.Id }); source.Items.Add(item); } others.Items.Add(source); }
            others.IsEnabled = others.Items.Count > 0; menu.Items.Add(others); Body.Children.Add(add); Draw();
        }
    }
}
