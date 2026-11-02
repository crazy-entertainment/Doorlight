using System.IO.Compression;
using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Doorlight.Setup;

var scratch = Path.GetFullPath(Path.Combine(Environment.CurrentDirectory, "local/tmp/setup-checks"));
Directory.CreateDirectory(scratch);
var root = Path.Combine(scratch, Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(root);
if (args.Length == 3 && args[0] == "--verify")
{
    try
    {
        using var metadata = System.IO.File.OpenRead(args[2]);
        var actual = PackageManifest.Read(metadata);
        using var archive = System.IO.File.OpenRead(args[1]);
        var stage = PackageStage.Extract(archive, actual, root);
        WindowsExecutable.Validate(Path.Combine(stage, "sybl.exe"));
        WindowsExecutable.Validate(Path.Combine(stage, "_setup", "DoorlightUpdater.exe"));
        Directory.Delete(stage, true);
        Console.WriteLine("Release package verified.");
    }
    finally { Directory.Delete(root, true); }
    return;
}
var checks = 0;
void Check(bool condition, string message)
{
    if (!condition) throw new Exception(message);
    checks++;
}
void Reject(Action action, string message)
{
    try { action(); }
    catch (InvalidDataException) { checks++; return; }
    throw new Exception(message);
}
PackageFile FileEntry(string path, string text) => new(path,
    Encoding.UTF8.GetByteCount(text), Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(text))).ToLowerInvariant());

// PE headers are checked without executing the fixture. Exercise platform,
// image-kind and truncation rejection independently of package hash validation.
var pe = new byte[512];
BinaryPrimitives.WriteUInt16LittleEndian(pe.AsSpan(0), 0x5a4d);
BinaryPrimitives.WriteInt32LittleEndian(pe.AsSpan(0x3c), 128);
BinaryPrimitives.WriteUInt32LittleEndian(pe.AsSpan(128), 0x4550);
BinaryPrimitives.WriteUInt16LittleEndian(pe.AsSpan(132), 0x8664);
BinaryPrimitives.WriteUInt16LittleEndian(pe.AsSpan(148), 240);
BinaryPrimitives.WriteUInt16LittleEndian(pe.AsSpan(150), 2);
BinaryPrimitives.WriteUInt16LittleEndian(pe.AsSpan(152), 0x20b);
BinaryPrimitives.WriteUInt32LittleEndian(pe.AsSpan(184), 4096);
BinaryPrimitives.WriteUInt32LittleEndian(pe.AsSpan(188), 512);
BinaryPrimitives.WriteUInt32LittleEndian(pe.AsSpan(208), 4096);
BinaryPrimitives.WriteUInt32LittleEndian(pe.AsSpan(212), 512);
BinaryPrimitives.WriteUInt32LittleEndian(pe.AsSpan(260), 16);
var pePath = Path.Combine(root, "entry-point.exe");
System.IO.File.WriteAllBytes(pePath, pe);
WindowsExecutable.Validate(pePath);
Check(true, "Windows x64 executable header accepted");
foreach (var malformed in new[] {
    pe[..32], Encoding.UTF8.GetBytes("not an executable"),
    pe.Select((b, i) => i == 132 ? (byte)0x4c : i == 133 ? (byte)0x01 : b).ToArray(),
    pe.Select((b, i) => i == 151 ? (byte)0x20 : b).ToArray(),
    pe.Select((b, i) => i == 128 ? (byte)0 : b).ToArray(),
    pe.Select((b, i) => i == 152 ? (byte)0x0b : i == 153 ? (byte)0x01 : b).ToArray(),
    pe.Select((b, i) => i == 150 ? (byte)0 : b).ToArray(),
}) {
    System.IO.File.WriteAllBytes(pePath, malformed);
    Reject(() => WindowsExecutable.Validate(pePath), "Invalid Windows entry point accepted");
}
System.IO.File.Delete(pePath);
MemoryStream Zip(params (string Path, string Text)[] files)
{
    files = files.Concat(new[] { ("Doorlight.version", "1.2.3"), ("_setup/DoorlightUpdater.exe", "helper") }).ToArray();
    var stream = new MemoryStream();
    using (var zip = new ZipArchive(stream, ZipArchiveMode.Create, leaveOpen: true))
        foreach (var file in files)
        {
            var entry = zip.CreateEntry(file.Path);
            using var output = new StreamWriter(entry.Open(), new UTF8Encoding(false));
            output.Write(file.Text);
        }
    stream.Position = 0;
    return stream;
}
var manifest = new PackageManifest(1, "1.2.3", [FileEntry("sybl.exe", "app"), FileEntry("data/test.txt", "hello"), FileEntry("Doorlight.version", "1.2.3"), FileEntry("_setup/DoorlightUpdater.exe", "helper")]);
try
{
    using (var json = new MemoryStream(JsonSerializer.SerializeToUtf8Bytes(manifest)))
        Check(PackageManifest.Read(json).Version == "1.2.3", "Manifest roundtrip failed");
    using (var zip = Zip(("sybl.exe", "app"), ("data/", ""), ("data/test.txt", "hello")))
    {
        var progress = new List<InstallProgress>();
        var stage = PackageStage.Extract(zip, manifest, root, progress.Add);
        Check(System.IO.File.ReadAllText(Path.Combine(stage, "sybl.exe")) == "app", "Executable changed");
        Check(System.IO.File.ReadAllText(Path.Combine(stage, "data/test.txt")) == "hello", "Data changed");
        Check(progress[^1].CompletedBytes == 19 && progress[^1].TotalBytes == 19, "Progress is not measured from bytes");
        Check(progress.Select(p => p.File).Distinct().SequenceEqual(new[] { "sybl.exe", "data/test.txt", "Doorlight.version", "_setup/DoorlightUpdater.exe" }), "Wrong current filenames");
        Directory.Delete(stage, true);
    }
    foreach (var path in new[] { "../escape", "/absolute", "C:/absolute", "data\\escape", "data/a:stream", "data/CON.txt", "data/NUL", "data/COM1", "data/a.", "data/a ", "data//a" })
        Reject(() => (manifest with { Files = [FileEntry("sybl.exe", "app"), FileEntry(path, "bad")] }).Validate(), "Unsafe path accepted: " + path);
    Reject(() => (manifest with { Files = [FileEntry("sybl.exe", "app"), FileEntry("SYBL.EXE", "other")] }).Validate(), "Case duplicate accepted");
    Reject(() => (manifest with { Files = [FileEntry("sybl.exe", "app"), FileEntry("data", "x"), FileEntry("data/a", "x")] }).Validate(), "File-directory collision accepted");
    Reject(() => (manifest with { Version = "1.2.3-preview" }).Validate(), "Unexpected version syntax accepted");
    Reject(() => (manifest with { Files = [FileEntry("sybl.exe", "app") with { Sha256 = new string('a', 64) + "\n" }] }).Validate(), "Hash with trailing newline accepted");
    Reject(() => (manifest with { Files = [new("sybl.exe", PackageManifest.MaximumBytes + 1, new string('0', 64))] }).Validate(), "Oversized package accepted");
    foreach (var files in new (string, string)[][] {
        [("sybl.exe", "bad"), ("data/test.txt", "hello")],
        [("sybl.exe", "app")],
        [("sybl.exe", "app"), ("data/test.txt", "hello"), ("extra.txt", "extra")],
        [("sybl.exe", "app"), ("data/test.txt", "hello"), ("../escape", "bad")],
        [("sybl.exe", "app"), ("SYBL.EXE", "app"), ("data/test.txt", "hello")],
        [("sybl.exe", "app"), ("data/test.txt", "wrong length")],
    })
    {
        using var zip = Zip(files);
        Reject(() => PackageStage.Extract(zip, manifest, root), "Invalid archive accepted");
        Check(!Directory.EnumerateFileSystemEntries(root).Any(), "Failed stage was not removed");
    }
    using (var zip = Zip(("sybl.exe", "app"), ("data/test.txt", "hello")))
    {
        using (var edit = new ZipArchive(zip, ZipArchiveMode.Update, leaveOpen: true))
            edit.GetEntry("data/test.txt")!.ExternalAttributes = unchecked((int)0xa1ff0000);
        zip.Position = 0;
        Reject(() => PackageStage.Extract(zip, manifest, root), "Symbolic link accepted");
    }
    using (var zip = Zip(("sybl.exe", "app"), ("data/test.txt", "hello")))
    {
        using var cancellation = new CancellationTokenSource();
        cancellation.Cancel();
        try { PackageStage.Extract(zip, manifest, root, cancellation: cancellation.Token); throw new Exception("Cancellation ignored"); }
        catch (OperationCanceledException) { checks++; }
        Check(!Directory.EnumerateFileSystemEntries(root).Any(), "Cancelled stage was not removed");
    }
    using (var zip = Zip(("sybl.exe", "app"), ("data/test.txt", "hello")))
    {
        using var cancellation = new CancellationTokenSource();
        try
        {
            PackageStage.Extract(zip, manifest, root, progress => {
                if (progress.CompletedBytes == progress.TotalBytes) cancellation.Cancel();
            }, cancellation.Token);
            throw new Exception("Final-chunk cancellation ignored");
        }
        catch (OperationCanceledException) { checks++; }
        Check(!Directory.EnumerateFileSystemEntries(root).Any(), "Final-chunk cancellation left a stage");
    }

    using (var zip = Zip(("sybl.exe", "app"), ("data/test.txt", "hello")))
    {
        var bytes = zip.ToArray();
        System.Buffers.Binary.BinaryPrimitives.WriteUInt32LittleEndian(bytes.AsSpan(bytes.Length - 10), 9 * 1024 * 1024);
        using var malformed = new MemoryStream(bytes);
        Reject(() => PackageStage.Extract(malformed, manifest, root), "Oversized ZIP directory accepted");
    }
    using (var zip = Zip(("sybl.exe", "app"), ("data/test.txt", "hello")))
    {
        var bytes = zip.ToArray();
        System.Buffers.Binary.BinaryPrimitives.WriteUInt16LittleEndian(bytes.AsSpan(bytes.Length - 12), ushort.MaxValue);
        using var malformed = new MemoryStream(bytes);
        Reject(() => PackageStage.Extract(malformed, manifest, root), "ZIP64 or oversized entry count accepted");
    }
    string Bundle(string parent, string name, string version, string text)
    {
        var directory = Path.Combine(parent, name);
        Directory.CreateDirectory(Path.Combine(directory, "_setup"));
        System.IO.File.WriteAllText(Path.Combine(directory, "sybl.exe"), text);
        System.IO.File.WriteAllText(Path.Combine(directory, "Doorlight.version"), version);
        System.IO.File.WriteAllText(Path.Combine(directory, "_setup/DoorlightUpdater.exe"), "helper-" + text);
        return directory;
    }
    string CaseRoot()
    {
        var directory = Path.Combine(root, Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(directory);
        return directory;
    }
    string Stage(string parent, string version = "1.2.3", string text = "new") =>
        Bundle(parent, ".stage-" + Guid.NewGuid().ToString("N"), version, text);
    void Old(string parent)
    {
        Bundle(parent, "current", "1.0.0", "old");
        System.IO.File.WriteAllText(Path.Combine(parent, "DoorlightUpdater.exe"), "helper-old");
    }
    if (OperatingSystem.IsWindows())
    {
        foreach (var blockStage in new[] { false, true })
        {
            var directory = CaseRoot();
            Old(directory);
            var stage = Stage(directory);
            var locked = blockStage ? stage : Path.Combine(directory, "current");
            using var held = DirectorySharingFixture.Hold(locked);
            try { Directory.Move(locked, locked + "-negative-control"); throw new Exception("Directory fixture did not block rename"); }
            catch (IOException error) when (error.HResult == unchecked((int)0x80070020)) { checks++; }
            using var blocked = new ManualResetEventSlim();
            var release = Task.Run(() => { blocked.Wait(TimeSpan.FromSeconds(10)); held.Dispose(); });
            var points = new List<string>();
            InstallTransaction transaction;
            try
            {
                transaction = BundleInstall.Apply(directory, stage, "1.2.3", checkpoint: point => {
                    points.Add(point);
                    if (point == (blockStage ? "candidate-rename-blocked" : "old-rename-blocked")) blocked.Set();
                });
            }
            finally { blocked.Set(); await release; }
            Check(points.Count(p => p == "journal") == 1, "Sharing retry restarted the transaction");
            Check(points.Count(p => p.EndsWith("-blocked", StringComparison.Ordinal)) == 1, "Actual sharing retry was not observed");
            Check(points.Count(p => p == "old-renamed") == 1 && points.Count(p => p == "candidate-promoted") == 1,
                "Sharing retry promoted a bundle more than once");
            BundleInstall.Accept(directory, transaction.Id);
            Check(PackageStage.ReadVersion(Path.Combine(directory, "current")) == "1.2.3", "Sharing retry did not install candidate");
            Check(!System.IO.File.Exists(Path.Combine(directory, "install-pending.json")), "Sharing retry left a pending journal");
        }
        foreach (var blockStage in new[] { false, true })
        {
            var directory = CaseRoot();
            Old(directory);
            var stage = Stage(directory);
            using (var held = DirectorySharingFixture.Hold(blockStage ? stage : Path.Combine(directory, "current")))
            {
                var timer = System.Diagnostics.Stopwatch.StartNew();
                try { BundleInstall.Apply(directory, stage, "1.2.3"); throw new Exception("Permanent sharing lock was ignored"); }
                catch (IOException error) when (error.HResult == unchecked((int)0x80070020))
                {
                    Check(timer.Elapsed >= TimeSpan.FromSeconds(4) && timer.Elapsed < TimeSpan.FromSeconds(30), "Sharing retry was not bounded");
                    Check(error.Data["BundleMove"] as string == (blockStage ? "candidate-rename-blocked" : "old-rename-blocked"), "Sharing failure lost its operation");
                }
                Check(System.IO.File.Exists(Path.Combine(directory, "install-pending.json")) && Directory.Exists(stage), "Blocked move discarded recovery evidence");
            }
            var recovered = BundleInstall.Recover(directory);
            Check(recovered is not null && recovered.Rejected == blockStage, "Blocked move recovery has wrong rejection state");
            Check(PackageStage.ReadVersion(Path.Combine(directory, "current")) == "1.0.0", "Blocked move did not restore predecessor");
            Check(System.IO.File.ReadAllText(Path.Combine(directory, "DoorlightUpdater.exe")) == "helper-old", "Blocked move lost predecessor helper");
            Check(!System.IO.File.Exists(Path.Combine(directory, "install-pending.json")), "Blocked move recovery left its journal");
        }
        foreach (var blockPrevious in new[] { false, true })
        {
            var directory = CaseRoot();
            Old(directory);
            var stage = Stage(directory);
            var transaction = BundleInstall.Apply(directory, stage, "1.2.3");
            using var held = DirectorySharingFixture.Hold(Path.Combine(directory, blockPrevious ? transaction.Previous! : "current"));
            using var blocked = new ManualResetEventSlim();
            var release = Task.Run(() => { blocked.Wait(TimeSpan.FromSeconds(10)); held.Dispose(); });
            var points = new List<string>();
            InstallRecovery? recovered;
            try
            {
                recovered = BundleInstall.Recover(directory, point => {
                    points.Add(point);
                    if (point == (blockPrevious ? "previous-restore-blocked" : "candidate-preserve-blocked")) blocked.Set();
                });
            }
            finally { blocked.Set(); await release; }
            Check(points.Count(p => p.EndsWith("-blocked", StringComparison.Ordinal)) == 1, "Actual recovery sharing retry was not observed");
            Check(points.Count(p => p == "rollback-journal") == 1 && points.Count(p => p == "previous-restored") == 1, "Recovery sharing retry restarted recovery");
            Check(recovered?.Rejected == true && PackageStage.ReadVersion(Path.Combine(directory, "current")) == "1.0.0", "Recovery sharing retry lost predecessor");
            Check(Directory.Exists(stage) && !System.IO.File.Exists(Path.Combine(directory, "install-pending.json")), "Recovery sharing retry lost evidence or journal completion");
        }
    }
    foreach (var phase in new[] { "journal", "old-renamed", "candidate-promoted", "helper-replaced" })
    {
        foreach (var initial in new[] { false, true })
        {
            var directory = CaseRoot();
            if (!initial) Old(directory);
            else System.IO.File.WriteAllText(Path.Combine(directory, "DoorlightUpdater.exe"), "bootstrap");
            var stage = Stage(directory);
            try
            {
                BundleInstall.Apply(directory, stage, "1.2.3", checkpoint: point => {
                    if (point == phase) throw new OperationCanceledException("Simulated power loss");
                });
                throw new Exception("Fault injection did not run");
            }
            catch (OperationCanceledException) { checks++; }
            Check(System.IO.File.Exists(Path.Combine(directory, "install-pending.json")), "Interrupted update lost its journal");
            var recovery = BundleInstall.Recover(directory);
            Check(recovery is not null && recovery.FirstInstall == initial, "Recovery returned wrong operation");
            Check(Directory.Exists(stage), "Recovery discarded candidate evidence");
            Check(!System.IO.File.Exists(Path.Combine(directory, "install-pending.json")), "Recovery did not finish");
            Check(System.IO.File.ReadAllText(Path.Combine(directory, "DoorlightUpdater.exe")) == (initial ? "bootstrap" : "helper-old"), "Recovery failed to restore helper");
            if (initial) Check(!Directory.Exists(Path.Combine(directory, "current")), "Unacknowledged initial install was accepted");
            else Check(System.IO.File.ReadAllText(Path.Combine(directory, "current/sybl.exe")) == "old", "Recovery failed to restore app");
            Check(BundleInstall.Recover(directory) is null, "Recovery is not idempotent");
        }
    }
    {
        var directory = CaseRoot();
        Old(directory);
        InstallTransaction? latest = null;
        for (var index = 1; index <= 3; index++)
        {
            latest = BundleInstall.Apply(directory, Stage(directory, $"1.{index}.0", $"app-{index}"), $"1.{index}.0");
            BundleInstall.Accept(directory, latest.Id);
        }
        var retained = Directory.GetDirectories(directory, "previous-*");
        Check(retained.Length == 1 && Path.GetFileName(retained[0]) == latest!.Previous, "Accepted updates accumulated old bundles");
        Check(System.IO.File.ReadAllText(Path.Combine(retained[0], "sybl.exe")) == "app-2", "Retention removed the immediate previous bundle");
        Check(System.IO.File.ReadAllText(Path.Combine(directory, "current/sybl.exe")) == "app-3", "Retention changed current app");
        Check(!System.IO.File.Exists(Path.Combine(directory, "install-pending.json")), "Retention left an accepted journal");
    }
    {
        var directory = CaseRoot();
        Old(directory);
        var older = Bundle(directory, "previous-" + new string('c', 32), "0.9.0", "locked-old");
        var unexpected = Path.Combine(directory, "previous-" + new string('d', 32));
        Directory.CreateDirectory(unexpected);
        System.IO.File.WriteAllText(Path.Combine(unexpected, "keep.txt"), "unrecognized");
        using (var locked = new FileStream(Path.Combine(older, "sybl.exe"), FileMode.Open, FileAccess.Read, FileShare.Read))
        {
            var accepted = BundleInstall.Apply(directory, Stage(directory), "1.2.3");
            BundleInstall.Accept(directory, accepted.Id);
            Check(System.IO.File.ReadAllText(Path.Combine(older, "sybl.exe")) == "locked-old", "Cleanup deleted a locked predecessor");
            Check(!System.IO.File.Exists(Path.Combine(directory, "install-pending.json")), "Locked cleanup broke acceptance");
            Check(BundleInstall.Recover(directory) is null, "Locked cleanup caused rollback");
            Check(System.IO.File.ReadAllText(Path.Combine(directory, "current/sybl.exe")) == "new", "Locked cleanup changed accepted app");
        }
        Check(System.IO.File.ReadAllText(Path.Combine(unexpected, "keep.txt")) == "unrecognized", "Cleanup removed an unrecognized directory");
    }
    {
        var directory = CaseRoot();
        Old(directory);
        var older = Bundle(directory, "previous-" + new string('e', 32), "0.9.0", "linked-old");
        var outside = Path.Combine(directory, "unowned");
        Directory.CreateDirectory(outside);
        System.IO.File.WriteAllText(Path.Combine(outside, "keep.txt"), "outside");
        var link = Path.Combine(older, "linked");
        Directory.CreateSymbolicLink(link, outside);
        try
        {
            var accepted = BundleInstall.Apply(directory, Stage(directory), "1.2.3");
            BundleInstall.Accept(directory, accepted.Id);
            Check(System.IO.File.ReadAllText(Path.Combine(outside, "keep.txt")) == "outside", "Cleanup followed a linked descendant");
            Check(System.IO.File.ReadAllText(Path.Combine(older, "sybl.exe")) == "linked-old", "Linked tree was partially cleaned");
            Check(!System.IO.File.Exists(Path.Combine(directory, "install-pending.json")), "Linked cleanup broke acceptance");
            Check(BundleInstall.Recover(directory) is null, "Linked cleanup caused rollback");
        }
        finally { Directory.Delete(link); }
    }
    {
        var directory = CaseRoot();
        Old(directory);
        var older = Bundle(directory, "previous-" + new string('f', 32), "0.9.0", "obsolete");
        var accepted = BundleInstall.Apply(directory, Stage(directory), "1.2.3");
        try { BundleInstall.Accept(directory, accepted.Id, _ => throw new OperationCanceledException()); }
        catch (OperationCanceledException) { checks++; }
        Check(Directory.Exists(older), "Cleanup ran before journal retirement");
        BundleInstall.Recover(directory);
        Check(!Directory.Exists(older), "Recovery of durable acceptance did not prune obsolete bundle");
        Check(Directory.Exists(Path.Combine(directory, accepted.Previous!)), "Acceptance recovery pruned immediate predecessor");
    }
    foreach (var phase in new[] { "rollback-journal", "candidate-preserved", "previous-restored", "helper-restored", "rejection-recorded" })
    {
        var directory = CaseRoot();
        Old(directory);
        var stage = Stage(directory);
        BundleInstall.Apply(directory, stage, "1.2.3");
        try
        {
            BundleInstall.Recover(directory, point => {
                if (point == phase) throw new OperationCanceledException("Recovery power loss");
            });
            throw new Exception("Recovery fault injection did not run");
        }
        catch (OperationCanceledException) { checks++; }
        BundleInstall.Recover(directory);
        Check(System.IO.File.ReadAllText(Path.Combine(directory, "current/sybl.exe")) == "old", "Interrupted recovery lost old app");
        Check(System.IO.File.ReadAllText(Path.Combine(directory, "DoorlightUpdater.exe")) == "helper-old", "Interrupted recovery lost old launcher");
        Check(Directory.Exists(stage), "Interrupted recovery lost failed candidate");
        Check(BundleInstall.IsRejected(directory, "1.2.3"), "Interrupted recovery forgot rejection");
    }
    foreach (var phase in new[] { "rollback-journal", "candidate-preserved", "helper-restored", "rejection-recorded" })
    {
        var directory = CaseRoot();
        System.IO.File.WriteAllText(Path.Combine(directory, "DoorlightUpdater.exe"), "bootstrap");
        var stage = Stage(directory);
        BundleInstall.Apply(directory, stage, "1.2.3");
        try
        {
            BundleInstall.Recover(directory, point => {
                if (point == phase) throw new OperationCanceledException("Initial recovery power loss");
            });
            throw new Exception("Initial recovery fault injection did not run");
        }
        catch (OperationCanceledException) { checks++; }
        var recovered = BundleInstall.Recover(directory);
        Check(recovered?.FirstInstall == true, "Initial recovery did not request reinstall");
        Check(!Directory.Exists(Path.Combine(directory, "current")), "Interrupted initial recovery retained unaccepted app");
        Check(Directory.Exists(stage), "Interrupted initial recovery lost candidate");
        Check(System.IO.File.ReadAllText(Path.Combine(directory, "DoorlightUpdater.exe")) == "bootstrap", "Interrupted initial recovery lost bootstrap");
    }
    {
        var directory = CaseRoot();
        Old(directory);
        var transaction = BundleInstall.Apply(directory, Stage(directory), "1.2.3");
        try { BundleInstall.Accept(directory, transaction.Id, _ => throw new OperationCanceledException()); }
        catch (OperationCanceledException) { checks++; }
        Check(BundleInstall.Recover(directory) is null, "Crash after durable acceptance incorrectly rolled back");
        Check(System.IO.File.ReadAllText(Path.Combine(directory, "current/sybl.exe")) == "new", "Accepted crash lost new app");
    }
    {
        var directory = CaseRoot();
        Old(directory);
        var transaction = BundleInstall.Apply(directory, Stage(directory), "1.2.3");
        Check(System.IO.File.Exists(Path.Combine(directory, "install-pending.json")), "Candidate was accepted without acknowledgment");
        Check(System.IO.File.ReadAllText(Path.Combine(directory, "DoorlightUpdater.exe")) == "helper-new", "Helper was not refreshed");
        Reject(() => BundleInstall.Accept(directory, new string('a', 32)), "Wrong acknowledgment accepted");
        BundleInstall.Accept(directory, transaction.Id);
        Check(BundleInstall.Recover(directory) is null, "Accepted update was rolled back");
        Check(System.IO.File.ReadAllText(Path.Combine(directory, "current/sybl.exe")) == "new", "Accepted candidate lost");
        Check(Directory.Exists(Path.Combine(directory, transaction.Previous!)), "Accepted update discarded previous bundle");
        Reject(() => BundleInstall.Apply(directory, Stage(directory, "1.0.0"), "1.0.0"), "Downgrade accepted");
        Reject(() => BundleInstall.Apply(directory, Stage(directory), "1.2.3"), "Equal version accepted by normal update");
        Reject(() => BundleInstall.Apply(directory, Stage(directory), "1.2.4"), "Mismatched version accepted");
        var repair = BundleInstall.Apply(directory, Stage(directory), "1.2.3", allowRepair: true);
        BundleInstall.Accept(directory, repair.Id);
        var failed = BundleInstall.Apply(directory, Stage(directory, "1.2.4", "bad"), "1.2.4");
        BundleInstall.Rollback(directory, failed.Id);
        Check(BundleInstall.IsRejected(directory, "1.2.4"), "Failed candidate was not remembered");
        Check(!BundleInstall.IsRejected(directory, "1.2.3"), "Accepted version was rejected");
        Check(System.IO.File.ReadAllText(Path.Combine(directory, "current/sybl.exe")) == "new", "Explicit rollback lost old app");
        Check(System.IO.File.ReadAllText(Path.Combine(directory, "DoorlightUpdater.exe")) == "helper-new", "Explicit rollback lost old helper");
        for (var index = 0; index < 34; index++)
        {
            var version = "2.0." + index;
            var rejected = BundleInstall.Apply(directory, Stage(directory, version), version);
            BundleInstall.Rollback(directory, rejected.Id);
        }
        Check(!BundleInstall.IsRejected(directory, "2.0.0") && BundleInstall.IsRejected(directory, "2.0.33"), "Rejected versions are not bounded to the latest 32");
    }
    {
        var directory = CaseRoot();
        Old(directory);
        var stage = Stage(directory);
        using (var locked = new FileStream(Path.Combine(directory, "DoorlightUpdater.exe"), FileMode.Open, FileAccess.Read, FileShare.Read))
        {
            try { BundleInstall.Apply(directory, stage, "1.2.3"); throw new Exception("Locked helper replaced"); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { checks++; }
            Check(System.IO.File.Exists(Path.Combine(directory, "DoorlightUpdater.exe")), "Locked swap left no launcher");
        }
        BundleInstall.Recover(directory);
        Check(System.IO.File.ReadAllText(Path.Combine(directory, "current/sybl.exe")) == "old", "Locked swap failed recovery");
    }
    {
        var directory = CaseRoot();
        Old(directory);
        var interruptedPrevious = "previous-" + new string('a', 32);
        var interruptedStage = ".stage-" + new string('b', 32);
        Directory.Move(Path.Combine(directory, "current"), Path.Combine(directory, interruptedPrevious));
        Bundle(directory, interruptedStage, "1.2.3", "candidate");
        System.IO.File.WriteAllText(Path.Combine(directory, "install-pending.json"),
            JsonSerializer.Serialize(new { Stage = interruptedStage, Previous = interruptedPrevious }));
        BundleInstall.Recover(directory);
        Check(System.IO.File.ReadAllText(Path.Combine(directory, "current/sybl.exe")) == "old", "Legacy interruption was not restored");
        Check(Directory.Exists(Path.Combine(directory, interruptedStage)), "Legacy recovery discarded pending files");
        System.IO.File.WriteAllText(Path.Combine(directory, "install-pending.json"),
            JsonSerializer.Serialize(new { Stage = "../outside", Previous = interruptedPrevious }));
        Reject(() => BundleInstall.Recover(directory), "Recovery accepted an external path");
    }
    {
        using var zip = Zip(("sybl.exe", "app"), ("data/test.txt", "hello"));
        Reject(() => PackageStage.Extract(zip, manifest with { Version = "1.2.4" }, root), "Archive version mismatch accepted");
        zip.Position = 0;
        var stage = PackageStage.Extract(zip, manifest, root);
        var progress = new List<InstallProgress>();
        PackageStage.VerifyDirectory(manifest, stage, progress.Add);
        Check(progress[^1].CompletedBytes == manifest.Files.Sum(file => file.Size), "Directory verification progress incorrect");
        System.IO.File.WriteAllText(Path.Combine(stage, "data/test.txt"), "wrong");
        Reject(() => PackageStage.VerifyDirectory(manifest, stage), "Changed directory file accepted");
        System.IO.File.WriteAllText(Path.Combine(stage, "data/test.txt"), "hello");
        System.IO.File.WriteAllText(Path.Combine(stage, "extra.txt"), "x");
        Reject(() => PackageStage.VerifyDirectory(manifest, stage), "Extra directory file accepted");
        System.IO.File.Delete(Path.Combine(stage, "extra.txt"));
        Reject(() => PackageStage.VerifyDirectory(manifest with { Version = "1.2.4" }, stage), "Manifest version mismatch accepted");
        using var cancelled = new CancellationTokenSource();
        cancelled.Cancel();
        try { PackageStage.VerifyDirectory(manifest, stage, cancellation: cancelled.Token); throw new Exception("Directory cancellation ignored"); }
        catch (OperationCanceledException) { checks++; }
    }
    JsonElement Release(string url, string digest, long size = 3, bool preview = false) => JsonSerializer.SerializeToElement(new {
        tag_name = "v1.2.3", draft = false, prerelease = preview,
        assets = new[] { new { name = "Doorlight.Package.zip", browser_download_url = url, digest, size } },
    });
    var assetUrl = ReleaseDownload.Repository + "/releases/download/v1.2.3/Doorlight.Package.zip";
    var assetHash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes("app"))).ToLowerInvariant();
    var asset = ReleaseDownload.ReadAsset(Release(assetUrl, "sha256:" + assetHash), "1.2.3", "Doorlight.Package.zip");
    Check(asset.Size == 3, "Release asset was not parsed");
    Reject(() => ReleaseDownload.ReadAsset(Release("https://example.com/payload", "sha256:" + assetHash), "1.2.3", asset.Name), "External release URL accepted");
    Reject(() => ReleaseDownload.ReadAsset(Release(assetUrl, "sha256:" + assetHash, preview: true), "1.2.3", asset.Name), "Preview accepted");
    Reject(() => ReleaseDownload.ReadAsset(Release(assetUrl, "sha256:" + assetHash), "1.2.4", asset.Name), "Wrong tag accepted");
    Reject(() => ReleaseDownload.ReadAsset(Release(assetUrl, ""), "1.2.3", asset.Name), "Missing digest accepted");
    using var http = new HttpClient(new FixtureHandler());
    var target = Path.Combine(root, "download.zip");
    ReleaseDownload.Download(http, asset, target, new Progress<InstallProgress>(), default).GetAwaiter().GetResult();
    Check(System.IO.File.ReadAllText(target) == "app", "Download changed bytes");
    System.IO.File.Delete(target);
    Reject(() => ReleaseDownload.Download(http, asset with { Digest = new string('0', 64) }, target,
        new Progress<InstallProgress>(), default).GetAwaiter().GetResult(), "Corrupt download accepted");
    foreach (var metadata in new[] { false, true })
    {
        using var stalled = new StalledBodyHandler();
        using var client = new HttpClient(stalled) { Timeout = Timeout.InfiniteTimeSpan };
        using var caller = new CancellationTokenSource();
        var path = Path.Combine(root, "stalled-" + metadata + ".zip");
        Task operation = metadata
            ? ReleaseDownload.ReadRelease(client, "1.2.3", caller.Token, TimeSpan.FromMilliseconds(250))
            : ReleaseDownload.Download(client, asset, path, new Progress<InstallProgress>(), caller.Token, TimeSpan.FromMilliseconds(250));
        stalled.Body.ReadStarted.Task.WaitAsync(TimeSpan.FromSeconds(5)).GetAwaiter().GetResult();
        try { operation.WaitAsync(TimeSpan.FromSeconds(5)).GetAwaiter().GetResult(); throw new Exception("Stalled response ignored total deadline"); }
        catch (TimeoutException) { checks++; }
        Check(stalled.Body.ReadToken.IsCancellationRequested, "Body read did not receive the deadline token");
        Check(!caller.IsCancellationRequested, "Internal timeout cancelled the caller's token source");
        // Cancellation must close the partial output even though cleanup belongs to the session.
        if (!metadata) { System.IO.File.Delete(path); Check(!System.IO.File.Exists(path), "Timed-out output remains locked"); }
    }
    foreach (var metadata in new[] { false, true })
    {
        using var stalled = new StalledBodyHandler();
        using var client = new HttpClient(stalled) { Timeout = Timeout.InfiniteTimeSpan };
        using var caller = new CancellationTokenSource();
        Task operation = metadata
            ? ReleaseDownload.ReadRelease(client, "1.2.3", caller.Token)
            : ReleaseDownload.Download(client, asset, Path.Combine(root, "cancelled.zip"), new Progress<InstallProgress>(), caller.Token);
        stalled.Body.ReadStarted.Task.WaitAsync(TimeSpan.FromSeconds(5)).GetAwaiter().GetResult();
        caller.Cancel();
        try { operation.WaitAsync(TimeSpan.FromSeconds(5)).GetAwaiter().GetResult(); throw new Exception("Stalled response ignored caller cancellation"); }
        catch (OperationCanceledException) { checks++; }
        Check(stalled.Body.ReadToken.IsCancellationRequested, "Caller cancellation did not reach body read");
    }
    foreach (var metadata in new[] { false, true })
    {
        using var stalled = new StalledBodyHandler();
        using var client = new HttpClient(stalled) { Timeout = Timeout.InfiniteTimeSpan };
        using var caller = new CancellationTokenSource();
        // Simulate caller cancellation arriving after the deadline interrupts the
        // read but before the download classifies that interruption.
        stalled.Body.OnCancelled = caller.Cancel;
        Task operation = metadata
            ? ReleaseDownload.ReadRelease(client, "1.2.3", caller.Token, TimeSpan.FromMilliseconds(250))
            : ReleaseDownload.Download(client, asset, Path.Combine(root, "both-cancelled.zip"), new Progress<InstallProgress>(), caller.Token, TimeSpan.FromMilliseconds(250));
        stalled.Body.ReadStarted.Task.WaitAsync(TimeSpan.FromSeconds(5)).GetAwaiter().GetResult();
        try { operation.WaitAsync(TimeSpan.FromSeconds(5)).GetAwaiter().GetResult(); throw new Exception("Concurrent cancellation was ignored"); }
        catch (OperationCanceledException) { checks++; }
        Check(caller.IsCancellationRequested && stalled.Body.ReadToken.IsCancellationRequested, "Concurrent cancellation fixture did not cancel both sources");
    }
    Console.WriteLine($"{checks} setup checks passed.");
}
finally { Directory.Delete(root, true); }

sealed class FixtureHandler : HttpMessageHandler
{
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token) =>
        Task.FromResult(new HttpResponseMessage(System.Net.HttpStatusCode.OK) { Content = new StringContent("app") });
}

sealed class StalledBodyHandler : HttpMessageHandler
{
    internal StalledBody Body { get; } = new();
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token) =>
        Task.FromResult(new HttpResponseMessage(System.Net.HttpStatusCode.OK) { Content = new StreamContent(Body) });
}

sealed class StalledBody : Stream
{
    internal TaskCompletionSource ReadStarted { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);
    internal CancellationToken ReadToken { get; private set; }
    internal Action? OnCancelled { get; set; }
    public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
    {
        ReadToken = cancellationToken;
        ReadStarted.TrySetResult();
        try { await Task.Delay(Timeout.InfiniteTimeSpan, cancellationToken); }
        catch (OperationCanceledException) { OnCancelled?.Invoke(); throw; }
        return 0;
    }
    public override bool CanRead => true;
    public override bool CanSeek => false;
    public override bool CanWrite => false;
    public override long Length => throw new NotSupportedException();
    public override long Position { get => throw new NotSupportedException(); set => throw new NotSupportedException(); }
    public override int Read(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException();
    public override void Write(byte[] buffer, int offset, int count) => throw new NotSupportedException();
    public override void Flush() => throw new NotSupportedException();
}
