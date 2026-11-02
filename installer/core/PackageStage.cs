using System.IO.Compression;
using System.Buffers.Binary;
using System.Security.Cryptography;

namespace Doorlight.Setup;

public sealed record InstallProgress(string File, long CompletedBytes, long TotalBytes);

public static class PackageStage
{
    // The caller owns the returned directory. No installed file is touched here.
    public static string Extract(Stream archiveStream, PackageManifest manifest,
        string stagingParent, Action<InstallProgress>? progress = null,
        CancellationToken cancellation = default)
    {
        manifest.Validate();
        ValidateArchiveBounds(archiveStream);
        RejectLinkedAncestors(stagingParent);
        Directory.CreateDirectory(stagingParent);
        RejectLinkedAncestors(stagingParent);
        var stage = Path.Combine(Path.GetFullPath(stagingParent), ".stage-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(stage);
        try
        {
            using var archive = new ZipArchive(archiveStream, ZipArchiveMode.Read, leaveOpen: true);
            var expected = manifest.Files.ToDictionary(f => f.Path, StringComparer.OrdinalIgnoreCase);
            var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
            var total = manifest.Files.Sum(f => f.Size);
            long completed = 0;
            if (archive.Entries.Count > PackageManifest.MaximumFiles * 2)
                throw new InvalidDataException("Too many archive entries.");
            foreach (var entry in archive.Entries)
            {
                cancellation.ThrowIfCancellationRequested();
                var directory = entry.FullName.EndsWith('/');
                var name = directory ? entry.FullName[..^1] : entry.FullName;
                PackageManifest.ValidatePath(name);
                if (!seen.Add(name) || (entry.ExternalAttributes & unchecked((int)0xf0000000)) == unchecked((int)0xa0000000) ||
                    (entry.ExternalAttributes & (int)FileAttributes.ReparsePoint) != 0)
                    throw new InvalidDataException("Duplicate or linked archive entry.");
                if (directory)
                {
                    if (entry.Length != 0 || expected.ContainsKey(name) ||
                        !expected.Keys.Any(path => path.StartsWith(name + "/", StringComparison.OrdinalIgnoreCase)))
                        throw new InvalidDataException("Unexpected archive directory.");
                    continue;
                }
                if (!expected.TryGetValue(name, out var file) || entry.Length != file.Size)
                    throw new InvalidDataException("Archive does not match its manifest.");
                var destination = Path.Combine(stage, name.Replace('/', Path.DirectorySeparatorChar));
                RejectLinkedAncestors(destination);
                Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
                RejectLinkedAncestors(destination);
                using var input = entry.Open();
                using var output = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None);
                using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
                var buffer = new byte[81920];
                long written = 0;
                progress?.Invoke(new InstallProgress(name, completed, total));
                int count;
                while ((count = input.Read(buffer)) > 0)
                {
                    cancellation.ThrowIfCancellationRequested();
                    written += count;
                    if (written > file.Size) throw new InvalidDataException("Expanded file exceeds its declared size.");
                    output.Write(buffer, 0, count);
                    hash.AppendData(buffer, 0, count);
                    completed += count;
                    progress?.Invoke(new InstallProgress(name, completed, total));
                }
                if (written != file.Size || !CryptographicOperations.FixedTimeEquals(
                    hash.GetHashAndReset(), Convert.FromHexString(file.Sha256)))
                    throw new InvalidDataException("Package file failed integrity verification.");
                output.Flush(flushToDisk: true);
            }
            if (expected.Keys.Any(name => !seen.Contains(name)))
                throw new InvalidDataException("Archive is missing a required file.");
            cancellation.ThrowIfCancellationRequested();
            ValidateVersion(stage, manifest.Version);
            return stage;
        }
        catch
        {
            Directory.Delete(stage, recursive: true);
            throw;
        }
    }

    public static void VerifyDirectory(PackageManifest manifest, string stage,
        Action<InstallProgress>? progress = null, CancellationToken cancellation = default)
    {
        manifest.Validate();
        RejectLinkedAncestors(stage);
        if (!Directory.Exists(stage)) throw new InvalidDataException("The staged bundle is missing.");
        var expected = manifest.Files.ToDictionary(file => file.Path, StringComparer.OrdinalIgnoreCase);
        var seen = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        var pending = new Stack<string>();
        pending.Push(Path.GetFullPath(stage));
        var total = manifest.Files.Sum(file => file.Size);
        long completed = 0;
        var entries = 0;
        while (pending.TryPop(out var directory))
        {
            foreach (var path in Directory.EnumerateFileSystemEntries(directory))
            {
                cancellation.ThrowIfCancellationRequested();
                if (++entries > PackageManifest.MaximumFiles * 2)
                    throw new InvalidDataException("Too many staged entries.");
                RejectLinkedAncestors(path);
                var name = Path.GetRelativePath(stage, path).Replace(Path.DirectorySeparatorChar, '/');
                PackageManifest.ValidatePath(name);
                if ((File.GetAttributes(path) & FileAttributes.Directory) != 0)
                {
                    if (!expected.Keys.Any(key => key.StartsWith(name + "/", StringComparison.OrdinalIgnoreCase)))
                        throw new InvalidDataException("Unexpected staged directory.");
                    pending.Push(path);
                    continue;
                }
                if (!seen.Add(name) || !expected.TryGetValue(name, out var file))
                    throw new InvalidDataException("Unexpected staged file.");
                using var input = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
                if (input.Length != file.Size) throw new InvalidDataException("Staged file size does not match.");
                using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
                var buffer = new byte[81920];
                progress?.Invoke(new(name, completed, total));
                int count;
                while ((count = input.Read(buffer)) != 0)
                {
                    cancellation.ThrowIfCancellationRequested();
                    hash.AppendData(buffer, 0, count);
                    completed += count;
                    progress?.Invoke(new(name, completed, total));
                }
                if (!CryptographicOperations.FixedTimeEquals(hash.GetHashAndReset(), Convert.FromHexString(file.Sha256)))
                    throw new InvalidDataException("Staged file failed integrity verification.");
            }
        }
        if (seen.Count != expected.Count) throw new InvalidDataException("Staged bundle is missing a required file.");
        cancellation.ThrowIfCancellationRequested();
        ValidateVersion(stage, manifest.Version);
    }

    public static string ReadVersion(string directory)
    {
        var path = Path.Combine(directory, "Doorlight.version");
        RejectLinkedAncestors(path);
        if (!File.Exists(path) || new FileInfo(path).Length > 64)
            throw new InvalidDataException("Bundle version is missing or too large.");
        var version = File.ReadAllText(path).Trim();
        if (!System.Text.RegularExpressions.Regex.IsMatch(version, @"^\d+\.\d+\.\d+\z") ||
            !Version.TryParse(version, out _))
            throw new InvalidDataException("Bundle version is invalid.");
        return version;
    }

    private static void ValidateVersion(string directory, string expected)
    {
        if (ReadVersion(directory) != expected)
            throw new InvalidDataException("Bundle version does not match its manifest.");
    }

    public static void RejectLinkedAncestors(string path)
    {
        for (var current = Path.GetFullPath(path); current is not null; current = Path.GetDirectoryName(current))
        {
            if ((File.Exists(current) || Directory.Exists(current)) &&
                (File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
                throw new IOException("Setup paths must not contain symbolic links or junctions.");
        }
    }

    private static void ValidateArchiveBounds(Stream input)
    {
        // ZipArchive buffers non-seekable streams and loads the central directory
        // eagerly. Bound both before it allocates; release packages use classic ZIP.
        if (!input.CanRead || !input.CanSeek || input.Length < 22 || input.Length > 2L * 1024 * 1024 * 1024)
            throw new InvalidDataException("Setup requires a bounded, seekable ZIP package.");
        var tail = new byte[(int)Math.Min(input.Length, 65557)];
        input.Position = input.Length - tail.Length;
        input.ReadExactly(tail);
        for (var offset = tail.Length - 22; offset >= 0; offset--)
        {
            var end = tail.AsSpan(offset);
            if (BinaryPrimitives.ReadUInt32LittleEndian(end) != 0x06054b50 ||
                BinaryPrimitives.ReadUInt16LittleEndian(end[20..]) != end.Length - 22) continue;
            var count = BinaryPrimitives.ReadUInt16LittleEndian(end[10..]);
            var size = BinaryPrimitives.ReadUInt32LittleEndian(end[12..]);
            var start = BinaryPrimitives.ReadUInt32LittleEndian(end[16..]);
            var endPosition = input.Length - tail.Length + offset;
            if (BinaryPrimitives.ReadUInt16LittleEndian(end[4..]) != 0 ||
                BinaryPrimitives.ReadUInt16LittleEndian(end[6..]) != 0 ||
                BinaryPrimitives.ReadUInt16LittleEndian(end[8..]) != count ||
                count == 0 || count > PackageManifest.MaximumFiles * 2 ||
                size > 8 * 1024 * 1024 || (long)start + size != endPosition)
                throw new InvalidDataException("Unsupported or oversized ZIP directory.");
            input.Position = 0;
            return;
        }
        throw new InvalidDataException("ZIP directory is missing.");
    }
}
