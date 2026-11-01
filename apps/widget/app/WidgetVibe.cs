using System;
using System.Collections.Generic;
using System.Diagnostics;
using Windows.Foundation;
using Windows.UI.Xaml;
using Windows.UI.Xaml.Controls;
using Windows.UI.Xaml.Markup;
using Windows.UI.Xaml.Media;
using Windows.UI.Xaml.Shapes;

namespace WidgetSampleCS
{
    // This surface belongs only to the Helper; no particles enter gameplay overlays.
    sealed class WidgetVibe : IDisposable
    {
        readonly Canvas canvas;
        readonly Func<bool> foreground;
        readonly DispatcherTimer timer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(33) };
        readonly Stopwatch elapsed = new Stopwatch();
        readonly List<Shape> shapes = new List<Shape>();
        readonly Action<string> changed;
        string kind;
        double intensity, opacity;
        bool disposed;

        public WidgetVibe(Canvas canvas, Func<bool> foreground)
        {
            this.canvas = canvas; this.foreground = foreground;
            timer.Tick += (s, e) => Draw();
            canvas.SizeChanged += (s, e) => Refresh();
            canvas.Loaded += (s, e) => Refresh();
            canvas.Unloaded += (s, e) => { timer.Stop(); elapsed.Stop(); };
            changed = key => {
                if (key == WidgetTheme.Setting || key == "helper.appearance" || key.StartsWith("helper.vibe"))
                    _ = canvas.Dispatcher.RunAsync(Windows.UI.Core.CoreDispatcherPriority.Normal, Refresh);
            };
            Cfg.Changed += changed;
        }

        public void Refresh()
        {
            if (disposed) return;
            timer.Stop(); elapsed.Stop(); shapes.Clear(); canvas.Children.Clear();
            kind = Cfg.Get("helper.vibe", "none");
            intensity = WidgetVibeMath.Unit(Cfg.Get("helper.vibeIntensity", 100.0) / 100);
            opacity = WidgetVibeMath.Unit(Cfg.Get("helper.vibeOpacity", 100.0) / 100);
            double width = canvas.ActualWidth, height = canvas.ActualHeight;
            canvas.Clip = new RectangleGeometry { Rect = new Rect(0, 0, width, height) };
            if (!foreground() || kind == "none" || opacity <= 0 || intensity <= 0 || width <= 0 || height <= 0) return;
            var p = WidgetTheme.Current;
            if (kind == "halloween") {
                var moon = Path("M16,0 A16,16 0 1 0 16,32 A13,13 0 0 1 16,0 Z", p.Ink);
                moon.Opacity = opacity * .14; Canvas.SetLeft(moon, width * .81 - 16); Canvas.SetTop(moon, height * .22 - 16);
                for (int i = 0; i < Math.Ceiling(3 * intensity); i++) {
                    var mist = new Ellipse { Width = width * .95, Height = height * .35, Opacity = opacity * .04,
                        Fill = new LinearGradientBrush { StartPoint = new Point(0, 0), EndPoint = new Point(0, 1), GradientStops = {
                            new GradientStop { Offset = 0, Color = Windows.UI.Colors.Transparent },
                            new GradientStop { Offset = .5, Color = WidgetTheme.Color(p.Sky) },
                            new GradientStop { Offset = 1, Color = Windows.UI.Colors.Transparent }
                        } } };
                    shapes.Add(mist); canvas.Children.Add(mist);
                }
                for (int i = 0; i < Math.Ceiling(2 * intensity); i++)
                    shapes.Add(Path("M-10,-2 Q-5,-5 -1,0 L-1,-2 L0,-1 L1,-2 L1,0 Q5,-5 10,-2 Q7,3 4,1 Q2,4 0,3 Q-2,4 -4,1 Q-7,3 -10,-2 Z", p.Ink));
            } else if (kind == "rain" || kind == "snow") {
                for (int i = 0; i < WidgetVibeMath.Count(width, height, intensity); i++) {
                    double depth = .55 + .45 * WidgetVibeMath.Seed(i, 4);
                    Shape shape = kind == "rain"
                        ? (Shape)new Line { X1 = 0, Y1 = 0, X2 = -.22 * 13 * depth, Y2 = 13 * depth, Stroke = new SolidColorBrush(WidgetTheme.Color(p.Sky)), StrokeThickness = .9, StrokeStartLineCap = PenLineCap.Round, StrokeEndLineCap = PenLineCap.Round }
                        : new Ellipse { Width = 3.4 * depth, Height = 3.4 * depth, Fill = new SolidColorBrush(WidgetTheme.Color(p.Ink)) };
                    shapes.Add(shape); canvas.Children.Add(shape);
                }
            }
            Draw();
            if (WidgetVibeMath.Animate(foreground(), canvas.IsLoaded, Cfg.Get("helper.vibeAnimated", true), kind, opacity, intensity)) {
                elapsed.Start(); timer.Start();
            }
        }

        Path Path(string data, string color)
        {
            var shape = (Path)XamlReader.Load("<Path xmlns='http://schemas.microsoft.com/winfx/2006/xaml/presentation' Data='" + data + "'/>");
            shape.Fill = new SolidColorBrush(WidgetTheme.Color(color)); canvas.Children.Add(shape); return shape;
        }

        void Draw()
        {
            if (disposed || !foreground() || !canvas.IsLoaded) { timer.Stop(); elapsed.Stop(); return; }
            double phase = elapsed.Elapsed.TotalSeconds / 12, width = canvas.ActualWidth, height = canvas.ActualHeight;
            int mistCount = (int)Math.Ceiling(3 * intensity);
            for (int i = 0; i < shapes.Count; i++) {
                var shape = shapes[i]; double x, y;
                if (kind == "halloween") {
                    if (i < mistCount) {
                        x = width * (.2 + i * .32) + Math.Sin(phase * Math.PI * 2 + i * 2) * width * .08 - shape.Width / 2;
                        y = height * (.96 - i * .025) - shape.Height / 2;
                    } else {
                        int bat = i - mistCount;
                        double travel = WidgetVibeMath.Wrap(phase + bat * .47, 1);
                        x = travel * (width + 32) - 16; y = height * (.16 + bat * .13) + Math.Sin(travel * Math.PI * 2 + bat) * 10;
                        var wings = shape.RenderTransform as ScaleTransform ?? new ScaleTransform { ScaleX = .7 };
                        wings.ScaleY = .7 + .2 * Math.Sin(phase * Math.PI * 24 + bat); shape.RenderTransform = wings;
                        shape.Opacity = opacity * .14 * WidgetVibeMath.Edge(x, y, width, height);
                    }
                } else {
                    double seed = WidgetVibeMath.Seed(i, 4), depth = .55 + .45 * seed;
                    if (kind == "rain") {
                        double travel = WidgetVibeMath.Wrap(WidgetVibeMath.Seed(i, 6) + phase * 6, 1) * (height + 48);
                        x = WidgetVibeMath.Wrap(seed * width - .22 * travel, width); y = travel - 24;
                    } else {
                        x = WidgetVibeMath.Wrap(seed * width + Math.Sin(phase * Math.PI * 2 + i) * 12, width);
                        y = WidgetVibeMath.Wrap(WidgetVibeMath.Seed(i, 6) + phase, 1) * (height + 12) - 6;
                    }
                    shape.Opacity = opacity * .13 * depth * WidgetVibeMath.Edge(x, y, width, height);
                }
                Canvas.SetLeft(shape, x); Canvas.SetTop(shape, y);
            }
        }

        public void Dispose() { disposed = true; timer.Stop(); elapsed.Stop(); Cfg.Changed -= changed; }
    }
}
