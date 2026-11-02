using System.Buffers.Binary;
using System.Diagnostics;
using System.IO.Compression;
using System.Security.Cryptography;
using System.Text.RegularExpressions;

namespace Doorlight.Setup;

public sealed record DeltaBaseReceipt(string Version, string OriginalPackageSha256,
    string CachedPackageSha256, string ManifestSha256);
public sealed record DeltaBaseIdentity(string Version, string PackageSha256, string ManifestSha256);
public sealed record DeltaPatchResult(string StageDirectory, string PackagePath, string PackageSha256);

// Velopack is only a codec. This class never delegates application lifecycle or
// installation authority to it, and never trusts its exit code as content proof.
public static class DeltaPackage
{
    public const string HelperSha256 = "9b5d28a356446c6ab61c0ec8f808fcb8a92af3cd0623a6d8fc634f1a5a1e6580";
    public const long HelperLength = 3979264;
    public const long MaximumArchiveBytes = 2L * 1024 * 1024 * 1024;
    private const long ExtraExecutableLimit = 16 * 1024 * 1024;
    private const long MetadataLimit = 1024 * 1024;

    public static PackageManifest VerifyBase(string archivePath, ReadOnlyMemory<byte> manifestBytes,
        DeltaBaseReceipt receipt, DeltaBaseIdentity required, string packageId,
        CancellationToken cancellation = default)
    {
        if (manifestBytes.Length > 8 * 1024 * 1024 || receipt.Version != required.Version ||
            !SameHash(receipt.OriginalPackageSha256, required.PackageSha256) ||
            !SameHash(receipt.ManifestSha256, required.ManifestSha256) ||
            !SameHash(Hash(manifestBytes.Span), required.ManifestSha256))
            throw new InvalidDataException("Cached delta base identity does not match.");
        using var metadata = new MemoryStream(manifestBytes.ToArray(), writable: false);
        var manifest = PackageManifest.Read(metadata);
        if (manifest.Version != receipt.Version) throw new InvalidDataException("Cached base version does not match.");
        using var input = OpenLocked(archivePath);
        Bounds(input);
        if (!SameHash(Hash(input, cancellation), receipt.CachedPackageSha256))
            throw new InvalidDataException("Cached base archive changed.");
        Inspect(input, manifest, null, packageId, verifyHashes: true, cancellation);
        return manifest;
    }

    public static void PreflightFull(string path, PackageManifest manifest, string packageId,
        CancellationToken cancellation = default)
    {
        using var input = OpenLocked(path);
        Inspect(input, manifest, null, packageId, verifyHashes: true, cancellation);
    }

    public static void PreflightDelta(string path, PackageManifest baseManifest, PackageManifest targetManifest,
        string packageId, CancellationToken cancellation = default)
    {
        using var input = OpenLocked(path);
        Inspect(input, targetManifest, baseManifest, packageId, verifyHashes: false, cancellation);
    }

    public static string Extract(string archivePath, PackageManifest manifest, string stagingParent,
        string packageId, Action<InstallProgress>? progress = null, CancellationToken cancellation = default)
    {
        using var input = OpenLocked(archivePath);
        return Extract(input, manifest, stagingParent, packageId, progress, cancellation);
    }

    public static async Task<DeltaPatchResult> RunPatchAsync(string helperPath, string basePath, string deltaPath,
        string expectedDeltaSha256, PackageManifest baseManifest, PackageManifest targetManifest,
        string stagingParent, string packageId, TimeSpan deadline, CancellationToken cancellation = default)
    {
        if (deadline <= TimeSpan.Zero || deadline > TimeSpan.FromMinutes(10))
            throw new ArgumentOutOfRangeException(nameof(deadline));
        cancellation.ThrowIfCancellationRequested();
        using var helper = OpenLocked(helperPath);
        if (helper.Length != HelperLength || !SameHash(Hash(helper, cancellation), HelperSha256))
            throw new InvalidDataException("Delta patch helper failed its pinned integrity check.");
        using var old = OpenLocked(basePath);
        using var delta = OpenLocked(deltaPath);
        Bounds(delta);
        if (!SameHash(Hash(delta, cancellation), expectedDeltaSha256))
            throw new InvalidDataException("Delta archive digest does not match.");
        var oldBytes = Inspect(old, baseManifest, null, packageId, true, cancellation);
        var deltaBytes = Inspect(delta, targetManifest, baseManifest, packageId, false, cancellation);
        var parent = PrepareParent(stagingParent);
        var work = Path.Combine(parent, ".delta-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(work);
        string? stage = null, retained = null;
        try
        {
            var temp = Path.Combine(work, "temp"); Directory.CreateDirectory(temp);
            var output = Path.Combine(work, "reconstructed.nupkg");
            var oldCopy = Path.Combine(work, "old.nupkg");
            var deltaCopy = Path.Combine(work, "delta.nupkg");
            var helperCopy = Path.Combine(work, "codec.exe");
            Copy(old, oldCopy, cancellation); Copy(delta, deltaCopy, cancellation); Copy(helper, helperCopy, cancellation);
            using var heldOld = OpenLocked(oldCopy);
            using var heldDelta = OpenLocked(deltaCopy);
            using var heldHelper = OpenLocked(helperCopy);
            var targetBytes = targetManifest.Files.Sum(file => file.Size) + ExtraExecutableLimit * 2 + MetadataLimit * 4;
            var budget = old.Length + delta.Length + HelperLength + oldBytes + deltaBytes + targetBytes * 2 + MaximumArchiveBytes;
            var drive = new DriveInfo(Path.GetPathRoot(work)!);
            if (drive.AvailableFreeSpace < budget + 64 * 1024 * 1024)
                throw new IOException("Not enough free space to reconstruct the update safely.");
            var start = new ProcessStartInfo(helperCopy) { UseShellExecute = false, CreateNoWindow = true, WorkingDirectory = work };
            foreach (var arg in new[] { "patch", "--old", oldCopy, "--delta", deltaCopy, "--output", output,
                "--log", Path.Combine(work, "patch.log") }) start.ArgumentList.Add(arg);
            start.Environment["TEMP"] = temp; start.Environment["TMP"] = temp;
            using var timeout = new CancellationTokenSource(deadline);
            using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellation, timeout.Token);
            using var process = Process.Start(start) ?? throw new IOException("The delta patch process did not start.");
            try
            {
                while (!process.HasExited)
                {
                    linked.Token.ThrowIfCancellationRequested();
                    CheckWorkspace(work, output, budget, drive, linked.Token);
                    await Task.Delay(50, linked.Token).ConfigureAwait(false);
                }
                await process.WaitForExitAsync(CancellationToken.None).ConfigureAwait(false);
                if (process.ExitCode != 0) throw new InvalidDataException("Delta reconstruction failed.");
                linked.Token.ThrowIfCancellationRequested();
                CheckWorkspace(work, output, budget, drive, linked.Token);
            }
            catch
            {
                // This handle is exclusively the codec process we just created,
                // never Doorlight, its children, or an executable found by name.
                if (!process.HasExited) process.Kill(entireProcessTree: false);
                await process.WaitForExitAsync(CancellationToken.None).ConfigureAwait(false);
                throw;
            }
            using (var reconstructed = OpenLocked(output))
            {
                stage = Extract(reconstructed, targetManifest, parent, packageId, null, cancellation);
                var actualHash = Hash(reconstructed, cancellation);
                retained = Path.Combine(parent, ".full-" + Guid.NewGuid().ToString("N") + ".nupkg");
                Copy(reconstructed, retained, cancellation);
                return new(stage, retained, actualHash);
            }
        }
        catch
        {
            if (stage is not null) DeleteOwned(stage);
            if (retained is not null) DeleteOwned(retained);
            throw;
        }
        finally { DeleteOwned(work); }
    }

    private static string Extract(Stream input, PackageManifest manifest, string parent, string packageId,
        Action<InstallProgress>? progress, CancellationToken cancellation)
    {
        Inspect(input, manifest, null, packageId, true, cancellation);
        var stage = Path.Combine(PrepareParent(parent), ".stage-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(stage);
        try
        {
            input.Position = 0;
            using var archive = new ZipArchive(input, ZipArchiveMode.Read, leaveOpen: true);
            var expected = manifest.Files.ToDictionary(file => "lib/app/" + file.Path, StringComparer.Ordinal);
            long completed = 0, total = manifest.Files.Sum(file => file.Size);
            foreach (var entry in archive.Entries)
            {
                cancellation.ThrowIfCancellationRequested();
                if (!expected.TryGetValue(entry.FullName, out var file)) continue;
                var destination = Path.Combine(stage, file.Path.Replace('/', Path.DirectorySeparatorChar));
                PackageStage.RejectLinkedAncestors(destination);
                Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
                PackageStage.RejectLinkedAncestors(destination);
                using var source = entry.Open();
                using var output = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None);
                ReadEntry(source, file.Size, cancellation, (buffer, count) => {
                    output.Write(buffer, 0, count); completed += count;
                    progress?.Invoke(new(file.Path, completed, total));
                });
                output.Flush(true);
            }
            PackageStage.VerifyDirectory(manifest, stage, cancellation: cancellation);
            return stage;
        }
        catch { DeleteOwned(stage); throw; }
    }

    // Validate every member and consume every expanded byte before native code
    // sees an archive. Canonical exact spelling avoids differing ZIP libraries
    // interpreting the same pathname differently on Windows.
    private static long Inspect(Stream input, PackageManifest manifest, PackageManifest? baseManifest,
        string packageId, bool verifyHashes, CancellationToken cancellation)
    {
        manifest.Validate(); baseManifest?.Validate();
        if (!Regex.IsMatch(packageId, @"^[A-Za-z][A-Za-z0-9_.-]{0,79}\z")) throw new InvalidDataException("Invalid package id.");
        Bounds(input);
        using var archive = new ZipArchive(input, ZipArchiveMode.Read, leaveOpen: true);
        var expected = manifest.Files.ToDictionary(file => file.Path, StringComparer.Ordinal);
        var basis = baseManifest?.Files.ToDictionary(file => file.Path, StringComparer.Ordinal);
        var names = new Dictionary<string, bool>(StringComparer.OrdinalIgnoreCase);
        var represented = new HashSet<string>(StringComparer.Ordinal);
        var checksumNames = new HashSet<string>(StringComparer.Ordinal);
        long expanded = 0;
        foreach (var entry in archive.Entries)
        {
            cancellation.ThrowIfCancellationRequested();
            var directory = entry.FullName.EndsWith('/');
            var name = directory ? entry.FullName[..^1] : entry.FullName;
            PackageManifest.ValidatePath(name);
            var unixType = (entry.ExternalAttributes >> 16) & 0xf000;
            var dosDirectory = (entry.ExternalAttributes & (int)FileAttributes.Directory) != 0;
            if (!names.TryAdd(name, directory) ||
                (entry.ExternalAttributes & (int)FileAttributes.ReparsePoint) != 0 ||
                unixType is not (0 or 0x8000 or 0x4000) ||
                (unixType == 0x4000 || dosDirectory) && !directory || unixType == 0x8000 && directory)
                throw new InvalidDataException("Duplicate, linked or conflicting archive member.");
            if (entry.Length < 0 || entry.CompressedLength < 0 || entry.CompressedLength > MaximumArchiveBytes ||
                entry.Length > PackageManifest.MaximumBytes || (expanded += entry.Length) > PackageManifest.MaximumBytes)
                throw new InvalidDataException("Archive expands beyond its budget.");
            if (directory) { if (entry.Length != 0) throw new InvalidDataException("Archive directory contains data."); continue; }
            var relative = name.StartsWith("lib/app/", StringComparison.Ordinal) ? name[8..] : null;
            long limit; PackageFile? file = null; bool patch = false, marker = false, checksum = false;
            if (relative is null) limit = Metadata(name, packageId);
            else
            {
                var target = relative;
                if (baseManifest is not null)
                {
                    if (target.EndsWith(".zsdiff", StringComparison.Ordinal)) { patch = true; target = target[..^7]; }
                    else if (target.EndsWith(".diff", StringComparison.Ordinal)) { marker = true; target = target[..^5]; }
                    else if (target.EndsWith(".shasum", StringComparison.Ordinal)) { checksum = true; target = target[..^7]; }
                    else if (target.EndsWith(".bsdiff", StringComparison.Ordinal)) throw new InvalidDataException("Unsupported legacy delta.");
                }
                if (expected.TryGetValue(target, out file)) limit = file.Size;
                else limit = Extra(target, packageId);
                if (checksum)
                {
                    if (!checksumNames.Add(target)) throw new InvalidDataException("Duplicate delta checksum.");
                    limit = 256;
                }
                else if (!represented.Add(target)) throw new InvalidDataException("Multiple delta representations for a file.");
                if (patch || marker)
                {
                    if (file is not null && (basis is null || !basis.TryGetValue(target, out var before) ||
                        marker && (before.Size != file.Size || before.Sha256 != file.Sha256)))
                        throw new InvalidDataException("Delta patch has no matching base file.");
                    if (marker && entry.Length != 0) throw new InvalidDataException("Only empty unchanged markers are supported.");
                }
                else if (!checksum && file is not null && entry.Length != file.Size)
                    throw new InvalidDataException("Archive member size differs from manifest.");
            }
            if (!patch && entry.Length > limit) throw new InvalidDataException("Archive member exceeds its budget.");
            using var content = entry.Open();
            if (patch) ValidateZstandard(content, entry.Length, limit, file is not null, cancellation);
            else if (verifyHashes && file is not null)
            {
                using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
                ReadEntry(content, entry.Length, cancellation, (buffer, count) => hash.AppendData(buffer, 0, count));
                if (!SameHash(Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant(), file.Sha256))
                    throw new InvalidDataException("Package content failed manifest verification.");
            }
            else ReadEntry(content, entry.Length, cancellation);
        }
        foreach (var pair in names)
        {
            var path = pair.Key;
            while (path.LastIndexOf('/') is var slash && slash >= 0)
            {
                path = path[..slash];
                if (names.TryGetValue(path, out var isDirectory) && !isDirectory)
                    throw new InvalidDataException("Archive path is both a file and directory.");
            }
            if (pair.Value && !names.Keys.Any(other => other.StartsWith(pair.Key + "/", StringComparison.Ordinal)))
                throw new InvalidDataException("Unexpected empty archive directory.");
        }
        if (expected.Keys.Any(path => !represented.Contains(path)) || checksumNames.Any(path => !represented.Contains(path)))
            throw new InvalidDataException("Package is missing a required file.");
        return expanded;
    }

    private static long Extra(string path, string packageId) => path switch {
        "Squirrel.exe" => ExtraExecutableLimit,
        "sq.version" => MetadataLimit,
        _ when path == packageId + "_ExecutionStub.exe" => ExtraExecutableLimit,
        _ => throw new InvalidDataException("Unexpected application package member.")
    };
    private static long Metadata(string path, string packageId) => path switch {
        "[Content_Types].xml" or "_rels/.rels" => MetadataLimit,
        _ when path == packageId + ".nuspec" => MetadataLimit,
        _ => throw new InvalidDataException("Unexpected package metadata.")
    };

    // vpk emits one standard Zstandard frame with a known content size. Reject
    // concatenated/skippable frames and unknown sizes, so codec output has a
    // defensible bound even before its filesystem monitor observes a write.
    private static void ValidateZstandard(Stream input, long length, long limit, bool exact, CancellationToken cancellation)
    {
        long read = 0;
        ulong Number(int count) {
            ulong value = 0;
            for (var i = 0; i < count; i++) {
                cancellation.ThrowIfCancellationRequested(); var next = input.ReadByte();
                if (next < 0 || ++read > length) throw new InvalidDataException("Truncated Zstandard frame.");
                value |= (ulong)next << (8 * i);
            }
            return value;
        }
        if (Number(4) != 0xfd2fb528) throw new InvalidDataException("Unsupported delta frame.");
        var descriptor = (int)Number(1);
        if ((descriptor & 0x18) != 0) throw new InvalidDataException("Reserved Zstandard frame flags.");
        bool single = (descriptor & 0x20) != 0;
        ulong window = 0;
        if (!single) {
            var wd = (int)Number(1); var basis = 1UL << (10 + (wd >> 3)); window = basis + (basis / 8) * (ulong)(wd & 7);
            if (window > PackageManifest.MaximumBytes) throw new InvalidDataException("Delta window is too large.");
        }
        Number((descriptor & 3) switch { 0 => 0, 1 => 1, 2 => 2, _ => 4 });
        var sizeBytes = (descriptor >> 6) switch { 0 => single ? 1 : 0, 1 => 2, 2 => 4, _ => 8 };
        if (sizeBytes == 0) throw new InvalidDataException("Delta frame has no bounded content size.");
        var size = Number(sizeBytes) + (sizeBytes == 2 ? 256UL : 0);
        if (size > (ulong)limit || exact && size != (ulong)limit) throw new InvalidDataException("Delta output differs from manifest size.");
        if (single) window = size;
        ulong maximumDecoded = 0;
        var buffer = new byte[81920];
        while (true) {
            var header = Number(3); bool last = (header & 1) != 0; var type = (int)((header >> 1) & 3); var blockSize = header >> 3;
            if (type == 3 || blockSize > 128 * 1024) throw new InvalidDataException("Invalid Zstandard block.");
            maximumDecoded += type == 2 ? Math.Min(window, 128UL * 1024) : blockSize;
            if (maximumDecoded > size + 128 * 1024) throw new InvalidDataException("Delta blocks exceed output budget.");
            var remaining = type == 1 ? 1L : (long)blockSize;
            while (remaining > 0) {
                cancellation.ThrowIfCancellationRequested();
                var count = input.Read(buffer, 0, (int)Math.Min(buffer.Length, remaining));
                if (count == 0 || (read += count) > length) throw new InvalidDataException("Truncated delta block.");
                remaining -= count;
            }
            if (last) break;
        }
        if ((descriptor & 4) != 0) Number(4);
        if (read != length || input.ReadByte() != -1) throw new InvalidDataException("Multiple or trailing delta frames.");
    }

    private static void Bounds(Stream input)
    {
        if (!input.CanRead || !input.CanSeek || input.Length < 22 || input.Length > MaximumArchiveBytes)
            throw new InvalidDataException("A bounded, seekable ZIP archive is required.");
        var tail = new byte[(int)Math.Min(input.Length, 65557)]; input.Position = input.Length - tail.Length; input.ReadExactly(tail);
        for (var offset = tail.Length - 22; offset >= 0; offset--) {
            var end = tail.AsSpan(offset);
            if (BinaryPrimitives.ReadUInt32LittleEndian(end) != 0x06054b50 || BinaryPrimitives.ReadUInt16LittleEndian(end[20..]) != end.Length - 22) continue;
            var count = BinaryPrimitives.ReadUInt16LittleEndian(end[10..]);
            var size = BinaryPrimitives.ReadUInt32LittleEndian(end[12..]);
            var start = BinaryPrimitives.ReadUInt32LittleEndian(end[16..]);
            if (BinaryPrimitives.ReadUInt16LittleEndian(end[4..]) != 0 || BinaryPrimitives.ReadUInt16LittleEndian(end[6..]) != 0 ||
                BinaryPrimitives.ReadUInt16LittleEndian(end[8..]) != count || count == 0 || count > PackageManifest.MaximumFiles * 2 ||
                size > 8 * 1024 * 1024 || (long)start + size != input.Length - tail.Length + offset)
                throw new InvalidDataException("Unsupported ZIP central directory.");
            ValidateCentralDirectory(input, start, count, size);
            input.Position = 0; return;
        }
        throw new InvalidDataException("ZIP central directory is missing.");
    }

    private static void ValidateCentralDirectory(Stream input, long start, int count, long size)
    {
        input.Position = start;
        var header = new byte[46]; var local = new byte[30];
        var utf8 = new System.Text.UTF8Encoding(false, true);
        for (var i = 0; i < count; i++) {
            input.ReadExactly(header);
            if (BinaryPrimitives.ReadUInt32LittleEndian(header) != 0x02014b50) throw new InvalidDataException("Malformed ZIP entry header.");
            var flags = BinaryPrimitives.ReadUInt16LittleEndian(header.AsSpan(8));
            var method = BinaryPrimitives.ReadUInt16LittleEndian(header.AsSpan(10));
            var length = BinaryPrimitives.ReadUInt16LittleEndian(header.AsSpan(28));
            var extra = BinaryPrimitives.ReadUInt16LittleEndian(header.AsSpan(30));
            var comment = BinaryPrimitives.ReadUInt16LittleEndian(header.AsSpan(32));
            var offset = BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(42));
            if ((flags & ~0x080e) != 0 || method is not (0 or 8) || length == 0 || length > 880 ||
                BinaryPrimitives.ReadUInt16LittleEndian(header.AsSpan(34)) != 0 || offset >= start)
                throw new InvalidDataException("Unsupported ZIP encoding, compression or volume.");
            var name = new byte[length]; input.ReadExactly(name);
            if ((flags & 0x0800) == 0 && name.Any(value => value > 127))
                throw new InvalidDataException("Non-ASCII archive names must explicitly use UTF-8.");
            try { _ = utf8.GetString(name); } catch (System.Text.DecoderFallbackException error) { throw new InvalidDataException("Invalid UTF-8 archive name.", error); }
            var next = input.Position + extra + comment;
            if (next > start + size) throw new InvalidDataException("ZIP header exceeds central directory.");
            input.Position = offset; input.ReadExactly(local);
            if (BinaryPrimitives.ReadUInt32LittleEndian(local) != 0x04034b50 ||
                BinaryPrimitives.ReadUInt16LittleEndian(local.AsSpan(6)) != flags ||
                BinaryPrimitives.ReadUInt16LittleEndian(local.AsSpan(8)) != method ||
                BinaryPrimitives.ReadUInt16LittleEndian(local.AsSpan(26)) != length)
                throw new InvalidDataException("ZIP local header differs from central directory.");
            var localName = new byte[length]; input.ReadExactly(localName);
            if (!name.AsSpan().SequenceEqual(localName)) throw new InvalidDataException("ZIP local pathname differs from central directory.");
            var compressed = BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(20));
            var localExtra = BinaryPrimitives.ReadUInt16LittleEndian(local.AsSpan(28));
            if (input.Position + localExtra + compressed > start) throw new InvalidDataException("ZIP member overlaps central directory.");
            input.Position = next;
        }
        if (input.Position != start + size) throw new InvalidDataException("Unexpected ZIP central directory records.");
    }

    private static void ReadEntry(Stream input, long expected, CancellationToken cancellation, Action<byte[], int>? consume = null)
    {
        var buffer = new byte[81920]; long total = 0; int count;
        while ((count = input.Read(buffer)) != 0) {
            cancellation.ThrowIfCancellationRequested(); total += count;
            if (total > expected) throw new InvalidDataException("Expanded member exceeds its declared size.");
            consume?.Invoke(buffer, count);
        }
        if (total != expected) throw new InvalidDataException("Truncated archive member.");
    }
    private static FileStream OpenLocked(string path) {
        PackageStage.RejectLinkedAncestors(path);
        return new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
    }
    private static string PrepareParent(string path) {
        path = Path.GetFullPath(path); PackageStage.RejectLinkedAncestors(path); Directory.CreateDirectory(path); PackageStage.RejectLinkedAncestors(path); return path;
    }
    private static bool SameHash(string? left, string? right) => left is not null && right is not null &&
        Regex.IsMatch(left, @"^[0-9a-f]{64}\z") && Regex.IsMatch(right, @"^[0-9a-f]{64}\z") &&
        CryptographicOperations.FixedTimeEquals(Convert.FromHexString(left), Convert.FromHexString(right));
    private static string Hash(ReadOnlySpan<byte> input) => Convert.ToHexString(SHA256.HashData(input)).ToLowerInvariant();
    private static string Hash(Stream input, CancellationToken cancellation) {
        input.Position = 0; using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        ReadEntry(input, input.Length, cancellation, (buffer, count) => hash.AppendData(buffer, 0, count));
        input.Position = 0; return Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant();
    }
    private static void Copy(Stream input, string path, CancellationToken cancellation) {
        PackageStage.RejectLinkedAncestors(path); input.Position = 0;
        using var output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None);
        ReadEntry(input, input.Length, cancellation, (buffer, count) => output.Write(buffer, 0, count)); output.Flush(true); input.Position = 0;
    }
    private static void CheckWorkspace(string work, string output, long budget, DriveInfo drive, CancellationToken cancellation) {
        long bytes = 0; int count = 0; var pending = new Stack<string>(); pending.Push(work);
        while (pending.TryPop(out var directory)) {
            string[] children;
            try { children = Directory.GetFileSystemEntries(directory); } catch (DirectoryNotFoundException) { continue; }
            foreach (var path in children) {
            cancellation.ThrowIfCancellationRequested();
            try { PackageStage.RejectLinkedAncestors(path); } catch (FileNotFoundException) { continue; } catch (DirectoryNotFoundException) { continue; }
            if (++count > PackageManifest.MaximumFiles * 8) throw new InvalidDataException("Codec created too many files.");
            if (Directory.Exists(path)) pending.Push(path);
            else {
                try { bytes += new FileInfo(path).Length; } catch (FileNotFoundException) { continue; }
                if (bytes > budget) throw new InvalidDataException("Codec exceeded its workspace budget.");
            }
        }}
        if (File.Exists(output) && new FileInfo(output).Length > MaximumArchiveBytes) throw new InvalidDataException("Reconstructed archive is too large.");
        if (drive.AvailableFreeSpace < 64 * 1024 * 1024) throw new IOException("Insufficient free space during delta reconstruction.");
    }
    private static void DeleteOwned(string path) {
        if (!File.Exists(path) && !Directory.Exists(path)) return;
        PackageStage.RejectLinkedAncestors(path);
        if (!Directory.Exists(path)) {
            // Windows may briefly retain an image mapping after the terminated
            // codec's process handle is signaled. Retry only this owned file.
            for (var attempt = 0; ; attempt++) {
                PackageStage.RejectLinkedAncestors(path);
                try { File.Delete(path); return; }
                catch (IOException) when (attempt < 20) { Thread.Sleep(50); }
                catch (UnauthorizedAccessException) when (attempt < 20) { Thread.Sleep(50); }
            }
        }
        foreach (var child in Directory.EnumerateFileSystemEntries(path)) DeleteOwned(child);
        Directory.Delete(path);
    }
}
