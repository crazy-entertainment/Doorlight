using System;
using Windows.UI.Xaml;
using Windows.UI.Xaml.Controls;
using Windows.UI.Xaml.Media;

namespace WidgetSampleCS
{
    public sealed partial class HelperWidget
    {
        Button EditorModeButton(bool toAdvanced, Action changeMode)
        {
            var content = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 6 };
            var arrow = new FontIcon { FontFamily = new FontFamily("Segoe MDL2 Assets"), Glyph = toAdvanced ? "\uE76C" : "\uE76B", FontSize = 11, VerticalAlignment = VerticalAlignment.Center };
            var label = new TextBlock { Text = toAdvanced ? "Advanced" : "Simple", FontSize = 14, VerticalAlignment = VerticalAlignment.Center };
            if (!toAdvanced) content.Children.Add(arrow);
            content.Children.Add(label);
            if (toAdvanced) content.Children.Add(arrow);
            var button = new Button { Content = content, MinWidth = 0, MinHeight = 36, Padding = new Thickness(10, 8, 10, 8), CornerRadius = new CornerRadius(6),
                Margin = new Thickness(-10, 10, 0, 0), HorizontalAlignment = HorizontalAlignment.Left,
                Background = new SolidColorBrush(Windows.UI.Colors.Transparent), BorderThickness = new Thickness(0),
                Foreground = new SolidColorBrush(Rgb(Palette.Accent)) };
            button.Resources["ButtonBackgroundPointerOver"] = new SolidColorBrush(Rgb(Palette.Surface));
            button.Resources["ButtonBackgroundPressed"] = new SolidColorBrush(Rgb(Palette.Selected));
            button.Resources["ButtonForegroundPointerOver"] = new SolidColorBrush(Rgb(Palette.Ink));
            button.Resources["ButtonForegroundPressed"] = new SolidColorBrush(Rgb(Palette.Ink));
            Windows.UI.Xaml.Automation.AutomationProperties.SetName(button, toAdvanced ? "Advanced" : "Simple");
            button.Click += (s, e) => changeMode();
            return button;
        }

        Grid Pair(FrameworkElement left, FrameworkElement right, bool equal = true, double gap = 20)
        {
            var g = new Grid { ColumnSpacing = gap };
            g.ColumnDefinitions.Add(new ColumnDefinition());
            g.ColumnDefinitions.Add(new ColumnDefinition { Width = equal ? new GridLength(1, GridUnitType.Star) : GridLength.Auto });
            g.Children.Add(left); Grid.SetColumn(right, 1); g.Children.Add(right); return g;
        }

        FrameworkElement TakeSlider(string label, string key, double min, double max, double def, double step)
        {
            Slider(label, key, min, max, def, step);
            var e = (FrameworkElement)Body.Children[Body.Children.Count - 1]; Body.Children.Remove(e); return e;
        }

        Button ColorChip(string key, string fallback, string label)
        {
            var b = new Button { Width = 32, Height = 36, MinWidth = 0, Padding = new Thickness(4) };
            var swatch = new Border { Width = 20, Height = 20, Background = new SolidColorBrush(Cfg.Color(key, fallback)), CornerRadius = new CornerRadius(2) };
            b.Content = swatch;
            Windows.UI.Xaml.Automation.AutomationProperties.SetName(b, label);
            var picker = new ColorPicker { Color = Cfg.Color(key, fallback), IsAlphaEnabled = false, IsColorSliderVisible = true, IsColorChannelTextInputVisible = true, Width = 260 };
            picker.ColorChanged += (s, a) => { var c = a.NewColor; Cfg.Set(key, $"#{c.R:X2}{c.G:X2}{c.B:X2}"); swatch.Background = new SolidColorBrush(c); };
            var flyout = new Flyout { Content = picker, Placement = Windows.UI.Xaml.Controls.Primitives.FlyoutPlacementMode.LeftEdgeAlignedTop, ShouldConstrainToRootBounds = false };
            b.Click += (s, e) => { picker.Color = Cfg.Color(key, fallback); flyout.ShowAt(this); };
            return b;
        }

        void CompactCross()
        {
            var mode = Cfg.Get("cross.mode", "shape");
            var types = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 20, Margin = new Thickness(0, 0, 0, 2) };
            foreach (var item in new[] { ("shape", "Shape"), ("pixel", "Pixels"), ("image", "Custom") })
            {
                bool selected = mode == item.Item1;
                var b = new Button {
                    Content = item.Item2, MinWidth = 0, MinHeight = 36, Padding = new Thickness(4, 6, 4, 8),
                    CornerRadius = new CornerRadius(0), Background = new SolidColorBrush(Windows.UI.Colors.Transparent),
                    BorderThickness = new Thickness(0, 0, 0, 2),
                    BorderBrush = new SolidColorBrush(selected ? Rgb(Palette.Fill) : Windows.UI.Colors.Transparent),
                    Foreground = new SolidColorBrush(Rgb(selected ? Palette.Ink : Palette.Muted))
                };
                Windows.UI.Xaml.Automation.AutomationProperties.SetHelpText(b, selected ? "Selected crosshair mode" : "Switch crosshair mode");
                types.Children.Add(b);
                b.Click += (s, a) => { Cfg.Set("cross.mode", item.Item1); Show(current); };
            }
            var header = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 4, HorizontalAlignment = HorizontalAlignment.Right, VerticalAlignment = VerticalAlignment.Center };
            var presets = CompactDropdown(120, "Choose crosshair");
            Windows.UI.Xaml.Automation.AutomationProperties.SetName(presets, "Selected crosshair");
            foreach (var id in Cfg.CrossIds) {
                var option = new ComboBoxItem { Content = Cfg.CrossName(id), Tag = id }; presets.Items.Add(option);
                if (id == Cfg.CrossActive) presets.SelectedItem = option;
            }
            presets.SelectionChanged += (s,e) => { if (presets.SelectedItem is ComboBoxItem item) Cfg.SelectCross((string)item.Tag); };
            if (Cfg.CrossActive != null) header.Children.Add(ItemSelector(presets));
            var more = TimerIcon("\uE712", "Crosshair actions"); var actions = new MenuFlyout(); more.Flyout = actions; header.Children.Add(WidgetActions(more, "cross", "Cross"));
            var add = new MenuFlyoutItem { Text = "Add crosshair", Icon = new SymbolIcon(Symbol.Add), IsEnabled = Cfg.CrossIds.Length < Cfg.CrossWindowLimit };
            add.Click += async (s,e) => { Cfg.CreateCross(); try { await ShowWidget("cross", "Cross"); } catch (Exception ex) { Status.Text = "Could not show crosshair: " + ex.Message; } }; actions.Items.Add(add);
            var duplicate = new MenuFlyoutItem { Text = "Duplicate", Icon = new SymbolIcon(Symbol.Copy), IsEnabled = Cfg.CrossActive != null && Cfg.CrossIds.Length < Cfg.CrossWindowLimit };
            duplicate.Click += async (s,e) => { Cfg.CreateCross(true); try { await ShowWidget("cross", "Cross"); } catch (Exception ex) { Status.Text = "Could not show crosshair: " + ex.Message; } }; actions.Items.Add(duplicate);
            var rename = new MenuFlyoutItem { Text = "Rename", Icon = new SymbolIcon(Symbol.Edit), IsEnabled = Cfg.CrossActive != null };
            rename.Click += async (s,e) => {
                string id = Cfg.CrossActive;
                var presetName = new TextBox { Text = Cfg.CrossName(id), MaxLength = 40 };
                var dialog = new ContentDialog { Title = "Rename crosshair", Content = presetName, PrimaryButtonText = "Save", CloseButtonText = "Cancel" };
                if (await dialog.ShowAsync() == ContentDialogResult.Primary) Cfg.RenameCross(id, presetName.Text);
            }; actions.Items.Add(rename);
            var delete = new MenuFlyoutItem { Text = "Delete", Icon = new SymbolIcon(Symbol.Delete), IsEnabled = Cfg.CrossActive != null };
            delete.Click += async (s,e) => {
                string id = Cfg.CrossActive, extension = Cfg.CrossExtension(id);
                try {
                    if (App.IsOpen(extension)) await new Microsoft.Gaming.XboxGameBar.XboxGameBarWidgetControl(widget).CloseAsync(extension);
                    if (id == Cfg.CrossActive) Cfg.DeleteCross();
                } catch (Exception ex) { Status.Text = "Could not delete crosshair: " + ex.Message; }
            }; actions.Items.Add(delete);
            actions.Items.Add(new MenuFlyoutSeparator());
            var reset = new MenuFlyoutItem { Text = "Reset selected crosshair", Icon = new SymbolIcon(Symbol.Refresh), IsEnabled = Cfg.CrossActive != null };
            reset.Click += (s,e) => { Cfg.ResetCross(); Cfg.Run("cross.refreshEditor"); }; actions.Items.Add(reset);
            WidgetMenu(actions, "cross", "Cross");
            { Grid.SetColumn(header, 1); PageHeader.Children.Add(header); timerEditorCleanup += () => PageHeader.Children.Remove(header); }
            if (Cfg.CrossActive == null) { EmptyWidget("crosshairs"); return; }
            if (!Cfg.AdvancedCrossEditor) { BuildSimpleCross(); return; }
            Body.Children.Add(types);
            if (mode == "shape")
            {
                string[] values = { "cross", "crossdot", "dot", "t", "circle" }, names = { "Cross", "Cross + dot", "Dot", "T-Crosshair", "Circle" };
                var label = new TextBlock { Text = names[Math.Max(0, Array.IndexOf(values, Cfg.Get("cross.style", "crossdot")))], FontWeight = Windows.UI.Text.FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center };
                var selectorContent = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8 };
                selectorContent.Children.Add(label);
                selectorContent.Children.Add(new FontIcon { FontFamily = new FontFamily("Segoe MDL2 Assets"), Glyph = "\uE70D", FontSize = 10, VerticalAlignment = VerticalAlignment.Center });
                var menu = new MenuFlyout();
                var shape = new Button { Content = selectorContent, Flyout = menu, HorizontalAlignment = HorizontalAlignment.Left, MinWidth = 0, Height = 36, Padding = new Thickness(0), BorderThickness = new Thickness(0), Background = new SolidColorBrush(Windows.UI.Colors.Transparent) };
                Windows.UI.Xaml.Automation.AutomationProperties.SetName(shape, "Crosshair shape");
                for (int i = 0; i < values.Length; i++) {
                    int index = i;
                    var option = new MenuFlyoutItem { Text = names[i] };
                    option.Click += (s, a) => { label.Text = names[index]; Cfg.Set("cross.style", values[index]); };
                    menu.Items.Add(option);
                }
                Body.Children.Add(CrossSurface(
                    Pair(shape, ColorChip("cross.color", "#7BD88F", "Crosshair color"), false, 8),
                    Pair(TakeSlider("Length", "cross.length", 1, 40, 12, 1), TakeSlider("Thickness", "cross.thickness", 1, 10, 2, 1)),
                    Pair(TakeSlider("Gap", "cross.gap", 0, 30, 5, 1), TakeSlider("Opacity", "cross.opacity", 0, 1, 1, .05))));
                var edge = ColorChip("cross.outlineColor", "#000000", "Outline color");
                var outlineControls = Pair(TakeSlider("Thickness", "cross.outlineThickness", 0, 6, 1, 1), TakeSlider("Opacity", "cross.outlineOpacity", 0, 1, 1, .05));
                var heading = new TextBlock { Text = "Outline", FontWeight = Windows.UI.Text.FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center };
                var outlineCard = CrossSurface(Pair(heading, edge, false), outlineControls);
                outlineCard.Padding = new Thickness(10, 4, 10, 4);
                Body.Children.Add(outlineCard);
            }
            else if (mode == "pixel")
            {
                PixelEditor();
                Body.Children.Add(Pair(TakeSlider("Pixel size", "cross.pixelSize", 1, 6, 2, 1), TakeSlider("Opacity", "cross.opacity", 0, 1, 1, .05)));
            }
            else
            {
                var pick = new Button { Content = "Choose image…" }; pick.Click += async (s, a) => await PickImage();
                var filename = new TextBlock { Text = Cfg.Get("cross.imageName", "Custom image"), TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center, FontSize = 12 };
                Body.Children.Add(Pair(filename, pick, false));
                Body.Children.Add(Pair(TakeSlider("Scale", "cross.imageScale", .25, 4, 1, .25), TakeSlider("Opacity", "cross.opacity", 0, 1, 1, .05)));
            }
            var toggle = new ToggleSwitch { IsOn = Cfg.Get("cross.aimToggle", false), OffContent = "", OnContent = "", MinWidth = 0, Width = 44, HorizontalAlignment = HorizontalAlignment.Right, Padding = new Thickness(0) };
            var aimMode = new TextBlock { Text = "Hold", VerticalAlignment = VerticalAlignment.Center };
            toggle.Toggled += (s, a) => Cfg.Set("cross.aimToggle", toggle.IsOn);
            Windows.UI.Xaml.Automation.AutomationProperties.SetName(toggle, "Aim input mode");
            var aimModeControl = new StackPanel { Orientation = Orientation.Horizontal, Spacing = 8, VerticalAlignment = VerticalAlignment.Center };
            aimModeControl.Children.Add(aimMode);
            aimModeControl.Children.Add(toggle);
            aimModeControl.Children.Add(new TextBlock { Text = "Toggle", VerticalAlignment = VerticalAlignment.Center });

            var input = CompactDropdown(180, alignment: HorizontalAlignment.Right);
            string[] keys = { "off", "right", "left", "middle", "x1", "x2", "shift", "ctrl" }, labels = { "Never", "Right mouse", "Left mouse", "Middle mouse", "Mouse button 4", "Mouse button 5", "Shift", "Ctrl" };
            foreach (var name in labels) input.Items.Add(name);
            input.SelectedIndex = Math.Max(0, Array.IndexOf(keys, Cfg.Get("cross.hold", "off")));
            Windows.UI.Xaml.Automation.AutomationProperties.SetName(input, "Hide when aiming input");
            input.VerticalAlignment = VerticalAlignment.Center;
            var aimDetails = new StackPanel { Margin = new Thickness(0, 8, 0, 0), Spacing = 2 };
            aimModeControl.HorizontalAlignment = HorizontalAlignment.Right;
            aimDetails.Children.Add(aimModeControl);
            aimDetails.Children.Add(Pair(
                TakeSlider("Fade out", "cross.aimFadeMs", 0, 750, 0, 25),
                TakeSlider("Fade in", "cross.aimFadeInMs", 0, 750, Cfg.Get("cross.aimFadeMs", 0.0), 25)));
            var aimSection = new StackPanel { Spacing = 0, Margin = new Thickness(10, 0, 10, 0) };
            aimSection.Children.Add(Pair(new TextBlock { Text = "Hide when aiming", VerticalAlignment = VerticalAlignment.Center }, input, false));
            aimSection.Children.Add(aimDetails);

            Action updateAimControls = () => {
                var visibility = input.SelectedIndex > 0 ? Visibility.Visible : Visibility.Collapsed;
                aimDetails.Visibility = visibility;
            };
            input.SelectionChanged += (s, a) => { if (input.SelectedIndex >= 0) { Cfg.Set("cross.hold", keys[input.SelectedIndex]); updateAimControls(); } };
            updateAimControls();

            Body.Children.Add(aimSection);
            Note("Hide when aiming uses the Doorlight desktop app.");
            Body.Children.Add(EditorModeButton(false, () => Cfg.SetCrossEditorMode(false)));
        }

        void AddProximitySettings()
        {
            var proximityHeading = CrossHeading("Fade when cursor is near");
            proximityHeading.Margin = new Thickness(0);
            proximityHeading.FontSize = 14;

            var start = new Slider { Minimum = 0, Maximum = 240, StepFrequency = 5, Value = Cfg.Appearance("general", "fadeStart", 0.0) };
            var end = new Slider { Minimum = 0, Maximum = 240, StepFrequency = 5, Value = Cfg.Appearance("general", "fadeEnd", 0.0) };
            var startValue = new TextBlock(); var endValue = new TextBlock(); bool updating = false;
            Action save = () => { Cfg.SetFade(start.Value, end.Value); startValue.Text = start.Value + " px"; endValue.Text = end.Value + " px"; };
            start.ValueChanged += (s, a) => { if (updating) return; updating = true; end.Value = CrossMath.ClampFadeEnd(a.NewValue, end.Value); save(); updating = false; };
            end.ValueChanged += (s, a) => { if (updating) return; updating = true; end.Value = CrossMath.ClampFadeEnd(start.Value, a.NewValue); save(); updating = false; };
            var distances = Pair(DistanceControl("Start fading", start, startValue), DistanceControl("Fully hidden at", end, endValue));
            Body.Children.Add(CrossSurface(new Border { Height = 36, Child = proximityHeading }, distances));
            Note("Cursor fading uses the Doorlight desktop app.");
            startValue.Text = start.Value + " px"; endValue.Text = end.Value + " px";
        }

        Border CrossSurface(params FrameworkElement[] controls)
        {
            var content = new StackPanel { Spacing = 4 };
            foreach (var control in controls) content.Children.Add(control);
            return new Border { Background = new SolidColorBrush(Rgb(Palette.Surface)), BorderBrush = new SolidColorBrush(Rgb(Palette.Border)), BorderThickness = new Thickness(1), CornerRadius = new CornerRadius(8), Padding = new Thickness(10, 4, 10, 4), Child = content };
        }
        TextBlock CrossHeading(string text) => new TextBlock { Text = text, FontSize = 15, FontWeight = Windows.UI.Text.FontWeights.SemiBold, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(0, 10, 0, 0) };
        FrameworkElement DistanceControl(string label, Slider slider, TextBlock value, string units = "pixels")
        {
            value.Foreground = new SolidColorBrush(Rgb(Palette.Ink)); value.FontSize = 12;
            Windows.UI.Xaml.Automation.AutomationProperties.SetName(slider, label + " in " + units);
            var panel = new StackPanel(); panel.Children.Add(Pair(new TextBlock { Text = label, FontSize = 14 }, value, false, 4)); panel.Children.Add(slider); return panel;
        }
    }
}
