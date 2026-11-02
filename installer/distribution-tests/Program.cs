using System.Buffers.Binary;
using System.Diagnostics;
using System.IO.Compression;
using System.Net;
using System.Net.Sockets;
using System.Reflection;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Doorlight.Setup;

if (args.Length != 2) throw new ArgumentException("Pass scratch and fixture verifier paths.");
var scratch = Path.Combine(Path.GetFullPath(args[0]), "run-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(scratch);
InstalledApp.Root = Path.Combine(scratch, "install");
var verifier = Path.GetFullPath(args[1]);
var verifierHash = Hash(File.ReadAllBytes(verifier));
var checks = 0;
void Check(bool condition, string message) { if (!condition) throw new Exception(message); checks++; }
async Task Reject(Func<Task> action, string message)
{
    try { await action(); } catch (Exception error) when (error is InvalidDataException or IOException or InvalidOperationException) { checks++; return; }
    throw new Exception(message);
}
string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();

// Header-valid fixtures are never executed; actual startup is simulated below.
var pe = new byte[512];
BinaryPrimitives.WriteUInt16LittleEndian(pe, 0x5a4d); BinaryPrimitives.WriteInt32LittleEndian(pe.AsSpan(60),128);
BinaryPrimitives.WriteUInt32LittleEndian(pe.AsSpan(128),0x4550); BinaryPrimitives.WriteUInt16LittleEndian(pe.AsSpan(132),0x8664);
BinaryPrimitives.WriteUInt16LittleEndian(pe.AsSpan(148),240); BinaryPrimitives.WriteUInt16LittleEndian(pe.AsSpan(150),2);
BinaryPrimitives.WriteUInt16LittleEndian(pe.AsSpan(152),0x20b); BinaryPrimitives.WriteUInt32LittleEndian(pe.AsSpan(184),4096);
BinaryPrimitives.WriteUInt32LittleEndian(pe.AsSpan(188),512); BinaryPrimitives.WriteUInt32LittleEndian(pe.AsSpan(208),4096);
BinaryPrimitives.WriteUInt32LittleEndian(pe.AsSpan(212),512); BinaryPrimitives.WriteUInt32LittleEndian(pe.AsSpan(260),16);
var content = new Dictionary<string,byte[]> { ["sybl.exe"]=pe, ["_setup/DoorlightUpdater.exe"]=pe, ["Doorlight.version"]=Encoding.UTF8.GetBytes("1.2.3") };
var manifest = new PackageManifest(1,"1.2.3",content.Select(item=>new PackageFile(item.Key,item.Value.Length,Hash(item.Value))).ToArray());
var manifestPath=Path.Combine(scratch,"manifest.json");
File.WriteAllBytes(manifestPath,JsonSerializer.SerializeToUtf8Bytes(manifest,CoreJsonContext.Default.PackageManifest));
var package=Path.Combine(scratch,"package.nupkg");
using (var archive=ZipFile.Open(package,ZipArchiveMode.Create))
    foreach(var item in content) { using var stream=archive.CreateEntry("lib/app/"+item.Key).Open(); stream.Write(item.Value); }
var zipPackage=Path.Combine(scratch,"package.zip");
using (var archive=ZipFile.Open(zipPackage,ZipArchiveMode.Create))
    foreach(var item in content) { using var stream=archive.CreateEntry(item.Key).Open(); stream.Write(item.Value); }
var served=Path.Combine(scratch,"served"); Directory.CreateDirectory(served);
using var server=new FixtureServer(served);

async Task<(DistributionRuntime Runtime,string State,string Repo)> Runtime(string name,bool enabled=true,string format="velopack")
{
    var input=Path.Combine(scratch,name+".json"); var repo=Path.Combine(served,name);
    var deltas=format=="zip"?"[]":$$$"""
        [{"baseVersion":"1.0.0","basePackageSha256":"{{{new string('a',64)}}}","baseManifestSha256":"{{{new string('b',64)}}}",
        "patch":{"url":"{{{server.Url+name}}}/missing-delta","length":1,"sha256":"{{{new string('c',64)}}}"}}]
        """;
    File.WriteAllText(input,$$$"""
        {"schema":1,"product":"Doorlight","channel":"stable","platform":"windows-x64","releaseSequence":1,"version":"1.2.3",
        "minimumUpdaterVersion":"1.0.0","enabled":{{{enabled.ToString().ToLowerInvariant()}}},"rolloutBasisPoints":10000,"salt":"fixture",
        "manifest":{"url":"https://example.invalid/manifest","length":1,"sha256":"{{{new string('0',64)}}}"},
        "fullPackage":{"url":"https://example.invalid/package","length":1,"sha256":"{{{new string('0',64)}}}","format":"{{{format}}}"},
        "deltas":{{{deltas}}}}
        """,new UTF8Encoding(false));
    var start=new ProcessStartInfo(verifier){UseShellExecute=false,CreateNoWindow=true};
    foreach(var a in new[]{"fixture","--policy-file",input,"--repository-dir",repo,"--manifest-file",manifestPath,"--package-file",format=="zip"?zipPackage:package,"--artifact-base-url",server.Url+name+"/artifacts"}) start.ArgumentList.Add(a);
    using(var process=Process.Start(start)??throw new Exception("fixture builder failed")) { await process.WaitForExitAsync(); Check(process.ExitCode==0,"signed fixture generation failed"); }
    var root=File.ReadAllBytes(Path.Combine(repo,"bootstrap.root.json"));
    var config=new DistributionConfig(1,server.Url+name+"/metadata",server.Url+name+"/targets",Hash(root),verifierHash,new FileInfo(verifier).Length,"1.0.0");
    var configBytes=JsonSerializer.SerializeToUtf8Bytes(config,DistributionJsonContext.Default.DistributionConfig);
    File.WriteAllBytes(Path.Combine(scratch,name+".config.json"),configBytes);
    Stream? Resources(string resource)=>resource switch {
        "Doorlight.Feed.json"=>new MemoryStream(configBytes,false),
        "Doorlight.Trust.Root.json"=>new MemoryStream(root,false),
        _=>Assembly.GetExecutingAssembly().GetManifestResourceStream(resource),
    };
    var state=Path.Combine(scratch,name+"-state");
    return(DistributionRuntime.LoadFixture(state,Resources),state,repo);
}

var live=await Runtime("enabled");
Check(live.Runtime.IsConfigured,"configured feed absent");
var decision=await live.Runtime.Check("1.0.0",false)??throw new Exception("no decision");
Check(decision.Eligible,"signed policy not eligible");
var receiptPath=Path.Combine(live.State,"accepted-base.json");
Check(!File.Exists(receiptPath),"check wrote accepted base");
// Corrupt optional receipt forces the full authenticated package path.
File.WriteAllText(receiptPath,"broken optional cache",new UTF8Encoding(false));
var prepared=await live.Runtime.Prepare(decision,"1.0.0");
Check(!prepared.UsedDelta && PackageStage.ReadVersion(prepared.StageDirectory)=="1.2.3","delta fallback/full preparation failed");
Check(File.ReadAllText(receiptPath)=="broken optional cache","preparation prematurely accepted base");
Check(!(await live.Runtime.Accept(prepared)),"accepted cache before installed bundle existed");
Check((await live.Runtime.Refresh(prepared,"1.0.0",false)).Eligible,"fresh handoff policy failed");
server.TimestampDelay=TimeSpan.FromMilliseconds(600);
using(var deadline=new CancellationTokenSource())
{
    var refresh=live.Runtime.Refresh(prepared,"1.0.0",false,deadline.Token);
    await server.DelayedStarted.Task.WaitAsync(TimeSpan.FromSeconds(5));
    deadline.CancelAfter(TimeSpan.FromMilliseconds(100));
    try { await refresh; throw new Exception("slow refresh ignored cancellation"); }
    catch(OperationCanceledException) { checks++; }
}
server.TimestampDelay=TimeSpan.Zero;
Check(server.DelayedRequests>0,"refresh was cancelled before reaching slow metadata server");
Check(Directory.Exists(prepared.StageDirectory)&&PackageStage.ReadVersion(prepared.StageDirectory)=="1.2.3"&&!Directory.Exists(Path.Combine(InstalledApp.Root,"current")),"cancelled refresh altered stage/install");
var changed=prepared with { Decision=decision with { Release=decision.Release with { Policy=decision.Release.Policy with { Manifest=decision.Release.Policy.Manifest with { Sha256=new string('d',64) } } } } };
Check(!(await live.Runtime.Refresh(changed,"1.0.0",false)).Eligible,"prepared manifest binding change accepted");

// Use the real bundle journal; no synthetic executable or actual app is launched.
var transaction=BundleInstall.Apply(InstalledApp.Root,prepared.StageDirectory,prepared.Policy.Version);
BundleInstall.Accept(InstalledApp.Root,transaction.Id);
Check(await live.Runtime.Accept(prepared),"accepted verified base was not cached");
var saved=JsonSerializer.Deserialize(File.ReadAllBytes(receiptPath),DistributionJsonContext.Default.AcceptedDistributionBase)!;
Check(saved.Receipt.OriginalPackageSha256==prepared.Policy.FullPackage.Sha256 && saved.Receipt.CachedPackageSha256==prepared.ActualPackageSha256,"base receipt identities incorrect");

// Cache maintenance preserves accepted bytes, active transfers and unknown files.
var artifacts=Path.Combine(live.State,"artifacts");
var old=Path.Combine(artifacts,new string('e',64)+".blob");
var active=Path.Combine(artifacts,new string('f',64)+".partial");
var unknown=Path.Combine(artifacts,"user-file.blob");
foreach(var p in new[]{old,active,unknown}) { File.WriteAllText(p,"fixture"); File.SetLastWriteTimeUtc(p,DateTime.UtcNow.AddDays(-30)); }
using(var locked=new FileStream(Path.Combine(artifacts,new string('f',64)+".lock"),FileMode.OpenOrCreate,FileAccess.ReadWrite,FileShare.None))
{
    Check(await live.Runtime.Accept(prepared),"optional maintenance failed acceptance");
    Check(!File.Exists(old),"stale known cache retained");
    Check(File.Exists(active),"locked partial deleted");
    Check(File.Exists(unknown),"unknown file deleted");
    Check(File.Exists(prepared.PackagePath)&&File.Exists(prepared.ManifestPath),"accepted base pruned");
}

// ZIP acceptance maintains its cache; its receipt cannot authorize a Velopack base.
var zip=await Runtime("zip",format:"zip");
var zipDecision=await zip.Runtime.Check("0.0.0",true)??throw new Exception("missing ZIP decision");
var zipPrepared=await zip.Runtime.Prepare(zipDecision,"1.2.3");
var zipTransaction=BundleInstall.Apply(InstalledApp.Root,zipPrepared.StageDirectory,zipPrepared.Policy.Version,allowRepair:true);
BundleInstall.Accept(InstalledApp.Root,zipTransaction.Id);
var zipArtifacts=Path.Combine(zip.State,"artifacts");
var zipStale=Path.Combine(zipArtifacts,new string('e',64)+".blob");
var zipActive=Path.Combine(zipArtifacts,new string('f',64)+".partial");
foreach(var path in new[]{zipStale,zipActive})File.WriteAllText(path,"fixture");
foreach(var path in new[]{zipStale,zipActive,zipPrepared.PackagePath,zipPrepared.ManifestPath})File.SetLastWriteTimeUtc(path,DateTime.UtcNow.AddDays(-30));
using(var locked=new FileStream(Path.Combine(zipArtifacts,new string('f',64)+".lock"),FileMode.OpenOrCreate,FileAccess.ReadWrite,FileShare.None))
{
    Check(await zip.Runtime.Accept(zipPrepared),"ZIP acceptance cache maintenance failed");
    Check(!File.Exists(zipStale),"ZIP acceptance skipped stale artifact pruning");
    Check(File.Exists(zipActive),"ZIP acceptance pruned active transfer");
    Check(File.Exists(zipPrepared.PackagePath)&&File.Exists(zipPrepared.ManifestPath),"ZIP acceptance pruned current package/manifest");
    var zipReceipt=JsonSerializer.Deserialize(File.ReadAllBytes(Path.Combine(zip.State,"accepted-base.json")),DistributionJsonContext.Default.AcceptedDistributionBase)!.Receipt;
    Check(zipReceipt.CachedPackageSha256==zipPrepared.ActualPackageSha256,"ZIP receipt changed accepted artifact identity");
    await Reject(()=>{DeltaPackage.VerifyBase(zipPrepared.PackagePath,File.ReadAllBytes(zipPrepared.ManifestPath),zipReceipt,
        new(zipReceipt.Version,zipReceipt.OriginalPackageSha256,zipReceipt.ManifestSha256),"Doorlight");return Task.CompletedTask;},"ZIP receipt authorized a Velopack delta base");
}

var halted=await Runtime("halted",enabled:false);
var halt=await halted.Runtime.Check("1.0.0",true)??throw new Exception("no halt decision");
Check(!halt.Eligible&&halt.Reason=="halted","signed halt bypassed manually");
await Reject(()=>halted.Runtime.Prepare(halt,"1.0.0"),"halted policy prepared");
// Cleanup after preparation/cancellation owns only the codec's reconstructed file.
var reconstructed=Path.Combine(InstalledApp.Root,".full-"+Guid.NewGuid().ToString("N")+".nupkg");
File.WriteAllText(reconstructed,"disposable reconstruction");
var disposable=prepared with { UsedDelta=true,PackagePath=reconstructed };
Check(DistributionRuntime.Discard(disposable)&&!File.Exists(reconstructed),"owned reconstruction leaked");
Check(DistributionRuntime.Discard(disposable),"already discarded reconstruction failed cleanup");
Check(DistributionRuntime.Discard(prepared)&&File.Exists(prepared.PackagePath),"full cached package was discarded");
Check(!DistributionRuntime.Discard(prepared with { UsedDelta=true })&&File.Exists(prepared.PackagePath),"mislabelled cache path was deleted");
var outside=Path.Combine(scratch,".full-"+Guid.NewGuid().ToString("N")+".nupkg");
File.WriteAllText(outside,"outside ownership");
Check(!DistributionRuntime.Discard(prepared with { UsedDelta=true,PackagePath=outside })&&File.Exists(outside),"outside reconstruction path was deleted");
var original=Path.Combine(InstalledApp.Root,"original.nupkg");File.WriteAllText(original,"original archive");
Check(!DistributionRuntime.Discard(prepared with { UsedDelta=true,PackagePath=original })&&File.Exists(original),"non-owned original archive was deleted");
Check(File.Exists(receiptPath)&&Directory.Exists(Path.Combine(InstalledApp.Root,"current")),"discard touched accepted state");
// A bad cached verifier is never replaced or executed silently.
var extracted=Path.Combine(live.State,"tools",verifierHash+".exe");
File.WriteAllBytes(extracted,[1,2,3]);
await Reject(()=>live.Runtime.Check("1.0.0",false),"tampered extracted verifier accepted");
Console.WriteLine($"PASS: {checks} configured distribution assertions. Synthetic startup acceptance only; no app launched. Scratch: {scratch}");

namespace Doorlight.Setup { internal static class InstalledApp { internal static string Root { get; set; } = ""; } }

sealed class FixtureServer : IDisposable
{
    private readonly HttpListener listener=new(); private readonly Task serving;
    internal string Url {get;}
    internal TimeSpan TimestampDelay {get;set;}
    internal int DelayedRequests {get;private set;}
    internal TaskCompletionSource DelayedStarted {get;}=new(TaskCreationOptions.RunContinuationsAsynchronously);
    internal FixtureServer(string root)
    {
        var socket=new TcpListener(IPAddress.Loopback,0); socket.Start(); var port=((IPEndPoint)socket.LocalEndpoint).Port; socket.Stop();
        Url=$"http://127.0.0.1:{port}/"; listener.Prefixes.Add(Url); listener.Start();
        serving=Task.Run(async()=>{
            while(listener.IsListening) {
                HttpListenerContext context;
                try { context=await listener.GetContextAsync(); } catch(Exception e)when(e is HttpListenerException or ObjectDisposedException){break;}
                try {
                    if(context.Request.Url!.AbsolutePath.EndsWith("timestamp.json",StringComparison.Ordinal)&&TimestampDelay>TimeSpan.Zero){DelayedRequests++;DelayedStarted.TrySetResult();await Task.Delay(TimestampDelay);}
                    var path=Path.GetFullPath(Path.Combine(root,context.Request.Url!.AbsolutePath.TrimStart('/').Replace('/',Path.DirectorySeparatorChar)));
                    if(!path.StartsWith(root+Path.DirectorySeparatorChar,StringComparison.OrdinalIgnoreCase)||!File.Exists(path))context.Response.StatusCode=404;
                    else {var bytes=File.ReadAllBytes(path);context.Response.ContentLength64=bytes.Length;await context.Response.OutputStream.WriteAsync(bytes);}
                } catch(Exception e)when(e is HttpListenerException or IOException){ }
                finally {context.Response.Close();}
            }
        });
    }
    public void Dispose(){listener.Close();serving.GetAwaiter().GetResult();}
}
