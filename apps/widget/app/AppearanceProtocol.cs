using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;
using System.IO;
using System.Text;

namespace WidgetSampleCS
{
    sealed class AppearanceValues
    {
        public string Theme, Vibe;
        public int Opacity, Intensity;
        public bool Animated;
    }
    sealed class AppearanceSnapshot
    {
        public string Epoch;
        public long Revision;
        public bool Writable;
        public AppearanceValues Values;
    }

    static class AppearanceProtocol
    {
        public const int MaxFrame = 4096;
        public static StreamWriter Writer(Stream stream) => new StreamWriter(stream, new UTF8Encoding(false)) { AutoFlush = true, NewLine = "\n" };
        static bool Keys(IDictionary<string, object> map, params string[] keys) => map.Count == keys.Length && keys.All(map.ContainsKey);
        static bool Integer(object value, long max, out long number) {
            number = 0;
            if (!(value is double n) || double.IsNaN(n) || double.IsInfinity(n) || n < 0 || n > max || n != Math.Floor(n)) return false;
            number = (long)n; return true;
        }
        public static bool IsValue(string field, object value) {
            switch (field) {
                case "theme": return value is string theme && new[] { "disaccord", "cozy", "midnight" }.Contains(theme);
                case "vibe": return value is string vibe && new[] { "none", "rain", "snow", "halloween" }.Contains(vibe);
                case "vibeAnimated": return value is bool;
                case "vibeOpacity": case "vibeIntensity": return value is int n && n >= 0 && n <= 100;
                default: return false;
            }
        }
        public static bool TrySnapshot(IDictionary<string, object> map, out AppearanceSnapshot snapshot) {
            snapshot = null;
            if (map == null || !Keys(map, "v", "type", "epoch", "revision", "writable", "appearance") ||
                !Integer(map["v"], 1, out var version) || version != 1 || !Equals(map["type"], "snapshot") ||
                !(map["epoch"] is string epoch) || !Guid.TryParse(epoch, out _) ||
                !Integer(map["revision"], 9007199254740991, out var revision) || !(map["writable"] is bool writable) ||
                !(map["appearance"] is IDictionary<string, object> appearance) ||
                !Keys(appearance, "theme", "vibe", "vibeOpacity", "vibeIntensity", "vibeAnimated") ||
                !IsValue("theme", appearance["theme"]) || !IsValue("vibe", appearance["vibe"]) ||
                !Integer(appearance["vibeOpacity"], 100, out var opacity) || !Integer(appearance["vibeIntensity"], 100, out var intensity) ||
                !(appearance["vibeAnimated"] is bool animated)) return false;
            snapshot = new AppearanceSnapshot { Epoch = epoch, Revision = revision, Writable = writable,
                Values = new AppearanceValues { Theme = (string)appearance["theme"], Vibe = (string)appearance["vibe"], Opacity = (int)opacity, Intensity = (int)intensity, Animated = animated } };
            return true;
        }
        public static string Patch(AppearanceSnapshot snapshot, string field, object value, string id) {
            if (snapshot == null || !snapshot.Writable || !IsValue(field, value) || !Guid.TryParse(id, out _) || !Guid.TryParse(snapshot.Epoch, out _))
                throw new ArgumentException("Invalid appearance request");
            string json = value is string text ? "\"" + text + "\"" : value is bool flag ? (flag ? "true" : "false") : ((int)value).ToString(CultureInfo.InvariantCulture);
            return "{\"v\":1,\"type\":\"patch\",\"id\":\"" + id + "\",\"epoch\":\"" + snapshot.Epoch + "\",\"revision\":" + snapshot.Revision.ToString(CultureInfo.InvariantCulture) + ",\"patch\":{\"" + field + "\":" + json + "}}";
        }
    }

    // Only authoritative snapshots update the cache. Requests never change it optimistically.
    sealed class AppearanceSession
    {
        public AppearanceSnapshot State { get; private set; }
        public string Pending { get; private set; }
        public bool Writable => State?.Writable == true && Pending == null;
        public void Disconnect() { State = null; Pending = null; }
        public bool Snapshot(AppearanceSnapshot next) {
            if (State != null && (next.Epoch != State.Epoch || next.Revision < State.Revision)) return false;
            State = next; return true;
        }
        public string Request(string field, object value) {
            if (!Writable || !AppearanceProtocol.IsValue(field, value)) return null;
            string id = Guid.NewGuid().ToString("N");
            string frame = AppearanceProtocol.Patch(State, field, value, id);
            Pending = id; return frame;
        }
        public bool Complete(string id, AppearanceSnapshot snapshot) {
            if (id != Pending || Pending == null || State == null || snapshot.Epoch != State.Epoch) return false;
            if (snapshot.Revision >= State.Revision) State = snapshot;
            Pending = null; return true;
        }
    }
}
