using System;
using System.Linq;
using System.Collections.Generic;
using Microsoft.Gaming.XboxGameBar;
using Windows.UI.Xaml;
using Windows.UI.Xaml.Controls;
using Windows.UI.Xaml.Media;
using Windows.UI.Xaml.Navigation;
using Windows.UI.Xaml.Shapes;
using Windows.Media.Playback;
using Windows.Media.Core;

namespace WidgetSampleCS
{
    public sealed partial class TimerWidget : Page
    {
        readonly DispatcherTimer tick = new DispatcherTimer { Interval = TimeSpan.FromMilliseconds(33) };
        readonly System.Diagnostics.Stopwatch celebration = new System.Diagnostics.Stopwatch();
        readonly Random random = new Random();
        Element el;
        MediaPlayer sound;
        string lastText;
        readonly Dictionary<string, TextBlock> labels = new Dictionary<string, TextBlock>();
        readonly Dictionary<string, ProgressBar> bars = new Dictionary<string, ProgressBar>();
        string finishingId;
        public TimerWidget() { WidgetTheme.Attach(this); InitializeComponent(); }
        protected override void OnNavigatedTo(NavigationEventArgs e)
        {
            el = new Element("timer", (XboxGameBarWidget)e.Parameter, Root, Viewport);
            Cfg.Changed += Changed;
            tick.Tick += (s, a) => Show(); tick.Start();
            Window.Current.Closed += (s, a) => { tick.Stop(); Cfg.Changed -= Changed; sound?.Dispose(); };
            Apply();
        }
        void Changed(string key) { if (key.StartsWith("timer.") && !key.StartsWith("timer.records.chunk.")) el.Ui(Apply); }
        void Apply()
        {
            var rows = TimerState.Records;
            var visible = rows.Where(r => r.Visible).ToArray();
            var ids = string.Join(",", visible.Select(r => r.Id));
            if (ids != string.Join(",", labels.Keys)) {
                labels.Clear(); bars.Clear(); Timers.Children.Clear();
                foreach (var r in visible) {
                    var panel = new StackPanel { Spacing = 2 };
                    var text = new TextBlock { TextLineBounds = TextLineBounds.Tight, FontFamily = new FontFamily("Segoe UI"), FontWeight = Windows.UI.Text.FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap, MaxWidth = 560, HorizontalAlignment = HorizontalAlignment.Center };
                    var bar = new ProgressBar { Minimum = 0, Maximum = 1, Height = 3 };
                    panel.Children.Add(text); panel.Children.Add(bar); Timers.Children.Add(panel); labels[r.Id] = text; bars[r.Id] = bar;
                }
            }
            foreach (var r in visible) {
                var text = labels[r.Id]; text.FontSize = Cfg.ForTimer(r.Id, "size", 32.0);
                text.Foreground = new SolidColorBrush(Cfg.Parse(Cfg.ForTimer(r.Id, "color", "#FFFFFF")) ?? Windows.UI.Colors.White);
                bars[r.Id].Foreground = text.Foreground;
                bars[r.Id].Visibility = r.Mode == "Countdown" && Cfg.ForTimer(r.Id, "progress", false) ? Visibility.Visible : Visibility.Collapsed;
            }
            if (finishingId != null && !rows.Any(r => r.Id == finishingId && r.Finished)) { celebration.Reset(); Confetti.Children.Clear(); sound?.Pause(); finishingId = null; }
            Show(); el.Fit();
        }        void Finish(string id)
        {
            Log.Write("timer finished " + id); finishingId = id; celebration.Restart();
            if (WidgetTheme.AnimationsEnabled && Cfg.ForTimer(id, "confetti", true)) {
                string[] colors = { "#7BD88F", "#5CC8FF", "#FF5C8A", "#F2B775", "#FFFFFF" };
                for (int i = 0; i < 28; i++) {
                    var piece = new Rectangle { Width = 3 + random.Next(4), Height = 3 + random.Next(6), Fill = new SolidColorBrush(Cfg.Parse(colors[i % colors.Length]).Value), Tag = new double[] { random.NextDouble(), random.NextDouble() } };
                    Confetti.Children.Add(piece);
                }
            }
            var selected = Cfg.ForTimer(id, "sound", "Silent");
            if (selected == "Chime" || selected == "Bell" || selected == "Custom") {
                try {
                    if (sound == null) { sound = new MediaPlayer(); sound.MediaFailed += (s, e) => Log.Write("timer sound failed: " + e.ErrorMessage); }
                    sound.Source = MediaSource.CreateFromUri(selected == "Custom"
                        ? new Uri("ms-appdata:///local/" + Uri.EscapeDataString(Cfg.ForTimer(id, "soundFile", "")))
                        : new Uri("ms-appx:///Assets/timer-" + selected.ToLowerInvariant() + ".wav"));
                    sound.Volume = Math.Max(0, Math.Min(1, Cfg.ForTimer(id, "volume", .5))); sound.Play();
                } catch (Exception ex) { Log.Write("timer sound failed: " + ex.Message); }
            }
        }
        void Show()
        {
            var records = TimerState.Records;
            foreach (var r in records) {
                if (TimerState.Complete(r.Id)) Finish(r.Id);
                if (!labels.TryGetValue(r.Id, out var text)) continue;
                text.Text = TimerState.FormatRecord(r.Id);
                var elapsedMs = celebration.Elapsed.TotalMilliseconds;
                var flash = r.Id == finishingId && Cfg.ForTimer(r.Id, "flash", false) && celebration.IsRunning && elapsedMs < 4000 && elapsedMs % 600 < 300;
                text.Opacity = Cfg.ForTimer(r.Id, "opacity", 1.0) * (flash ? .25 : 1);
                bars[r.Id].Opacity = Cfg.ForTimer(r.Id, "opacity", 1.0);
                bars[r.Id].Value = Math.Min(1, TimerState.Value(r.Id) * 1000 / Math.Max(1, r.Kind == "Until" ? r.StoredMilliseconds : r.DurationMilliseconds));
            }            var elapsed = celebration.Elapsed.TotalSeconds;
            Confetti.Opacity = Cfg.Get("timer.visible", true) ? Cfg.ForTimer(finishingId, "opacity", 1.0) : 0;
            if (elapsed >= 2.5 || !WidgetTheme.AnimationsEnabled || !Cfg.ForTimer(finishingId, "confetti", true)) Confetti.Children.Clear();
            foreach (Rectangle p in Confetti.Children) {
                var v = (double[])p.Tag;
                Canvas.SetLeft(p, ActualWidth / 2 + (v[0] - .5) * Math.Min(ActualWidth, 220) * elapsed);
                Canvas.SetTop(p, ActualHeight / 2 - (25 + v[1] * 35) * elapsed + 35 * elapsed * elapsed);
                p.Opacity = Math.Max(0, 1 - elapsed / 2.5);
            }
            var sizing = string.Join(",", labels.Values.Select(t => t.Text.Length.ToString())); if (sizing != lastText) { lastText = sizing; el.Fit(); }
        }
    }
}
