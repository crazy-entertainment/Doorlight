using System;
using Microsoft.Gaming.XboxGameBar;
using Windows.Storage;
using Windows.UI;
using Windows.UI.Xaml;
using Windows.UI.Xaml.Controls;
using Windows.UI.Xaml.Media;
using Windows.UI.Xaml.Media.Imaging;
using Windows.UI.Xaml.Navigation;
using Windows.UI.Xaml.Shapes;

namespace WidgetSampleCS
{
    sealed class CrossWindowContext { public XboxGameBarWidget Widget; public string Id; public string Extension; }

    public sealed partial class CrossWidget : Page
    {
        public const int Grid = 21; // pixel editor is Grid x Grid
        Element el;
        string instanceId;
        T Get<T>(string key, T fallback) => Cfg.ForCross(instanceId, key, fallback);
        void Set(string key, object value) => Cfg.SetCross(instanceId, key, value);
        Windows.UI.Color Color(string key, string fallback) => Cfg.Parse(Get(key, fallback)) ?? Cfg.Parse(fallback).Value;
        int imageRequest;
        readonly DispatcherTimer setupBlurTimer = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(150) };
        bool setupBlurReported;
        string setupBlurState;
        string extensionId;

        static readonly string[] Styles = { "cross", "crossdot", "dot", "t", "circle" };
        static readonly string[] Names = { "Cross", "Cross + dot", "Dot", "T-Crosshair", "Circle" };

        public CrossWidget() { WidgetTheme.Attach(this); InitializeComponent(); }

        protected override void OnNavigatedTo(NavigationEventArgs e)
        {
            var context = (CrossWindowContext)e.Parameter;
            instanceId = context.Id;
            extensionId = context.Extension;
            el = new Element("cross", context.Widget, Holder, crossId: instanceId);
            if (instanceId == null) { _ = new XboxGameBarWidgetControl(context.Widget).CloseAsync(context.Extension); return; }
            el.Widget.MinWindowSize = new Windows.Foundation.Size(200, 160);
            el.Widget.MaxWindowSize = new Windows.Foundation.Size(700, 700);

            Action<string> changed = key => { if(key=="crossPresets."+instanceId+".visible")el.Ui(async()=>{try{var control=new XboxGameBarWidgetControl(context.Widget);if(Cfg.CrossVisible(instanceId))await control.RestoreAsync(context.Extension);else await control.MinimizeAsync(context.Extension);}catch(Exception ex){Log.Write("cross visibility: "+ex.GetType().Name);}}); if (key == WidgetTheme.Setting || key == "helper.appearance") el.Ui(UpdateSetup); if (key.StartsWith("cross.") || key.StartsWith("crossPresets.")) el.Ui(Redraw); };
            Action<string> command = cmd => {
                if (cmd == "cross.center:" + instanceId) el.Ui(Center);
                if (cmd == "cross.toggle:" + instanceId) el.Ui(async () => {
                    var control = new XboxGameBarWidgetControl(context.Widget);
                    bool show = !Cfg.CrossVisible(instanceId);
                    if (show) await control.RestoreAsync(context.Extension); else await control.MinimizeAsync(context.Extension);
                    Cfg.SetCrossVisible(instanceId, show);
                });
                if (cmd == "cross.close:" + context.Extension) el.Ui(async () => await new XboxGameBarWidgetControl(context.Widget).CloseAsync(context.Extension));
            };
            Cfg.Changed += changed;
            Cfg.Command += command;
            Window.Current.Closed += (s, a) => {
                setupBlurTimer.Stop(); Link.Send("SETUP_BLUR|" + extensionId + "|0");
                Cfg.Changed -= changed; Cfg.Command -= command;
            };
            el.Widget.GameBarDisplayModeChanged += (s, a) => el.Ui(UpdateSetup);
            el.Widget.PinnedChanged += (s, a) => el.Ui(UpdateSetup);
            el.Widget.WindowBoundsChanged += (s, a) => el.Ui(SendSetupBlur);
            el.Widget.VisibleChanged += (s, a) => el.Ui(UpdateSetup);
            setupBlurTimer.Tick += (s, a) => SendSetupBlur();
            setupBlurTimer.Start();
            UpdateSetup();
            Root.Loaded += async (s, a) => {
                Redraw();
                string initialSize = "crossPresets." + instanceId + ".initialSizePending";
                // A reused Game Bar slot can retain its previous owner's much larger window.
                for (int attempt = 0; attempt < 3 && Root.IsLoaded && Cfg.Get(initialSize, false); attempt++) {
                    try {
                        if (await el.Widget.TryResizeWindowAsync(new Windows.Foundation.Size(220, 180))) {
                            Cfg.Set(initialSize, false); break;
                        }
                    } catch (Exception ex) { Log.Write("cross initial size: " + ex.Message); }
                    await System.Threading.Tasks.Task.Delay(150);
                }
                Log.Write("cross instance " + instanceId + " window=" + context.Extension + " bounds=" + el.Widget.WindowBounds);
            };
            Redraw();
        }

        void UpdateSetup()
        {
            bool editing = el.Widget.GameBarDisplayMode == XboxGameBarDisplayMode.Foreground;

            Holder.Margin = new Thickness(0);
            Setup.Margin = new Thickness(16, 0, 16, 12);
            Root.UpdateLayout();
            el.Refresh();
            Setup.Visibility = editing ? Visibility.Visible : Visibility.Collapsed;
            Setup.IsHitTestVisible = editing;
            SetupBackground.Visibility = Setup.Visibility;
            SetupBackground.Background = new SolidColorBrush(el.Widget.Pinned ? Windows.UI.Color.FromArgb(64, 0, 0, 0) : Cfg.Parse(WidgetTheme.Current.Background).Value);
            SendSetupBlur();
            System.Diagnostics.Debug.Assert(editing || (Setup.Visibility == Visibility.Collapsed && SetupBackground.Visibility == Visibility.Collapsed), "Setup controls must never appear during gameplay.");
        }

        void SendSetupBlur()
        {
            bool show = Root.IsLoaded && el.Widget.Pinned && el.Widget.Visible && el.Widget.GameBarDisplayMode == XboxGameBarDisplayMode.Foreground && Cfg.CrossVisible(instanceId);
            string state = "show=" + show + " mode=" + el.Widget.GameBarDisplayMode + " visible=" + el.Widget.Visible + " loaded=" + Root.IsLoaded + " enabled=" + Cfg.CrossVisible(instanceId);
            if (state != setupBlurState) { setupBlurState = state; Log.Write("cross setup blur " + extensionId + " " + state); }
            if (!show) {
                if (setupBlurReported) Link.Send("SETUP_BLUR|" + extensionId + "|0");
                setupBlurReported = false; return;
            }
            setupBlurReported = true;
            double scale = Windows.Graphics.Display.DisplayInformation.GetForCurrentView().RawPixelsPerViewPixel;
            var bounds = el.Widget.WindowBounds;
            if (Root.ActualWidth > bounds.Width + 1 || Root.ActualHeight > bounds.Height + 1) return;
            Link.Send(string.Format(System.Globalization.CultureInfo.InvariantCulture, "SETUP_BLUR|{0}|1|{1:0}|{2:0}|{3:0}|{4:0}", extensionId,
                bounds.X * scale, (bounds.Bottom - Root.ActualHeight) * scale, Root.ActualWidth * scale, Root.ActualHeight * scale));
        }

        void Center_Click(object sender, RoutedEventArgs e) => Center();
        void Previous_Click(object sender, RoutedEventArgs e) => Cycle(-1);
        void Next_Click(object sender, RoutedEventArgs e) => Cycle(1);

        int SelectedIndex()
        {
            var mode = Get("cross.mode", "shape");
            return Math.Max(0, Array.IndexOf(Styles, mode == "shape" ? Get("cross.style", "crossdot") : mode));
        }

        void Cycle(int direction)
        {
            if (Get("cross.mode", "shape") != "shape") return;
            int next = (SelectedIndex() + direction + Styles.Length) % Styles.Length;
            System.Diagnostics.Debug.Assert(next >= 0 && next < Styles.Length);
            Set("cross.style", Styles[next]);

            Cfg.Run("cross.refreshEditor");
            Log.Write("cross selection: " + Names[next]);
        }

        async void Center()
        {
            try {
                await el.Widget.CenterWindowAsync();
                Set("cross.windowWidth", el.Widget.WindowBounds.Width);
                Root.UpdateLayout();
                var center = Holder.TransformToVisual(Root).TransformPoint(new Windows.Foundation.Point(Holder.ActualWidth / 2, Holder.ActualHeight / 2));
                double expectedX = (Root.ActualWidth + Holder.Margin.Left) / 2;
                System.Diagnostics.Debug.Assert(Math.Abs(center.X - expectedX) < 1 && Math.Abs(center.Y - Root.ActualHeight / 2) < 1, "Preview and gameplay must use their respective centers.");
                Log.Write($"cross gameplay centered: {el.Widget.WindowBounds}; preview={center.X},{center.Y}; content={Root.ActualWidth},{Root.ActualHeight}");
            }
            catch (Exception ex) { Log.Write($"cross center failed: {ex.Message}"); }
        }

        void Redraw()
        {
            imageRequest++;

            Draw.Children.Clear();
            var mode = Get("cross.mode", "shape");
            double bodyOpacity = CrossMath.Clamp(Get("cross.opacity", 1.0), 0, 1);
            Draw.Opacity = mode == "pixel" ? bodyOpacity : 1;
            Picture.Opacity = bodyOpacity;
            ShapeNavigation.Visibility = mode == "shape" ? Visibility.Visible : Visibility.Collapsed;
            Picture.Visibility = mode == "image" ? Visibility.Visible : Visibility.Collapsed;
            Draw.Visibility = mode == "image" ? Visibility.Collapsed : Visibility.Visible;
            if (mode == "image") { LoadPicture(imageRequest); return; }
            else if (mode == "pixel") DrawPixels();
            else DrawShape();
        }

        async void LoadPicture(int request)
        {
            try
            {
                var file = await ApplicationData.Current.LocalFolder.GetFileAsync(Get("cross.imageFile", "crosshair.png"));
                var bmp = new BitmapImage();
                using (var s = await file.OpenReadAsync()) await bmp.SetSourceAsync(s);
                if (request != imageRequest) return;
                double k = Get("cross.imageScale", 1.0);
                Picture.Source = bmp;
                Picture.Width = bmp.PixelWidth * k; Picture.Height = bmp.PixelHeight * k;


            }
            catch (Exception ex) { if (request != imageRequest) return; Log.Write("cross image failed: " + ex.Message); Picture.Source = new BitmapImage(new Uri("ms-appx:///Assets/crosshair.png")); Picture.Width = Picture.Height = 48;   }
        }

        void DrawPixels()
        {
            var bits = Get("cross.pixels", DefaultPixels());
            double px = Get("cross.pixelSize", 2.0);
            var brush = new SolidColorBrush(Color("cross.color", "#7BD88F"));
            Draw.Width = Draw.Height = Grid * px;
            for (int i = 0; i < bits.Length && i < Grid * Grid; i++)
                if (bits[i] == '1') Add(i % Grid * px, i / Grid * px, px, px, brush);
        }

        public static string DefaultPixels()
        {
            var c = new char[Grid * Grid];
            for (int i = 0; i < c.Length; i++)
            {
                int x = i % Grid, y = i / Grid, m = Grid / 2;
                c[i] = (x == m && Math.Abs(y - m) >= 3 && Math.Abs(y - m) <= 7) || (y == m && Math.Abs(x - m) >= 3 && Math.Abs(x - m) <= 7) || (x == m && y == m) ? '1' : '0';
            }
            return new string(c);
        }

        void DrawShape()
        {
            string style = Get("cross.style", "crossdot");
            double len = CrossMath.Clamp(Get("cross.length", 12.0), 1, 40), gap = CrossMath.Clamp(Get("cross.gap", 5.0), 0, 30), t = CrossMath.Clamp(Get("cross.thickness", 2.0), 1, 10);
            double o = CrossMath.Clamp(Get("cross.outlineThickness", 1.0), 0, 6);
            bool outline = o > 0;
            double size = Math.Ceiling(2 * (gap + len) + t + 2 * o + 2);
            Draw.Width = Draw.Height = size;
            double c = size / 2;
            var fill = new SolidColorBrush(Color("cross.color", "#7BD88F")) { Opacity = CrossMath.Clamp(Get("cross.opacity", 1.0), 0, 1) };
            var edge = new SolidColorBrush(Color("cross.outlineColor", "#000000")) { Opacity = CrossMath.Clamp(Get("cross.outlineOpacity", 1.0), 0, 1) };

            if (style == "circle")
            {
                double r = gap + len / 2;
                if (outline) {
                    Ring(c, r + t / 2 + o / 2, o, edge);
                    double inner = Math.Max(0, r - t / 2), innerStroke = Math.Min(o, inner);
                    if (innerStroke > 0) Ring(c, inner - innerStroke / 2, innerStroke, edge);
                }
                Ring(c, r, t, fill);
                return;
            }
            if (style == "dot") {
                double radius = t / 2;
                if (outline) {
                    var annulus = new GeometryGroup { FillRule = FillRule.EvenOdd };
                    annulus.Children.Add(new EllipseGeometry { Center = new Windows.Foundation.Point(c, c), RadiusX = radius + o, RadiusY = radius + o });
                    annulus.Children.Add(new EllipseGeometry { Center = new Windows.Foundation.Point(c, c), RadiusX = radius, RadiusY = radius });
                    Draw.Children.Add(new Path { Data = annulus, Fill = edge });
                }
                Draw.Children.Add(new Path { Data = new EllipseGeometry { Center = new Windows.Foundation.Point(c, c), RadiusX = radius, RadiusY = radius }, Fill = fill });
                return;
            }
            // Arms as rectangles: x, y, w, h relative to center.
            var arms = new System.Collections.Generic.List<double[]>();
            if (style != "dot")
            {
                if (style != "t") arms.Add(new[] { -t / 2, -gap - len, t, len });  // top
                arms.Add(new[] { -t / 2, gap, t, len });                             // bottom
                arms.Add(new[] { -gap - len, -t / 2, len, t });                     // left
                arms.Add(new[] { gap, -t / 2, len, t });                            // right
            }
            if (style == "dot" || style == "crossdot") arms.Add(new[] { -t / 2, -t / 2, t, t });
            if (outline) foreach (var a in CrossMath.OutlineCells(arms, o)) Add(c + a[0], c + a[1], a[2], a[3], edge);
            foreach (var a in arms) Add(c + a[0], c + a[1], a[2], a[3], fill);
        }

        void Add(double x, double y, double w, double h, Brush b)
        {
            var r = new Rectangle { Width = w, Height = h, Fill = b };
            Canvas.SetLeft(r, x); Canvas.SetTop(r, y);
            Draw.Children.Add(r);
        }

        void Ring(double c, double r, double stroke, Brush b)
        {
            var e = new Ellipse { Width = 2 * r, Height = 2 * r, Stroke = b, StrokeThickness = stroke };
            Canvas.SetLeft(e, c - r); Canvas.SetTop(e, c - r);
            Draw.Children.Add(e);
        }
    }
}
