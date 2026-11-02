using System.IO.Compression;
using System.Reflection;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;
using System.Text.RegularExpressions;

namespace Doorlight.Setup;

internal sealed record DistributionConfig(int Schema, string MetadataUrl, string TargetsUrl,
    string RootSha256, string VerifierSha256, long VerifierLength, string UpdaterVersion,
    string Channel = "stable", string PackageId = "Doorlight");
internal sealed record AcceptedDistributionBase(int Schema, DeltaBaseReceipt Receipt);

internal sealed record DistributionPrepared(FeedDecision Decision, PackageManifest Manifest,
    string ManifestPath, string PackagePath, string StageDirectory, bool UsedDelta,
    string ActualPackageSha256)
{
    internal ReleasePolicy Policy => Decision.Release.Policy;
}

// Feed trust and archive preparation only. The caller retains all lifecycle,
// profile-lock, journal and startup-health authority.
internal sealed class DistributionRuntime
{
    private const string ConfigResource = "Doorlight.Feed.json";
    private const string RootResource = "Doorlight.Trust.Root.json";
    private const string VerifierResource = "Doorlight.Trust.exe.br";
    private const string DeltaResource = "Doorlight.Delta.exe.br";
    private readonly DistributionConfig? config;
    private readonly string state;
    private readonly Func<string, Stream?> resource;
    internal bool IsConfigured => config is not null;

    private DistributionRuntime(Func<string, Stream?> resource, string state, DistributionConfig? config)
    { this.resource = resource; this.state = state; this.config = config; }

    internal static DistributionRuntime Load()
    {
        var assembly = Assembly.GetExecutingAssembly();
#if DOORLIGHT_FEED_FIXTURE
        const string stateLeaf = "fixture-updates";
#else
        const string stateLeaf = "updates";
#endif
        var state = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Doorlight", stateLeaf);
        return LoadResources(assembly.GetManifestResourceStream, state);
    }

#if DOORLIGHT_FEED_FIXTURE
    internal static DistributionRuntime LoadFixture(string stateDirectory, Func<string, Stream?>? resources = null)
        => LoadResources(resources ?? Assembly.GetExecutingAssembly().GetManifestResourceStream, Path.GetFullPath(stateDirectory));
#endif

    private static DistributionRuntime LoadResources(Func<string, Stream?> resources, string state)
    {
        using var input = resources(ConfigResource);
        if (input is null) return new(resources, state, null);
        var bytes = ReadBounded(input, 16 << 10);
        var configuration = JsonSerializer.Deserialize(bytes, DistributionJsonContext.Default.DistributionConfig)
            ?? throw new InvalidDataException("Update configuration is missing.");
        Validate(configuration);
        return new(resources, state, configuration);
    }

    internal async Task<FeedDecision?> Check(string current, bool manual, CancellationToken token = default)
    {
        if (config is null) return null;
        var feed = await CreateFeed(token);
        return await feed.Check(current, config.UpdaterVersion, token, manual);
    }

    internal async Task<DistributionPrepared> Prepare(FeedDecision decision, string current,
        IProgress<InstallProgress>? progress = null, CancellationToken token = default)
    {
        var configuration = RequireConfiguration();
        if (!decision.Eligible || decision.Release.ExpiresUtc <= DateTimeOffset.UtcNow || !decision.Release.Policy.Enabled)
            throw new InvalidDataException("This release is not eligible for installation.");
        var policy = decision.Release.Policy;
        if (policy.Channel != configuration.Channel || policy.Platform != "windows-x64" || policy.Product != "Doorlight")
            throw new InvalidDataException("The release does not match this installer.");
        var artifacts = Ensure(Path.Combine(state, "artifacts"));
        var origins = new List<Uri> { policy.Manifest.Url, policy.FullPackage.Url };
        origins.AddRange(policy.Deltas.Select(d => d.Patch.Url));
        using var cache = new ArtifactCache(artifacts, origins);
        var manifestPath = await cache.Get(policy.Manifest, new DownloadProgress("Doorlight.Package.json", progress), token);
        var manifestBytes = ReadFile(manifestPath, 8 << 20);
        RequireHash(manifestBytes, policy.Manifest.Sha256);
        using var metadata = new MemoryStream(manifestBytes, writable: false);
        var manifest = PackageManifest.Read(metadata);
        if (manifest.Version != policy.Version) throw new InvalidDataException("The authenticated manifest version changed.");
        string? stage = null;
        string? retainedDelta = null;
        try
        {
            // A failed optimization falls back to the independently authenticated
            // full package; cancellation must never trigger a second download.
            if (policy.FullPackage.Format == "velopack")
            {
                try
                {
                    var prepared = await TryDelta(decision, current, manifest, manifestPath, cache, progress, token);
                    if (prepared is not null)
                    {
                        stage = prepared.StageDirectory;
                        retainedDelta = prepared.PackagePath;
                        ValidateExecutables(stage);
                        return prepared;
                    }
                }
                catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidDataException or TimeoutException or JsonException or System.ComponentModel.Win32Exception)
                {
                    if (stage is not null) { DeleteOwnedStage(stage); stage = null; }
                    if (retainedDelta is not null) { DeleteOwnedArchive(retainedDelta); retainedDelta = null; }
                    token.ThrowIfCancellationRequested();
                }
            }
            var package = await cache.Get(policy.FullPackage, new DownloadProgress("Doorlight.Package", progress), token);
            stage = await Task.Run(() => {
                token.ThrowIfCancellationRequested();
                if (policy.FullPackage.Format == "velopack")
                    return DeltaPackage.Extract(package, manifest, InstalledApp.Root, configuration.PackageId, Report(progress), token);
                using var archive = new FileStream(package, FileMode.Open, FileAccess.Read, FileShare.Read);
                return PackageStage.Extract(archive, manifest, InstalledApp.Root, Report(progress), token);
            }, token);
            ValidateExecutables(stage);
            return new(decision, manifest, manifestPath, package, stage, false, policy.FullPackage.Sha256);
        }
        catch
        {
            if (stage is not null) DeleteOwnedStage(stage);
            if (retainedDelta is not null) DeleteOwnedArchive(retainedDelta);
            throw;
        }
    }

    internal async Task<FeedDecision> Refresh(DistributionPrepared prepared, string current, bool manual,
        CancellationToken token = default)
    {
        var configuration = RequireConfiguration();
        var feed = await CreateFeed(token);
        return await feed.RefreshCandidate(prepared.Policy, current, configuration.UpdaterVersion, token, manual);
    }

    // The caller still owns stage/journal recovery. Only the disposable archive
    // produced by our delta codec is eligible here, including after acceptance.
    internal static bool Discard(DistributionPrepared prepared)
    {
        if (!prepared.UsedDelta) return true;
        try { DeleteOwnedArchive(prepared.PackagePath); return true; }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidDataException or ArgumentException or NotSupportedException)
        { return false; }
    }

    // Call ONLY after startup acknowledgment and BundleInstall.Accept. Cache
    // failure is optional and cannot turn an accepted installation into failure.
    internal async Task<bool> Accept(DistributionPrepared prepared, CancellationToken token = default)
    {
        try
        {
            var configuration = RequireConfiguration();
            Ensure(state);
            using var lease = Lock(Path.Combine(state, "base.lock"));
            await Task.Run(() => PackageStage.VerifyDirectory(prepared.Manifest,
                Path.Combine(InstalledApp.Root, "current"), cancellation: token), token);
            var manifestBytes = ReadFile(prepared.ManifestPath, 8 << 20);
            var receipt = new DeltaBaseReceipt(prepared.Policy.Version, prepared.Policy.FullPackage.Sha256,
                prepared.ActualPackageSha256, prepared.Policy.Manifest.Sha256);
            var identity = new DeltaBaseIdentity(receipt.Version, receipt.OriginalPackageSha256, receipt.ManifestSha256);
            if (prepared.Policy.FullPackage.Format == "velopack")
                await Task.Run(() => DeltaPackage.VerifyBase(prepared.PackagePath, manifestBytes, receipt,
                    identity, configuration.PackageId, token), token);
            else
            {
                RequireHash(manifestBytes, receipt.ManifestSha256);
                PackageStage.RejectLinkedAncestors(prepared.PackagePath);
                using var package = new FileStream(prepared.PackagePath, FileMode.Open, FileAccess.Read, FileShare.Read);
                if (package.Length != prepared.Policy.FullPackage.Length ||
                    Convert.ToHexString(await SHA256.HashDataAsync(package, token)).ToLowerInvariant() != receipt.CachedPackageSha256)
                    throw new InvalidDataException("Accepted archive changed.");
            }
            var cached = Path.Combine(Ensure(Path.Combine(state, "artifacts")), receipt.CachedPackageSha256 + ".blob");
            if (!string.Equals(Path.GetFullPath(prepared.PackagePath), cached, StringComparison.OrdinalIgnoreCase))
            {
                PackageStage.RejectLinkedAncestors(cached);
                if (File.Exists(cached))
                {
                    using var existing = new FileStream(cached, FileMode.Open, FileAccess.Read, FileShare.Read);
                    if (Hash(existing) != receipt.CachedPackageSha256) throw new InvalidDataException("Cached base archive changed.");
                }
                else await CopyArchive(prepared.PackagePath, cached, token);
            }
            var data = JsonSerializer.SerializeToUtf8Bytes(new AcceptedDistributionBase(1, receipt),
                DistributionJsonContext.Default.AcceptedDistributionBase);
            Atomic(Path.Combine(state, "accepted-base.json"), data);
            if (prepared.UsedDelta) DeleteOwnedArchive(prepared.PackagePath);
            PruneArtifacts(prepared.Policy, receipt);
            return true;
        }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidDataException)
        { return false; }
    }

    private async Task<DistributionPrepared?> TryDelta(FeedDecision decision, string current, PackageManifest manifest,
        string manifestPath, ArtifactCache cache, IProgress<InstallProgress>? progress, CancellationToken token)
    {
        var configuration = RequireConfiguration();
        var matching = decision.Release.Policy.Deltas.FirstOrDefault(delta => delta.BaseVersion == current);
        if (matching is null) return null;
        var receiptPath = Path.Combine(state, "accepted-base.json");
        if (!File.Exists(receiptPath)) return null;
        var accepted = JsonSerializer.Deserialize(ReadFile(receiptPath, 4096), DistributionJsonContext.Default.AcceptedDistributionBase);
        if (accepted?.Schema != 1 || accepted.Receipt is not { } receipt || !IsHash(receipt.CachedPackageSha256) || !IsHash(receipt.ManifestSha256))
            throw new InvalidDataException("Invalid accepted base receipt.");
        var basePath = Path.Combine(state, "artifacts", receipt.CachedPackageSha256 + ".blob");
        var baseManifestPath = Path.Combine(state, "artifacts", receipt.ManifestSha256 + ".blob");
        var baseBytes = ReadFile(baseManifestPath, 8 << 20);
        var required = new DeltaBaseIdentity(matching.BaseVersion, matching.BasePackageSha256, matching.BaseManifestSha256);
        var baseManifest = await Task.Run(() => DeltaPackage.VerifyBase(basePath, baseBytes, receipt,
            required, configuration.PackageId, token), token);
        using var embedded = resource(DeltaResource);
        if (embedded is null) return null;
        var codec = await ExtractResource(DeltaResource, DeltaPackage.HelperSha256, DeltaPackage.HelperLength, true, token);
        var patch = await cache.Get(matching.Patch, new DownloadProgress("Doorlight.Delta", progress), token);
        var result = await DeltaPackage.RunPatchAsync(codec, basePath, patch, matching.Patch.Sha256,
            baseManifest, manifest, InstalledApp.Root, configuration.PackageId, TimeSpan.FromMinutes(5), token);
        return new(decision, manifest, manifestPath, result.PackagePath, result.StageDirectory, true, result.PackageSha256);
    }

    private async Task<TrustedFeed> CreateFeed(CancellationToken token)
    {
        var c = RequireConfiguration();
        var root = await ExtractResource(RootResource, c.RootSha256, 2 << 20, false, token);
        var verifier = await ExtractResource(VerifierResource, c.VerifierSha256, c.VerifierLength, true, token);
        return new(new TrustVerifierOptions(verifier, c.VerifierSha256, root, c.RootSha256,
            new Uri(c.MetadataUrl), new Uri(c.TargetsUrl), state, c.Channel));
    }

    private async Task<string> ExtractResource(string resource, string sha256, long length, bool compressed, CancellationToken token)
    {
        var tools = Ensure(Path.Combine(state, "tools"));
        using var lease = Lock(Path.Combine(tools, sha256 + ".lock"));
        var destination = Path.Combine(tools, sha256 + (compressed ? ".exe" : ".json"));
        PackageStage.RejectLinkedAncestors(destination);
        if (File.Exists(destination))
        {
            using var existing = new FileStream(destination, FileMode.Open, FileAccess.Read, FileShare.Read);
            if (existing.Length <= length && (!compressed || existing.Length == length) && Hash(existing) == sha256) return destination;
            throw new InvalidDataException("An extracted trust component changed.");
        }
        using var embedded = this.resource(resource)
            ?? throw new InvalidDataException("A configured trust resource is missing.");
        using var source = compressed ? new BrotliStream(embedded, CompressionMode.Decompress, leaveOpen: true) : embedded;
        var temporary = destination + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            using (var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            using (var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256))
            {
                var buffer = new byte[81920]; long written = 0; int n;
                while ((n = await source.ReadAsync(buffer, token)) != 0)
                {
                    written += n;
                    if (written > length) throw new InvalidDataException("Embedded trust resource exceeds its bounds.");
                    hash.AppendData(buffer, 0, n); await output.WriteAsync(buffer.AsMemory(0, n), token);
                }
                if (written == 0 || compressed && written != length ||
                    Convert.ToHexString(hash.GetHashAndReset()).ToLowerInvariant() != sha256)
                    throw new InvalidDataException("Embedded trust resource failed its pinned hash.");
                output.Flush(true);
            }
            File.Move(temporary, destination);
            return destination;
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }

    private DistributionConfig RequireConfiguration() => config ?? throw new InvalidOperationException("Online updates are not configured in this build.");

    // Opportunistic cache maintenance never removes trust state or unknown names.
    // Locks use exactly ArtifactCache's per-digest protocol and remain on disk.
    private void PruneArtifacts(ReleasePolicy policy, DeltaBaseReceipt receipt)
    {
        var directory = Path.Combine(state, "artifacts");
        PackageStage.RejectLinkedAncestors(directory);
        var keep = new HashSet<string>(StringComparer.Ordinal) {
            receipt.CachedPackageSha256, receipt.ManifestSha256, policy.Manifest.Sha256, policy.FullPackage.Sha256,
        };
        foreach (var delta in policy.Deltas) keep.Add(delta.Patch.Sha256);
        var files = new List<FileInfo>();
        var examined = 0;
        foreach (var pattern in new[] { "*.blob", "*.partial", "*.etag" })
        {
            foreach (var path in Directory.EnumerateFiles(directory, pattern, SearchOption.TopDirectoryOnly))
            {
                if (++examined > 8192 || files.Count >= 4096) break;
                if (!Regex.IsMatch(Path.GetFileName(path), @"^[0-9a-f]{64}\.(blob|partial|etag)\z")) continue;
                PackageStage.RejectLinkedAncestors(path);
                files.Add(new FileInfo(path));
            }
            if (examined > 8192 || files.Count >= 4096) break;
        }
        long total = files.Sum(file => file.Length);
        var staleBefore = DateTime.UtcNow.AddDays(-7);
        var recentlyUsed = DateTime.UtcNow.AddHours(-1);
        foreach (var file in files.OrderBy(file => file.LastWriteTimeUtc))
        {
            var digest = file.Name[..64];
            if (keep.Contains(digest) || file.LastWriteTimeUtc >= recentlyUsed || file.LastWriteTimeUtc >= staleBefore && total <= 2L << 30) continue;
            try
            {
                using var lease = Lock(Path.Combine(directory, digest + ".lock"));
                PackageStage.RejectLinkedAncestors(file.FullName);
                file.Refresh();
                if (!file.Exists || file.LastWriteTimeUtc >= recentlyUsed || file.LastWriteTimeUtc >= staleBefore && total <= 2L << 30) continue;
                var length = file.Length; File.Delete(file.FullName); total -= length;
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidDataException) { }
        }
    }
    private static void Validate(DistributionConfig c)
    {
        if (c.Schema != 1 || !IsHash(c.RootSha256) || !IsHash(c.VerifierSha256) || c.VerifierLength is <= 0 or > 67108864 ||
            c.UpdaterVersion is null || !Regex.IsMatch(c.UpdaterVersion, @"^\d+\.\d+\.\d+\z") || !Version.TryParse(c.UpdaterVersion, out _) ||
            c.Channel is null || !Regex.IsMatch(c.Channel, @"^[a-z][a-z0-9-]{0,31}\z") ||
            c.PackageId is null || !Regex.IsMatch(c.PackageId, @"^[A-Za-z][A-Za-z0-9_.-]{0,79}\z"))
            throw new InvalidDataException("Invalid embedded distribution configuration.");
        foreach (var text in new[] { c.MetadataUrl, c.TargetsUrl })
        {
            if (!Uri.TryCreate(text, UriKind.Absolute, out var uri) || uri.UserInfo != "" || uri.Fragment != "" || uri.Query != "")
                throw new InvalidDataException("Invalid embedded feed URL.");
#if DOORLIGHT_FEED_FIXTURE
            if (uri.Scheme == "http" && uri.Host == "127.0.0.1") continue;
#endif
            if (uri.Scheme != "https" || !uri.IsDefaultPort) throw new InvalidDataException("Unsafe embedded feed URL.");
        }
    }
    private static bool IsHash(string? value) => value is not null && Regex.IsMatch(value, @"^[0-9a-f]{64}\z");
    private static void ValidateExecutables(string stage)
    {
        WindowsExecutable.Validate(Path.Combine(stage, "sybl.exe"));
        WindowsExecutable.Validate(Path.Combine(stage, "_setup", "DoorlightUpdater.exe"));
    }
    private static Action<InstallProgress>? Report(IProgress<InstallProgress>? progress) => progress is null ? null : progress.Report;
    private sealed class DownloadProgress(string name, IProgress<InstallProgress>? progress) : IProgress<ArtifactProgress>
    { public void Report(ArtifactProgress value) => progress?.Report(new(name, value.Bytes, value.Total)); }
    private static string Ensure(string path)
    { PackageStage.RejectLinkedAncestors(path); Directory.CreateDirectory(path); return Path.GetFullPath(path); }
    private static FileStream Lock(string path)
    { PackageStage.RejectLinkedAncestors(path); return new(path, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None); }
    private static byte[] ReadFile(string path, int limit)
    { PackageStage.RejectLinkedAncestors(path); using var input = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read); return ReadBounded(input, limit); }
    private static byte[] ReadBounded(Stream input, int limit)
    {
        using var output = new MemoryStream(); var buffer = new byte[8192]; int n;
        while ((n = input.Read(buffer)) != 0) { if (output.Length + n > limit) throw new InvalidDataException("Distribution metadata is too large."); output.Write(buffer, 0, n); }
        return output.ToArray();
    }
    private static string Hash(Stream input) => Convert.ToHexString(SHA256.HashData(input)).ToLowerInvariant();
    private static void RequireHash(byte[] bytes, string hash)
    { if (Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant() != hash) throw new InvalidDataException("Authenticated artifact changed."); }
    private static void Atomic(string path, byte[] data)
    {
        PackageStage.RejectLinkedAncestors(path); var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try { using (var f = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None)) { f.Write(data); f.Flush(true); } File.Move(temporary, path, true); }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
    private static async Task CopyArchive(string source, string destination, CancellationToken token)
    {
        PackageStage.RejectLinkedAncestors(source); PackageStage.RejectLinkedAncestors(destination);
        using var input = new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.Read);
        if (input.Length > DeltaPackage.MaximumArchiveBytes) throw new InvalidDataException("Base archive is too large.");
        var temporary = destination + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try { using (var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None)) { await input.CopyToAsync(output, token); output.Flush(true); } File.Move(temporary, destination); }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
    private static void DeleteOwnedStage(string path)
    {
        var full = Path.GetFullPath(path);
        if (Path.GetDirectoryName(full) != Path.GetFullPath(InstalledApp.Root) || !Regex.IsMatch(Path.GetFileName(full), @"^\.stage-[0-9a-f]{32}\z"))
            throw new InvalidDataException("Invalid stage cleanup path.");
        DeleteTree(full);
    }
    private static void DeleteTree(string path)
    {
        PackageStage.RejectLinkedAncestors(path);
        if (Directory.Exists(path)) { foreach (var child in Directory.EnumerateFileSystemEntries(path)) DeleteTree(child); Directory.Delete(path); }
        else if (File.Exists(path)) File.Delete(path);
    }
    private static void DeleteOwnedArchive(string path)
    {
        var full = Path.GetFullPath(path);
        if (Path.GetDirectoryName(full) != Path.GetFullPath(InstalledApp.Root) || !Regex.IsMatch(Path.GetFileName(full), @"^\.full-[0-9a-f]{32}\.nupkg\z"))
            throw new InvalidDataException("Invalid reconstructed archive cleanup path.");
        PackageStage.RejectLinkedAncestors(full); if (File.Exists(full)) File.Delete(full);
    }
}

[JsonSourceGenerationOptions(PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase,
    UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow)]
[JsonSerializable(typeof(DistributionConfig))]
[JsonSerializable(typeof(AcceptedDistributionBase))]
internal partial class DistributionJsonContext : JsonSerializerContext;
