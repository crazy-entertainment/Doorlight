using System;
using System.Linq;
using Windows.UI.Xaml;
using Windows.UI.Xaml.Controls;
using Windows.UI.Xaml.Media;

namespace WidgetSampleCS
{
    public sealed partial class HelperWidget
    {
        FrameworkElement TimeSelector()
        {
            var selector = CompactDropdown(170, "Choose item");
            Windows.UI.Xaml.Automation.AutomationProperties.SetName(selector, "Selected clock, stopwatch or countdown");
            foreach (var id in Clocks.Ids) {
                var item = new ComboBoxItem { Content = Clocks.Name(id), Tag = "clock:" + id };
                selector.Items.Add(item);
                if (current.Id == "clock" && id == selectedClock) selector.SelectedItem = item;
            }
            foreach (var record in TimerState.Records.OrderBy(record => record.Mode == "Stopwatch" ? 0 : 1)) {
                var item = new ComboBoxItem { Content = record.Name, Tag = "timer:" + record.Id };
                selector.Items.Add(item);
                if (current.Id == "timer" && record.Id == TimerState.ActiveId) selector.SelectedItem = item;
            }
            selector.Visibility = selector.Items.Count == 0 ? Visibility.Collapsed : Visibility.Visible;
            selector.SelectionChanged += (s,e) => {
                if (!(selector.SelectedItem is ComboBoxItem item)) return;
                var selection = ((string)item.Tag).Split(':');
                if (selection[0] == "clock") selectedClock = selection[1]; else TimerState.Select(selection[1]);
                Cfg.Set("time.kind", selection[0]); Show(tabs[2]);
            };
            return ItemSelector(selector);
        }
        static FrameworkElement ItemSelector(ComboBox selector)
        {
            selector.Visibility = selector.Items.Count > 1 ? Visibility.Visible : Visibility.Collapsed;
            return selector;
        }
        void AddTimeActions(MenuFlyout menu)
        {
            foreach (var kind in new[] { "clock", "stopwatch", "countdown" }) {
                var add = new MenuFlyoutItem { Text = "Add " + kind, Icon = new SymbolIcon(Symbol.Add) };
                add.Click += async (s,e) => {
                    if (kind == "clock") {
                        selectedClock = Guid.NewGuid().ToString("N");
                        Cfg.Set(Clocks.Key(selectedClock) + "name", "Clock " + (Clocks.Ids.Length + 1));
                        Cfg.Set("clock.ids", string.Join("|", Clocks.Ids.Concat(new[] { selectedClock })));
                    } else {
                        string label = kind == "stopwatch" ? "Stopwatch" : "Countdown";
                        var records = TimerState.Records;
                        string name = Enumerable.Range(1, records.Count + 1).Select(n => label + " " + n).First(n => !records.Any(r => string.Equals(r.Name, n, StringComparison.OrdinalIgnoreCase)));
                        TimerState.Create(name); TimerState.SetMode(kind == "stopwatch" ? "Stopwatch" : "Countdown");
                        if (kind == "countdown") Cfg.Set("timer.simpleEmptyDuration." + TimerState.ActiveId, true);
                        SetDefaultTimerShortcuts(TimerState.ActiveId);
                    }
                    string timerId = kind == "clock" ? null : TimerState.ActiveId;
                    Cfg.Set("time.kind", kind == "clock" ? "clock" : "timer"); Show(tabs[2]);
                    try { await ShowWidget(kind == "clock" ? "clock" : "timer", kind == "clock" ? "Clock" : "Timer", timerId); }
                    catch (Exception ex) { Status.Text = "Could not show " + kind + ": " + ex.Message; }
                };
                menu.Items.Add(add);
            }
        }
        void BuildGeneral()
        {
            var themes = CompactDropdown(180);
            Windows.UI.Xaml.Automation.AutomationProperties.SetName(themes, "Theme");
            foreach (var theme in new[] { ("disaccord", "Disaccord"), ("cozy", "Cozy"), ("midnight", "Midnight") }) {
                var item = new ComboBoxItem { Content = theme.Item2, Tag = theme.Item1 };
                themes.Items.Add(item);
                if (Palette.Id == theme.Item1) themes.SelectedItem = item;
            }
            themes.SelectionChanged += (s, e) => {
                if (themes.SelectedItem is ComboBoxItem item) AppearanceSync.Request("theme", (string)item.Tag);
            };
            Labeled("Theme", themes);
            var vibes = CompactDropdown(180);
            foreach (var choice in new[] { ("none", "None"), ("rain", "Rain"), ("snow", "Snow"), ("halloween", "Halloween") }) {
                var item = new ComboBoxItem { Content = choice.Item2, Tag = choice.Item1 }; vibes.Items.Add(item);
                if (Cfg.Get("helper.vibe", "none") == choice.Item1) vibes.SelectedItem = item;
            }
            vibes.SelectionChanged += (s, e) => { if (vibes.SelectedItem is ComboBoxItem item) AppearanceSync.Request("vibe", (string)item.Tag); };
            Labeled("Vibe", vibes);
            bool hasVibe = Cfg.Get("helper.vibe", "none") != "none";
            var adjustments = new StackPanel { Spacing = 4, Opacity = hasVibe ? 1 : .5 };
            var appearanceControls = new System.Collections.Generic.List<Control> { themes, vibes };
            foreach (var setting in new[] { ("Intensity", "helper.vibeIntensity"), ("Opacity", "helper.vibeOpacity") }) {
                var slider = new Slider { Minimum = 0, Maximum = 100, StepFrequency = 1, Value = Cfg.Get(setting.Item2, 100.0), MinWidth = 0, IsEnabled = hasVibe };
                var value = new TextBlock { Text = slider.Value.ToString("0") + "%", VerticalAlignment = VerticalAlignment.Center };
                var commit = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(350) };
                bool dirty = false;
                void Commit() { commit.Stop(); if (!dirty) return; dirty = false; AppearanceSync.Request(setting.Item1 == "Intensity" ? "vibeIntensity" : "vibeOpacity", (int)Math.Round(slider.Value)); }
                commit.Tick += (s, e) => Commit();
                slider.PointerCaptureLost += (s, e) => Commit(); slider.KeyUp += (s, e) => Commit();
                slider.ValueChanged += (s, e) => { dirty = true; value.Text = e.NewValue.ToString("0") + "%"; commit.Stop(); commit.Start(); };
                timerEditorCleanup += () => commit.Stop();
                appearanceControls.Add(slider);
                Windows.UI.Xaml.Automation.AutomationProperties.SetName(slider, "Vibe " + setting.Item1.ToLowerInvariant());
                var row = new Grid { ColumnSpacing = 12 };
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(64) });
                row.ColumnDefinitions.Add(new ColumnDefinition()); row.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(42) });
                row.Children.Add(new TextBlock { Text = setting.Item1, VerticalAlignment = VerticalAlignment.Center });
                Grid.SetColumn(slider, 1); row.Children.Add(slider); Grid.SetColumn(value, 2); row.Children.Add(value); adjustments.Children.Add(row);
            }
            Body.Children.Add(adjustments);
            var animate = new CheckBox { Content = "Animations", IsChecked = Cfg.Get("helper.vibeAnimated", true) };

            animate.Checked += (s, e) => AppearanceSync.Request("vibeAnimated", true);
            animate.Unchecked += (s, e) => AppearanceSync.Request("vibeAnimated", false);
            appearanceControls.Add(animate); Body.Children.Add(animate);
            var syncStatus = new TextBlock { FontSize = 12, TextWrapping = TextWrapping.Wrap, Foreground = new SolidColorBrush(Rgb(Palette.Muted)) };
            Body.Children.Add(syncStatus);
            void RefreshAppearanceControls() {
                foreach (var control in appearanceControls) control.IsEnabled = AppearanceSync.Editable && (control == themes || control == vibes || control == animate || hasVibe);
                syncStatus.Text = AppearanceSync.Message;
            }
            Action syncChanged = () => Ui(() => {
                if (!AppearanceSync.Connected && current?.Id == "settings") Show(current);
                else RefreshAppearanceControls();
            });
            AppearanceSync.Changed += syncChanged;
            timerEditorCleanup += () => AppearanceSync.Changed -= syncChanged;
            RefreshAppearanceControls();
            AddProximitySettings();
        }
        void BuildWeatherActions()
        {
            string id = Cfg.WeatherActive;
            bool advanced = Cfg.Get("helper.weatherEditorMode", "simple") == "advanced";
            var header = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center };
            var selector = CompactDropdown(120, "Choose weather widget");
            Windows.UI.Xaml.Automation.AutomationProperties.SetName(selector, "Selected weather widget");
            foreach (var itemId in Cfg.WeatherIds) {
                var item = new ComboBoxItem { Content = Cfg.WeatherName(itemId), Tag = itemId }; selector.Items.Add(item);
                if (itemId == id) selector.SelectedItem = item;
            }
            selector.SelectionChanged += (s, e) => { if (selector.SelectedItem is ComboBoxItem item) { Cfg.SelectWeather((string)item.Tag); Show(current); } };
            if (advanced) header.Children.Add(ItemSelector(selector));
            async System.Threading.Tasks.Task Add(bool duplicate) {
                try {
                    string created = Cfg.CreateWeather(duplicate);
                    Show(current);
                    if (Cfg.Get(Cfg.WeatherKey(created) + "hasPlace", false))
                        await ShowWidget(Cfg.WeatherKey(created).TrimEnd('.'), Cfg.WeatherExtension(created));
                    else weatherCity?.Focus(FocusState.Programmatic);
                } catch (Exception ex) { Status.Text = "Could not show weather: " + ex.Message; }
            }
            if (id == null) {
                var plus = TimerIcon("\uE710", "Add weather widget");
                plus.Background = new SolidColorBrush(Rgb(Palette.Fill));
                plus.Foreground = new SolidColorBrush(Rgb(Palette.OnAccent));
                plus.Click += async (s, e) => await Add(false); header.Children.Add(plus);
            } else {
                string key = Cfg.WeatherKey(id), extension = Cfg.WeatherExtension(id);
                var more = TimerIcon("\uE712", "Weather actions"); var menu = new MenuFlyout(); more.Flyout = menu;
                foreach (bool duplicate in advanced ? new[] { false, true } : new bool[0]) {
                    var add = new MenuFlyoutItem { Text = duplicate ? "Duplicate" : "Add weather widget", Icon = new SymbolIcon(duplicate ? Symbol.Copy : Symbol.Add), IsEnabled = Cfg.WeatherIds.Length < Cfg.WeatherWindowLimit };
                    add.Click += async (s, e) => await Add(duplicate); menu.Items.Add(add);
                }
                var rename = new MenuFlyoutItem { Text = "Rename", Icon = new SymbolIcon(Symbol.Edit) };
                rename.Click += async (s, e) => {
                    var name = new TextBox { Text = Cfg.WeatherName(id), MaxLength = 40 };
                    var dialog = new ContentDialog { Title = "Rename weather widget", Content = name, PrimaryButtonText = "Save", CloseButtonText = "Cancel" };
                    if (await dialog.ShowAsync() == ContentDialogResult.Primary && !string.IsNullOrWhiteSpace(name.Text) && Cfg.WeatherIds.Contains(id)) { Cfg.Set(key + "name", name.Text.Trim()); Show(current); }
                }; menu.Items.Add(rename);
                var delete = new MenuFlyoutItem { Text = "Delete", Icon = new SymbolIcon(Symbol.Delete) };
                delete.Click += async (s, e) => {
                    try {
                        if (App.IsOpen(extension)) await new Microsoft.Gaming.XboxGameBar.XboxGameBarWidgetControl(widget).CloseAsync(extension);
                        Cfg.DeleteWeather(id); Show(current);
                    } catch (Exception ex) { Status.Text = "Could not delete weather: " + ex.Message; }
                }; menu.Items.Add(delete);
                WidgetMenu(menu, key.TrimEnd('.'), extension);
                header.Children.Add(WidgetActions(more, key.TrimEnd('.'), extension));
            }
            Grid.SetColumn(header, 1); PageHeader.Children.Add(header); timerEditorCleanup += () => PageHeader.Children.Remove(header);
        }
        void AddWidgetAppearance(string id)
        {
            TimerDivider();
            Slider("Opacity", id + ".appearance.opacity", 0, 1, Cfg.Appearance(id, "opacity", 1.0), .05);
        }
        TextBox weatherCity;
        static void CenterWeatherSearchContent(DependencyObject node)
        {
            if (node is FrameworkElement part && (part.Name == "ContentElement" || part.Name == "PlaceholderTextContentPresenter"))
                part.VerticalAlignment = VerticalAlignment.Center;
            for (int i = 0; i < VisualTreeHelper.GetChildrenCount(node); i++)
                CenterWeatherSearchContent(VisualTreeHelper.GetChild(node, i));
        }
        string revealWeatherSettings;
        void CompactWeather()
        {
            string id = Cfg.WeatherActive;
            bool reveal = revealWeatherSettings == id && id != null;
            revealWeatherSettings = null;
            BuildWeatherActions();
            if (id == null) { EmptyWidget("weather widgets"); return; }
            string key = Cfg.WeatherKey(id);
            bool configured = Cfg.Get(key + "hasPlace", false);
            var city = new TextBox { Text = Cfg.Get(key + "place", ""), PlaceholderText = "City or postal code", MaxLength = 128, MinWidth = 0,
                VerticalContentAlignment = VerticalAlignment.Center, Padding = new Thickness(10, 0, 10, 0) };
            city.Loaded += (s, e) => CenterWeatherSearchContent(city);
            weatherCity = city;
            var pills = new WeatherPills();
            var matches = new ScrollViewer { Content = pills, MaxHeight = 220, HorizontalScrollMode = ScrollMode.Disabled, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, Visibility = Visibility.Collapsed };
            Windows.UI.Xaml.Automation.AutomationProperties.SetName(matches, "Matching locations");
            var settings = new StackPanel { Spacing = 8, Visibility = configured ? Visibility.Visible : Visibility.Collapsed };
            var debounce = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(350) };
            int generation = 0;
            bool disposed = false, choosing = false;
            System.Threading.CancellationTokenSource searchRequest = null;
            timerEditorCleanup += () => { disposed = true; ++generation; searchRequest?.Cancel(); debounce.Stop(); };
            bool Current() => !disposed && !pageClosed && current?.Id == "weather" && Cfg.WeatherActive == id && weatherCity == city;
            async System.Threading.Tasks.Task Choose(WeatherPlace place) {
                if (choosing || !Current()) return;
                choosing = true; debounce.Stop(); ++generation; searchRequest?.Cancel();
                try {
                    if (!Cfg.SetWeatherPlace(id, place)) return;
                    if (!configured) {
                        Cfg.Set(key + "name", place.Name);
                        await ShowWidget(key.TrimEnd('.'), Cfg.WeatherExtension(id));
                    }
                    if (Current()) { revealWeatherSettings = id; Show(current); }
                } catch (Exception ex) { if (Current()) Status.Text = "Could not show weather: " + ex.Message; }
                finally { choosing = false; }
            }
            async System.Threading.Tasks.Task FindCity() {
                debounce.Stop();
                searchRequest?.Cancel();
                int pending = ++generation;
                string query = city.Text.Trim();
                if (!Current() || string.IsNullOrWhiteSpace(query)) { if (Current()) Status.Text = ""; return; }
                Status.Text = "Looking up…";
                pills.Children.Clear(); matches.Visibility = Visibility.Collapsed;
                using (var cancellation = new System.Threading.CancellationTokenSource()) {
                searchRequest = cancellation;
                try {
                    var places = await WeatherWidget.FindPlaces(query, cancellation.Token);
                    if (!Current() || pending != generation || city.Text.Trim() != query) return;
                    if (places.Count == 0) { Status.Text = "No locations found. Try a city or postal code."; return; }
                    string homeCountry = "";
                    try { homeCountry = Windows.System.UserProfile.GlobalizationPreferences.HomeGeographicRegion; }
                    catch (Exception ex) { Log.Write("Weather region unavailable: " + ex.GetType().Name); }
                    var countryCounts = places.GroupBy(place => place.CountryKey).ToDictionary(group => group.Key, group => group.Count());
                    foreach (var place in WeatherPlace.ByRegionDistance(places, homeCountry)) {
                        bool sameCountry = countryCounts[place.CountryKey] > 1;
                        var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 7, VerticalAlignment = VerticalAlignment.Center };
                        if (place.FlagCode != null) content.Children.Add(new Image {
                            Source = new Windows.UI.Xaml.Media.Imaging.SvgImageSource(new Uri("ms-appx:///Assets/Flags/" + place.FlagCode + ".svg")),
                            Width = 20, Height = 15, Stretch = Stretch.Uniform, VerticalAlignment = VerticalAlignment.Center
                        });
                        else content.Children.Add(new FontIcon { Glyph = "\uE774", FontSize = 16 });
                        content.Children.Add(new TextBlock { Text = place.PillText(sameCountry), FontSize = 13, MaxWidth = 270, TextWrapping = TextWrapping.Wrap, VerticalAlignment = VerticalAlignment.Center });
                        var pill = new Button { Content = content, CornerRadius = new CornerRadius(18), Padding = new Thickness(10, 6, 10, 6), MinHeight = 34, MinWidth = 0,
                            Background = new SolidColorBrush(Rgb(Palette.High)), Foreground = new SolidColorBrush(Rgb(Palette.Ink)), BorderBrush = new SolidColorBrush(Rgb(Palette.Border)), BorderThickness = new Thickness(1) };
                        Windows.UI.Xaml.Automation.AutomationProperties.SetName(pill, place.Details);
                        pill.Click += async (s, e) => await Choose(place);
                        pills.Children.Add(pill);
                    }
                    matches.Visibility = Visibility.Visible; Status.Text = ""; Ui(FitTimerSettings);
                } catch (OperationCanceledException) { }
                catch (Exception) { if (Current() && pending == generation) Status.Text = "Could not get weather. Try again."; }
                finally { if (searchRequest == cancellation) searchRequest = null; }
                }
            }
            debounce.Tick += async (s, e) => await FindCity();
            city.TextChanged += (s, e) => {
                ++generation; searchRequest?.Cancel(); debounce.Stop();
                pills.Children.Clear(); matches.Visibility = Visibility.Collapsed; settings.Visibility = Visibility.Collapsed;
                Status.Text = "";
                if (!string.IsNullOrWhiteSpace(city.Text)) debounce.Start();
                Ui(FitTimerSettings);
            };
#if DEBUG
            weatherSearchForCapture = async query => { city.Text = query; await FindCity(); return pills.Children.Count > 0 && matches.Visibility == Visibility.Visible; };
#endif
            city.KeyDown += async (s,e) => { if (e.Key == Windows.System.VirtualKey.Enter) { e.Handled = true; await FindCity(); } };
            Body.Children.Add(city); Body.Children.Add(matches); Body.Children.Add(settings);
            Body.Children.Add(new HyperlinkButton { Content = "Locations: GeoNames via Open-Meteo", NavigateUri = new Uri("https://open-meteo.com/en/docs/geocoding-api"), Padding = new Thickness(0), HorizontalAlignment = HorizontalAlignment.Left });
            Body.Children.Add(new HyperlinkButton { Content = "CC BY 4.0", NavigateUri = new Uri("https://creativecommons.org/licenses/by/4.0/"), Padding = new Thickness(0), HorizontalAlignment = HorizontalAlignment.Left });
            if (!configured) return;
            bool advanced = Cfg.Get("helper.weatherEditorMode", "simple") == "advanced";
            var styleRow = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6, VerticalAlignment = VerticalAlignment.Center };
            var styles = new Windows.UI.Xaml.Controls.Primitives.ToggleButton[2];
            void RefreshStyles() {
                bool mono = Cfg.Get(key + "iconSet", "mono") == "mono";
                for (int i = 0; i < styles.Length; ++i) {
                    bool selected = (i == 0) == mono;
                    styles[i].IsChecked = selected;
                    styles[i].Background = new SolidColorBrush(Rgb(selected ? Palette.Selected : Palette.Surface));
                    styles[i].BorderBrush = new SolidColorBrush(Rgb(selected ? Palette.Fill : Palette.Border));
                }
            }
            for (int i = 0; i < 2; ++i) {
                int choice = i;
                var button = new Windows.UI.Xaml.Controls.Primitives.ToggleButton {
                    Content = new TextBlock { Text = "⛅", FontFamily = new FontFamily(i == 0 ? "Segoe UI Symbol" : "Segoe UI Emoji"), IsColorFontEnabled = i == 1, FontSize = 26, Foreground = new SolidColorBrush(Rgb(Palette.Ink)) },
                    Width = 44, Height = 38, MinWidth = 0, MinHeight = 0, Padding = new Thickness(2), CornerRadius = new CornerRadius(6)
                };
                string title = i == 0 ? "Monochrome weather icons" : "Color weather icons";
                Windows.UI.Xaml.Automation.AutomationProperties.SetName(button, title); ToolTipService.SetToolTip(button, title);
                button.Click += (s, e) => { Cfg.Set(key + "iconSet", choice == 0 ? "mono" : "color"); RefreshStyles(); };
                styles[i] = button; styleRow.Children.Add(button);
            }
            RefreshStyles();
            var temp = new CheckBox { Content = "Temperature", IsChecked = Cfg.Get(key + "temp", false), MinWidth = 0,
                MinHeight = 36, FontSize = 13, VerticalAlignment = VerticalAlignment.Center };
            var units = CompactDropdown(); units.Items.Add("°C"); units.Items.Add("°F"); units.SelectedIndex = Cfg.Get(key + "unit", "C") == "C" ? 0 : 1;
            units.Width = 64; units.MaxWidth = 64;
            units.SelectionChanged += (s,e) => Cfg.Set(key + "unit", units.SelectedIndex == 0 ? "C" : "F");
            var unitHost = new Grid { Width = temp.IsChecked == true ? 72 : 0, Opacity = temp.IsChecked == true ? 1 : 0,
                IsHitTestVisible = temp.IsChecked == true, VerticalAlignment = VerticalAlignment.Center };
            units.HorizontalAlignment = HorizontalAlignment.Right; unitHost.Children.Add(units);
            unitHost.SizeChanged += (s, e) => unitHost.Clip = new RectangleGeometry { Rect = new Windows.Foundation.Rect(0, 0, Math.Max(0, e.NewSize.Width), Math.Max(0, e.NewSize.Height)) };
            Windows.UI.Xaml.Media.Animation.Storyboard unitAnimation = null;
            void RefreshUnits() {
                bool visible = temp.IsChecked == true;
                Cfg.Set(key + "temp", visible);
                unitHost.IsHitTestVisible = visible; units.IsTabStop = visible;
                if (!visible) units.IsDropDownOpen = false;
                if (!visible && units.FocusState != FocusState.Unfocused) temp.Focus(FocusState.Programmatic);
                double fromWidth = unitHost.ActualWidth, fromOpacity = unitHost.Opacity;
                unitAnimation?.Stop(); unitHost.Width = fromWidth; unitHost.Opacity = fromOpacity;
                if (!WidgetTheme.AnimationsEnabled) { unitHost.Width = visible ? 72 : 0; unitHost.Opacity = visible ? 1 : 0; return; }
                unitAnimation = new Windows.UI.Xaml.Media.Animation.Storyboard();
                foreach (var property in new[] { "Width", "Opacity" }) {
                    var anim = new Windows.UI.Xaml.Media.Animation.DoubleAnimation { From = property == "Width" ? fromWidth : fromOpacity,
                        To = visible ? (property == "Width" ? 72 : 1) : 0, EnableDependentAnimation = true,
                        Duration = new Duration(TimeSpan.FromMilliseconds(180)), EasingFunction = new Windows.UI.Xaml.Media.Animation.CubicEase { EasingMode = Windows.UI.Xaml.Media.Animation.EasingMode.EaseOut } };
                    Windows.UI.Xaml.Media.Animation.Storyboard.SetTarget(anim, unitHost);
                    Windows.UI.Xaml.Media.Animation.Storyboard.SetTargetProperty(anim, property); unitAnimation.Children.Add(anim);
                }
                unitAnimation.Begin();
            }
            units.IsTabStop = temp.IsChecked == true;
            temp.Checked += (s, e) => RefreshUnits(); temp.Unchecked += (s, e) => RefreshUnits();
            timerEditorCleanup += () => unitAnimation?.Stop();
            var tempRow = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
            tempRow.Children.Add(temp); tempRow.Children.Add(unitHost);
            settings.Children.Add(Pair(styleRow, tempRow, false, 10));
            if (advanced) {
                var color = ColorChip(key + "color", "#EFE6DC", "Weather color");
                var colorRow = Pair(new TextBlock { Text = "Color", VerticalAlignment = VerticalAlignment.Center }, color, false, 8);
                colorRow.Visibility = Cfg.Get(key + "iconSet", "mono") == "mono" ? Visibility.Visible : Visibility.Collapsed;
                Action<string> styleChanged = changed => { if (changed == key + "iconSet") colorRow.Visibility = Cfg.Get(key + "iconSet", "mono") == "mono" ? Visibility.Visible : Visibility.Collapsed; };
                Cfg.Changed += styleChanged; timerEditorCleanup += () => Cfg.Changed -= styleChanged;
                settings.Children.Add(colorRow);
            }
            var opacity = new Slider { Minimum = 0, Maximum = 1, StepFrequency = .05, Value = Cfg.Appearance(key.TrimEnd('.'), "opacity", 1.0), MinWidth = 0, VerticalAlignment = VerticalAlignment.Center };
            var opacityValue = new TextBlock { Text = opacity.Value.ToString("P0"), Width = 42, TextAlignment = TextAlignment.Right, VerticalAlignment = VerticalAlignment.Center };
            Windows.UI.Xaml.Automation.AutomationProperties.SetName(opacity, "Weather opacity");
            opacity.ValueChanged += (s, e) => { Cfg.Set(key + "appearance.opacity", e.NewValue); opacityValue.Text = e.NewValue.ToString("P0"); };
            var opacityRow = new Grid { ColumnSpacing = 10 };
            opacityRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            opacityRow.ColumnDefinitions.Add(new ColumnDefinition()); opacityRow.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
            opacityRow.Children.Add(new TextBlock { Text = "Opacity", VerticalAlignment = VerticalAlignment.Center });
            Grid.SetColumn(opacity, 1); opacityRow.Children.Add(opacity); Grid.SetColumn(opacityValue, 2); opacityRow.Children.Add(opacityValue); settings.Children.Add(opacityRow);
            settings.Children.Add(EditorModeButton(!advanced, () => Cfg.Set("helper.weatherEditorMode", advanced ? "simple" : "advanced")));
            if (reveal && WidgetTheme.AnimationsEnabled) {
                settings.Opacity = 0;
                settings.Loaded += (s, e) => {
                    var fade = new Windows.UI.Xaml.Media.Animation.DoubleAnimation { From = 0, To = 1, Duration = new Duration(TimeSpan.FromMilliseconds(180)) };
                    Windows.UI.Xaml.Media.Animation.Storyboard.SetTarget(fade, settings);
                    Windows.UI.Xaml.Media.Animation.Storyboard.SetTargetProperty(fade, "Opacity");
                    var animation = new Windows.UI.Xaml.Media.Animation.Storyboard(); animation.Children.Add(fade); animation.Begin();
                };
            }
        }
    }
}
