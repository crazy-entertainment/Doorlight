using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading.Tasks;
namespace Windows.Data.Json { class JsonObject:Dictionary<string,object>{public string GetNamedString(string key)=>(string)this[key];public bool GetNamedBoolean(string key)=>(bool)this[key];} }
namespace WidgetSampleCS {
    static class Cfg {static readonly Dictionary<string,object> values=new();public static T Get<T>(string key,T fallback)=>values.TryGetValue(key,out var value)&&value is T typed?typed:fallback;public static void Set(string key,object value)=>values[key]=value;}
    static class OverlaySettings {public static TaskCompletionSource<bool> Acknowledgement=new(TaskCreationOptions.RunContinuationsAsynchronously);public static double DurableDuration;public static async Task<bool> FlushAsync(){bool ok=await Acknowledgement.Task;if(ok)DurableDuration=TimerState.Active.DurationMilliseconds;return ok;}}
    static class OverlaySync {public static object State=new();public static int Calls;public static string Command;public static double StartedDuration;public static Windows.Data.Json.JsonObject Args(params object[] pairs){var result=new Windows.Data.Json.JsonObject();for(int i=0;i<pairs.Length;i+=2)result[(string)pairs[i]]=pairs[i+1];return result;}public static Task<object> RequestAsync(string command,Windows.Data.Json.JsonObject args){Calls++;Command=command;StartedDuration=OverlaySettings.DurableDuration;return Task.FromResult<object>(null);}public static void SetError(string text){}}
    static class Program {static async Task Main(){
        string id=TimerState.ActiveId;TimerState.SetDuration(7);TimerState.Toggle(id);
        if(OverlaySync.Calls!=0)throw new Exception("Timer started before setting acknowledgement");
        OverlaySettings.Acknowledgement.SetResult(true);await Task.Delay(100);
        if(OverlaySync.Calls!=1||OverlaySync.Command!="timer.toggle"||OverlaySync.StartedDuration!=7000)throw new Exception("Timer did not start with acknowledged edited duration");
        OverlaySettings.Acknowledgement=new(TaskCreationOptions.RunContinuationsAsynchronously);TimerState.Reset(id);OverlaySettings.Acknowledgement.SetResult(false);await Task.Delay(100);
        if(OverlaySync.Calls!=1)throw new Exception("Timer reset escaped failed settings commit");
        OverlaySync.State=null;
        TimerState.SetDuration(.05);TimerState.Toggle(id);
        if(!TimerState.Active.Running)throw new Exception("Offline countdown did not start");
        await Task.Delay(100);
        if(!TimerState.Complete(id)||!TimerState.Active.Finished||TimerState.Active.Running||TimerState.Complete(id))throw new Exception("Offline countdown must finish exactly once");
        TimerState.Toggle(id);if(!TimerState.Active.Running||TimerState.Active.Finished)throw new Exception("Finished countdown did not restart");
        TimerState.Reset(id);if(TimerState.Active.Running||TimerState.Active.Finished||TimerState.Active.StoredMilliseconds!=50)throw new Exception("Offline countdown reset failed");
        TimerState.SetVisible(id,false);if(TimerState.Active.Visible)throw new Exception("Offline timer visibility failed");
        TimerState.SetMode("Stopwatch");TimerState.Toggle(id);await Task.Delay(35);TimerState.Toggle(id);
        var elapsed=TimerState.Active.StoredMilliseconds;if(TimerState.Active.Running||elapsed<=0)throw new Exception("Offline stopwatch did not pause");
        TimerState.Toggle(id);await Task.Delay(35);TimerState.Toggle(id);
        if(TimerState.Active.StoredMilliseconds<=elapsed)throw new Exception("Offline stopwatch did not resume");
        TimerState.Reset(id);if(TimerState.Active.StoredMilliseconds!=0)throw new Exception("Offline stopwatch reset failed");
        TimerState.SetMode("Countdown");TimerState.SetUntil(DateTime.UtcNow.AddMilliseconds(50));TimerState.Toggle(id);await Task.Delay(100);
        if(!TimerState.Complete(id)||TimerState.Active.Running)throw new Exception("Offline deadline countdown did not complete");
        if(OverlaySync.Calls!=1)throw new Exception("Offline actions must never submit desktop commands");
        string escapedName = "A|B\nC;🙂";
        string escapedText = new string('x', 240) + ",;|\n🙂";
        TimerState.Create(escapedName);
        TimerState.SetParts(Enumerable.Range(0, 32).Select(_ => new TimerDisplayPart { Text = escapedText }));
        var restored = TimerState.Active;
        if (restored.Name != escapedName || restored.Parts.Count != 32 || restored.Parts.Any(part => part.Text != escapedText))
            throw new Exception("Escaped timer names and display parts did not round trip");
        var manifest = Cfg.Get("timer.records.v2", "");
        if (!manifest.StartsWith("@") || int.Parse(manifest.Substring(1).Split(':')[1]) < 2)
            throw new Exception("Large timer records must span multiple storage chunks");
        foreach (var invalid in new[] {
            "incomplete|record",
            "not-a-guid|Name|Countdown|Duration|1000|1000|0|0|0|0|1|,,",
            id + "|Name|Countdown|Duration|NaN|1000|0|0|0|0|1|,,",
            id + "|Name|Countdown|Duration|1000|invalid|0|0|0|0|1|,,"
        }) {
            Cfg.Set("timer.records.v2", invalid);
            if (TimerState.Records.Count != 0) throw new Exception("Malformed timer record was accepted");
        }
        Console.WriteLine("TimerState connected ordering, offline runtime and storage checks passed");
    }}
}
