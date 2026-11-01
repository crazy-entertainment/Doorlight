using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using System.Reflection;
using System.Text.Json;
using System.Threading.Tasks;
namespace Windows.Data.Json {
    enum JsonValueType { Null,String,Number,Boolean,Object,Array }
    interface IJsonValue {JsonValueType ValueType{get;}string GetString();bool GetBoolean();double GetNumber();}
    class JsonValue:IJsonValue {
        internal readonly object Value;public JsonValue(object value){Value=value;}
        public JsonValueType ValueType=>Value==null?JsonValueType.Null:Value is string?JsonValueType.String:Value is bool?JsonValueType.Boolean:JsonValueType.Number;
        public string GetString()=>(string)Value;public bool GetBoolean()=>(bool)Value;public double GetNumber()=>Convert.ToDouble(Value);
        public static JsonValue CreateNumberValue(double value)=>new(value);public static JsonValue CreateStringValue(string value)=>new(value);public static JsonValue CreateBooleanValue(bool value)=>new(value);
    }
    class JsonObject:Dictionary<string,IJsonValue>,IJsonValue {
        public JsonValueType ValueType=>JsonValueType.Object;public string GetString()=>throw new Exception();public bool GetBoolean()=>throw new Exception();public double GetNumber()=>throw new Exception();
        public string GetNamedString(string key)=>this[key].GetString();public string GetNamedString(string key,string fallback)=>TryGetValue(key,out var value)?value.GetString():fallback;
        public bool GetNamedBoolean(string key)=>this[key].GetBoolean();public bool GetNamedBoolean(string key,bool fallback)=>TryGetValue(key,out var value)?value.GetBoolean():fallback;
        public double GetNamedNumber(string key)=>this[key].GetNumber();public JsonObject GetNamedObject(string key)=>(JsonObject)this[key];public JsonObject GetNamedObject(string key,JsonObject fallback)=>TryGetValue(key,out var value)?(JsonObject)value:fallback;
        static object Plain(IJsonValue value)=>value is JsonObject map?map.ToDictionary(p=>p.Key,p=>Plain(p.Value)):((JsonValue)value).Value;
        public string Stringify()=>JsonSerializer.Serialize(Plain(this));
        static IJsonValue Convert(JsonElement element){switch(element.ValueKind){case JsonValueKind.Object:var map=new JsonObject();foreach(var item in element.EnumerateObject())map[item.Name]=Convert(item.Value);return map;case JsonValueKind.String:return new JsonValue(element.GetString());case JsonValueKind.True:return new JsonValue(true);case JsonValueKind.False:return new JsonValue(false);case JsonValueKind.Number:return new JsonValue(element.GetDouble());default:return new JsonValue(null);}}
        public static JsonObject Parse(string value){using var doc=JsonDocument.Parse(value);return (JsonObject)Convert(doc.RootElement);}
    }
}
namespace WidgetSampleCS {
    using Windows.Data.Json;
    static class OverlaySettings {public static int Calls;public static bool Completion,Ok;public static double Revision;public static void Accept(JsonObject state,bool completion,bool ok){Calls++;Completion=completion;Ok=ok;Revision=state.GetNamedNumber("revision");}public static void Rollback(){}}
    static class Link {public static void Input(JsonObject input){}}
    static class Log {public static readonly List<string> Lines=new();public static void Write(string line)=>Lines.Add(line);}
    static class Program {
        static readonly Type Sync=typeof(OverlaySync);
        static void Set(string name,object value)=>Sync.GetField(name,BindingFlags.Static|BindingFlags.NonPublic).SetValue(null,value);
        static object Get(string name)=>Sync.GetField(name,BindingFlags.Static|BindingFlags.NonPublic).GetValue(null);
        static void Handle(string frame){try{Sync.GetMethod("Handle",BindingFlags.Static|BindingFlags.NonPublic).Invoke(null,new object[]{frame});}catch(TargetInvocationException ex){throw ex.InnerException;}}
        static JsonObject Snapshot(int revision,string epoch="epoch-a")=>OverlaySync.Args("v",1,"type","snapshot","epoch",epoch,"revision",revision,"settingsRevision",3,"imported",true,"writable",true,"settings",new JsonObject(),"chat",OverlaySync.Args("status","ready"),"voice",new JsonObject(),"input",new JsonObject());
        static string Result(string id,int revision,bool ok=true,string epoch="epoch-a") {var result=OverlaySync.Args("v",1,"type","result","id",id,"ok",ok,"snapshot",Snapshot(revision,epoch));if(!ok)result["error"]=JsonValue.CreateStringValue("save_failed");return result.Stringify();}
        static TaskCompletionSource<JsonObject> Pending(string id){var receipt=new TaskCompletionSource<JsonObject>(TaskCreationOptions.RunContinuationsAsynchronously);Set("pending",id);Set("pendingCommand","settings.replace");Set("completion",receipt);return receipt;}
        static void Check(bool pass,string label){if(!pass)throw new Exception(label);}
        static void Main(){
            Set("state",null);Set("writer",new StreamWriter(new MemoryStream()));
            Handle(Snapshot(10).Stringify());var first=Pending("request-a");Handle(Result("request-a",9));
            Check(first.Task.IsCompletedSuccessfully&&Get("pending")==null,"Matching older result must settle pending command");
            Check(OverlaySync.State.GetNamedNumber("revision")==10&&OverlaySettings.Revision==10,"Older result must keep newer authoritative state");
            Check(OverlaySettings.Completion&&OverlaySettings.Ok&&first.Task.Result.GetNamedObject("snapshot").GetNamedNumber("revision")==10,"Acknowledgement must apply using latest snapshot and retain result success");
            var second=Pending("request-b");Handle(Snapshot(12).Stringify());Handle(Result("request-b",11,false));
            Check(second.Task.IsCompletedSuccessfully&&!second.Task.Result.GetNamedBoolean("ok")&&OverlaySettings.Completion&&!OverlaySettings.Ok&&OverlaySettings.Revision==12,"Older failed result must settle failure against newer state");
            var third=Pending("request-c");int before=OverlaySettings.Calls;Handle(Snapshot(8).Stringify());Check(!third.Task.IsCompleted&&OverlaySettings.Calls==before,"Older standalone snapshot must not settle pending command");
            bool rejected=false;try{Handle(Result("wrong-id",7));}catch(InvalidDataException){rejected=true;}Check(rejected&&!third.Task.IsCompleted&&(string)Get("pending")=="request-c","Unknown receipt ID must be rejected even when its snapshot is old");
            rejected=false;try{Handle(Result("request-c",13,true,"other-epoch"));}catch(InvalidDataException){rejected=true;}Check(rejected&&!third.Task.IsCompleted,"Wrong-epoch acknowledgement must not settle current operation");
            Handle(Result("request-c",12));Check(third.Task.IsCompletedSuccessfully,"Valid acknowledgement after rejected frame still settles current operation");
            Check(Log.Lines.Count(line=>line.StartsWith("overlay connected "))==1&&Log.Lines.Count(line=>line.StartsWith("overlay settings result "))==3,"Diagnostics must be bounded to first connection and settings receipts");
            var busy=Pending("heartbeat");
            Check(!OverlaySync.TryRequestAsync("chat.send",OverlaySync.Args("text","unsent"),out var refused)&&refused.IsCompletedSuccessfully&&refused.Result==null,"A busy local transport must report not dispatched synchronously");
            Check(!busy.Task.IsCompleted&&(string)Get("pending")=="heartbeat","A refused send must not replace another command or its receipt");
            Handle(Result("heartbeat",13));
            Set("pipe",new System.IO.Pipes.NamedPipeClientStream("unused-overlay-fixture"));
            Check(OverlaySync.TryRequestAsync("chat.send",OverlaySync.Args("text","accepted"),out var accepted)&&!accepted.IsCompleted,"An admitted send owns an asynchronous receipt");
            string sendId=(string)Get("pending");Handle(Result(sendId,14));
            Check(accepted.IsCompletedSuccessfully&&accepted.Result.GetNamedBoolean("ok"),"Only the matching admitted request settles its receipt");
            Console.WriteLine("13 actual OverlaySync stale-ack/epoch/admission/diagnostic checks passed");
        }
    }
}
