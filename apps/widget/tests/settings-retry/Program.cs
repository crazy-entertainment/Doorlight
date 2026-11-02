using System;
using System.Collections.Generic;
using System.Linq;
using System.Reflection;
using System.Threading.Tasks;
namespace Windows.Data.Json {
    enum JsonValueType { String,Number,Boolean,Object }
    interface IJsonValue { JsonValueType ValueType{get;} string GetString();bool GetBoolean();double GetNumber();JsonObject GetObject(); }
    class JsonValue:IJsonValue {readonly object value;public JsonValue(object value){this.value=value;}public JsonValueType ValueType=>value is string?JsonValueType.String:value is bool?JsonValueType.Boolean:JsonValueType.Number;public string GetString()=>(string)value;public bool GetBoolean()=>(bool)value;public double GetNumber()=>Convert.ToDouble(value);public JsonObject GetObject()=>throw new Exception();}
    class JsonObject:Dictionary<string,IJsonValue>,IJsonValue {public JsonValueType ValueType=>JsonValueType.Object;public string GetString()=>throw new Exception();public bool GetBoolean()=>throw new Exception();public double GetNumber()=>throw new Exception();public JsonObject GetObject()=>this;public static JsonObject Parse(string value)=>throw new NotSupportedException("Transport parsing is covered separately");public bool GetNamedBoolean(string key,bool fallback)=>TryGetValue(key,out var value)?value.GetBoolean():fallback;public double GetNamedNumber(string key)=>this[key].GetNumber();public JsonObject GetNamedObject(string key)=>(JsonObject)this[key];}
}
namespace Windows.Storage {class ApplicationData {public static readonly ApplicationData Current=new();public readonly Container LocalSettings=new();}class Container {public readonly Dictionary<string,object> Values=new();}}
namespace WidgetSampleCS {
    using Windows.Data.Json;
    static class Cfg {public static string[] Changed;public static void Refresh(params string[] keys){Changed=keys;}public static void Set(string key,object value)=>OverlaySettings.Values[key]=value;public static void ApplyAppearance(AppearanceValues value,bool force){}}
    static class Log {public static void Write(string value){}}
    static class OverlaySync {
        internal static void ReportUserActivity() { }
        public static JsonObject State;public static bool Writable=true;public static string Error;public static int Calls;public static JsonObject LastArgs;public static event Action Changed;
        public static Task<JsonObject> PendingCompletion=>Task.FromResult<JsonObject>(null);
        public static IJsonValue Scalar(object value)=>value as IJsonValue??new JsonValue(value);
        public static JsonObject Args(params object[] pairs){var result=new JsonObject();for(int i=0;i<pairs.Length;i+=2)result[(string)pairs[i]]=Scalar(pairs[i+1]);return result;}
        public static bool Request(string command,JsonObject args){Calls++;LastArgs=args;return true;}
        public static void SetError(string error){Error=error;}
        public static void Notify()=>Changed?.Invoke();
    }
    static class Program {
        static int checks;
        static void Check(bool pass,string label){if(!pass)throw new Exception(label);checks++;}
        static JsonObject Snapshot(int revision,double width,string name="A")=>OverlaySync.Args("settingsRevision",revision,"imported",true,"settings",OverlaySync.Args("chat.width",width,"clock.item.first.name",name));
        static void Accept(int revision,double width,bool completion=false,bool ok=true,string name="A"){OverlaySync.State=Snapshot(revision,width,name);OverlaySettings.Accept(OverlaySync.State,completion,ok);}
        static void Flush()=>typeof(OverlaySettings).GetMethod("Flush",BindingFlags.Static|BindingFlags.NonPublic).Invoke(null,null);
        static double Width=>OverlaySettings.Read("chat.width",0d);
        static double SentWidth=>OverlaySync.LastArgs.GetNamedObject("values").GetNamedNumber("chat.width");
        static void Main(){
            OverlaySettings.Values["hotkey.chat.quick"]="Ctrl+Alt+C";
            OverlaySync.Writable=false;OverlaySettings.Rollback();
            Check(OverlaySettings.Read("hotkey.chat.quick","")=="Ctrl+Alt+C","Pre-import disconnect must retain prepared constructor defaults");
            Check(!OverlaySettings.RetryRequired,"Prepared defaults must not become an uncertain submitted transaction");
            string timerId=Guid.NewGuid().ToString("N");
            OverlaySettings.Values["crossPresets.ids"]="original";
            OverlaySettings.Values["crossPresets.original.window"]="Cross";
            OverlaySettings.Values["weatherInstances.ids"]="original";
            OverlaySettings.Values["weatherInstances.original.window"]="Weather";
            OverlaySettings.Values["timer.activeId"]=timerId;
            OverlaySettings.Values["timer.records.v2"]=timerId+"|Timer|Countdown|Duration|900000|900000|0|0|0|0|1|Minutes,,;,,%3A;Seconds,,";
            OverlaySettings.Rollback();OverlaySettings.Rollback();
            Check(OverlaySettings.Read("crossPresets.ids","")=="original"&&OverlaySettings.Read("crossPresets.original.window","")=="Cross","Lazy crosshair identity and extension must survive repeated offline connection failures");
            Check(OverlaySettings.Read("weatherInstances.ids","")=="original"&&OverlaySettings.Read("weatherInstances.original.window","")=="Weather","Lazy weather identity and extension must survive offline initialization");
            Check(OverlaySettings.Read("timer.activeId","")==timerId&&OverlaySettings.Read("timer.records.v2","").StartsWith(timerId+"|"),"Lazy timer identity and records must remain stable before first snapshot");
            Check(OverlaySync.Calls==0&&Windows.Storage.ApplicationData.Current.LocalSettings.Values["timer.activeId"].Equals(timerId),"Offline defaults must persist locally without faking a desktop acknowledgement");
            OverlaySync.State=OverlaySync.Args("settingsRevision",0,"imported",false,"settings",new JsonObject());
            OverlaySettings.Accept(OverlaySync.State,false);
            OverlaySettings.Values["timer.activeId"]="unapproved";
            Check(OverlaySync.Calls==0&&OverlaySettings.Read("timer.activeId","")==timerId,"First read-only snapshot must seal initialization and refuse further local writes");
            OverlaySync.Writable=true;OverlaySync.Notify();
            Check(OverlaySync.Calls==1&&OverlaySync.LastArgs.GetNamedObject("values")["hotkey.chat.quick"].GetString()=="Ctrl+Alt+C","First import must include defaults retained across failed initial connection");
            Check(OverlaySync.LastArgs.GetNamedObject("values")["timer.activeId"].GetString()==timerId,"First import must publish the same prepared lazy timer identity");
            OverlaySync.State=Snapshot(1,400);
            OverlaySync.State.GetNamedObject("settings")["hotkey.chat.quick"]=new JsonValue("Ctrl+Alt+C");
            OverlaySettings.Accept(OverlaySync.State,true,true);
            Accept(1,400);OverlaySettings.Values["chat.width"]=500d;Flush();
            Check(SentWidth==500,"Queued document must contain edited value");
            Accept(1,400,true,false);Check(Width==400&&OverlaySettings.RetryRequired,"Failure rolls visible cache back and retains retry");
            OverlaySettings.Retry();Check(SentWidth==500,"Explicit retry must resend retained unsaved value");Accept(2,500,true,true);Check(Width==500&&!OverlaySettings.RetryRequired,"Only successful acknowledgement clears retry");
            OverlaySettings.Values["chat.width"]=600d;Accept(3,500,name:"B");Check(Width==600&&SentWidth==600,"Unrelated canonical update must preserve pending edit");
            Accept(3,500,true,false,"B");OverlaySettings.Retry();Check(SentWidth==600&&OverlaySync.LastArgs.GetNamedObject("values")["clock.item.first.name"].GetString()=="B","Retry must retain fresh unrelated canonical values");Accept(4,600,true,true,"B");
            OverlaySettings.Values["chat.width"]=650d;Flush();OverlaySync.Writable=false;OverlaySettings.Rollback();Check(Width==600&&OverlaySettings.RetryRequired,"Disconnect must retain queued retry while rolling back cache");
            OverlaySync.Writable=true;Accept(4,600,name:"B");OverlaySettings.Retry();Check(SentWidth==650,"Reconnect retry must retain timed-out candidate");Accept(5,650,true,true,"B");
            OverlaySettings.Values["chat.width"]=700d;Flush();Accept(6,675,true,false,"B");int before=OverlaySync.Calls;OverlaySettings.Retry();Check(OverlaySync.Calls==before&&Width==675&&OverlaySettings.RetryRequired,"Same-key conflict must not overwrite newer desktop value");
            OverlaySettings.Values["chat.width"]=750d;Flush();Accept(7,750,true,true,"B");
            OverlaySettings.Values["chat.width"]=800d;Flush();OverlaySettings.Values["chat.width"]=850d;Accept(8,800,true,true,"B");Check(Width==850&&SentWidth==850,"Acknowledgement must preserve a later edit without false conflict");Accept(9,850,true,true,"B");
            Check(Cfg.Changed.Contains("chat.width"),"Canonical rollback must emit actual affected key");
            OverlaySettings.Values["chat.width"]=900d;
            OverlaySync.Writable=false;OverlaySettings.Rollback();
            Check(Width==850&&OverlaySettings.RetryRequired,"Disconnect before debounce must retain an unsent edit for explicit retry");
            OverlaySync.Writable=true;Accept(9,850,name:"B");OverlaySettings.Retry();
            Check(SentWidth==900,"Reconnect retry must send the edit that never reached the transport");
            Accept(10,900,true,true,"B");Check(Width==900&&!OverlaySettings.RetryRequired,"Acknowledging an unsent-edit retry must clear its recovery state");
            OverlaySync.State=null;OverlaySync.Writable=false;OverlaySettings.Rollback();
            int offlineCalls=OverlaySync.Calls;
            OverlaySettings.Values["chat.width"]=910d;OverlaySettings.Values["helper.theme"]="midnight";
            OverlaySettings.Rollback();OverlaySettings.Rollback();
            Check(Width==910&&OverlaySettings.Editable&&OverlaySync.Calls==offlineCalls,"Repeated offline discovery must not disable editing or roll back local preferences");
            Check(Windows.Storage.ApplicationData.Current.LocalSettings.Values["chat.width"].Equals(910d),"Offline edits must be durable before desktop reconnect");
            OverlaySettings.Values.RawSet("chat.width",0d);
            typeof(OverlaySettings).GetMethod("LoadLocal",BindingFlags.Static|BindingFlags.NonPublic).Invoke(null,null);
            Check(Width==910&&OverlaySettings.Read("helper.theme","")=="midnight","Restart must restore local utility and appearance preferences");
            OverlaySync.Writable=true;Accept(11,900,name:"C");Flush();
            Check(Width==910&&SentWidth==910&&OverlaySync.LastArgs.GetNamedObject("values")["clock.item.first.name"].GetString()=="C","Reconnect must merge offline edits with unrelated fresh desktop changes");
            Check(!OverlaySync.LastArgs.GetNamedObject("values").Keys.Any(key=>key.StartsWith("overlay.")),"Local merge metadata must never enter desktop settings transactions");
            Accept(12,910,true,true,"C");
            OverlaySync.State=null;OverlaySync.Writable=false;OverlaySettings.Rollback();
            OverlaySettings.Values["chat.width"]=920d;
            OverlaySync.Writable=true;Accept(13,930,name:"C");
            Check(Width==930&&OverlaySync.Error!=null,"Reconnect must not overwrite a conflicting newer desktop value");
            OverlaySync.Writable=false;OverlaySync.Notify();OverlaySettings.Values["chat.width"]=940d;
            Check(Width==930&&!OverlaySettings.Editable,"A connected read-only desktop must still refuse edits");
            Check(AppearanceSync.Editable&&AppearanceSync.Request("theme","midnight")&&OverlaySettings.Read("helper.theme","")=="midnight","Offline appearance changes must use local settings");
            Check(AppearanceSync.Request("vibe","rain")&&AppearanceSync.Request("vibeIntensity",42)&&AppearanceSync.Request("vibeOpacity",65)&&AppearanceSync.Request("vibeAnimated",false),"All appearance controls must save offline");
            Check(Windows.Storage.ApplicationData.Current.LocalSettings.Values["helper.vibeIntensity"].Equals(42)&&Windows.Storage.ApplicationData.Current.LocalSettings.Values["helper.vibeAnimated"].Equals(false),"Offline appearance must survive restart");
            Check(!AppearanceSync.Request("theme","invalid")&&!AppearanceSync.Request("vibeOpacity",101)&&!AppearanceSync.Request("consent",true),"Offline appearance must retain protocol value/field validation");
            var session=(AppearanceSession)typeof(AppearanceSync).GetField("session",BindingFlags.Static|BindingFlags.NonPublic).GetValue(null);
            session.Snapshot(new AppearanceSnapshot{Epoch=Guid.NewGuid().ToString(),Revision=0,Writable=false});
            Check(!AppearanceSync.Editable&&!AppearanceSync.Request("theme","cozy"),"Connected read-only appearance must not escape into the offline save path");session.Disconnect();
            OverlaySync.State=null;OverlaySettings.Rollback();OverlaySettings.Values["chat.width"]=940d;
            OverlaySync.Writable=true;OverlaySync.Error=null;int matchingCalls=OverlaySync.Calls;Accept(14,940,name:"C");
            Check(Width==940&&OverlaySync.Error==null&&OverlaySync.Calls==matchingCalls,"A matching offline/desktop value must settle quietly without a conflict or redundant save");
            Console.WriteLine(checks+" actual OverlaySettings initialization/save/retry/merge checks passed");
        }
    }
}
