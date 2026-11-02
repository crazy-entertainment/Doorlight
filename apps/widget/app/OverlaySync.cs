using System;
using System.Collections.Generic;
using System.IO;
using System.IO.Pipes;
using System.Linq;
using System.Text;
using System.Threading.Tasks;
using Windows.Data.Json;

namespace WidgetSampleCS
{
    // Connected settings and private state belong to the desktop. Commands are never replayed.
    static class OverlaySync
    {
        static readonly object gate = new object();
        static NamedPipeClientStream pipe;
        static StreamWriter writer;
        static string pending, pendingCommand;
        static TaskCompletionSource<JsonObject> completion;
        static bool started;
        static bool? updatePresenceSupported;
        static readonly Dictionary<object, bool> updateBusy = new Dictionary<object, bool>();
        static bool updateActivity;
        internal static void ReportUserActivity() { lock (gate) updateActivity = true; }
        internal static void ReportUpdateState(object owner, bool busy, bool activity = false) {
            lock (gate) { updateBusy[owner] = busy; updateActivity |= activity; }
        }
        internal static void ForgetUpdateState(object owner) { lock (gate) updateBusy.Remove(owner); }
        static async Task ReportUpdatePresence() {
            if (!Writable) return;
            bool? supported;
            string epoch;
            lock (gate) { supported = updatePresenceSupported; epoch = state?.GetNamedString("epoch"); }
            if (supported == null) {
                var result = await RequestAsync("update.capabilities", new JsonObject());
                if (result != null) lock (gate) {
                    if (state?.GetNamedString("epoch") == epoch)
                        updatePresenceSupported = result.GetNamedBoolean("ok", false)
                            ? result.GetNamedObject("result", new JsonObject()).GetNamedBoolean("desktopIdleGuard", false)
                            : result.GetNamedString("error", "") == "invalid" ? (bool?)false : null;
                }
                return;
            }
            if (supported != true) return;
            bool busy, activity;
            lock (gate) { busy = updateBusy.Values.Any(value => value); activity = updateActivity; updateActivity = false; }
            var receipt = await RequestAsync("update.presence", Args("busy", busy, "activity", activity));
            if (receipt == null || !receipt.GetNamedBoolean("ok", false)) lock (gate) updateActivity |= activity;
        }
        static JsonObject state;
        static string uiSignature;
        public static event Action Changed;
        public static JsonObject State { get { lock (gate) return state; } }
        public static bool Writable { get { lock (gate) return writer != null && state != null && state.GetNamedBoolean("writable", false) && pending == null; } }
        public static string Error { get; private set; }
        internal static void SetError(string message) { Error=message; }
        internal static Task<JsonObject> PendingCompletion { get {lock(gate)return completion?.Task??Task.FromResult<JsonObject>(null);} }
        public static JsonObject Args(params object[] pairs) {
            var value = new JsonObject();
            for (int i = 0; i < pairs.Length; i += 2) value[(string)pairs[i]] = Scalar(pairs[i + 1]);
            return value;
        }
        public static IJsonValue Scalar(object value) {
            if (value is IJsonValue json) return json;
            if (value is bool flag) return JsonValue.CreateBooleanValue(flag);
            if (value is string text) return JsonValue.CreateStringValue(text);
            return JsonValue.CreateNumberValue(Convert.ToDouble(value, System.Globalization.CultureInfo.InvariantCulture));
        }
        public static bool Request(string command, JsonObject args) => BeginRequest(command,args,null);
        static bool BeginRequest(string command, JsonObject args, TaskCompletionSource<JsonObject> receipt) {
            NamedPipeClientStream owner; StreamWriter target; string id, frame;
            lock (gate) {
                if (!Writable) return false;
                completion = receipt ?? new TaskCompletionSource<JsonObject>(TaskCreationOptions.RunContinuationsAsynchronously);
                id = Guid.NewGuid().ToString("N"); pending = id; pendingCommand = command; owner = pipe; target = writer;
                frame = Args("v", 1, "type", "command", "id", id, "epoch", state.GetNamedString("epoch"), "command", command, "args", args).Stringify();
                if (Encoding.UTF8.GetByteCount(frame) > 262144) { pending = null; pendingCommand=null; completion=null; Error="Settings are too large to save."; return false; }
                Error = null;
            }
            Changed?.Invoke();
            _ = Task.Run(async () => { try { await target.WriteLineAsync(frame); } catch { owner.Dispose(); } });
            _ = Task.Run(async () => { await Task.Delay(8000); lock (gate) { if (pipe == owner && pending == id) owner.Dispose(); } });
            return true;
        }
        public static Task<JsonObject> RequestAsync(string command, JsonObject args) {
            TryRequestAsync(command, args, out var result);
            return result;
        }
        internal static bool TryRequestAsync(string command, JsonObject args, out Task<JsonObject> result) {
            var receipt = new TaskCompletionSource<JsonObject>(TaskCreationOptions.RunContinuationsAsynchronously);
            bool started = BeginRequest(command,args,receipt);
            result = started ? receipt.Task : Task.FromResult<JsonObject>(null);
            return started;
        }
        public static void Start() {
            lock (gate) { if (started) return; started = true; }
            _ = Task.Run(async () => { while (true) { await Task.Delay(1000); try { await ReportUpdatePresence(); } catch { /* Retry on the next live connection. */ } } });
            _ = Task.Run(async () => {
                while (true) {
                    NamedPipeClientStream owner = null;
                    try {
                        owner = new NamedPipeClientStream(".", @"LOCAL\doorlight-overlay-v1", PipeDirection.InOut, PipeOptions.Asynchronous);
                        owner.Connect(1500);
                        lock (gate) { pipe = owner; writer = new StreamWriter(owner, new UTF8Encoding(false, true)) { AutoFlush = true, NewLine = "\n" }; }
                        var connectedOwner = owner;
                        _ = Task.Run(async () => { await Task.Delay(5000); lock(gate) { if(pipe == connectedOwner && state == null) connectedOwner.Dispose(); } });
                        var bytes = new byte[4096]; var frame = new List<byte>(); var utf8 = new UTF8Encoding(false, true); int count;
                        while ((count = await owner.ReadAsync(bytes, 0, bytes.Length)) != 0) {
                            for (int i = 0; i < count; i++) {
                                if (bytes[i] == 10) { Handle(utf8.GetString(frame.ToArray())); frame.Clear(); }
                                else { frame.Add(bytes[i]); if (frame.Count > 262144) throw new InvalidDataException("Overlay frame too large"); }
                            }
                        }
                    } catch (Exception ex) { Error = null; if(!(ex is TimeoutException)&&!(ex is IOException)&&!(ex is ObjectDisposedException))Log.Write("overlay connection: " + ex.GetType().Name); }
                    finally {
                        lock (gate) { if (pipe == owner) { pipe = null; writer = null; state = null; pending = null; pendingCommand = null; completion?.TrySetResult(null); completion = null; } }
                        lock (gate) updatePresenceSupported = null;
                        owner?.Dispose(); OverlaySettings.Rollback(); Changed?.Invoke();
                    }
                    await Task.Delay(2000);
                }
            });
        }
        static void Handle(string frame) {
            var message = JsonObject.Parse(frame); var type = message.GetNamedString("type");
            if (message.GetNamedNumber("v") != 1 || (type != "snapshot" && type != "result")) throw new InvalidDataException("Invalid overlay envelope");
            bool isResult=type=="result",resultOk=true;
            string requestId=null,resultError="";
            if(isResult){
                if(message.Keys.Any(key=>!new[]{"v","type","id","ok","error","snapshot","result"}.Contains(key)))throw new InvalidDataException("Invalid overlay result");
                requestId=message.GetNamedString("id");resultOk=message.GetNamedBoolean("ok");
                if(string.IsNullOrEmpty(requestId)||requestId.Length>64)throw new InvalidDataException("Invalid overlay result id");
                resultError=message.GetNamedString("error", "");
                if(resultOk&&message.ContainsKey("error")||!resultOk&&resultError.Length==0)throw new InvalidDataException("Invalid overlay result error");
                if(message.TryGetValue("result",out var body)&&body.ValueType!=JsonValueType.Object)throw new InvalidDataException("Invalid overlay result body");
            }
            var next = type == "result" ? message.GetNamedObject("snapshot") : message;
            var epoch = next.GetNamedString("epoch"); var revision = next.GetNamedNumber("revision");
            var settingsRevision=next.GetNamedNumber("settingsRevision");
            if(next.GetNamedNumber("v")!=1||next.GetNamedString("type")!="snapshot"||epoch.Length==0||double.IsInfinity(revision)||revision<0||revision!=Math.Floor(revision)||double.IsInfinity(settingsRevision)||settingsRevision<0||settingsRevision!=Math.Floor(settingsRevision))throw new InvalidDataException("Invalid overlay snapshot");
            next.GetNamedBoolean("writable");next.GetNamedBoolean("imported");
            next.GetNamedObject("settings"); next.GetNamedObject("chat"); next.GetNamedObject("voice");
            bool settingsCompletion = false, firstSnapshot;
            TaskCompletionSource<JsonObject> finished=null;
            lock (gate) {
                if (state != null && state.GetNamedString("epoch") != epoch) throw new InvalidDataException("Overlay epoch changed");
                firstSnapshot=state==null;
                if (isResult) {
                    if (pending != requestId) throw new InvalidDataException("Unexpected overlay result");
                    // Broadcasts may overtake a queued reply. Its receipt still settles
                    // the command, while the newest authoritative snapshot wins.
                    if(state!=null&&state.GetNamedNumber("revision")>revision)next=state;
                    message["snapshot"]=next;
                    bool updateStatus = pendingCommand?.StartsWith("update.") == true;
                    settingsCompletion = pendingCommand?.StartsWith("settings.") == true; pending = null; pendingCommand = null; finished=completion; completion = null;
                    if (!updateStatus) Error = resultOk ? null : "Couldn’t save the change. Try again.";
                }else if(state!=null&&state.GetNamedNumber("revision")>revision){
                    return;
                }
                state = next;
            }
            try {
                OverlaySettings.Accept(next, settingsCompletion, resultOk); Link.Input(next.GetNamedObject("input", new JsonObject()));
                if(firstSnapshot){
                    string status=next.GetNamedObject("chat").GetNamedString("status", "unknown");
                    if(!new[]{"consent","locked","disconnected","ready"}.Contains(status))status="unknown";
                    Log.Write("overlay connected settingsCount="+next.GetNamedObject("settings").Count+" imported="+next.GetNamedBoolean("imported",false)+" writable="+next.GetNamedBoolean("writable",false)+" chat.status="+status);
                }
                if(settingsCompletion){
                    string code=resultError;
                    if(!new[]{"","invalid","stale","busy","save_failed","locked","disconnected","unavailable"}.Contains(code))code="unavailable";
                    Log.Write("overlay settings result ok="+resultOk+" error="+code+" settingsRevision="+next.GetNamedNumber("settingsRevision")+" settingsCount="+next.GetNamedObject("settings").Count);
                }
                var durableInput=next.GetNamedObject("input",new JsonObject());
                string signature = next.GetNamedObject("chat").Stringify() + next.GetNamedObject("voice").Stringify() + durableInput.GetNamedObject("compose",new JsonObject()).Stringify()+durableInput.GetNamedObject("submission",new JsonObject()).Stringify()+ next.GetNamedNumber("settingsRevision") + Writable;
                if (signature != uiSignature || isResult) { uiSignature = signature; Changed?.Invoke(); }
                finished?.TrySetResult(message);
            } catch {finished?.TrySetResult(null);throw;}
        }
    }
}
