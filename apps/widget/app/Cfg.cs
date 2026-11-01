using System;
using System.Linq;
using Windows.Storage;

namespace WidgetSampleCS
{
    // Local utilities save in the package; connected edits use the desktop's settings transaction.
    static class Cfg
    {
        static class store { internal static OverlaySettings.Cache Values => OverlaySettings.Values; }

        static Cfg()
        {
            if (!store.Values.ContainsKey("hotkey.chat.quick"))
                store.Values["hotkey.chat.quick"] = "Ctrl+Alt+C";
            bool existingCross = store.Values.ContainsKey("crossPresets.ids") || store.Values.Keys.Any(k => k.StartsWith("cross."));
            if (!store.Values.ContainsKey("general.fadeStart")) {
                store.Values["general.fadeStart"] = Get("general.fade", false) ? 40.0 : 0.0;
                store.Values["general.fadeEnd"] = 0.0;
            }
            if (store.Values.TryGetValue("cross.aimFadeMs", out var duration) && duration is double milliseconds)
                store.Values["cross.aimFadeMs"] = CrossMath.Clamp(milliseconds, 0, 750);
            if (!store.Values.ContainsKey("cross.aimFadeInMs"))
                store.Values["cross.aimFadeInMs"] = Get("cross.aimFadeMs", 0.0);
            // Preserve an outline previously switched off; thickness now owns visibility.
            if (store.Values.TryGetValue("cross.outline", out var enabled)) {
                if (enabled is bool value && !value) store.Values["cross.outlineThickness"] = 0.0;
                store.Values.Remove("cross.outline");
            }
            if (!existingCross) SetCrossDefaults("");
        }

        static void SetCrossDefaults(string prefix)
        {
            store.Values[prefix + "cross.mode"] = "shape";
            store.Values[prefix + "cross.style"] = "t";
            store.Values[prefix + "cross.color"] = "#FFFFFF";
            store.Values[prefix + "cross.outlineColor"] = "#000000";
            store.Values[prefix + "cross.outlineThickness"] = 1.0;
        }
        public static bool AdvancedCrossEditor => Get("helper.crossEditorMode", "simple") == "advanced";
        public static void SetCrossEditorMode(bool advanced)
        {
            Set("helper.crossEditorMode", advanced ? "advanced" : "simple");
            Run("cross.refreshEditor");
        }
        public static double CrossSimpleScale => CrossMath.Clamp(Get("cross.length", 12.0) / 12, .5, 1.6);
        public static void SetCrossSimpleScale(double scale)
        {
            if (CrossActive == null || Get("cross.mode", "shape") != "shape") return;
            scale = CrossMath.Clamp(scale, .5, 1.6);
            store.Values["cross.length"] = 12 * scale;
            store.Values["cross.thickness"] = Math.Max(1, 2 * scale);
            Changed?.Invoke("cross.simpleSize");
        }

        public static T Appearance<T>(string id, string option, T fallback)
        {
            if (option == "opacity") {
                if (id == "general" || id == "cross") return fallback;
                return Get(id + ".appearance.opacity", id == "timer" ? fallback : Get(id + ".opacity", fallback));
            }
            return Get("general." + option, fallback);
        }

        internal static void Refresh(params string[] keys) { foreach(var key in keys)Changed?.Invoke(key);Changed?.Invoke("helper.appearance"); }
        public static event Action<string> Changed;   // key that changed
        public static event Action<string> Command;   // one-shot actions, e.g. "cross.center"

        static readonly string[] TimerOptions = { "size", "opacity", "color", "progress", "confetti", "flash", "sound", "soundFile", "soundName", "volume" };
        static bool TimerOption(string key) => key.StartsWith("timer.") && TimerOptions.Contains(key.Substring(6));
        public static T ForTimer<T>(string id, string option, T fallback)
        {
            if (id != null && store.Values.ContainsKey("timer.option." + id + "." + option)) return OverlaySettings.Read("timer.option." + id + "." + option, fallback);
            return OverlaySettings.Read("timer." + option, fallback);
        }
        public static T Get<T>(string key, T fallback) => TimerOption(key) ? ForTimer(TimerState.ActiveId, key.Substring(6), fallback) : OverlaySettings.Read(key, fallback);

        public static bool HotkeyInUse(string combination) => store.Values.Any(entry =>
            entry.Key.StartsWith("hotkey.") && entry.Value is string value && string.Equals(value, combination, StringComparison.OrdinalIgnoreCase));

        public static void Set(string key, object value)
        {
            var storedKey = TimerOption(key) && TimerState.ActiveId != null ? "timer.option." + TimerState.ActiveId + "." + key.Substring(6) : key;
            store.Values[storedKey] = value;
            Changed?.Invoke(key);
        }

        public static void ApplyAppearance(AppearanceValues appearance, bool force = false)
        {
            if (!force && Get("helper.theme", "cozy") == appearance.Theme && Get("helper.vibe", "none") == appearance.Vibe &&
                Get("helper.vibeOpacity", 100.0) == appearance.Opacity && Get("helper.vibeIntensity", 100.0) == appearance.Intensity &&
                Get("helper.vibeAnimated", true) == appearance.Animated) return;
            store.Values["helper.theme"] = appearance.Theme;
            store.Values["helper.vibe"] = appearance.Vibe;
            store.Values["helper.vibeOpacity"] = (double)appearance.Opacity;
            store.Values["helper.vibeIntensity"] = (double)appearance.Intensity;
            store.Values["helper.vibeAnimated"] = appearance.Animated;
            Changed?.Invoke("helper.appearance");
        }

        public static void SetCrossOpacity(double value, bool outline)
        {
            value = CrossMath.Clamp(value, 0, 1);
            bool linked = !outline && Get("cross.outlineOpacityLinked", Get("cross.opacity", 1.0) == Get("cross.outlineOpacity", 1.0));
            Set("cross.outlineOpacityLinked", linked);
            Set(outline ? "cross.outlineOpacity" : "cross.opacity", value);
            if (linked) Set("cross.outlineOpacity", value);
        }

        public static void SetFade(double start, double end)
        {
            start = CrossMath.Clamp(start, 0, 240); end = CrossMath.Clamp(end, 0, start);
            store.Values["general.fadeStart"] = start; store.Values["general.fadeEnd"] = end;
            Changed?.Invoke("general.fadeStart");
        }
        static bool CrossOption(string key) => key.StartsWith("cross.") && key != "cross.visible" && key != "cross.editing" && key != "cross.windowWidth";
        public static string[] CrossIds {
            get {
                if (!store.Values.ContainsKey("crossPresets.ids")) {
                    store.Values["crossPresets.ids"] = "original";
                    store.Values["crossPresets.active"] = "original";
                    store.Values["crossPresets.original.name"] = "Crosshair 1";
                }
                return Get("crossPresets.ids", "").Split('|').Where(id => id.Length > 0).ToArray();
            }
        }
        public static string CrossActive => CrossIds.Contains(Get("crossPresets.active", "")) ? Get("crossPresets.active", "") : CrossIds.FirstOrDefault();
        public static string CrossName(string id) => Get("crossPresets." + id + ".name", "Crosshair");
        public const int CrossWindowLimit = 16;
        public static string CrossExtension(string id)
        {
            if (id == null || !CrossIds.Contains(id)) return null;
            string key = "crossPresets." + id + ".window";
            string assigned = Get(key, "");
            if (assigned.Length > 0) return assigned;
            var used = CrossIds.Select(i => Get("crossPresets." + i + ".window", "")).ToArray();
            assigned = Enumerable.Range(1, CrossWindowLimit).Select(i => i == 1 ? "Cross" : "Cross" + i).FirstOrDefault(i => !used.Contains(i));
            if (assigned == null) throw new InvalidOperationException("All 16 crosshair windows are in use.");
            store.Values[key] = assigned;
            return assigned;
        }
        public static string CrossForExtension(string extension)
        {
            foreach (var id in CrossIds) if (CrossExtension(id) == extension) return id;
            return null;
        }
        public static T ForCross<T>(string id, string key, T fallback)
        {
            if (id == null) return fallback;
            if (id == CrossActive && CrossOption(key)) return Get(key, fallback);
            return Get("crossPresets." + id + ".value." + key, fallback);
        }
        public static void SetCross(string id, string key, object value)
        {
            if (id == null || !CrossIds.Contains(id)) return;
            if (id == CrossActive && CrossOption(key)) Set(key, value);
            else { store.Values["crossPresets." + id + ".value." + key] = value; Changed?.Invoke(key); }
        }
        public static bool CrossVisible(string id) => Get("crossPresets." + id + ".visible", true);
        public static void SetCrossVisible(string id, bool value) { if (id != null) Set("crossPresets." + id + ".visible", value); }
        public static T CrossAppearance<T>(string id, string option, T fallback)
        {
            if (option == "opacity") return fallback;
            return Get("general." + option, fallback);
        }
        static void SaveCross()
        {
            var id = CrossActive; if (id == null) return;
            string prefix = "crossPresets." + id + ".value.";
            foreach (var key in store.Values.Keys.Where(k => k.StartsWith(prefix) && CrossOption(k.Substring(prefix.Length))).ToArray()) store.Values.Remove(key);
            foreach (var key in store.Values.Keys.Where(CrossOption).ToArray()) store.Values[prefix + key] = store.Values[key];
        }
        static void CrossChanged()
        {
            Changed?.Invoke("cross.hold"); Changed?.Invoke("cross.aimToggle"); Changed?.Invoke("cross.reset");
            Run("cross.refreshEditor");
        }
        public static void SelectCross(string id)
        {
            if (!CrossIds.Contains(id) || id == CrossActive) return;
            SaveCross(); LoadCross(id);
        }
        static void LoadCross(string id)
        {
            foreach (var key in store.Values.Keys.Where(CrossOption).ToArray()) store.Values.Remove(key);
            store.Values["crossPresets.active"] = id ?? "";
            string prefix = "crossPresets." + id + ".value.";
            foreach (var key in store.Values.Keys.Where(k => k.StartsWith(prefix) && CrossOption(k.Substring(prefix.Length))).ToArray()) store.Values[key.Substring(prefix.Length)] = store.Values[key];
            CrossChanged();
        }
        public static void CreateCross(bool duplicate = false)
        {
            if (CrossIds.Length >= CrossWindowLimit) throw new InvalidOperationException("You can create up to 16 crosshairs.");
            SaveCross();
            var ids = CrossIds; string source = CrossActive, id = Guid.NewGuid().ToString("N");
            string name = Enumerable.Range(1, ids.Length + 1).Select(n => "Crosshair " + n).First(n => !ids.Any(i => CrossName(i) == n));
            store.Values["crossPresets." + id + ".name"] = name;
            store.Values["crossPresets." + id + ".initialSizePending"] = true;
            if (duplicate && source != null) {
                string prefix = "crossPresets." + source + ".value.";
                foreach (var key in store.Values.Keys.Where(k => k.StartsWith(prefix)).ToArray()) store.Values["crossPresets." + id + ".value." + key.Substring(prefix.Length)] = store.Values[key];
            }
            else SetCrossDefaults("crossPresets." + id + ".value.");
            store.Values["crossPresets.ids"] = string.Join("|", ids.Concat(new[] { id }));
            CrossExtension(id);
            LoadCross(id);
        }
        public static void RenameCross(string id, string name)
        {
            if (!CrossIds.Contains(id) || string.IsNullOrWhiteSpace(name)) return;
            store.Values["crossPresets." + id + ".name"] = name.Trim(); Run("cross.refreshEditor");
        }
        public static void DeleteCross()
        {
            string id = CrossActive; if (id == null) return;
            var remaining = CrossIds.Where(i => i != id).ToArray();
            foreach (var key in store.Values.Keys.Where(k => k.StartsWith("crossPresets." + id + ".")).ToArray()) store.Values.Remove(key);
            store.Values["crossPresets.ids"] = string.Join("|", remaining);
            LoadCross(remaining.FirstOrDefault());
        }
        public static void ResetCross()
        {
            foreach (var key in store.Values.Keys.Where(CrossOption).ToArray()) store.Values.Remove(key);
            store.Values["cross.aimFadeInMs"] = 0.0;
            SetCrossDefaults("");
            Changed?.Invoke("cross.hold"); Changed?.Invoke("cross.aimToggle"); Changed?.Invoke("cross.reset");
        }
        public static void Run(string command) => Command?.Invoke(command);

        public const int WeatherWindowLimit = 16;
        public static string WeatherKey(string id) => "weatherInstances." + id + ".";
        public static string[] WeatherIds {
            get {
                if (!store.Values.ContainsKey("weatherInstances.ids")) {
                    string prefix = WeatherKey("original");
                    foreach (var key in store.Values.Keys.Where(k => k.StartsWith("weather.")).ToArray())
                        store.Values[prefix + key.Substring(8)] = store.Values[key];
                    store.Values[prefix + "name"] = "Weather 1";
                    store.Values[prefix + "window"] = "Weather";
                    store.Values["weatherInstances.ids"] = "original";
                }
                return Get("weatherInstances.ids", "").Split('|').Where(id => id.Length > 0).ToArray();
            }
        }
        public static string WeatherActive => WeatherIds.Contains(Get("weatherInstances.active", "")) ? Get("weatherInstances.active", "") : WeatherIds.FirstOrDefault();
        public static string WeatherName(string id) => Get(WeatherKey(id) + "name", "Weather");
        public static bool SetWeatherPlace(string id, WeatherPlace place)
        {
            if (!WeatherIds.Contains(id)) return false;
            string key = WeatherKey(id);
            Set(key + "lon", place.Longitude);
            Set(key + "hasPlace", true);
            Set(key + "place", place.Name);
            Set(key + "placeLabel", place.Details);
            Set(key + "lat", place.Latitude); // last: triggers only this instance's forecast
            return true;
        }
        public static string WeatherExtension(string id)
        {
            if (id == null || !WeatherIds.Contains(id)) return null;
            string key = WeatherKey(id) + "window", assigned = Get(key, "");
            if (assigned.Length > 0) return assigned;
            var used = WeatherIds.Select(i => Get(WeatherKey(i) + "window", "")).ToArray();
            assigned = Enumerable.Range(1, WeatherWindowLimit).Select(i => i == 1 ? "Weather" : "Weather" + i).FirstOrDefault(i => !used.Contains(i));
            if (assigned == null) throw new InvalidOperationException("All 16 weather windows are in use.");
            store.Values[key] = assigned; return assigned;
        }
        public static string WeatherForExtension(string extension) => WeatherIds.FirstOrDefault(id => WeatherExtension(id) == extension);
        public static void SelectWeather(string id) { if (WeatherIds.Contains(id)) Set("weatherInstances.active", id); }
        public static string CreateWeather(bool duplicate = false)
        {
            var ids = WeatherIds;
            if (ids.Length >= WeatherWindowLimit) throw new InvalidOperationException("You can create up to 16 weather widgets.");
            string source = WeatherActive, id = Guid.NewGuid().ToString("N"), prefix = WeatherKey(id);
            if (duplicate && source != null) {
                string sourcePrefix = WeatherKey(source);
                foreach (var key in store.Values.Keys.Where(k => k.StartsWith(sourcePrefix) && k != sourcePrefix + "window" && k != sourcePrefix + "name" && k != sourcePrefix + "visible").ToArray())
                    store.Values[prefix + key.Substring(sourcePrefix.Length)] = store.Values[key];
            } else {
                store.Values[prefix + "temp"] = true;
                store.Values[prefix + "contentWidth"] = 180.0;
                store.Values[prefix + "contentHeight"] = 72.0;
            }
            store.Values[prefix + "name"] = Enumerable.Range(1, ids.Length + 1).Select(n => "Weather " + n).First(n => !ids.Any(i => WeatherName(i) == n));
            Set("weatherInstances.ids", string.Join("|", ids.Concat(new[] { id })));
            WeatherExtension(id); SelectWeather(id); return id;
        }
        public static void DeleteWeather(string id)
        {
            if (!WeatherIds.Contains(id)) return;
            var remaining = WeatherIds.Where(i => i != id).ToArray();
            foreach (var key in store.Values.Keys.Where(k => k.StartsWith(WeatherKey(id))).ToArray()) store.Values.Remove(key);
            Set("weatherInstances.ids", string.Join("|", remaining));
            if (Get("weatherInstances.active", "") == id) Set("weatherInstances.active", remaining.FirstOrDefault() ?? "");
        }

        // Colors are stored as "#RRGGBB".
        public static Windows.UI.Color Color(string key, string fallback) => Parse(Get(key, fallback)) ?? Parse(fallback).Value;

        public static Windows.UI.Color? Parse(string s)
        {
            try
            {
                return Windows.UI.Color.FromArgb(255,
                    Convert.ToByte(s.Substring(1, 2), 16), Convert.ToByte(s.Substring(3, 2), 16), Convert.ToByte(s.Substring(5, 2), 16));
            }
            catch { return null; }
        }
    }
}
