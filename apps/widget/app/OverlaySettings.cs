using System;
using System.Collections.Generic;
using System.Linq;
using System.Threading;
using Windows.Data.Json;
using Windows.Storage;

namespace WidgetSampleCS
{
    static class OverlaySettings
    {
        internal sealed class Cache : IDictionary<string, object>
        {
            readonly Dictionary<string,object> data=new Dictionary<string,object>();
            public object this[string key]
            {
                get { lock (gate) return data[key]; }
                set
                {
                    lock (gate)
                    {
                        if (!CanEdit(key)) return;
                        if (data.TryGetValue(key, out var previous) && Equals(previous, value)) return;
                        data[key] = value;
                        Dirty(key);
                    }
                }
            }
            public ICollection<string> Keys {get{lock(gate)return data.Keys.ToArray();}}
            public ICollection<object> Values {get{lock(gate)return data.Values.ToArray();}}
            public int Count {get{lock(gate)return data.Count;}} public bool IsReadOnly=>false;
            public bool ContainsKey(string key){lock(gate)return data.ContainsKey(key);}
            public bool TryGetValue(string key,out object value){lock(gate)return data.TryGetValue(key,out value);}
            public bool Remove(string key)
            {
                lock (gate)
                {
                    if (!CanEdit(key)) return false;
                    bool removed = data.Remove(key);
                    if (removed) Dirty(key);
                    return removed;
                }
            }
            public void Add(string key,object value){this[key]=value;}
            public void Add(KeyValuePair<string,object> item){this[item.Key]=item.Value;}
            public void Clear(){foreach(var key in Keys)Remove(key);}
            public bool Contains(KeyValuePair<string,object> item){lock(gate)return ((ICollection<KeyValuePair<string,object>>)data).Contains(item);}
            public void CopyTo(KeyValuePair<string,object>[] array,int index){lock(gate)((ICollection<KeyValuePair<string,object>>)data.ToArray()).CopyTo(array,index);}
            public bool Remove(KeyValuePair<string,object> item){lock(gate)return Contains(item)&&Remove(item.Key);}
            public IEnumerator<KeyValuePair<string,object>> GetEnumerator(){lock(gate)return ((IEnumerable<KeyValuePair<string,object>>)data.ToArray()).GetEnumerator();}
            System.Collections.IEnumerator System.Collections.IEnumerable.GetEnumerator()=>GetEnumerator();
            internal void Replace(IDictionary<string,object> values)
            {
                lock (gate)
                {
                    data.Clear();
                    foreach (var item in values) data[item.Key] = item.Value;
                }
            }
            internal void RawSet(string key,object value){lock(gate)data[key]=value;}
            internal void RawRemove(string key){lock(gate)data.Remove(key);}
        }
        internal static readonly Cache Values = new Cache();
        static Dictionary<string, object> confirmed;
        static bool desktopSession, dirty, submitting, retryRequired;
        static volatile bool canWrite;
        static readonly HashSet<string> edited=new HashSet<string>();
        sealed class Transaction {
            public Dictionary<string,object> Baseline, Values;
            public HashSet<string> Keys;
        }
        static Transaction inFlight, retry;
        static long generation, settingsRevision=-1;
        static readonly object gate = new object();
        static readonly string[] appearance = { "helper.theme", "helper.vibe", "helper.vibeOpacity", "helper.vibeIntensity", "helper.vibeAnimated" };
        const string BaselinePrefix = "overlay.localBaseline.", LocalEdits = "overlay.localEdits";
        static OverlaySettings() {
            LoadLocal();
            OverlaySync.Changed += SyncChanged;
        }
        static void LoadLocal() {
            var local=ApplicationData.Current.LocalSettings.Values;
            Values.Replace(local.Where(p=>p.Key!=LocalEdits&&!p.Key.StartsWith(BaselinePrefix)).ToDictionary(p=>p.Key,p=>p.Value));
            confirmed=Values.ToDictionary(p=>p.Key,p=>p.Value);
            if(local.ContainsKey(LocalEdits)) {
                foreach(var key in confirmed.Keys.Where(Shared).ToArray())confirmed.Remove(key);
                foreach(var item in local.Where(p=>p.Key.StartsWith(BaselinePrefix)))confirmed[item.Key.Substring(BaselinePrefix.Length)]=item.Value;
            }
            edited.Clear();edited.UnionWith(Changes(confirmed,Values).Where(Shared));dirty=edited.Count>0;
        }
        static void PersistLocal() {
            var local=ApplicationData.Current.LocalSettings.Values;
            var baseline=confirmed.Where(p=>edited.Count>0&&Shared(p.Key)).ToDictionary(p=>BaselinePrefix+p.Key,p=>p.Value);
            foreach(var key in local.Keys.Where(k=>k.StartsWith(BaselinePrefix)&&!baseline.ContainsKey(k)).ToArray())local.Remove(key);
            if(edited.Count>0) {
                foreach(var item in baseline)if(!local.TryGetValue(item.Key,out var previous)||!Equals(previous,item.Value))local[item.Key]=item.Value;
                local[LocalEdits]=true;
            } else local.Remove(LocalEdits);
            foreach(var item in Values.Where(p=>Shared(p.Key)||appearance.Contains(p.Key)))if(!local.TryGetValue(item.Key,out var previous)||!Equals(previous,item.Value))local[item.Key]=item.Value;
            foreach(var key in local.Keys.Where(k=>Shared(k)&&!Values.ContainsKey(k)).ToArray())local.Remove(key);
        }
        static readonly string[] runtimeOnly = { "cross.editing", "cross.windowWidth", "clock.fadeOpacity", "clock.shown", "weather.windowWidth", "weather.windowHeight" };
        static bool Shared(string key) => !appearance.Contains(key) && !key.StartsWith("overlay.") && !key.StartsWith("consent.") && !runtimeOnly.Contains(key);
        internal static bool Editable => OverlaySync.State==null || canWrite;
        static bool CanEdit(string key) => !Shared(key) || Editable;
        static void SyncChanged(){canWrite=OverlaySync.Writable;Flush();}
        static void Dirty(string key) {
            if (!Shared(key)) {
                if(Values.TryGetValue(key,out var value))confirmed[key]=value;else confirmed.Remove(key);
                if(appearance.Contains(key)){var local=ApplicationData.Current.LocalSettings.Values;if(Values.TryGetValue(key,out value))local[key]=value;else local.Remove(key);}
                return;
            }
            lock (gate) {
                retry=null;retryRequired=false;dirty = true; edited.Add(key); generation++;
                if(OverlaySync.State==null)PersistLocal();
            }
            var version = generation;
            // Coalesce all mutations in an editor transaction, including every timer chunk.
            _ = System.Threading.Tasks.Task.Run(async () => { await System.Threading.Tasks.Task.Delay(100); if (version == generation) Flush(); });
        }
        internal static T Read<T>(string key, T fallback) {
            if (!Values.TryGetValue(key, out var value)) return fallback;
            if (value is T typed) return typed;
            try { if (!(value is bool) && !(value is string) && typeof(T) != typeof(bool) && typeof(T) != typeof(string)) return (T)Convert.ChangeType(value, typeof(T), System.Globalization.CultureInfo.InvariantCulture); } catch { }
            return fallback;
        }
        static JsonObject Encode() { var result = new JsonObject(); foreach (var item in Values.ToArray()) if (Shared(item.Key)) result[item.Key] = OverlaySync.Scalar(item.Value); return result; }
        static void Flush() {
            var snapshot=OverlaySync.State;
            if(snapshot==null||!OverlaySync.Writable)return;
            JsonObject transaction; string command;long revision;Transaction sent;
            lock(gate){
                if(!dirty||submitting||retryRequired||inFlight!=null)return;
                submitting=true;transaction=Encode();revision=(long)snapshot.GetNamedNumber("settingsRevision");
                sent=new Transaction { Baseline=new Dictionary<string,object>(confirmed),Values=Values.ToDictionary(p=>p.Key,p=>p.Value),Keys=new HashSet<string>(edited) };
                command=snapshot.GetNamedBoolean("imported",false)?"settings.replace":"settings.import";
                if(command=="settings.import")sent.Keys.UnionWith(sent.Values.Keys.Where(Shared));
                inFlight=sent;

                dirty=false;
            }
            bool accepted=OverlaySync.Request(command,OverlaySync.Args("revision",revision,"values",transaction));
            lock(gate){submitting=false;if(!accepted&&ReferenceEquals(inFlight,sent)){dirty=true;inFlight=null;}}
        }
        internal static void Retry(){
            string[] changed=new string[0];bool conflict=false;
            lock(gate){
                if(retry!=null){
                    var before=Values.ToDictionary(p=>p.Key,p=>p.Value);
                    foreach(var key in retry.Keys)if(!Same(confirmed,retry.Values,key)&&!Same(confirmed,retry.Baseline,key)){conflict=true;break;}
                    if(!conflict){
                        foreach(var key in retry.Keys){if(Same(confirmed,retry.Values,key))continue;if(retry.Values.TryGetValue(key,out var value))Values.RawSet(key,value);else Values.RawRemove(key);edited.Add(key);}
                        changed=Changes(before,Values);retry=null;retryRequired=false;dirty=edited.Count>0;
                    }
                }else{retryRequired=false;dirty=true;}
            }
            if(conflict)OverlaySync.SetError("Settings changed in Doorlight. Reapply your change before saving.");
            if(changed.Length>0)Cfg.Refresh(changed);
            if(!conflict)Flush();
        }
        internal static async System.Threading.Tasks.Task<bool> FlushAsync(){
            for(int attempt=0;attempt<5;attempt++){
                var outstanding=OverlaySync.PendingCompletion;await outstanding;
                if(!OverlaySync.Writable)return false;
                lock(gate){if(retryRequired)return false;if(!dirty&&!submitting&&inFlight==null)return true;}
                Flush();
                var result=await OverlaySync.PendingCompletion;
                if(result!=null&&!result.GetNamedBoolean("ok",false))return false;
            }
            return false;
        }
        internal static bool RetryRequired {get{lock(gate)return retryRequired;}}
        static bool Same(IDictionary<string,object> a,IDictionary<string,object> b,string key){
            bool left=a.TryGetValue(key,out var x),right=b.TryGetValue(key,out var y);
            if(left!=right)return false;if(!left)return true;if(Equals(x,y))return true;
            if(x is string||x is bool||y is string||y is bool)return false;
            try{return Convert.ToDouble(x)==Convert.ToDouble(y);}catch{return false;}
        }
        static string[] Changes(IDictionary<string,object> before,IDictionary<string,object> after)=>before.Keys.Union(after.Keys).Where(key=>!Same(before,after,key)).ToArray();
        static void PreserveRetry(Transaction transaction,IDictionary<string,object> current){
            if(transaction==null)return;
            var desired=new Dictionary<string,object>(transaction.Values);
            var keys=new HashSet<string>(transaction.Keys);keys.UnionWith(edited);
            foreach(var key in edited){if(current.TryGetValue(key,out var value))desired[key]=value;else desired.Remove(key);}
            retry=new Transaction{Baseline=transaction.Baseline,Values=desired,Keys=keys};retryRequired=true;
        }
        static bool SameTimer(IDictionary<string,object> left,IDictionary<string,object> right)=>!Changes(left,right).Any(key=>key.StartsWith("timer.records."));
        internal static void Accept(JsonObject snapshot,bool completion,bool ok=true) {
            canWrite=OverlaySync.Writable;
            bool imported=snapshot.GetNamedBoolean("imported",false),conflict=false;
            string[] changed=new string[0];
            lock(gate){
                long revision=(long)snapshot.GetNamedNumber("settingsRevision");
                if(!completion&&desktopSession&&revision==settingsRevision&&imported)return;
                desktopSession=true;
                var before=Values.ToDictionary(p=>p.Key,p=>p.Value);
                var next=before.Where(p=>!Shared(p.Key)).ToDictionary(p=>p.Key,p=>p.Value);
                if(imported){
                    foreach(var item in snapshot.GetNamedObject("settings")){
                        if(!Shared(item.Key))continue;
                        switch(item.Value.ValueType){case JsonValueType.String:next[item.Key]=item.Value.GetString();break;case JsonValueType.Boolean:next[item.Key]=item.Value.GetBoolean();break;case JsonValueType.Number:next[item.Key]=item.Value.GetNumber();break;default:throw new System.IO.InvalidDataException("Invalid setting value");}
                    }
                }else next=new Dictionary<string,object>(confirmed);
                var acknowledged=inFlight;
                if(completion&&!ok){
                    PreserveRetry(acknowledged,before);inFlight=null;
                    edited.Clear();dirty=false;Values.Replace(next);
                }else{
                    var mergeBase=confirmed;
                    if(completion&&ok&&acknowledged!=null){
                        foreach(var key in acknowledged.Keys)if(Same(before,acknowledged.Values,key))edited.Remove(key);
                        mergeBase=acknowledged.Values;inFlight=null;retry=null;retryRequired=false;
                    }
                    var merged=new Dictionary<string,object>(next);
                    bool timerExpected=inFlight!=null&&SameTimer(next,inFlight.Values);
                    bool timerConflict=edited.Any(key=>key.StartsWith("timer.records."))&&!SameTimer(mergeBase,next)&&!timerExpected;
                    foreach(var key in edited.ToArray()){
                        if(Same(before,next,key)){edited.Remove(key);continue;}
                        bool expected=inFlight!=null&&inFlight.Keys.Contains(key)&&Same(next,inFlight.Values,key);
                        if((!expected&&!Same(mergeBase,next,key))||timerConflict&&key.StartsWith("timer.records.")){edited.Remove(key);conflict=true;continue;}
                        if(before.TryGetValue(key,out var value))merged[key]=value;else merged.Remove(key);
                    }
                    Values.Replace(merged);dirty=edited.Count>0;
                    if(!imported&&!retryRequired&&inFlight==null)dirty=true;
                }
                changed=Changes(before,Values);
                confirmed=next;settingsRevision=revision;
                PersistLocal();
            }
            if(conflict)OverlaySync.SetError("Settings changed in Doorlight. Review your last change.");
            if(changed.Length>0)Cfg.Refresh(changed);
            Flush();
        }
        internal static void Rollback(){
            string[] changed;lock(gate){
                canWrite=false;
                if(!desktopSession)return;
                desktopSession=false;
                var interrupted=inFlight;
                if(interrupted==null&&edited.Count>0)interrupted=new Transaction{Baseline=new Dictionary<string,object>(confirmed),Values=Values.ToDictionary(p=>p.Key,p=>p.Value),Keys=new HashSet<string>(edited)};
                PreserveRetry(interrupted,Values);inFlight=null;
                changed=Changes(Values,confirmed);Values.Replace(confirmed);dirty=false;edited.Clear();generation++;
                PersistLocal();
            }
            Cfg.Refresh(changed);
        }
    }
}
