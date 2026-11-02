using System.IO.Compression;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using Doorlight.Setup;

var root = Path.Combine(Path.GetTempPath(), "Doorlight-delta-checks-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(root);
var checks = 0;
void Check(bool value, string message) { if (!value) throw new Exception(message); checks++; }
void Reject(Action action, string message) {
    try { action(); } catch (InvalidDataException) { checks++; return; }
    throw new Exception(message);
}
async Task RejectAsync(Func<Task> action, string message) {
    try { await action(); } catch (InvalidDataException) { checks++; return; }
    throw new Exception(message);
}
string Digest(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
string FileDigest(string path) { using var stream=File.OpenRead(path);return Convert.ToHexString(SHA256.HashData(stream)).ToLowerInvariant(); }
byte[] Bytes(string value) => Encoding.UTF8.GetBytes(value);
Dictionary<string, byte[]> Files(string value) => new() {
    ["sybl.exe"]=Bytes("synthetic exe"),["_setup/DoorlightUpdater.exe"]=Bytes("synthetic updater"),
    ["Doorlight.version"]=Bytes("0.1.0"),["value.txt"]=Bytes(value)
};
PackageManifest Manifest(Dictionary<string, byte[]> files) => new(1,"0.1.0", files.Select(pair=>new PackageFile(pair.Key,pair.Value.Length,Digest(pair.Value))).ToArray());
string Zip(string name, Dictionary<string,byte[]> files, string prefix="lib/app/",Action<ZipArchive>? amend=null) {
    var path=Path.Combine(root,name+".nupkg");
    using var output=File.Create(path);using var zip=new ZipArchive(output,ZipArchiveMode.Create);
    foreach(var pair in files){var entry=zip.CreateEntry(prefix+pair.Key);using var content=entry.Open();content.Write(pair.Value);}
    amend?.Invoke(zip); return path;
}
byte[] Frame(byte[] content) {
    if(content.Length>255)throw new Exception("Fixture frame too large");
    using var stream=new MemoryStream();stream.Write(new byte[]{0x28,0xb5,0x2f,0xfd,0x20,(byte)content.Length});
    var header=(content.Length<<3)|1;stream.Write(new byte[]{(byte)header,(byte)(header>>8),(byte)(header>>16)});stream.Write(content);return stream.ToArray();
}
try {
    var oldFiles=Files("old");var newFiles=Files("new");
    oldFiles["removed.txt"]=Bytes("removed");newFiles["added.txt"]=Bytes("added");
    var oldManifest=Manifest(oldFiles);var target=Manifest(newFiles);
    var full=Zip("base",oldFiles);var updated=Zip("target",newFiles);
    DeltaPackage.PreflightFull(full,oldManifest,"DoorlightDeltaResearch");checks++;
    var stage=DeltaPackage.Extract(updated,target,root,"DoorlightDeltaResearch");
    Check(File.ReadAllText(Path.Combine(stage,"value.txt"))=="new","Extraction mismatch");
    var metadata=JsonSerializer.SerializeToUtf8Bytes(oldManifest,CoreJsonContext.Default.PackageManifest);
    var receipt=new DeltaBaseReceipt("0.1.0",FileDigest(full),FileDigest(full),Digest(metadata));
    var identity=new DeltaBaseIdentity("0.1.0",receipt.OriginalPackageSha256,receipt.ManifestSha256);
    Check(DeltaPackage.VerifyBase(full,metadata,receipt,identity,"DoorlightDeltaResearch").Files.Length==5,"Base verification");
    Reject(()=>DeltaPackage.VerifyBase(full,metadata,receipt,identity with{PackageSha256=new string('0',64)},"DoorlightDeltaResearch"),"Wrong base accepted");
    Reject(()=>DeltaPackage.VerifyBase(full,metadata,receipt with{CachedPackageSha256=new string('0',64)},identity,"DoorlightDeltaResearch"),"Changed archive accepted");
    Reject(()=>DeltaPackage.PreflightFull(full,target,"DoorlightDeltaResearch"),"Corrupt content accepted");
    var traversal=Zip("traversal",oldFiles,amend:z=>z.CreateEntry("lib/app/../escape"));
    Reject(()=>DeltaPackage.PreflightFull(traversal,oldManifest,"DoorlightDeltaResearch"),"Traversal accepted");
    var collision=Zip("collision",oldFiles,amend:z=>z.CreateEntry("lib/app/SYBL.EXE"));
    Reject(()=>DeltaPackage.PreflightFull(collision,oldManifest,"DoorlightDeltaResearch"),"Case collision accepted");
    var symlink=Zip("symlink",oldFiles,amend:z=>{var e=z.CreateEntry("lib/app/link");e.ExternalAttributes=unchecked((int)0xa1ff0000);});
    Reject(()=>DeltaPackage.PreflightFull(symlink,oldManifest,"DoorlightDeltaResearch"),"Symlink accepted");
    var extra=Zip("extra",oldFiles,amend:z=>z.CreateEntry("lib/app/unknown.exe"));
    Reject(()=>DeltaPackage.PreflightFull(extra,oldManifest,"DoorlightDeltaResearch"),"Unexpected executable accepted");
    var malicious=Zip("root-path",oldFiles,amend:z=>z.CreateEntry("C:/outside"));
    Reject(()=>DeltaPackage.PreflightFull(malicious,oldManifest,"DoorlightDeltaResearch"),"Drive path accepted");
    var patches=oldFiles.Keys.Where(newFiles.ContainsKey).ToDictionary(path=>path+".diff",_=>Array.Empty<byte>());
    patches.Remove("value.txt.diff");patches["value.txt.zsdiff"]=Frame(Bytes("new"));
    patches["added.txt"]=Bytes("added");
    var delta=Zip("delta",patches);
    DeltaPackage.PreflightDelta(delta,oldManifest,target,"DoorlightDeltaResearch");checks++;
    var badFrames=new Dictionary<string,byte[]>(patches){["value.txt.zsdiff"]=Frame(Bytes("new")).Concat(Frame(Bytes("new"))).ToArray()};
    Reject(()=>DeltaPackage.PreflightDelta(Zip("extra-frame",badFrames),oldManifest,target,"DoorlightDeltaResearch"),"Concatenated frames accepted");
    var oversized=new Dictionary<string,byte[]>(patches){["value.txt.zsdiff"]=Frame(Bytes("longer"))};
    Reject(()=>DeltaPackage.PreflightDelta(Zip("oversized-frame",oversized),oldManifest,target,"DoorlightDeltaResearch"),"Oversized frame accepted");
    var wrongMarker=oldFiles.Keys.ToDictionary(path=>path+".diff",_=>Array.Empty<byte>());
    Reject(()=>DeltaPackage.PreflightDelta(Zip("changed-marker",wrongMarker),oldManifest,target,"DoorlightDeltaResearch"),"Changed file marker accepted");
    await RejectAsync(()=>DeltaPackage.RunPatchAsync(full,full,delta,FileDigest(delta),oldManifest,target,root,"DoorlightDeltaResearch",TimeSpan.FromSeconds(5)),"Replaced helper accepted");
    using(var cancelled=new CancellationTokenSource()){
        cancelled.Cancel();try{await DeltaPackage.RunPatchAsync(full,full,delta,FileDigest(delta),oldManifest,target,root,"DoorlightDeltaResearch",TimeSpan.FromSeconds(5),cancelled.Token);throw new Exception("Cancellation ignored");}catch(OperationCanceledException){checks++;}
    }
    var helper=Environment.GetEnvironmentVariable("DOORLIGHT_DELTA_HELPER");
    if(!string.IsNullOrEmpty(helper)){
        var result=await DeltaPackage.RunPatchAsync(helper,full,delta,FileDigest(delta),oldManifest,target,root,"DoorlightDeltaResearch",TimeSpan.FromSeconds(30));
        Check(File.ReadAllText(Path.Combine(result.StageDirectory,"value.txt"))=="new","Native patch mismatch");
        Check(File.Exists(Path.Combine(result.StageDirectory,"added.txt"))&&!File.Exists(Path.Combine(result.StageDirectory,"removed.txt")),"Native add/delete mismatch");
        Check(FileDigest(result.PackagePath)==result.PackageSha256,"Retained archive hash mismatch");
        var corrupt=new Dictionary<string,byte[]>(patches){["value.txt.zsdiff"]=Frame(Bytes("bad"))};
        var wrong=Zip("wrong-output",corrupt);
        await RejectAsync(()=>DeltaPackage.RunPatchAsync(helper,full,wrong,FileDigest(wrong),oldManifest,target,root,"DoorlightDeltaResearch",TimeSpan.FromSeconds(30)),"Exit-zero wrong output accepted");
        await RejectAsync(()=>DeltaPackage.RunPatchAsync(helper,full,delta,new string('0',64),oldManifest,target,root,"DoorlightDeltaResearch",TimeSpan.FromSeconds(30)),"Wrong patch digest accepted");
    }
    var real=Environment.GetEnvironmentVariable("DOORLIGHT_DELTA_REAL");
    if(!string.IsNullOrEmpty(real)&&!string.IsNullOrEmpty(helper)){
        PackageManifest FromDirectory(string path)=>new(1,"0.1.0",Directory.GetFiles(path,"*",SearchOption.AllDirectories).Select(file=>new PackageFile(Path.GetRelativePath(path,file).Replace('\\','/'),new FileInfo(file).Length,FileDigest(file))).ToArray());
        var before=FromDirectory(Path.Combine(real,"old-input"));var after=FromDirectory(Path.Combine(real,"new-input"));
        var oldPackage=Directory.GetFiles(Path.Combine(real,"old-release"),"*-full.nupkg").Single();
        var patch=Directory.GetFiles(real,"*-delta.nupkg").Single();
        var result=await DeltaPackage.RunPatchAsync(helper,oldPackage,patch,FileDigest(patch),before,after,root,"DoorlightDeltaResearch",TimeSpan.FromMinutes(2));
        PackageStage.VerifyDirectory(after,result.StageDirectory);checks++;
        Console.WriteLine($"Real native roundtrip verified {after.Files.Length} application files.");
        using var cancel=new CancellationTokenSource();
        using var watching=new CancellationTokenSource(TimeSpan.FromSeconds(30));
        var observed=Task.Run(async()=>{
            while(!watching.IsCancellationRequested){
                if(Directory.GetDirectories(root,".delta-*").Any(path=>File.Exists(Path.Combine(path,"patch.log")))){cancel.Cancel();return true;}
                await Task.Delay(10);
            }
            return false;
        });
        try {
            await DeltaPackage.RunPatchAsync(helper,oldPackage,patch,FileDigest(patch),before,after,root,"DoorlightDeltaResearch",TimeSpan.FromMinutes(2),cancel.Token);
            throw new Exception("Running codec ignored cancellation");
        } catch(OperationCanceledException){Check(await observed,"Cancellation never observed native codec start");}
        finally {watching.Cancel();}
        Check(Directory.GetDirectories(root,".delta-*").Length==0,"Cancelled codec workspace was not cleaned");
    }
    Console.WriteLine($"Passed {checks} delta checks. Evidence workspace: {root}");
} catch { Console.Error.WriteLine($"Failed evidence workspace: {root}");throw; }

namespace Doorlight.Setup {
    [JsonSerializable(typeof(PackageManifest))]
    internal partial class CoreJsonContext:JsonSerializerContext;
}
