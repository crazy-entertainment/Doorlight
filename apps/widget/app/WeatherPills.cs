using System;
using Windows.Foundation;
using Windows.UI.Xaml;
using Windows.UI.Xaml.Controls;

namespace WidgetSampleCS
{
    // UWP's WrapGrid uses equal-size cells; location pills fit their own labels instead.
    sealed class WeatherPills : Panel
    {
        protected override Size MeasureOverride(Size available)
        {
            double x = 0, y = 0, rowHeight = 0, width = 0;
            foreach (FrameworkElement child in Children) {
                child.Measure(new Size(available.Width, double.PositiveInfinity));
                var size = child.DesiredSize;
                if (x > 0 && x + size.Width > available.Width) { y += rowHeight + 6; x = 0; rowHeight = 0; }
                width = Math.Max(width, x + size.Width);
                x += size.Width + 6; rowHeight = Math.Max(rowHeight, size.Height);
            }
            return new Size(width, y + rowHeight);
        }
        protected override Size ArrangeOverride(Size final)
        {
            double x = 0, y = 0, rowHeight = 0;
            foreach (FrameworkElement child in Children) {
                var size = child.DesiredSize;
                if (x > 0 && x + size.Width > final.Width) { y += rowHeight + 6; x = 0; rowHeight = 0; }
                child.Arrange(new Rect(x, y, size.Width, size.Height));
                x += size.Width + 6; rowHeight = Math.Max(rowHeight, size.Height);
            }
            return final;
        }
    }
}
