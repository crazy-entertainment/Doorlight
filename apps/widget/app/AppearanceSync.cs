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
    static class AppearanceSync
    {
        static readonly object gate = new object();
        static readonly AppearanceSession session = new AppearanceSession();
        static NamedPipeClientStream connection;
        static StreamWriter writer;
        static bool started;
        const string LocalMessage = "Saved on this PC";
        static string message = LocalMessage;
        public static event Action Changed;
        public static bool Connected { get { lock (gate) return writer != null && session.State != null; } }
        internal static AppearanceSnapshot CurrentSnapshot { get { lock (gate) return session.State; } }
        public static bool Writable { get { lock (gate) return writer != null && session.Writable; } }
        public static bool Editable { get { lock (gate) return session.State==null || writer != null && session.Writable; } }
        public static string Message { get { lock (gate) return message; } }

        public static void Start()
        {
            lock (gate) { if (started) return; started = true; }
            _ = Task.Run(async () => {
                while (true) {
                    NamedPipeClientStream pipe = null;
                    try {
                        pipe = new NamedPipeClientStream(".", @"LOCAL\doorlight-appearance-v1", PipeDirection.InOut, PipeOptions.Asynchronous);
                        pipe.Connect(1500);
                        lock (gate) { connection = pipe; writer = AppearanceProtocol.Writer(pipe); message = LocalMessage; }
                        Changed?.Invoke();
                        var active = pipe;
                        _ = Task.Run(async () => { await Task.Delay(5000); lock (gate) { if (connection == active && session.State == null) active.Dispose(); } });
                        var bytes = new byte[1024]; var frame = new List<byte>(); var utf8 = new UTF8Encoding(false, true);
                        int count;
                        while ((count = await pipe.ReadAsync(bytes, 0, bytes.Length)) != 0) {
                            for (int i = 0; i < count; i++) {
                                if (bytes[i] == 10) {
                                    if (frame.Count > 0 && frame[frame.Count - 1] == 13) frame.RemoveAt(frame.Count - 1);
                                    Handle(utf8.GetString(frame.ToArray())); frame.Clear();
                                } else {
                                    frame.Add(bytes[i]);
                                    if (frame.Count > AppearanceProtocol.MaxFrame) throw new InvalidDataException("Appearance frame too large");
                                }
                            }
                        }
                    } catch (Exception ex) {
                        if (!(ex is TimeoutException) && !(ex is IOException) && !(ex is ObjectDisposedException))
                            Log.Write("appearance connection: " + ex.GetType().Name);
                    } finally {
                        bool notify;
                        lock (gate) {
                            notify = connection != null || session.State != null || session.Pending != null || message != LocalMessage;
                            if (connection == pipe) { connection = null; writer = null; }
                            session.Disconnect(); message = LocalMessage;
                        }
                        pipe?.Dispose(); if (notify) Changed?.Invoke();
                    }
                    await Task.Delay(2000);
                }
            });
        }

        public static bool Request(string field, object value)
        {
            string frame, id; NamedPipeClientStream pipe;
            lock (gate) {
                if(session.State==null) {
                    if(!AppearanceProtocol.IsValue(field,value))return false;
                    Cfg.Set("helper."+field,value);
                    OverlaySync.ReportUserActivity();
                    message=LocalMessage;
                    Changed?.Invoke();
                    return true;
                }
                if (writer == null || (frame = session.Request(field, value)) == null) return false;
                id = session.Pending; pipe = connection; message = "Saving in Doorlight…";
            }
            OverlaySync.ReportUserActivity();
            Changed?.Invoke();
            _ = Task.Run(async () => { await Task.Delay(8000); lock (gate) { if (connection == pipe && session.Pending == id) pipe.Dispose(); } });
            _ = Task.Run(async () => {
                try {
                    StreamWriter target;
                    lock (gate) { if (connection != pipe || session.Pending != id) return; target = writer; }
                    await target.WriteLineAsync(frame);
                } catch { pipe?.Dispose(); }
            });
            return true;
        }

        static Dictionary<string, object> Object(JsonObject json, int depth = 0)
        {
            if (depth > 3) throw new InvalidDataException("Appearance nesting too deep");
            var result = new Dictionary<string, object>();
            foreach (var pair in json) {
                var value = pair.Value;
                switch (value.ValueType) {
                    case JsonValueType.String: result[pair.Key] = value.GetString(); break;
                    case JsonValueType.Number: result[pair.Key] = value.GetNumber(); break;
                    case JsonValueType.Boolean: result[pair.Key] = value.GetBoolean(); break;
                    case JsonValueType.Object: result[pair.Key] = Object(value.GetObject(), depth + 1); break;
                    default: throw new InvalidDataException("Invalid appearance value");
                }
            }
            return result;
        }

        static void Handle(string line)
        {
            var map = Object(JsonObject.Parse(line));
            AppearanceSnapshot snapshot;
            bool apply = false, force = false;
            lock (gate) {
                if (map.TryGetValue("type", out var type) && Equals(type, "snapshot")) {
                    if (!AppearanceProtocol.TrySnapshot(map, out snapshot)) throw new InvalidDataException("Invalid appearance snapshot");
                    if (!session.Snapshot(snapshot)) {
                        if (session.State?.Epoch == snapshot.Epoch && snapshot.Revision < session.State.Revision) return;
                        throw new InvalidDataException("Unexpected appearance epoch");
                    }
                    message = session.Pending != null ? "Saving in Doorlight…" : snapshot.Writable ? "Synced with Doorlight" : "Doorlight settings are locked.";
                    apply = true;
                } else {
                    if (!map.TryGetValue("v", out var version) || !Equals(version, 1.0) || !Equals(type, "result") ||
                        !map.TryGetValue("id", out var request) || !(request is string id) ||
                        !map.TryGetValue("ok", out var success) || !(success is bool ok) ||
                        !map.TryGetValue("snapshot", out var nested) || !(nested is IDictionary<string, object> state) ||
                        map.Keys.Any(k => k != "v" && k != "type" && k != "id" && k != "ok" && k != "error" && k != "snapshot") ||
                        !AppearanceProtocol.TrySnapshot(state, out snapshot)) throw new InvalidDataException("Invalid appearance result");
                    string error = map.TryGetValue("error", out var raw) ? raw as string : null;
                    if ((ok && map.ContainsKey("error")) || (!ok && !new[] { "invalid", "stale", "busy", "save_failed" }.Contains(error))) throw new InvalidDataException("Invalid appearance error");
                    if (!session.Complete(id, snapshot)) throw new InvalidDataException("Unexpected appearance result");
                    snapshot = session.State;
                    message = ok ? "Synced with Doorlight" : error == "stale" ? "Settings changed in Doorlight. Try again." : "Doorlight could not save that change. Try again.";
                    apply = true; force = !ok;
                }
            }
            if (apply) Cfg.ApplyAppearance(snapshot.Values, force);
            Changed?.Invoke();
        }
    }
}
