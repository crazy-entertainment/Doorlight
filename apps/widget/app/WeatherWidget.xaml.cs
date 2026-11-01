using System;
using System.Globalization;
using System.Net.Http;
using System.Threading;
using Microsoft.Gaming.XboxGameBar;
using Windows.Data.Json;
using Windows.UI.Xaml;
using Windows.UI.Xaml.Controls;
using Windows.UI.Xaml.Media;
using Windows.UI.Xaml.Navigation;

namespace WidgetSampleCS
{
    sealed class WeatherWindowContext { public XboxGameBarWidget Widget; public string Id, Extension; }
    // Current weather from Open-Meteo (no key). Only the chosen place's coordinates are sent.
    public sealed partial class WeatherWidget : Page
    {
        readonly DispatcherTimer refresh = new DispatcherTimer { Interval = TimeSpan.FromMinutes(15) };
        Element el;
        int code = -1, isDay = 1;
        double temp = double.NaN;
        string instanceId, prefix;
        int request;
        bool closed;
        CancellationTokenSource forecastRequest;
        static readonly HttpClient client = new HttpClient(new HttpClientHandler { AllowAutoRedirect = false });
        T Get<T>(string key, T fallback) => Cfg.Get(prefix + key, fallback);

        public WeatherWidget() { WidgetTheme.Attach(this); InitializeComponent(); }

        protected override void OnNavigatedTo(NavigationEventArgs e)
        {
            var context = (WeatherWindowContext)e.Parameter;
            instanceId = context.Id;
            if (instanceId == null) { _ = new XboxGameBarWidgetControl(context.Widget).CloseAsync(context.Extension); return; }
            prefix = Cfg.WeatherKey(instanceId);
            if (!Get("hasPlace", false)) { _ = new XboxGameBarWidgetControl(context.Widget).CloseAsync(context.Extension); return; }
            el = new Element("weather", context.Widget, Root, Viewport, settingsId: prefix.TrimEnd('.'));
            Action<string> changed = key =>
            {
                if (key == prefix + "lat" || key == prefix + "unit") el.Ui(Fetch);
                else if (key.StartsWith(prefix)) el.Ui(Show);
            };
            Cfg.Changed += changed;
            Window.Current.Closed += (s, a) => { closed = true; request++; forecastRequest?.Cancel(); refresh.Stop(); Cfg.Changed -= changed; };
            refresh.Tick += (s, a) => Fetch();
            refresh.Start();
            Show();
            Fetch();
        }

        async void Fetch()
        {
            forecastRequest?.Cancel();
            if (closed) return;
            int pending = ++request;
            code = -1; temp = double.NaN;
            Show();
            if (!Get("hasPlace", false)) return;
            var inv = CultureInfo.InvariantCulture;
            var url = "https://api.open-meteo.com/v1/forecast?latitude=" + Get("lat", 0.0).ToString(inv) +
                      "&longitude=" + Get("lon", 0.0).ToString(inv) +
                      "&current=temperature_2m,weather_code,is_day&temperature_unit=" + (Get("unit", "C") == "F" ? "fahrenheit" : "celsius");
            using (var cancellation = new CancellationTokenSource())
            {
                forecastRequest = cancellation;
                try {
                    var cur = WeatherData.Forecast(await WeatherResponse.FetchAsync(client, new Uri(url), cancellation.Token));
                    if (closed || pending != request) return;
                    code = cur.Code; isDay = cur.IsDay; temp = cur.Temperature;
                }
                catch (OperationCanceledException) { if (!closed && pending == request) code = -2; }
                catch (Exception ex) { if (!closed && pending == request) code = -2; Log.Write("weather fetch failed: " + ex.GetType().Name); }
                finally { if (forecastRequest == cancellation) forecastRequest = null; }
            }
            if (!closed && pending == request) Show();
        }

        // Searching never mutates a widget; the user selects a returned location first.
        internal static async System.Threading.Tasks.Task<System.Collections.Generic.List<WeatherPlace>> FindPlaces(string query, CancellationToken cancellation)
        {
            return WeatherData.Places(await WeatherResponse.FetchAsync(client, new Uri(WeatherPlace.SearchUrl(query)), cancellation));
        }

        void Show()
        {
            double size = Get("size", 20.0);
            var brush = new SolidColorBrush(Cfg.Color(prefix + "color", "#EFE6DC"));
            bool color = Get("iconSet", "mono") == "color";
            Icon.FontFamily = new FontFamily(color ? "Segoe UI Emoji" : "Segoe UI Symbol");
            Icon.Text = Glyph(color);
            Icon.FontSize = size;
            Icon.Foreground = Temp.Foreground = brush;
            Temp.FontSize = size * 0.8;
            Temp.Visibility = Get("temp", false) && !double.IsNaN(temp) ? Visibility.Visible : Visibility.Collapsed;
            Temp.Text = Math.Round(temp) + "°";
            el.Fit();
        }

        string Glyph(bool color)
        {
            if (code < 0) return code == -1 ? "…" : "Unavailable";
            if (code == 0) return isDay == 1 ? (color ? "☀️" : "☀") : (color ? "🌙" : "☾");
            if (code <= 2) return color ? "⛅" : "⛅";
            if (code == 3) return color ? "☁️" : "☁";
            if (code == 45 || code == 48) return color ? "🌫️" : "≋";
            if (code >= 95) return color ? "⛈️" : "⚡";
            if ((code >= 71 && code <= 77) || code == 85 || code == 86) return color ? "❄️" : "❄";
            return color ? "🌧️" : "☂";
        }
    }
}
