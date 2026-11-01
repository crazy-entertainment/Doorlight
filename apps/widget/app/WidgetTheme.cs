using System;
using System.Collections.Generic;
using Windows.UI.Xaml;
using Windows.UI.Xaml.Controls;
using Windows.UI.Xaml.Media;

namespace WidgetSampleCS
{
    static class WidgetTheme
    {
        public const string Setting = "helper.theme";
        public static WidgetPalette Current => WidgetPalette.For(Cfg.Get(Setting, "cozy"));
        public static bool AnimationsEnabled => Cfg.Get("helper.vibeAnimated", true);
        // Game Bar views use separate UI apartments and can close independently.
        public static FontFamily Sans => new FontFamily("ms-appx:///Assets/Fonts/HankenGrotesk-Variable.ttf#Hanken Grotesk");
        public static FontFamily Heading => Current.Serif ? new FontFamily("ms-appx:///Assets/Fonts/Fraunces-Variable.ttf#Fraunces") : Sans;
        public static Windows.UI.Color Color(string hex) => hex.Length == 9
            ? Windows.UI.Color.FromArgb(Convert.ToByte(hex.Substring(1, 2), 16), Convert.ToByte(hex.Substring(3, 2), 16), Convert.ToByte(hex.Substring(5, 2), 16), Convert.ToByte(hex.Substring(7, 2), 16))
            : Cfg.Parse(hex).Value;

        public static Dictionary<string, string> Brushes(WidgetPalette p) => new Dictionary<string, string> {
            ["WidgetBackground"] = p.Background, ["WidgetSurface"] = p.Surface, ["WidgetHigh"] = p.High,
            ["WidgetInk"] = p.Ink, ["WidgetMuted"] = p.Muted, ["WidgetBorder"] = p.Border,
            ["WidgetAccent"] = p.Fill, ["WidgetOnAccent"] = p.OnAccent,
            ["WidgetButton"] = p.ButtonFill, ["WidgetButtonBorder"] = p.ButtonBorder, ["WidgetFieldBorder"] = p.FieldBorder,
            ["SystemControlHighlightAccentBrush"] = p.Fill,
            ["SliderTrackValueFill"] = p.Fill, ["SliderTrackValueFillPointerOver"] = p.Accent, ["SliderTrackValueFillPressed"] = p.Pressed,
            ["SliderThumbBackground"] = p.Ink, ["SliderThumbBackgroundPointerOver"] = p.Ink, ["SliderThumbBackgroundPressed"] = p.Ink,
            ["SliderThumbBackgroundDisabled"] = p.Faint, ["SliderTrackFill"] = p.Border, ["SliderTrackFillPointerOver"] = p.Faint,
            ["SliderTrackFillDisabled"] = p.Top, ["SliderTrackValueFillDisabled"] = p.Border,
            ["ToggleSwitchFillOn"] = p.Fill, ["ToggleSwitchFillOnPointerOver"] = p.Accent, ["ToggleSwitchFillOnPressed"] = p.Pressed,
            ["ToggleSwitchKnobFillOn"] = p.OnAccent,
            ["ButtonBackgroundPointerOver"] = p.ButtonHover, ["ButtonBackgroundPressed"] = p.ButtonPressed,
            ["ButtonBorderBrushPointerOver"] = p.ButtonBorder, ["ButtonBorderBrushPressed"] = p.ButtonBorder,
            ["ButtonForegroundPointerOver"] = p.Ink, ["ButtonForegroundPressed"] = p.Ink,
            ["ComboBoxBackgroundPointerOver"] = p.Top, ["ComboBoxBackgroundPressed"] = p.Selected,
            ["ComboBoxBorderBrushPointerOver"] = p.Accent, ["ComboBoxForegroundPointerOver"] = p.Ink,
            ["ComboBoxDropDownBackground"] = p.Surface, ["ComboBoxDropDownBorderBrush"] = p.Border,
            ["ComboBoxItemBackgroundSelected"] = p.Selected, ["ComboBoxItemBackgroundSelectedPointerOver"] = p.Top,
            ["ComboBoxItemForegroundSelected"] = p.Ink, ["ComboBoxItemBackgroundPointerOver"] = p.High,
            ["TextControlForeground"] = p.Ink, ["TextControlForegroundPointerOver"] = p.Ink, ["TextControlForegroundFocused"] = p.Ink,
            ["TextControlForegroundDisabled"] = p.Muted, ["TextControlPlaceholderForeground"] = p.Muted,
            ["TextControlPlaceholderForegroundFocused"] = p.Muted, ["TextControlBackgroundPointerOver"] = p.High,
            ["TextControlBackgroundFocused"] = p.Desk, ["TextControlBorderBrushFocused"] = p.Fill,
            ["CheckBoxCheckBackgroundFillChecked"] = p.Fill, ["CheckBoxCheckBackgroundFillCheckedPointerOver"] = p.Accent,
            ["CheckBoxCheckBackgroundFillCheckedPressed"] = p.Pressed, ["CheckBoxCheckGlyphForegroundChecked"] = p.OnAccent,
            ["CheckBoxForeground"] = p.Ink, ["CheckBoxForegroundPointerOver"] = p.Ink,
            ["ToggleButtonBackgroundChecked"] = p.Selected, ["ToggleButtonBackgroundCheckedPointerOver"] = p.Top,
            ["ToggleButtonBackgroundCheckedPressed"] = p.Selected, ["ToggleButtonForegroundChecked"] = p.Ink,
            ["ToggleButtonBorderBrushChecked"] = p.Accent,
            ["FlyoutBackground"] = p.Surface, ["FlyoutBorderBrush"] = p.Border,
            ["MenuFlyoutPresenterBackground"] = p.Surface, ["MenuFlyoutPresenterBorderBrush"] = p.Border,
            ["MenuFlyoutItemForeground"] = p.Ink, ["MenuFlyoutItemForegroundPointerOver"] = p.Ink,
            ["MenuFlyoutItemBackgroundPointerOver"] = p.High, ["MenuFlyoutItemBackgroundPressed"] = p.Selected,
            ["ContentDialogBackground"] = p.Surface, ["ContentDialogForeground"] = p.Ink,
            ["SystemControlForegroundBaseHighBrush"] = p.Ink, ["SystemControlForegroundBaseMediumBrush"] = p.Muted
        };

        public static void Attach(Page page)
        {
            // Resources and mutable brushes belong to this view's UI thread.
            void Apply() {
                var palette = Current;
                foreach (var item in Brushes(palette)) {
                    var color = Color(item.Value);
                    if (page.Resources.ContainsKey(item.Key) && page.Resources[item.Key] is SolidColorBrush brush) brush.Color = color;
                    else page.Resources[item.Key] = new SolidColorBrush(color);
                }
                page.Resources["SystemAccentColor"] = Cfg.Parse(palette.Fill).Value;
                page.FontFamily = Sans;
            }
            Apply();
            Action<string> changed = key => {
                if (key == Setting || key == "helper.appearance") _ = page.Dispatcher.RunAsync(Windows.UI.Core.CoreDispatcherPriority.Normal, Apply);
            };
            Cfg.Changed += changed;
            Window.Current.Closed += (s, e) => Cfg.Changed -= changed;
        }
    }
}
