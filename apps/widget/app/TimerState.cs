using System;
using System.Collections.Generic;
using System.Globalization;
using System.Linq;

namespace WidgetSampleCS
{
    sealed class TimerDisplayPart
    {
        public string Text = "";
        public string Unit = "";
        public string SourceId = "";
    }
    sealed class TimerRecord
    {
        public string Id, Name, Mode = "Countdown", Kind = "Duration";
        public double DurationMilliseconds = 900000, StoredMilliseconds = 900000;
        public long UntilUtcTicks, AnchorUtcTicks;
        public bool Running, Finished, Visible = true;
        public List<TimerDisplayPart> Parts = new List<TimerDisplayPart>();
    }
    static class TimerState
    {
        static readonly object gate = new object();
        static List<TimerRecord> publishing;
        public const double MaxSeconds = 1000 * 86400 - .001;
        static string E(string value) => Uri.EscapeDataString(value ?? "");
        static string D(string value) => Uri.UnescapeDataString(value);
        static string N(double value) => value.ToString("R", CultureInfo.InvariantCulture);
        static double Num(string value) => double.Parse(value, CultureInfo.InvariantCulture);
        static List<TimerDisplayPart> DefaultParts() => new List<TimerDisplayPart> { new TimerDisplayPart { Unit="Minutes" },new TimerDisplayPart { Text=":" },new TimerDisplayPart { Unit="Seconds" } };
        static void Write(List<TimerRecord> records)
        {
            publishing = records;
            try {
                var encoded = string.Join("\n", records.Select(r => string.Join("|", new[] {
                    r.Id, E(r.Name), r.Mode, r.Kind,
                    N(r.DurationMilliseconds), N(r.StoredMilliseconds),
                    r.UntilUtcTicks.ToString(), r.AnchorUtcTicks.ToString(),
                    r.Running ? "1" : "0", r.Finished ? "1" : "0", r.Visible ? "1" : "0",
                    string.Join(";", r.Parts.Select(p => E(p.Unit) + "," + E(p.SourceId) + "," + E(p.Text)))
                })));
                // LocalSettings values are limited to 8 KB; publish the manifest after all chunks.
                var previous = Cfg.Get("timer.records.v2", "");
                var slot = previous.StartsWith("@0:") ? 1 : 0;
                var count = (encoded.Length + 2999) / 3000;
                for (var i = 0; i < count; i++) {
                    Cfg.Set("timer.records.chunk." + slot + "." + i,
                        encoded.Substring(i * 3000, Math.Min(3000, encoded.Length - i * 3000)));
                }
                Cfg.Set("timer.records.v2", "@" + slot + ":" + count);
            } finally {
                publishing = null;
            }
        }
        public static List<TimerRecord> Records
        {
            get {
                lock (gate) {
                    if (publishing != null) return publishing;
                    var raw = Cfg.Get("timer.records.v2", "~");
                    if (raw.StartsWith("@")) {
                        var manifest = raw.Substring(1).Split(':');
                        raw = string.Concat(Enumerable.Range(0, int.Parse(manifest[1]))
                            .Select(i => Cfg.Get("timer.records.chunk." + manifest[0] + "." + i, "")));
                    }
                    if (raw == "~") {
                        var total = Math.Max(1, Math.Min(MaxSeconds,
                            Cfg.Get("timer.duration", Cfg.Get("timer.minutes", 15.0) * 60)));
                        var end = Cfg.Get("timer.utcEnd", 0L);
                        if (end == 0 && Cfg.Get("timer.endsAt", 0L) > 0)
                            end = new DateTime(Cfg.Get("timer.endsAt", 0L), DateTimeKind.Local).ToUniversalTime().Ticks;
                        var first = new TimerRecord {
                            Id = Guid.NewGuid().ToString("N"),
                            Name = "Timer",
                            DurationMilliseconds = total * 1000,
                            StoredMilliseconds = Cfg.Get("timer.remaining", total) * 1000,
                            Running = Cfg.Get("timer.running", false),
                            AnchorUtcTicks = end,
                            Parts = DefaultParts()
                        };
                        var migrated = new List<TimerRecord> { first };
                        Write(migrated);
                        Cfg.Set("timer.activeId", first.Id);
                        return migrated;
                    }
                    var result = new List<TimerRecord>();
                    foreach (var line in raw.Split('\n')) {
                        if (line.Length == 0) continue;
                        try {
                            var fields = line.Split('|');
                            if (fields.Length != 12) continue;
                            var record = new TimerRecord {
                                Id = fields[0], Name = D(fields[1]), Mode = fields[2], Kind = fields[3],
                                DurationMilliseconds = Num(fields[4]), StoredMilliseconds = Num(fields[5]),
                                UntilUtcTicks = long.Parse(fields[6]), AnchorUtcTicks = long.Parse(fields[7]),
                                Running = fields[8] == "1", Finished = fields[9] == "1", Visible = fields[10] == "1"
                            };
                            if (!Guid.TryParse(record.Id, out var _) ||
                                double.IsNaN(record.DurationMilliseconds) ||
                                record.DurationMilliseconds < 1 || record.DurationMilliseconds > MaxSeconds * 1000 ||
                                double.IsNaN(record.StoredMilliseconds) || double.IsInfinity(record.StoredMilliseconds)) continue;
                            foreach (var part in fields[11].Split(';')) {
                                var values = part.Split(',');
                                if (values.Length == 3)
                                    record.Parts.Add(new TimerDisplayPart {
                                        Unit = D(values[0]), SourceId = D(values[1]), Text = D(values[2])
                                    });
                            }
                            result.Add(record);
                        } catch (FormatException) {
                        } catch (ArgumentException) {
                        }
                    }
                    return result;
                }
            }
        }
        public static string ActiveId { get {var rows=Records;var id=Cfg.Get("timer.activeId","");return rows.Any(r=>r.Id==id)?id:rows.FirstOrDefault()?.Id;} }
        public static TimerRecord Active => Records.FirstOrDefault(r=>r.Id==ActiveId);
        public static void Select(string id) {if(!Records.Any(r=>r.Id==id))throw new ArgumentException("Timer not found");Cfg.Set("timer.activeId",id);}
        public static string Create(string name=null) {lock(gate){var rows=Records;var r=new TimerRecord{Id=Guid.NewGuid().ToString("N"),Name=string.IsNullOrWhiteSpace(name)?Enumerable.Range(1,rows.Count+1).Select(n=>"Timer "+n).First(n=>!rows.Any(t=>string.Equals(t.Name,n,StringComparison.OrdinalIgnoreCase))):name.Trim(),Parts=DefaultParts()};if(r.Name.Length>32)throw new ArgumentException("Name too long");rows.Add(r);Write(rows);Select(r.Id);return r.Id;}}
        static void Change(string id,Action<TimerRecord> edit) {lock(gate){var rows=Records;var r=rows.FirstOrDefault(t=>t.Id==id);if(r==null)return;edit(r);Write(rows);}}
        public static void Rename(string id,string name) {if(string.IsNullOrWhiteSpace(name)||name.Trim().Length>32)throw new ArgumentException("Enter a name up to 32 characters");if(Records.Any(r=>r.Id!=id&&string.Equals(r.Name,name.Trim(),StringComparison.OrdinalIgnoreCase)))throw new ArgumentException("That name is already used");Change(id,r=>r.Name=name.Trim());}
        public static void Delete(string id) {lock(gate){var rows=Records;rows.RemoveAll(r=>r.Id==id);Write(rows);if(Cfg.Get("timer.activeId","")==id)Cfg.Set("timer.activeId",rows.FirstOrDefault()?.Id??"");}}
        public static void SetVisible(string id,bool value) => _ = RuntimeCommand("timer.visibility",OverlaySync.Args("id",id,"visible",value));
        public static void SetParts(IEnumerable<TimerDisplayPart> parts) {var list=parts.Take(64).Select(p=>new TimerDisplayPart{Text=p.Text??"",Unit=p.Unit??"",SourceId=p.SourceId??""}).ToList();if(list.Any(p=>p.Text.Length>256||(!string.IsNullOrEmpty(p.Unit)&&!Units.Contains(p.Unit))))throw new ArgumentException("Invalid display field");Change(ActiveId,r=>r.Parts=list);}
        static readonly string[] Units={"Days","Hours","Minutes","Seconds","Milliseconds"};
        public static void SetMode(string mode) {if(mode!="Countdown"&&mode!="Stopwatch")throw new ArgumentException("Invalid mode");Change(ActiveId,r=>{r.Mode=mode;ResetRecord(r);});}
        public static void SetKind(string kind) {if(kind!="Duration"&&kind!="Until")throw new ArgumentException("Invalid countdown kind");Change(ActiveId,r=>{r.Kind=kind;ResetRecord(r);});}
        public static void SetUntil(DateTime utc) {var ticks=utc.ToUniversalTime().Ticks;if(ticks<=DateTime.UtcNow.Ticks)throw new ArgumentOutOfRangeException(nameof(utc),"Choose a future time");Cfg.Set("timer.simpleEmptyDuration."+ActiveId,false);Change(ActiveId,r=>{r.Kind="Until";r.UntilUtcTicks=ticks;ResetRecord(r);});}
        public static bool Running => Active?.Running??false;
        public static double Total => (Active?.DurationMilliseconds??0)/1000;
        public static double Remaining => Value(ActiveId);
        static double ValueMs(TimerRecord r) {
            if(r==null || (r.Mode=="Countdown" && Cfg.Get("timer.simpleEmptyDuration."+r.Id,false)))return 0;
            if(!r.Running)return Math.Max(0,r.StoredMilliseconds);
            var elapsed=(DateTime.UtcNow.Ticks-r.AnchorUtcTicks)/(double)TimeSpan.TicksPerMillisecond;
            if(r.Mode=="Stopwatch")return Math.Max(0,r.StoredMilliseconds+elapsed);
            var deadline=r.Kind=="Until"?r.UntilUtcTicks:r.AnchorUtcTicks;
            return Math.Max(0,(deadline-DateTime.UtcNow.Ticks)/(double)TimeSpan.TicksPerMillisecond);
        }
        public static double Value(string id) => ValueMs(Records.FirstOrDefault(r=>r.Id==id))/1000;
        public static void SetDuration(double seconds) {if(double.IsNaN(seconds)||double.IsInfinity(seconds)||seconds<.001||seconds>MaxSeconds)throw new ArgumentOutOfRangeException(nameof(seconds));Cfg.Set("timer.simpleEmptyDuration."+ActiveId,false);Change(ActiveId,r=>{r.DurationMilliseconds=Math.Round(seconds*1000);r.Kind="Duration";ResetRecord(r);});}
        static void ResetRecord(TimerRecord r) {r.Running=false;r.Finished=false;r.StoredMilliseconds=r.Mode=="Stopwatch"?0:r.Kind=="Until"?Math.Max(0,(r.UntilUtcTicks-DateTime.UtcNow.Ticks)/(double)TimeSpan.TicksPerMillisecond):r.DurationMilliseconds;}
        public static void Reset() => Reset(ActiveId);
        public static void Reset(string id) => _ = RuntimeCommand("timer.reset",OverlaySync.Args("id",id));
        public static void Toggle() => Toggle(ActiveId);
        public static async System.Threading.Tasks.Task ToggleAfterActivationAsync(string id, Func<System.Threading.Tasks.Task> activate)
        {
            if (!Records.Any(r => r.Id == id)) return;
            await activate();
            // Selection may change while the host opens; the original action still owns its ID.
            Toggle(id);
        }
        public static void Toggle(string id) => _ = RuntimeCommand("timer.toggle",OverlaySync.Args("id",id));
        static async System.Threading.Tasks.Task RuntimeCommand(string command,Windows.Data.Json.JsonObject args) {
            try {
                if(OverlaySync.State==null) {
                    Change(args.GetNamedString("id"),row=>{
                        switch(command) {
                            case "timer.visibility":
                                row.Visible = args.GetNamedBoolean("visible");
                                break;
                            case "timer.reset":
                                ResetRecord(row);
                                break;
                            case "timer.toggle":
                                if (row.Running) {
                                    row.StoredMilliseconds = ValueMs(row);
                                    row.Running = false;
                                }
                                else {
                                    if (row.Mode == "Countdown" && row.Kind == "Duration" && row.StoredMilliseconds <= 0)
                                        row.StoredMilliseconds = row.DurationMilliseconds;
                                    row.AnchorUtcTicks = DateTime.UtcNow.Ticks + (row.Mode == "Stopwatch" ? 0 :
                                        (long)Math.Round(row.StoredMilliseconds * TimeSpan.TicksPerMillisecond));
                                    row.Running = true;
                                    row.Finished = false;
                                }
                                break;
                        }
                    });
                    return;
                }
                if (!await OverlaySettings.FlushAsync()) {
                    OverlaySync.SetError("Could not save timer changes. Try again.");
                    return;
                }
                await OverlaySync.RequestAsync(command, args);
            } catch {
                OverlaySync.SetError("Could not change the timer. Try again.");
            }
        }
        static readonly Dictionary<string,bool> observedRunning = new Dictionary<string,bool>();
        public static bool Complete() => Complete(ActiveId);
        public static bool Complete(string id) {
            lock(gate) {
            var row=Records.FirstOrDefault(r=>r.Id==id);if(row==null)return false;
            if(OverlaySync.State==null&&row.Running&&row.Mode=="Countdown"&&ValueMs(row)<=0) {
                Change(id,record=>{record.Running=false;record.Finished=true;record.StoredMilliseconds=0;});
                observedRunning[id]=false;return true;
            }
            bool completed=observedRunning.TryGetValue(id,out var running)&&running&&row.Finished; observedRunning[id]=row.Running;return completed;
            }
        }
        public static int[] Suggestions() => Cfg.Get("timer.recent", "").Split(',').Select(v=>int.TryParse(v,out var n)?n:0).Where(n=>n>0&&n<=MaxSeconds).Concat(new[]{300,900,1800}).Distinct().Take(3).ToArray();
        static void Remember(int seconds) => Cfg.Set("timer.recent",string.Join(",",new[]{seconds}.Concat(Suggestions()).Distinct().Take(3)));
        public static string Format(double seconds) {var t=TimeSpan.FromSeconds(Math.Ceiling(Math.Max(0,seconds)));return t.TotalDays>=1?((int)t.TotalDays)+"d "+t.ToString(@"hh\:mm\:ss"):t.TotalHours>=1?((int)t.TotalHours)+t.ToString(@"\:mm\:ss"):t.ToString(@"mm\:ss");}
        public static string FormatRecord(string id) {
            var rows=Records;var record=rows.FirstOrDefault(r=>r.Id==id);if(record==null)return "—";
            return string.Concat(record.Parts.Select(p=>FormatPartCore(id,record,p,rows)));
        }
        public static string FormatPart(string id,TimerDisplayPart part) {var rows=Records;var record=rows.FirstOrDefault(r=>r.Id==id);return record==null?"—":FormatPartCore(id,record,part,rows);}
        static string FormatPartCore(string id,TimerRecord record,TimerDisplayPart p,List<TimerRecord> rows) {
                if(string.IsNullOrEmpty(p.Unit))return p.Text;
                var sourceId=string.IsNullOrEmpty(p.SourceId)?id:p.SourceId;var source=rows.FirstOrDefault(r=>r.Id==sourceId);if(source==null)return "—";
                var relevant=record.Parts.Where(q=>!string.IsNullOrEmpty(q.Unit)&&(string.IsNullOrEmpty(q.SourceId)?id:q.SourceId)==sourceId).ToList();
                var index=Array.IndexOf(Units,p.Unit);if(index<0)return "—";
                if(relevant.Count==0)relevant.Add(p);var highest=relevant.Min(q=>Array.IndexOf(Units,q.Unit));var ms=ValueMs(source);
                // Whole-second displays count down with ceiling; millisecond formats retain precision.
                ms=relevant.Any(q=>q.Unit=="Milliseconds")?Math.Floor(ms+.0001):source.Mode=="Stopwatch"?Math.Floor(ms/1000)*1000:Math.Ceiling(ms/1000)*1000;
                var divisors=new[]{86400000d,3600000d,60000d,1000d,1d};var value=Math.Floor(ms/divisors[index]);
                if(index!=highest)value%=index==1?24:index==4?1000:60;
                return value.ToString(index==4?"000":"00",CultureInfo.InvariantCulture);
        }
    }
    sealed class TimerPreset
    {
        public string Name;
        public int Seconds;
        public string Label => (string.IsNullOrWhiteSpace(Name) ? "" : Name + " · ") + TimerState.Format(Seconds);
        public static List<TimerPreset> Read(string value)
        {
            var result = new List<TimerPreset>();
            foreach (var line in value.Split('\n').Take(12)) {
                var fields = line.Split('|');
                if (fields.Length != 2 || !int.TryParse(fields[0], NumberStyles.None, CultureInfo.InvariantCulture, out var seconds) || seconds < 1 || seconds > 59999) continue;
                try { var name = Uri.UnescapeDataString(fields[1]); if (name.Length <= 32) result.Add(new TimerPreset { Name = name, Seconds = seconds }); }
                catch (UriFormatException) { }
            }
            return result;
        }
        public static string Write(IEnumerable<TimerPreset> items) => string.Join("\n", items.Take(12).Select(p => p.Seconds.ToString(CultureInfo.InvariantCulture) + "|" + Uri.EscapeDataString(p.Name ?? "")));
    }
}
