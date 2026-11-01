using System;
using System.Linq;
using System.Collections.Generic;
using Microsoft.Gaming.XboxGameBar;
using Windows.UI;
using Windows.UI.Text;
using Windows.UI.Xaml;
using Windows.UI.Xaml.Controls;
using Windows.UI.Xaml.Media;
using Windows.UI.Xaml.Navigation;

namespace WidgetSampleCS
{
    public sealed partial class ClockWidget : Page
    {
        readonly DispatcherTimer timer = new DispatcherTimer();
        readonly Dictionary<string, TextBlock[]> rows = new Dictionary<string, TextBlock[]>();
        Element el;
        Action<string> changed;
        public ClockWidget() { WidgetTheme.Attach(this); InitializeComponent(); }
        protected override void OnNavigatedTo(NavigationEventArgs e)
        {
            el = new Element("clock", (XboxGameBarWidget)e.Parameter, Root, Viewport);
            changed = key => { if (key.StartsWith("clock.")) el.Ui(Apply); };
            Cfg.Changed += changed;
            timer.Tick += (s,a) => Tick();
            Window.Current.Closed += (s,a) => { timer.Stop(); Cfg.Changed -= changed; };
            Apply();
        }
        void Apply()
        {
            rows.Clear(); ClockRows.Children.Clear();
            bool precise = false;
            foreach (string id in Clocks.Ids)
            {
                string key = Clocks.Key(id);

                precise |= Cfg.Get(key + "format", "HH:mm").Contains("fff");
                var grid = new Grid();
                double outline = CrossMath.Clamp(Cfg.Get(key + "outlineThickness", 0.0), 0, 4);
                var texts = Enumerable.Range(0, outline > 0 ? 10 : 2).Select(_ => new TextBlock()).ToArray();
                foreach (var t in texts) { t.FontFamily = new FontFamily(Cfg.Get(key + "font", "Segoe UI Variable Display")); t.FontSize = Cfg.Get(key + "size", 20.0); t.FontWeight = FontWeights.SemiBold; t.TextAlignment = TextAlignment.Center; t.TextLineBounds = TextLineBounds.Full; t.Padding = new Thickness(1); grid.Children.Add(t); }
                texts[0].Foreground = new SolidColorBrush(Color.FromArgb(192,0,0,0)); texts[0].Margin = new Thickness(1,1,0,0);
                texts[0].Visibility = Cfg.Get(key + "bg", "none") == "shadow" ? Visibility.Visible : Visibility.Collapsed;
                for (int i = 1; i < texts.Length - 1; i++) {
                    double angle = (i - 1) * Math.PI / 4;
                    texts[i].Foreground = new SolidColorBrush(Cfg.Color(key + "outlineColor", "#000000"));
                    texts[i].RenderTransform = new TranslateTransform { X = Math.Cos(angle) * outline, Y = Math.Sin(angle) * outline };
                }
                texts[texts.Length - 1].Foreground = new SolidColorBrush(Cfg.Color(key + "color", "#EFE6DC"));
                var border = new Border { Child = grid, Padding = new Thickness(outline), CornerRadius = new CornerRadius(8) };
                if (Cfg.Get(key + "bg", "none") == "pill") border.Background = new SolidColorBrush(Color.FromArgb(190,37,40,44));
                ClockRows.Children.Add(border); rows[id] = texts;
            }
            timer.Interval = TimeSpan.FromMilliseconds(precise ? 16 : 200);
            timer.Start(); Tick(); el.Fit();
        }
        void Tick()
        {
            var now = DateTimeOffset.UtcNow;
            bool resize = false;
            foreach (var row in rows)
            {
                string text = Clocks.Text(row.Key, now);
                resize |= row.Value[row.Value.Length - 1].Text.Length != text.Length;
                foreach (var t in row.Value) if (t.Text != text) t.Text = text;
            }
            if (resize) el.Fit();
        }
    }
}
