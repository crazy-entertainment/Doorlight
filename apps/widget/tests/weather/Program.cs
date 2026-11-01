using System.Net;
using System.Text;
using System.Text.Json;
using WidgetSampleCS;

// Platform JSON adapter only; production framing, bounds, field validation and HTTP code are linked above.
namespace Windows.Data.Json {
    class JsonValue {
        internal JsonElement Value; internal JsonValue(JsonElement value){Value=value;}
        public string GetString()=>Value.GetString(); public JsonObject GetObject()=>new(Value);
    }
    class JsonArray:List<JsonValue>{internal JsonArray(JsonElement value):base(value.EnumerateArray().Select(item=>new JsonValue(item))){} }
    class JsonObject {
        readonly JsonElement value; internal JsonObject(JsonElement element){value=element.Clone();}
        public static JsonObject Parse(string text){using var doc=JsonDocument.Parse(text);return new(doc.RootElement);}
        public bool ContainsKey(string key)=>value.TryGetProperty(key,out _);
        public string GetNamedString(string key)=>value.GetProperty(key).GetString();
        public string GetNamedString(string key,string fallback)=>ContainsKey(key)?GetNamedString(key):fallback;
        public double GetNamedNumber(string key)=>value.GetProperty(key).GetDouble();
        public JsonObject GetNamedObject(string key)=>new(value.GetProperty(key));
        public JsonArray GetNamedArray(string key)=>new(value.GetProperty(key));
    }
}
class Handler:HttpMessageHandler {
    internal HttpContent Body; internal HttpStatusCode Status=HttpStatusCode.OK;
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request,CancellationToken token){token.ThrowIfCancellationRequested();return Task.FromResult(new HttpResponseMessage(Status){Content=Body});}
}
class UnknownLengthContent:HttpContent {
    readonly Stream stream; internal UnknownLengthContent(Stream value){stream=value;}
    protected override bool TryComputeLength(out long length){length=0;return false;}
    protected override Task SerializeToStreamAsync(Stream target,TransportContext context)=>stream.CopyToAsync(target);
    protected override Task<Stream> CreateContentReadStreamAsync()=>Task.FromResult(stream);
    protected override void Dispose(bool disposing){if(disposing)stream.Dispose();base.Dispose(disposing);}
}
class SlowStream:MemoryStream {
    public override async Task<int> ReadAsync(byte[] buffer,int offset,int count,CancellationToken token){await Task.Delay(Timeout.Infinite,token);return 0;}
}
static class Program {
    static int checks;
    static readonly Uri ForecastUri=new("https://api.open-meteo.com/v1/forecast");
    static void Check(bool condition,string description){if(!condition)throw new Exception(description);checks++;}
    static async Task Reject(Func<Task> action,string description){try{await action();}catch(Exception ex)when(ex is InvalidDataException||ex is DecoderFallbackException||ex is HttpRequestException||ex is OperationCanceledException){checks++;return;}throw new Exception(description);}
    static void RejectJson(Action action,string description){try{action();}catch(Exception ex)when(ex is InvalidDataException||ex is ArgumentException||ex is JsonException){checks++;return;}throw new Exception(description);}
    static string Place(string name="Zürich")=>JsonSerializer.Serialize(new{name,country="Switzerland",country_code="CH",latitude=47.37,longitude=8.54,admin1="Zürich",postcodes=new[]{"8001","8002"}});
    static async Task Main(){
        var normal=WeatherData.Places("{\"results\":["+Place()+"]}");
        Check(normal.Count==1&&normal[0].Name=="Zürich"&&normal[0].FlagCode=="ch"&&normal[0].Postcodes.Length==2,"Legitimate Unicode locations preserve fields");
        Check(WeatherData.Places("{}").Count==0,"Missing results means no matches");
        Check(WeatherData.Places("{\"results\":["+string.Join(',',Enumerable.Repeat(Place(),100))+"]}").Count==100,"All 100 supported results remain available");
        RejectJson(()=>WeatherData.Places("{\"results\":["+string.Join(',',Enumerable.Repeat(Place(),101))+"]}"),"Reject surplus results rather than silently truncating");
        RejectJson(()=>WeatherData.Places("{\"results\":["+Place(new string('x',129))+"]}"),"Bound displayed provider strings");
        RejectJson(()=>WeatherData.Places("{\"results\":["+Place("bad\nname")+"]}"),"Refuse provider control characters");
        RejectJson(()=>WeatherData.Places("{\"results\":["+Place().Replace("47.37","91")+"]}"),"Reject out-of-range latitude");
        RejectJson(()=>WeatherData.Places("{\"results\":["+Place().Replace("8.54","181")+"]}"),"Reject out-of-range longitude");
        var manyCodes=Place().Replace("[\"8001\",\"8002\"]",JsonSerializer.Serialize(Enumerable.Repeat("8001",33)));
        RejectJson(()=>WeatherData.Places("{\"results\":["+manyCodes+"]}"),"Reject surplus postcodes");
        Check(WeatherData.Forecast("{\"current\":{\"weather_code\":3,\"is_day\":1,\"temperature_2m\":21.2}}").Temperature==21.2,"Legitimate forecast remains usable");
        RejectJson(()=>WeatherData.Forecast("{\"current\":{\"weather_code\":3.5,\"is_day\":1,\"temperature_2m\":21}}"),"Reject fractional weather code");
        RejectJson(()=>WeatherResponse.Validate(new string('[',13)+new string(']',13)),"Reject deep JSON before platform parsing");
        RejectJson(()=>WeatherResponse.Validate("{\"x\":\""+new string('x',4097)+"\"}"),"Reject oversized escaped/unknown JSON strings");
        Check(WeatherResponse.Validate("{\"x\":\"\\\"[\\\\]\\\"\"}").Length>0,"Quotes, escapes and brackets inside strings do not change nesting");
        RejectJson(()=>WeatherPlace.SearchUrl(new string('x',129)),"Bound outgoing queries");
        Check(WeatherPlace.SearchUrl("Zürich & region").EndsWith("Z%C3%BCrich%20%26%20region"),"Queries remain encoded");
        using var handler=new Handler();using var client=new HttpClient(handler);
        handler.Body=new StringContent("{\"current\":{}}",Encoding.UTF8);
        Check(await WeatherResponse.FetchAsync(client,ForecastUri,CancellationToken.None)=="{\"current\":{}}","Transport accepts a normal JSON response");
        handler.Body=new ByteArrayContent(new byte[WeatherResponse.MaxBytes+1]);
        await Reject(()=>WeatherResponse.FetchAsync(client,ForecastUri,CancellationToken.None),"Reject oversized declared Content-Length");
        var oversized=new MemoryStream(new byte[WeatherResponse.MaxBytes+10000]);handler.Body=new UnknownLengthContent(oversized);
        await Reject(()=>WeatherResponse.FetchAsync(client,ForecastUri,CancellationToken.None),"Reject oversized chunked/unknown-length body");
        handler.Body=new UnknownLengthContent(new MemoryStream(new byte[]{0xff,0xfe}));
        await Reject(()=>WeatherResponse.FetchAsync(client,ForecastUri,CancellationToken.None),"Reject malformed UTF-8");
        handler.Body=new StringContent("{}");handler.Status=HttpStatusCode.BadGateway;
        await Reject(()=>WeatherResponse.FetchAsync(client,ForecastUri,CancellationToken.None),"Reject error responses");handler.Status=HttpStatusCode.OK;
        handler.Body=new UnknownLengthContent(new SlowStream());
        using(var cancel=new CancellationTokenSource(40))await Reject(()=>WeatherResponse.FetchAsync(client,ForecastUri,cancel.Token),"Cancel stalled obsolete response reads");
        handler.Body=new UnknownLengthContent(new SlowStream());var start=DateTime.UtcNow;
        await Reject(()=>WeatherResponse.FetchAsync(client,ForecastUri,CancellationToken.None),"Deadline covers stalled body as well as headers");
        Check(DateTime.UtcNow-start<TimeSpan.FromSeconds(15),"Stalled response obeys 12-second deadline");
        await Reject(()=>WeatherResponse.FetchAsync(client,new Uri("https://unapproved.example/"),CancellationToken.None),"Refuse an unapproved origin");
        Console.WriteLine($"{checks} production weather boundary checks passed");
    }
}
