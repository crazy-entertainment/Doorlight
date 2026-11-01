using System;
using System.Linq;
using Windows.UI.Xaml;
using Windows.UI.Xaml.Controls;
using Windows.UI.Xaml.Automation;

namespace WidgetSampleCS
{
    public sealed partial class HelperWidget
    {
        bool WidgetShown(string id, string extension) => (id == "cross" ? Cfg.CrossVisible(Cfg.CrossActive) : Cfg.Get(id + ".visible", true)) && App.IsOpen(extension) && (id != "timer" || TimerState.Active?.Visible == true);
        bool HasWidget(string id) => id == "timer" ? TimerState.Active != null : id == "cross" ? Cfg.CrossActive != null : id != "clock" || Clocks.Ids.Length > 0;
        async System.Threading.Tasks.Task ShowWidget(string id, string extension, string timerTarget = null, string crossTarget = null)
        {
            if (id.StartsWith("weatherInstances.") && !Cfg.Get(id + ".hasPlace", false)) {
                Status.Text = "Choose a city first."; weatherCity?.Focus(FocusState.Programmatic); return;
            }
            string crossId = id == "cross" ? crossTarget ?? Cfg.CrossActive : null;
            string timerId = id == "timer" ? timerTarget ?? TimerState.ActiveId : null;
            if (id == "timer" && !TimerState.Records.Any(record => record.Id == timerId)) return;
            if (id == "cross") { extension = Cfg.CrossExtension(crossId); if (extension == null) return; }
            var control = new Microsoft.Gaming.XboxGameBar.XboxGameBarWidgetControl(widget);
            if (App.IsOpen(extension)) await control.RestoreAsync(extension); else await control.ActivateAsync(extension);
            if (id == "timer" && !TimerState.Records.Any(record => record.Id == timerId)) return;
            if (id == "cross") Cfg.SetCrossVisible(crossId, true);
            else Cfg.Set(id + ".visible", true);
            if (id == "timer") TimerState.SetVisible(timerId, true);
        }
        FrameworkElement WidgetActions(Button more, string id, string extension)
        {
            if (!HasWidget(id)) {
                var add = TimerIcon("\uE710", id == "cross" ? "Add crosshair" : "Add clock, stopwatch or countdown");
                add.Background = new Windows.UI.Xaml.Media.SolidColorBrush(Rgb(Palette.Fill));
                add.Foreground = new Windows.UI.Xaml.Media.SolidColorBrush(Rgb(Palette.OnAccent));
                if (id == "cross") add.Click += async (s, e) => {
                    Cfg.CreateCross();
                    try { await ShowWidget("cross", "Cross"); }
                    catch (Exception ex) { Status.Text = "Could not show crosshair: " + ex.Message; }
                };
                else { var choices = new MenuFlyout(); AddTimeActions(choices); add.Flyout = choices; }
                return add;
            }
            string crossId = id == "cross" ? Cfg.CrossActive : null;
            string timerId = id == "timer" ? TimerState.ActiveId : null;
            if (id == "cross") extension = Cfg.CrossExtension(crossId);
            bool TargetExists() => id == "timer" ? TimerState.Records.Any(record => record.Id == timerId) : id == "cross" ? Cfg.CrossIds.Contains(crossId) : HasWidget(id);
            bool TargetShown() => id == "timer" ? Cfg.Get("timer.visible", true) && App.IsOpen(extension) && TimerState.Records.FirstOrDefault(record => record.Id == timerId)?.Visible == true :
                id == "cross" ? Cfg.CrossVisible(crossId) && App.IsOpen(extension) : WidgetShown(id, extension);
            string label = id.StartsWith("weatherInstances.") ? "weather" : id;
            var eye = TimerIcon("\uE890", "Show " + label);
            var icon = new Grid { Width = 16, Height = 16 };
            var eyeGlyph = (UIElement)eye.Content; eye.Content = null;
            icon.Children.Add(eyeGlyph);
            var slash = new Windows.UI.Xaml.Shapes.Line { X1 = 1, Y1 = 15, X2 = 15, Y2 = 1,
                Stroke = new Windows.UI.Xaml.Media.SolidColorBrush(Rgb(Palette.Ink)), StrokeThickness = 1.5,
                IsHitTestVisible = false };
            icon.Children.Add(slash); eye.Content = icon;
            bool busy = false;
            void Refresh() {
                bool shown = TargetShown();
                slash.Visibility = shown ? Visibility.Collapsed : Visibility.Visible;
                AutomationProperties.SetName(eye, (shown ? "Hide " : "Show ") + (id == "cross" ? "crosshair" : label));
                eye.IsEnabled = !busy && TargetExists();
            }
            eye.Click += async (s, e) => {
                if (busy || !TargetExists()) return;
                busy = true; Refresh();
                try {
                    if (TargetShown()) {
                        // Keep the same host alive: RestoreAsync retains its location and size.
                        await new Microsoft.Gaming.XboxGameBar.XboxGameBarWidgetControl(widget).MinimizeAsync(extension);
                        if (id == "timer") TimerState.SetVisible(timerId, false);
                        else if (id == "cross") Cfg.SetCrossVisible(crossId, false);
                        else Cfg.Set(id + ".visible", false);
                    } else await ShowWidget(id, extension, timerId, crossId);
                } catch (Exception ex) { Status.Text = "Could not change visibility: " + ex.Message; }
                finally { busy = false; Refresh(); }
            };
            Action changed = () => Ui(Refresh);
            Action<string> settingsChanged = key => Ui(Refresh);
            App.OpenChanged += changed; Cfg.Changed += settingsChanged;
            timerEditorCleanup += () => { App.OpenChanged -= changed; Cfg.Changed -= settingsChanged; };
            Refresh();
            var actions = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center };
            if (id == "timer" && Clocks.Ids.Length == 0 && TimerState.Records.Count == 0) {
                var add = TimerIcon("\uE710", "Add clock, stopwatch or countdown");
                var choices = new MenuFlyout(); AddTimeActions(choices); add.Flyout = choices;
                actions.Children.Add(add);
            }
            actions.Children.Add(eye);
            bool advanced = id == "cross" ? Cfg.AdvancedCrossEditor :
                id == "clock" || id == "timer" ? Cfg.Get("helper.clockEditorMode", "simple") == "advanced" :
                id.StartsWith("weatherInstances.") ? Cfg.Get("helper.weatherEditorMode", "simple") == "advanced" : true;
            if (advanced) actions.Children.Add(more);
            return actions;
        }
        void WidgetMenu(MenuFlyout menu, string id, string extension)
        {
            menu.Placement = Windows.UI.Xaml.Controls.Primitives.FlyoutPlacementMode.BottomEdgeAlignedRight;
            menu.ShouldConstrainToRootBounds = false;
            var placement = new MenuFlyoutItem { Text = "Reset placement", Icon = new SymbolIcon(Symbol.Refresh) };
            menu.Opening += (s,e) => placement.IsEnabled = HasWidget(id);
            placement.Click += async (s,e) => {
                string crossId = id == "cross" ? Cfg.CrossActive : null;
                string timerId = id == "timer" ? TimerState.ActiveId : null;
                try { await ShowWidget(id, extension, timerId, crossId); Cfg.Run(id == "cross" ? "cross.resetPlacement:" + crossId : id + ".resetPlacement"); }
                catch (Exception ex) { Status.Text = "Could not reset placement: " + ex.Message; }
            };
            if (menu.Items.Count > 0 && id != "cross") menu.Items.Add(new MenuFlyoutSeparator());
            menu.Items.Add(placement);
        }
        void EmptyWidget(string noun)
        {
            PageHeader.Margin = new Thickness(20,12,20,0);
            var empty = new Grid { Margin = new Thickness(0,-4,0,0), VerticalAlignment = VerticalAlignment.Top };
            empty.Children.Add(new TextBlock { Text = "No " + noun + " yet. Create one.", VerticalAlignment = VerticalAlignment.Center, Foreground = new Windows.UI.Xaml.Media.SolidColorBrush(Rgb(Palette.Muted)), Margin = new Thickness(0,0,44,0) });
            var arrow = new TextBlock { Text = "↑", FontFamily = new Windows.UI.Xaml.Media.FontFamily("Segoe UI"), FontSize = 28, Foreground = new Windows.UI.Xaml.Media.SolidColorBrush(Rgb(Palette.Danger)), Width = 36, TextAlignment = TextAlignment.Center, HorizontalAlignment = HorizontalAlignment.Right, IsHitTestVisible = false };
            empty.Children.Add(arrow); Body.Children.Add(empty);
            Ui(FitEmptyWidget);
        }
        void FitEmptyWidget() => FitTimerSettings();
        string selectedClock = "local";
        void BuildClockOptions()
        {
            if (!Clocks.Ids.Contains(selectedClock)) selectedClock = Clocks.Ids.FirstOrDefault();
            var row = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center };
            var selector = TimeSelector();
            var more = TimerIcon("\uE712", "Time actions"); var menu = new MenuFlyout(); more.Flyout = menu;
            AddTimeActions(menu);
            var rename = new MenuFlyoutItem { Text = "Rename", Icon = new SymbolIcon(Symbol.Edit), IsEnabled = selectedClock != null };
            rename.Click += async (s,e) => {
                string id = selectedClock;
                var name = new TextBox { Text = Clocks.Name(id), MaxLength = 40 };
                var dialog = new ContentDialog { Title = "Rename clock", Content = name, PrimaryButtonText = "Save", CloseButtonText = "Cancel" };
                if (await dialog.ShowAsync() == ContentDialogResult.Primary && !string.IsNullOrWhiteSpace(name.Text)) { Cfg.Set(Clocks.Key(id) + "name", name.Text.Trim()); Show(current); }
            };
            var delete = new MenuFlyoutItem { Text = "Delete", Icon = new SymbolIcon(Symbol.Delete), IsEnabled = Clocks.Ids.Length > 0 };
            delete.Click += (s,e) => { Cfg.Set("clock.ids", string.Join("|", Clocks.Ids.Where(id => id != selectedClock))); Show(tabs[2]); };

            menu.Items.Add(rename); menu.Items.Add(delete); WidgetMenu(menu, "clock", "Clock"); row.Children.Add(selector); row.Children.Add(WidgetActions(more, "clock", "Clock")); Grid.SetColumn(row, 1); PageHeader.Children.Add(row); timerEditorCleanup += () => PageHeader.Children.Remove(row);
            if (selectedClock == null) { EmptyWidget("clocks or timers"); return; }
            string key = Clocks.Key(selectedClock);
            if (Cfg.Get("helper.clockEditorMode", "simple") != "advanced") { BuildSimpleClock(key); return; }
            var zone = CompactDropdown(380); zone.Header = "Time zone";
            string zoneId = Cfg.Get(key + "zone", TimeZoneInfo.Local.Id);
            foreach (var z in TimeZoneInfo.GetSystemTimeZones()) { var item = new ComboBoxItem { Content = z.DisplayName, Tag = z.Id }; zone.Items.Add(item); if (z.Id == zoneId) zone.SelectedItem = item; }
            zone.SelectionChanged += (s,e) => { if (zone.SelectedItem is ComboBoxItem item) Cfg.Set(key + "zone", (string)item.Tag); };
            Body.Children.Add(zone);
            // Visibility belongs to the widget header; every configured clock is rendered.
            var display = new StackPanel { Spacing = 8 };
            ComboBox Pick(string label, string option, string fallback, params (string value, string text)[] choices) {
                var box = CompactDropdown(180);
                AutomationProperties.SetName(box, label);
                foreach (var choice in choices) { var item = new ComboBoxItem { Content = choice.text, Tag = choice.value }; box.Items.Add(item); if (choice.value == Cfg.Get(key + option, fallback)) box.SelectedItem = item; }
                box.SelectionChanged += (s,e) => { if (box.SelectedItem is ComboBoxItem item) { Cfg.Set(key + option, (string)item.Tag); if (option == "format") Cfg.Set(key + "dateOnly", false); } };
                return box;
            }
            var format = Pick("Time format", "format", "HH:mm", ("HH:mm", "21:47"), ("HH:mm:ss", "21:47:05"), ("HH:mm:ss.fff", "21:47:05.123"), ("h:mm tt", "9:47 PM"), ("h:mm:ss tt", "9:47:05 PM"), ("h:mm:ss.fff tt", "9:47:05.123 PM"));
            var date = new CheckBox { Content = "Date", IsChecked = Cfg.Get(key + "date", false), MinWidth = 0 };
            display.Children.Add(Pair(format, date, false, 12));
            var dateOptions = new StackPanel { Spacing = 8 };
            var layout = Pick("Time and date layout", "layout", "stacked", ("single", "One line"), ("stacked", "Two lines"));
            layout.Header = "Layout";
            var dateFormat = CompactDropdown(180); dateFormat.Header = "Date format";
            AutomationProperties.SetName(dateFormat, "Date format");
            var savedDateFormat = Cfg.Get(key + "dateFormat", "ddd d MMM");
            foreach (var choice in new[] { ("ddd d MMM", "Sat 17 Oct"), ("dd.MM.yyyy", "17.10.2026"), ("yyyy-MM-dd", "2026-10-17"), ("dddd d MMMM yyyy", "Saturday 17 October 2026"), ("", "Custom…") }) {
                var item = new ComboBoxItem { Content = choice.Item2, Tag = choice.Item1 }; dateFormat.Items.Add(item);
                if (choice.Item1 == savedDateFormat) dateFormat.SelectedItem = item;
            }
            if (dateFormat.SelectedIndex < 0) dateFormat.SelectedIndex = dateFormat.Items.Count - 1;
            dateOptions.Children.Add(Pair(dateFormat, layout, true, 12));
            var customDate = new TextBox { Header = "Custom date format", Text = savedDateFormat, PlaceholderText = "dd.MM.yyyy", MaxLength = 60, MinWidth = 0 };
            var dateHelp = new TextBlock { Text = "dd = day · MM = month · yyyy = year", FontSize = 12, Foreground = new Windows.UI.Xaml.Media.SolidColorBrush(Rgb(Palette.Muted)), TextWrapping = TextWrapping.Wrap };
            var datePreview = new TextBlock { FontSize = 12, TextWrapping = TextWrapping.Wrap };
            AutomationProperties.SetLiveSetting(datePreview, Windows.UI.Xaml.Automation.Peers.AutomationLiveSetting.Polite);
            void RefreshDate() {
                bool custom = (dateFormat.SelectedItem as ComboBoxItem)?.Tag as string == "";
                customDate.Visibility = dateHelp.Visibility = custom ? Visibility.Visible : Visibility.Collapsed;
                string pattern = custom ? customDate.Text : Cfg.Get(key + "dateFormat", "ddd d MMM");
                bool valid = Clocks.TryDateText(Clocks.Now(selectedClock, DateTimeOffset.UtcNow), pattern, out string example);
                datePreview.Text = valid ? "Preview: " + example : "Invalid format. Try dd.MM.yyyy.";
                if (custom && valid) Cfg.Set(key + "dateFormat", pattern);
                dateOptions.Visibility = date.IsChecked == true ? Visibility.Visible : Visibility.Collapsed;
            }
            dateFormat.SelectionChanged += (s,e) => {
                if (dateFormat.SelectedItem is ComboBoxItem item && (string)item.Tag != "") Cfg.Set(key + "dateFormat", (string)item.Tag);
                else customDate.Text = Cfg.Get(key + "dateFormat", "ddd d MMM");
                RefreshDate(); Ui(FitTimerSettings);
            };
            customDate.TextChanged += (s,e) => RefreshDate();
            date.Checked += (s,e) => { Cfg.Set(key + "date", true); RefreshDate(); Ui(FitTimerSettings); };
            date.Unchecked += (s,e) => { Cfg.Set(key + "date", false); Cfg.Set(key + "dateOnly", false); RefreshDate(); Ui(FitTimerSettings); };
            dateOptions.Children.Add(customDate); dateOptions.Children.Add(dateHelp); dateOptions.Children.Add(datePreview);
            RefreshDate(); display.Children.Add(dateOptions);
            var before = new TextBox { Header = "Before time", PlaceholderText = "Optional text", Text = Cfg.Get(key + "prefix", ""), MaxLength = 60, MinWidth = 0 };
            var after = new TextBox { Header = "After time", PlaceholderText = "Optional text", Text = Cfg.Get(key + "suffix", ""), MaxLength = 60, MinWidth = 0 };
            AutomationProperties.SetName(before, "Text before time"); AutomationProperties.SetName(after, "Text after time");
            before.TextChanged += (s,e) => Cfg.Set(key + "prefix", before.Text); after.TextChanged += (s,e) => Cfg.Set(key + "suffix", after.Text);
            display.Children.Add(Pair(before, after, true, 8));
            var font = Pick("Font", "font", "Segoe UI Variable Display", ("Segoe UI Variable Display", "Segoe UI"), ("Bahnschrift", "Bahnschrift"), ("Cascadia Mono", "Cascadia Mono"), ("Georgia", "Georgia"));
            display.Children.Add(Pair(font, ColorChip(key + "color", "#EFE6DC", "Clock color"), false, 8));
            display.Children.Add(Pair(TakeSlider("Outline thickness", key + "outlineThickness", 0, 4, 0, 1), ColorChip(key + "outlineColor", "#000000", "Clock outline color"), false, 12));
            display.Children.Add(Pair(new TextBlock { Text = "Background", VerticalAlignment = VerticalAlignment.Center }, Pick("Background", "bg", "none", ("none", "Transparent"), ("shadow", "Text shadow"), ("pill", "Dark pill")), true, 8));
            var chevron = new FontIcon { FontFamily = new Windows.UI.Xaml.Media.FontFamily("Segoe MDL2 Assets"), Glyph = "\uE70E", FontSize = 12, VerticalAlignment = VerticalAlignment.Center };
            var expand = new Button {
                Content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, Children = {
                    new TextBlock { Text = "Display", FontWeight = Windows.UI.Text.FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center }, chevron
                } },
                HorizontalAlignment = HorizontalAlignment.Left, HorizontalContentAlignment = HorizontalAlignment.Left,
                Background = new Windows.UI.Xaml.Media.SolidColorBrush(Windows.UI.Colors.Transparent), BorderThickness = new Thickness(0),
                Padding = new Thickness(0, 6, 4, 6), MinHeight = 32
            };
            AutomationProperties.SetName(expand, "Collapse display settings");
            expand.Click += (s,e) => {
                bool open = display.Visibility != Visibility.Visible;
                display.Visibility = open ? Visibility.Visible : Visibility.Collapsed;
                chevron.Glyph = open ? "\uE70E" : "\uE70D";
                AutomationProperties.SetName(expand, open ? "Collapse display settings" : "Expand display settings");
                Ui(FitTimerSettings);
            };
            Body.Children.Add(expand); Body.Children.Add(display);
        }
    }
}
