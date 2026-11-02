using System.Diagnostics;
using System.Security.Cryptography;
using System.Text.Json;

namespace Doorlight.Setup;

public sealed record TrustVerifierOptions(string ExecutablePath, string ExecutableSha256,
    string RootPath, string RootSha256, Uri MetadataUrl, Uri TargetsUrl, string StateDirectory,
    string Channel = "stable");
public sealed record VerifiedRelease(ReleasePolicy Policy, DateTimeOffset ExpiresUtc,
    long RootVersion, long TimestampVersion, long SnapshotVersion, long TargetsVersion);
public sealed record FeedDecision(VerifiedRelease Release, bool Eligible, string Reason);

public sealed class TrustedFeed
{
    private readonly string state;
    private readonly string channel;
    private readonly Func<CancellationToken, Task<VerifiedRelease>> verify;

    public TrustedFeed(TrustVerifierOptions options)
    {
        state = FeedFiles.Directory(options.StateDirectory);
        channel = options.Channel;
        verify = token => TrustVerifierInvoker.Verify(options, token);
    }

    // Only the linked-source fixture project can replace verification.
    internal TrustedFeed(string stateDirectory, Func<CancellationToken, Task<VerifiedRelease>> verifier, string channel = "stable")
    {
        state = FeedFiles.Directory(stateDirectory); this.channel = channel; verify = verifier;
    }

    public async Task<FeedDecision> Check(string currentVersion, string updaterVersion,
        CancellationToken token = default, bool manual = false)
    {
        var release = await verify(token);
        token.ThrowIfCancellationRequested();
        if (release.Policy.Channel != channel) throw new InvalidDataException("Release channel changed.");
        if (release.ExpiresUtc <= DateTimeOffset.UtcNow) throw new InvalidDataException("Release policy expired.");
        using var lease = FeedFiles.Lock(Path.Combine(state, "policy.lock"));
        var path = Path.Combine(state, "policy-state.json");
        var cohort = Guid.NewGuid();
        var sequence = 0L;
        var binding = "";
        if (File.Exists(path))
        {
            using var doc = JsonDocument.Parse(FeedFiles.Read(path, 4096));
            var v = doc.RootElement;
            FeedJson.Object(v, "schema", "cohort", "releaseSequence", "payloadBinding");
            FeedJson.Int(v, "schema", 1, 1);
            if (!Guid.TryParseExact(FeedJson.Text(v, "cohort", 32), "N", out cohort)) throw new InvalidDataException("Invalid local cohort.");
            sequence = FeedJson.Long(v, "releaseSequence", 1, long.MaxValue);
            binding = FeedJson.Hash(v, "payloadBinding");
        }
        var policy = release.Policy;
        var nextBinding = policy.PayloadBinding();
        if (policy.ReleaseSequence < sequence || policy.ReleaseSequence == sequence && nextBinding != binding)
            throw new InvalidDataException("Release rollback or payload replacement rejected.");
        if (sequence != policy.ReleaseSequence)
        {
            using var bytes = new MemoryStream();
            using (var json = new Utf8JsonWriter(bytes))
            {
                json.WriteStartObject(); json.WriteNumber("schema", 1); json.WriteString("cohort", cohort.ToString("N"));
                json.WriteNumber("releaseSequence", policy.ReleaseSequence); json.WriteString("payloadBinding", nextBinding); json.WriteEndObject();
            }
            FeedFiles.Atomic(path, bytes.ToArray());
        }
        return ResolveEligibility(release, currentVersion, updaterVersion, cohort, manual);
    }

    public async Task<FeedDecision> RefreshCandidate(ReleasePolicy prepared, string currentVersion,
        string updaterVersion, CancellationToken token = default, bool manual = false)
    {
        var decision = await Check(currentVersion, updaterVersion, token, manual);
        if (decision.Release.Policy.ReleaseSequence != prepared.ReleaseSequence ||
            decision.Release.Policy.Version != prepared.Version ||
            decision.Release.Policy.Manifest.Sha256 != prepared.Manifest.Sha256 ||
            decision.Release.Policy.PayloadBinding() != prepared.PayloadBinding())
            return decision with { Eligible = false, Reason = "candidate-changed" };
        return decision;
    }

    public static FeedDecision ResolveEligibility(VerifiedRelease release, string currentVersion,
        string updaterVersion, Guid cohort, bool manual = false)
    {
        var p = release.Policy;
        string reason;
        if (release.ExpiresUtc <= DateTimeOffset.UtcNow) reason = "expired";
        else if (!p.Enabled) reason = "halted";
        else if (Version.Parse(updaterVersion) < Version.Parse(p.MinimumUpdaterVersion)) reason = "updater-too-old";
        else if (Version.Parse(p.Version) <= Version.Parse(currentVersion)) reason = "not-newer";
        else if (!manual && !p.IncludesCohort(cohort)) reason = "outside-rollout";
        else reason = "eligible";
        return new(release, reason == "eligible", reason);
    }
}

public static class TrustVerifierInvoker
{
    public static async Task<VerifiedRelease> Verify(TrustVerifierOptions options, CancellationToken token = default)
    {
        FeedJson.ValidateUrl(options.MetadataUrl); FeedJson.ValidateUrl(options.TargetsUrl);
        if (options.MetadataUrl.Query != "" || options.TargetsUrl.Query != "") throw new InvalidDataException("Invalid feed base.");
        var state = FeedFiles.Directory(options.StateDirectory);
        // Keep these handles open without write/delete sharing through process exit.
        using var executable = FeedFiles.Pin(options.ExecutablePath, options.ExecutableSha256, 64L << 20);
        using var root = FeedFiles.Pin(options.RootPath, options.RootSha256, 2L << 20);
        var output = Path.Combine(state, "verified-" + Guid.NewGuid().ToString("N") + ".json");
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token);
        deadline.CancelAfter(TimeSpan.FromSeconds(75));
        using var process = new Process { StartInfo = new ProcessStartInfo {
            FileName = Path.GetFullPath(options.ExecutablePath), UseShellExecute = false, CreateNoWindow = true,
            RedirectStandardOutput = true, RedirectStandardError = true, WorkingDirectory = state,
        }};
        foreach (var arg in new[] { "verify", "--root-file", Path.GetFullPath(options.RootPath), "--metadata-url", options.MetadataUrl.AbsoluteUri,
            "--targets-url", options.TargetsUrl.AbsoluteUri, "--state-dir", Path.Combine(state, "tuf"), "--target-name", "rollout.json", "--out", output })
            process.StartInfo.ArgumentList.Add(arg);
        var started = false;
        try
        {
            if (!process.Start()) throw new IOException("The trust verifier did not start.");
            started = true;
            var stdout = Drain(process.StandardOutput, deadline.Token);
            var stderr = Drain(process.StandardError, deadline.Token);
            await process.WaitForExitAsync(deadline.Token);
            await Task.WhenAll(stdout, stderr);
            if (process.ExitCode != 0) throw new InvalidDataException("Feed authentication failed.");
            return ParseResult(FeedFiles.Read(output, 512 << 10));
        }
        catch (OperationCanceledException error) when (!token.IsCancellationRequested)
        { throw new TimeoutException("Feed authentication timed out.", error); }
        finally
        {
            // Only the verifier we started is cancelled; never the application.
            if (started && !process.HasExited) { process.Kill(entireProcessTree: true); await process.WaitForExitAsync(CancellationToken.None); }
            if (File.Exists(output)) { FeedFiles.RejectLinks(output); File.Delete(output); }
        }
    }

    private static async Task Drain(StreamReader stream, CancellationToken token)
    {
        var buffer = new char[1024]; var count = 0; int n;
        while ((n = await stream.ReadAsync(buffer.AsMemory(), token)) != 0)
        { count += n; if (count > 16384) throw new InvalidDataException("Unexpected verifier output."); }
    }

    public static VerifiedRelease ParseResult(byte[] bytes)
    {
        try { return ParseResultCore(bytes); }
        catch (Exception error) when (error is JsonException or InvalidOperationException or KeyNotFoundException or FormatException or OverflowException)
        { throw new InvalidDataException("Invalid verifier result.", error); }
    }

    private static VerifiedRelease ParseResultCore(byte[] bytes)
    {
        if (bytes.Length == 0 || bytes.Length > 512 << 10) throw new InvalidDataException("Invalid verifier result size.");
        using var doc = JsonDocument.Parse(bytes, new JsonDocumentOptions { MaxDepth = 32 });
        var v = doc.RootElement;
        FeedJson.Object(v, "schema", "targetName", "length", "sha256", "target", "rootVersion", "timestampVersion", "snapshotVersion", "targetsVersion", "expiresUtc");
        FeedJson.Int(v, "schema", 1, 1);
        if (FeedJson.Text(v, "targetName", 128) != "rollout.json") throw new InvalidDataException("Wrong verified target.");
        FeedJson.Long(v, "length", 1, 256 << 10); FeedJson.Hash(v, "sha256");
        var expiryText = FeedJson.Text(v, "expiresUtc", 64);
        if (!DateTimeOffset.TryParse(expiryText, System.Globalization.CultureInfo.InvariantCulture,
            System.Globalization.DateTimeStyles.AssumeUniversal, out var expiry) || expiry <= DateTimeOffset.UtcNow)
            throw new InvalidDataException("Expired verifier result.");
        return new(ReleasePolicy.Parse(v.GetProperty("target")), expiry,
            FeedJson.Long(v, "rootVersion", 1, long.MaxValue), FeedJson.Long(v, "timestampVersion", 1, long.MaxValue),
            FeedJson.Long(v, "snapshotVersion", 1, long.MaxValue), FeedJson.Long(v, "targetsVersion", 1, long.MaxValue));
    }
}

internal static class FeedFiles
{
    internal static void RejectLinks(string path)
    {
        var p = Path.GetFullPath(path);
        for (string? current = p; current is not null; current = Path.GetDirectoryName(current))
        {
            try { if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0) throw new InvalidDataException("Linked update path."); }
            catch (FileNotFoundException) { }
            catch (DirectoryNotFoundException) { }
        }
    }
    internal static string Directory(string path)
    {
        var full = Path.GetFullPath(path); RejectLinks(full); System.IO.Directory.CreateDirectory(full); return full;
    }
    internal static FileStream Lock(string path)
    { RejectLinks(path); return new(path, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None); }
    internal static byte[] Read(string path, int maximum)
    {
        RejectLinks(path); using var f = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        if (f.Length <= 0 || f.Length > maximum) throw new InvalidDataException("Invalid update file size.");
        var bytes = new byte[checked((int)f.Length)]; f.ReadExactly(bytes); return bytes;
    }
    internal static FileStream Pin(string path, string expected, long maximum)
    {
        RejectLinks(path);
        var f = new FileStream(Path.GetFullPath(path), FileMode.Open, FileAccess.Read, FileShare.Read);
        try {
            if (f.Length <= 0 || f.Length > maximum || expected.Length != 64 ||
                !CryptographicOperations.FixedTimeEquals(SHA256.HashData(f), Convert.FromHexString(expected)))
                throw new InvalidDataException("Pinned update component changed.");
            f.Position = 0; return f;
        } catch { f.Dispose(); throw; }
    }
    internal static void Atomic(string path, byte[] data)
    {
        RejectLinks(path); var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try {
            using (var f = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None)) { f.Write(data); f.Flush(true); }
            File.Move(temporary, path, true);
        } finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}
