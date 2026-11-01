#if WINDOWS_UWP
using Windows.UI.Xaml.Media.Animation;
#endif

namespace WidgetSampleCS
{
    sealed class PinHintState
    {
        bool dismissed;
        public bool Update(bool editing, bool pinned)
        {
            if (pinned) dismissed = true;
            return editing && !dismissed;
        }
    }

#if WINDOWS_UWP
    static class PinHint
    {
        public static void Attach(Microsoft.Gaming.XboxGameBar.XboxGameBarWidget widget, Windows.UI.Xaml.Controls.Page page)
        {
            var host = page.Content as Windows.UI.Xaml.Controls.Grid;
            if (host == null) return;
            var hint = (Windows.UI.Xaml.Controls.StackPanel)Windows.UI.Xaml.Markup.XamlReader.Load(
                "<StackPanel xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' HorizontalAlignment='Right' VerticalAlignment='Top' Margin='0,8,34,0' Spacing='4' IsHitTestVisible='False' Visibility='Collapsed'>" +
                "<Path Data='M 6,20 L 6,2 M 1,7 L 6,2 L 11,7' Stroke='#E0685E' StrokeThickness='2' HorizontalAlignment='Right' Margin='0,0,5,0'/>" +
                "<TextBlock Text='Pin to stay visible' FontFamily='Segoe UI' FontSize='12' Foreground='#E0685E' HorizontalAlignment='Right'/></StackPanel>");
            Windows.UI.Xaml.Controls.Grid.SetRowSpan(hint, System.Math.Max(1, host.RowDefinitions.Count));
            host.Children.Add(hint);
            var arrow = (Windows.UI.Xaml.Shapes.Path)hint.Children[0];
            var movement = new Windows.UI.Xaml.Media.TranslateTransform();
            arrow.RenderTransform = movement;
            var bounce = new Storyboard { RepeatBehavior = RepeatBehavior.Forever };
            var motion = new DoubleAnimationUsingKeyFrames();
            foreach (var frame in new[] { (0, 0.0), (220, -3.0), (440, 0.0), (620, -1.5), (800, 0.0), (2200, 0.0) })
                motion.KeyFrames.Add(new EasingDoubleKeyFrame {
                    KeyTime = KeyTime.FromTimeSpan(System.TimeSpan.FromMilliseconds(frame.Item1)), Value = frame.Item2,
                    EasingFunction = new SineEase { EasingMode = EasingMode.EaseInOut }
                });
            Storyboard.SetTarget(motion, movement); Storyboard.SetTargetProperty(motion, "Y");
            bounce.Children.Add(motion);
            bool animating = false;
            var label = (Windows.UI.Xaml.Controls.TextBlock)hint.Children[1];
            bool weather = page is WeatherWidget;
            if (weather) {
                // An auto row disappears with the hint; the saved viewport size stays unchanged.
                host.RowDefinitions.Add(new Windows.UI.Xaml.Controls.RowDefinition { Height = Windows.UI.Xaml.GridLength.Auto });
                host.RowDefinitions.Add(new Windows.UI.Xaml.Controls.RowDefinition());
                foreach (var child in host.Children) if (child != hint) Windows.UI.Xaml.Controls.Grid.SetRow((Windows.UI.Xaml.FrameworkElement)child, 1);
                hint.Children.Remove(label); hint.Children.Insert(0, label);
                label.VerticalAlignment = Windows.UI.Xaml.VerticalAlignment.Center;
                hint.Margin = new Windows.UI.Xaml.Thickness(0, 8, 34, 4);
            }
            var state = new PinHintState();
            System.Action update = () => {
                // Tiny saved windows still need a readable label without resizing their content.
                bool compact = host.ActualWidth < 160 || host.ActualHeight < 44;
                hint.Orientation = compact || weather ? Windows.UI.Xaml.Controls.Orientation.Horizontal : Windows.UI.Xaml.Controls.Orientation.Vertical;
                label.Text = compact ? "Pin" : "Pin to stay visible";
                hint.Visibility = state.Update(widget.GameBarDisplayMode == Microsoft.Gaming.XboxGameBar.XboxGameBarDisplayMode.Foreground, widget.Pinned)
                    ? Windows.UI.Xaml.Visibility.Visible : Windows.UI.Xaml.Visibility.Collapsed;
                bool animate = WidgetTheme.AnimationsEnabled && hint.IsLoaded && hint.Visibility == Windows.UI.Xaml.Visibility.Visible;
                if (animate != animating) {
                    animating = animate;
                    if (animate) bounce.Begin(); else bounce.Stop();
                }
            };
            hint.Loaded += (s, e) => update();
            hint.Unloaded += (s, e) => { bounce.Stop(); animating = false; };
            widget.GameBarDisplayModeChanged += (s, e) => { _ = hint.Dispatcher.RunAsync(Windows.UI.Core.CoreDispatcherPriority.Normal, () => update()); };
            widget.PinnedChanged += (s, e) => { _ = hint.Dispatcher.RunAsync(Windows.UI.Core.CoreDispatcherPriority.Normal, () => update()); };
            host.SizeChanged += (s, e) => update();
            System.Action<string> settingsChanged = key => { if (key == "helper.appearance") _ = hint.Dispatcher.RunAsync(Windows.UI.Core.CoreDispatcherPriority.Normal, () => update()); };
            Cfg.Changed += settingsChanged;
            Windows.UI.Xaml.Window.Current.Closed += (s, e) => Cfg.Changed -= settingsChanged;
            update();
        }
    }
#endif
}
