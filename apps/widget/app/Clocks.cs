using System;
using System.Linq;
namespace WidgetSampleCS
{
    static class Clocks
    {
        public static string SimpleTimeFormat(bool ampm, bool seconds) => ampm ? (seconds ? "h:mm:ss tt" : "h:mm tt") : (seconds ? "HH:mm:ss" : "HH:mm");
        public static bool TryHourFormat(string pattern, bool ampm, out string converted)
        {
            if (new[] { "HH:mm", "HH:mm:ss", "HH:mm:ss.fff", "h:mm tt", "h:mm:ss tt", "h:mm:ss.fff tt" }.Contains(pattern)) {
                converted = SimpleTimeFormat(ampm, pattern.Contains("ss"));
                if (pattern.Contains("fff")) converted = ampm ? "h:mm:ss.fff tt" : "HH:mm:ss.fff";
                return true;
            }
            converted = pattern; return false;
        }
        public static string[] Ids => Cfg.Get("clock.ids", "local").Split('|').Where(x => x.Length > 0).Distinct().ToArray();
        public static string Key(string id) => id == "local" ? "clock." : "clock.item." + id + ".";
        public static string Name(string id) => Cfg.Get(Key(id) + "name", "Local time");
        public static DateTimeOffset Now(string id, DateTimeOffset utc)
        {
            string key = Key(id);
            try { return TimeZoneInfo.ConvertTime(utc, TimeZoneInfo.FindSystemTimeZoneById(Cfg.Get(key + "zone", TimeZoneInfo.Local.Id))); }
            catch { return utc.ToLocalTime(); }
        }
        public static bool TryDateText(DateTimeOffset now, string format, out string text)
        {
            try {
                if (!string.IsNullOrWhiteSpace(format)) { text = now.ToString(format); return true; }
            } catch (FormatException) { }
            text = now.ToString("ddd d MMM"); return false;
        }
        public static string Text(string id, DateTimeOffset utc)
        {
            string key = Key(id);
            var now = Now(id, utc);
            string text;
            try { text = now.ToString(Cfg.Get(key + "format", "HH:mm")); }
            catch (FormatException) { text = now.ToString("HH:mm"); }
            text = Cfg.Get(key + "prefix", "") + text + Cfg.Get(key + "suffix", "");
            if (Cfg.Get(key + "date", false)) {
                TryDateText(now, Cfg.Get(key + "dateFormat", "ddd d MMM"), out string date);
                text = Cfg.Get(key + "dateOnly", false) ? date : text + (Cfg.Get(key + "layout", "stacked") == "single" ? " · " : "\n") + date;
            }
            return text;
        }
    }

}
