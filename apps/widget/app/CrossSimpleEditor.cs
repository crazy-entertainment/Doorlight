using System;
using Windows.Foundation;
using Windows.UI;
using Windows.UI.Xaml;
using Windows.UI.Xaml.Automation;
using Windows.UI.Xaml.Controls;
using Windows.UI.Xaml.Controls.Primitives;
using Windows.UI.Xaml.Media;
using Windows.UI.Xaml.Shapes;
using UiColors = Windows.UI.Colors;

namespace WidgetSampleCS
{
    public sealed partial class HelperWidget
    {
        static readonly string[] SimpleShapes = { "crossdot", "cross", "dot", "circle", "t" };
        static readonly string[] SimpleShapeNames = { "Cross + dot", "Cross", "Dot", "Ring", "T-shape" };
        static readonly string[] SimpleColors = { "#FFFFFF", "#7BD88F", "#60DFFF", "#548CFF", "#B18CFF", "#FF7AD9", "#FF6666", "#FFAB59", "#FFDF63", "#000000" };
        static readonly string[] SimpleColorNames = { "White", "Green", "Cyan", "Blue", "Purple", "Pink", "Red", "Orange", "Yellow", "Black" };

        void BuildSimpleCross()
        {
            var advanced = EditorModeButton(true, () => Cfg.SetCrossEditorMode(true));
            if (Cfg.Get("cross.mode", "shape") != "shape") {
                Note("Use Advanced to edit this " + (Cfg.Get("cross.mode", "shape") == "pixel" ? "pixel crosshair." : "custom image."));
                Body.Children.Add(advanced); return;
            }

            Body.Children.Add(CrossHeading("Shape"));
            var shapes = new Grid { ColumnSpacing = 7 };
            var shapeButtons = new ToggleButton[SimpleShapes.Length];
            var shapeColor = new SolidColorBrush(Cfg.Color("cross.color", "#FFFFFF"));
            var shapeTemplate = (ControlTemplate)Windows.UI.Xaml.Markup.XamlReader.Load(
                "<ControlTemplate xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' TargetType='ToggleButton'>" +
                "<Border CornerRadius='8' Background='{TemplateBinding Background}' BorderBrush='{TemplateBinding BorderBrush}' BorderThickness='{TemplateBinding BorderThickness}' Padding='{TemplateBinding Padding}'>" +
                "<ContentPresenter Content='{TemplateBinding Content}' HorizontalAlignment='Center' VerticalAlignment='Center'/></Border></ControlTemplate>");
            for (int i = 0; i < SimpleShapes.Length; i++) {
                int index = i;
                shapes.ColumnDefinitions.Add(new ColumnDefinition());
                var content = new StackPanel { Spacing = 7, HorizontalAlignment = HorizontalAlignment.Center };
                content.Children.Add(SimpleShapeIcon(SimpleShapes[i], shapeColor));
                content.Children.Add(new TextBlock { Text = SimpleShapeNames[i], FontSize = 11, TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap, MaxWidth = 62 });
                var button = new ToggleButton { Content = content, Template = shapeTemplate,
                    MinWidth = 0, MinHeight = 0, Padding = new Thickness(2, 10, 2, 10),
                    BorderThickness = new Thickness(1), HorizontalAlignment = HorizontalAlignment.Stretch,
                    HorizontalContentAlignment = HorizontalAlignment.Center, UseSystemFocusVisuals = true };
                AutomationProperties.SetName(button, SimpleShapeNames[i]);
                button.Click += (s, e) => Cfg.Set("cross.style", SimpleShapes[index]);
                Grid.SetColumn(button, i); shapes.Children.Add(button); shapeButtons[i] = button;
            }
            Body.Children.Add(shapes);

            bool syncingSize = false;
            var size = new Slider { Minimum = .5, Maximum = 1.6, StepFrequency = .01, Value = Cfg.CrossSimpleScale, IsThumbToolTipEnabled = false };
            AutomationProperties.SetName(size, "Crosshair size");
            size.ValueChanged += (s, e) => { if (!syncingSize) Cfg.SetCrossSimpleScale(e.NewValue); };
            var gap = new Slider { Minimum = 0, Maximum = 30, StepFrequency = 1, Value = Cfg.Get("cross.gap", 5.0) };
            AutomationProperties.SetName(gap, "Crosshair gap");
            gap.ValueChanged += (s, e) => { if (!syncingSize) Cfg.Set("cross.gap", e.NewValue); };
            FrameworkElement InlineSlider(string label, Slider slider) {
                var row = new Grid { ColumnSpacing = 12 };
                row.ColumnDefinitions.Add(new ColumnDefinition { Width = GridLength.Auto });
                row.ColumnDefinitions.Add(new ColumnDefinition());
                row.Children.Add(new TextBlock { Text = label, VerticalAlignment = VerticalAlignment.Center });
                Grid.SetColumn(slider, 1); row.Children.Add(slider); return row;
            }
            Body.Children.Add(new Border { Margin = new Thickness(0, 8, 0, 2), Child = Pair(InlineSlider("Size", size), InlineSlider("Gap", gap), true, 18) });

            var palette = new Grid { ColumnSpacing = 5, Margin = new Thickness(3, 3, 3, 3) };
            var colorButtons = new Button[SimpleColors.Length];
            for (int i = 0; i < SimpleColors.Length; i++) {
                int index = i;
                palette.ColumnDefinitions.Add(new ColumnDefinition());
                var button = new Button {
                    MinWidth = 0, MinHeight = 28, Height = 28, Padding = new Thickness(0), CornerRadius = new CornerRadius(14),
                    Background = new SolidColorBrush(Rgb(SimpleColors[i])), HorizontalAlignment = HorizontalAlignment.Stretch
                };
                AutomationProperties.SetName(button, SimpleColorNames[i]);
                button.Click += (s, e) => Cfg.Set("cross.color", SimpleColors[index]);
                Grid.SetColumn(button, i); palette.Children.Add(button); colorButtons[i] = button;
            }
            palette.ColumnDefinitions.Add(new ColumnDefinition());
            var custom = ColorChip("cross.color", "#FFFFFF", "Choose a custom crosshair color");
            custom.Content = new FontIcon { FontFamily = new FontFamily("Segoe MDL2 Assets"), Glyph = "\uE790", FontSize = 17 };
            custom.Width = double.NaN; custom.Height = 28; custom.MinHeight = 28; custom.Padding = new Thickness(0); custom.CornerRadius = new CornerRadius(5);
            custom.HorizontalAlignment = HorizontalAlignment.Stretch;
            Grid.SetColumn(custom, SimpleColors.Length); palette.Children.Add(custom);
            Body.Children.Add(palette);
            Body.Children.Add(advanced);

            void Refresh()
            {
                string selectedShape = Cfg.Get("cross.style", "crossdot"), selectedColor = Cfg.Get("cross.color", "#7BD88F");
                shapeColor.Color = Cfg.Color("cross.color", "#FFFFFF");
                for (int i = 0; i < shapeButtons.Length; i++) {
                    bool selected = selectedShape == SimpleShapes[i];
                    shapeButtons[i].IsChecked = selected;
                    shapeButtons[i].Background = new SolidColorBrush(Rgb(selected ? Palette.Selected : Palette.Surface));
                    shapeButtons[i].BorderBrush = new SolidColorBrush(Rgb(selected ? Palette.Fill : Palette.Border));
                    shapeButtons[i].Foreground = new SolidColorBrush(Rgb(Palette.Ink));
                }
                for (int i = 0; i < colorButtons.Length; i++) {
                    bool selected = string.Equals(selectedColor, SimpleColors[i], StringComparison.OrdinalIgnoreCase);
                    colorButtons[i].BorderThickness = new Thickness(selected ? 3 : 1);
                    colorButtons[i].BorderBrush = new SolidColorBrush(Rgb(selected ? Palette.Fill : Palette.Faint));
                    AutomationProperties.SetHelpText(colorButtons[i], selected ? "Selected color" : "");
                }
                syncingSize = true; size.Value = Cfg.CrossSimpleScale; gap.Value = Cfg.Get("cross.gap", 5.0); syncingSize = false;
            }
            Action<string> changed = key => { if (key.StartsWith("cross.")) Refresh(); };
            Cfg.Changed += changed; timerEditorCleanup += () => Cfg.Changed -= changed;
            Refresh();
        }

        static FrameworkElement SimpleShapeIcon(string shape, SolidColorBrush fill)
        {
            var canvas = new Canvas { Width = 56, Height = 48 };
            var edge = new SolidColorBrush(UiColors.Black);
            void Arm(double x, double y, double w, double h) {
                var outline = new Rectangle { Width = w + 3.2, Height = h + 3.2, Fill = edge };
                Canvas.SetLeft(outline, x - 1.6); Canvas.SetTop(outline, y - 1.6); canvas.Children.Add(outline);
                var body = new Rectangle { Width = w, Height = h, Fill = fill };
                Canvas.SetLeft(body, x); Canvas.SetTop(body, y); canvas.Children.Add(body);
            }
            if (shape == "circle") {
                canvas.Children.Add(new Path { Data = new EllipseGeometry { Center = new Point(28, 24), RadiusX = 12.8, RadiusY = 12.8 }, Stroke = edge, StrokeThickness = 6.4 });
                canvas.Children.Add(new Path { Data = new EllipseGeometry { Center = new Point(28, 24), RadiusX = 12.8, RadiusY = 12.8 }, Stroke = fill, StrokeThickness = 3.2 });
            } else if (shape == "dot") {
                canvas.Children.Add(new Path { Data = new EllipseGeometry { Center = new Point(28, 24), RadiusX = 6.4, RadiusY = 6.4 }, Fill = edge });
                canvas.Children.Add(new Path { Data = new EllipseGeometry { Center = new Point(28, 24), RadiusX = 4.8, RadiusY = 4.8 }, Fill = fill });
            }
            else {
                if (shape != "t") Arm(26.4, 3.2, 3.2, 16);
                Arm(26.4, 28.8, 3.2, 16); Arm(7.2, 22.4, 16, 3.2); Arm(32.8, 22.4, 16, 3.2);
                if (shape == "crossdot") Arm(26.4, 22.4, 3.2, 3.2);
            }
            return new Viewbox { Width = 44, Height = 40, Stretch = Stretch.Fill, Child = canvas };
        }
    }
}
