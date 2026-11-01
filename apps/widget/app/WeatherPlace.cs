using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Reflection;

namespace WidgetSampleCS
{
    sealed class WeatherPlace
    {
        public string Name, Country, CountryCode;
        public string[] Regions = new string[0], Postcodes = new string[0];
        public double Latitude, Longitude;
        public string Label => string.Join(", ", new[] { Name }.Concat(Regions).Concat(new[] { Country }).Where(s => !string.IsNullOrWhiteSpace(s)).Distinct());
        public string Details => Label + (Postcodes.Length == 0 ? "" : "\nPostal codes: " + string.Join(", ", Postcodes.Distinct()));
        public string FlagCode => CountryCode != null && CountryCode.Length == 2 && CountryCode.All(c => (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')) ? CountryCode.ToLowerInvariant() : null;
        public string CountryKey => FlagCode ?? Country ?? "";
        static readonly Dictionary<string, double[]> CountryCentres = LoadCountryCentres();
        static Dictionary<string, double[]> LoadCountryCentres()
        {
            var centres = new Dictionary<string, double[]>(StringComparer.OrdinalIgnoreCase);
            using (var stream = typeof(WeatherPlace).GetTypeInfo().Assembly.GetManifestResourceStream("Doorlight.CountryCentres.csv")) {
                if (stream == null) return centres;
                using (var reader = new StreamReader(stream)) {
                    string line;
                    while ((line = reader.ReadLine()) != null) {
                        var fields = line.Split(',');
                        if (fields.Length == 3 && double.TryParse(fields[1], NumberStyles.Float, CultureInfo.InvariantCulture, out var lat)
                            && double.TryParse(fields[2], NumberStyles.Float, CultureInfo.InvariantCulture, out var lon)
                            && lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180) centres[fields[0]] = new[] { lat, lon };
                    }
                }
            }
            return centres;
        }
        public static double DistanceKm(double lat1, double lon1, double lat2, double lon2)
        {
            if (!(lat2 >= -90 && lat2 <= 90 && lon2 >= -180 && lon2 <= 180)) return double.PositiveInfinity;
            double radians = Math.PI / 180, lat = (lat2 - lat1) * radians, lon = (lon2 - lon1) * radians;
            double a = Math.Pow(Math.Sin(lat / 2), 2) + Math.Cos(lat1 * radians) * Math.Cos(lat2 * radians) * Math.Pow(Math.Sin(lon / 2), 2);
            return 12742 * Math.Asin(Math.Sqrt(Math.Max(0, Math.Min(1, a))));
        }
        public static IEnumerable<WeatherPlace> ByRegionDistance(IEnumerable<WeatherPlace> places, string country)
        {
            if (string.IsNullOrWhiteSpace(country) || !CountryCentres.TryGetValue(country.Trim(), out var centre)) return places;
            return places.OrderBy(p => DistanceKm(centre[0], centre[1], p.Latitude, p.Longitude));
        }
        public string PillText(bool sameCountry)
        {
            if (!sameCountry) return Name;
            var codes = Postcodes.Where(s => !string.IsNullOrWhiteSpace(s)).Distinct().ToArray();
            string detail = codes.Length > 0 ? string.Join(", ", codes.Take(2)) + (codes.Length > 2 ? " +" + (codes.Length - 2) : "")
                : Regions.LastOrDefault(s => !string.IsNullOrWhiteSpace(s) && s != Name);
            return Name + (string.IsNullOrWhiteSpace(detail) ? "" : " · " + detail);
        }
        public static string SearchUrl(string query)
        {
            if (string.IsNullOrWhiteSpace(query) || query.Length > 128 || query.Any(char.IsControl)) throw new ArgumentException("Enter a city or postal code up to 128 characters");
            return "https://geocoding-api.open-meteo.com/v1/search?count=100&name=" + Uri.EscapeDataString(query.Trim());
        }
    }
}
