using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Text;
using Windows.Data.Json;

namespace WidgetSampleCS
{
    sealed class WeatherForecast { internal int Code, IsDay; internal double Temperature; }

    static class WeatherData
    {
        static string Text(JsonObject row, string key, bool required = false, int maximum = 128)
        {
            string text = required ? row.GetNamedString(key) : row.GetNamedString(key, "");
            if (text.Length > maximum || Encoding.UTF8.GetByteCount(text) > maximum * 4 || text.Any(char.IsControl) || (required && string.IsNullOrWhiteSpace(text)))
                throw new InvalidDataException("Invalid weather field");
            return text;
        }
        static double Number(JsonObject row, string key, double minimum, double maximum)
        {
            double value = row.GetNamedNumber(key);
            if (double.IsNaN(value) || double.IsInfinity(value) || value < minimum || value > maximum)
                throw new InvalidDataException("Invalid weather number");
            return value;
        }
        internal static WeatherForecast Forecast(string json)
        {
            var current = JsonObject.Parse(WeatherResponse.Validate(json)).GetNamedObject("current");
            double code = Number(current, "weather_code", 0, 99), day = Number(current, "is_day", 0, 1);
            if (code != Math.Floor(code) || day != Math.Floor(day)) throw new InvalidDataException("Invalid weather code");
            return new WeatherForecast { Code = (int)code, IsDay = (int)day, Temperature = Number(current, "temperature_2m", -1000, 1000) };
        }
        internal static List<WeatherPlace> Places(string json)
        {
            var root = JsonObject.Parse(WeatherResponse.Validate(json));
            var places = new List<WeatherPlace>();
            if (!root.ContainsKey("results")) return places;
            var results = root.GetNamedArray("results");
            if (results.Count > WeatherResponse.MaxResults) throw new InvalidDataException("Too many weather locations");
            foreach (var value in results) {
                var row = value.GetObject();
                var place = new WeatherPlace { Name = Text(row, "name", true), Country = Text(row, "country"), CountryCode = Text(row, "country_code", maximum: 2),
                    Latitude = Number(row, "latitude", -90, 90), Longitude = Number(row, "longitude", -180, 180),
                    Regions = new[] { "admin1", "admin2", "admin3", "admin4" }.Select(key => Text(row, key)).ToArray() };
                if (row.ContainsKey("postcodes")) {
                    var codes = row.GetNamedArray("postcodes");
                    if (codes.Count > WeatherResponse.MaxPostcodes) throw new InvalidDataException("Too many postal codes");
                    place.Postcodes = codes.Select(code => code.GetString()).ToArray();
                    if (place.Postcodes.Any(code => code.Length > 32 || code.Any(char.IsControl))) throw new InvalidDataException("Invalid postal code");
                }
                places.Add(place);
            }
            return places;
        }
    }
}
