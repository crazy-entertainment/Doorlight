using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Diagnostics;
using System.Net.Sockets;
using Doorlight.Setup;

var root = Path.Combine(Path.GetTempPath(), "Doorlight-feed-checks-" + Guid.NewGuid().ToString("N"));
Directory.CreateDirectory(root);
var count = 0;
void Check(bool value, string message) { if (!value) throw new Exception(message); count++; }
async Task Reject(Func<Task> action, string message)
{
    try { await action(); } catch (Exception e) when (e is InvalidDataException or IOException or TimeoutException or OperationCanceledException) { count++; return; }
    throw new Exception(message);
}
string Dir() { var d = Path.Combine(root, Guid.NewGuid().ToString("N")); Directory.CreateDirectory(d); return d; }
var bytes = Encoding.UTF8.GetBytes("A complete, authenticated Doorlight archive fixture.");
var digest = Convert.ToHexString(SHA256.HashData(bytes)).ToLowerInvariant();
var artifact = new ArtifactDescriptor(new Uri("https://feed.example/fixture.zip"), bytes.Length, digest);
ReleasePolicy Policy(long seq = 1, bool enabled = true, int percent = 10000, string? hash = null)
{
    using var json = JsonDocument.Parse($$$"""
        {"schema":1,"product":"Doorlight","channel":"stable","platform":"windows-x64","releaseSequence":{{{seq}}},
        "version":"1.2.3","minimumUpdaterVersion":"1.0.0","enabled":{{{enabled.ToString().ToLowerInvariant()}}},"rolloutBasisPoints":{{{percent}}},"salt":"rollout-one",
        "manifest":{"url":"https://feed.example/manifest.json","length":100,"sha256":"{{{hash ?? digest}}}"},
        "fullPackage":{"url":"https://feed.example/package.zip","length":{{{bytes.Length}}},"sha256":"{{{digest}}}","format":"zip"}}
        """);
    return ReleasePolicy.Parse(json.RootElement);
}
VerifiedRelease Verified(ReleasePolicy p) => new(p, DateTimeOffset.UtcNow.AddHours(1), 1, 1, 1, 1);
ArtifactCache Cache(string dir, HttpMessageHandler handler, TimeSpan? timeout = null) =>
    new(dir, [artifact.Url], handler, false, timeout ?? TimeSpan.FromSeconds(5), (_, token) => Task.Delay(1, token));
HttpResponseMessage Response(byte[] data, HttpStatusCode code = HttpStatusCode.OK)
    => new(code) { Content = new ByteArrayContent(data) };

// Strict policy parsing and same-sequence payload identity.
var policy = Policy();
Check(policy.Product == "Doorlight" && policy.FullPackage.Format == "zip", "valid policy changed");
using (var invalid = JsonDocument.Parse("{\"schema\":1,\"schema\":1}"))
    await Reject(() => { ReleasePolicy.Parse(invalid.RootElement); return Task.CompletedTask; }, "duplicate policy accepted");
using (var invalid = JsonDocument.Parse("{\"schema\":\"one\"}"))
    await Reject(() => { ReleasePolicy.Parse(invalid.RootElement); return Task.CompletedTask; }, "wrong field type accepted");
await Reject(() => { TrustVerifierInvoker.ParseResult(Encoding.UTF8.GetBytes("{\"schema\":1}")); return Task.CompletedTask; }, "incomplete verifier result accepted");
Check(policy.PayloadBinding() == Policy(enabled: false, percent: 0).PayloadBinding(), "rollout controls changed payload binding");
Check(policy.PayloadBinding() != Policy(hash: new string('a', 64)).PayloadBinding(), "manifest replacement did not change binding");
var cohort = Guid.NewGuid();
Check(!Policy(percent: 0).IncludesCohort(cohort) && Policy(percent: 10000).IncludesCohort(cohort), "cohort boundaries wrong");
var previous = false;
for (var bp = 0; bp <= 10000; bp += 100)
{
    var selected = Policy(percent: bp).IncludesCohort(cohort);
    Check(!previous || selected, "increasing rollout dropped stable cohort"); previous = selected;
}

var chosen = Verified(policy);
var state = Dir();
var feed = new TrustedFeed(state, _ => Task.FromResult(chosen));
Check((await feed.Check("1.0.0", "1.0.0")).Eligible, "eligible release rejected");
chosen = Verified(Policy(enabled: false));
Check(!(await feed.RefreshCandidate(policy, "1.0.0", "1.0.0", manual: true)).Eligible, "manual bypassed halt");
chosen = Verified(Policy(percent: 0));
Check(!(await feed.RefreshCandidate(policy, "1.0.0", "1.0.0")).Eligible, "decreased rollout did not defer prepared package");
Check((await feed.Check("1.0.0", "1.0.0", manual: true)).Eligible, "manual percentage override failed");
chosen = Verified(Policy(hash: new string('a', 64)));
await Reject(() => feed.Check("1.0.0", "1.0.0"), "same sequence payload mutation accepted");
chosen = Verified(Policy(seq: 2));
Check(!(await feed.RefreshCandidate(policy, "1.0.0", "1.0.0")).Eligible, "new release reused prepared candidate");
chosen = Verified(policy);
feed = new TrustedFeed(state, _ => Task.FromResult(chosen));
await Reject(() => feed.Check("1.0.0", "1.0.0"), "release sequence replay accepted across client instances");
Check(!TrustedFeed.ResolveEligibility(Verified(policy), "1.0.0", "0.9.0", cohort, true).Eligible, "manual bypassed minimum updater");
Check(!TrustedFeed.ResolveEligibility(Verified(policy) with { ExpiresUtc = DateTimeOffset.UtcNow.AddSeconds(-1) }, "1.0.0", "1.0.0", cohort, true).Eligible, "manual bypassed expiry");

// Complete cache is always checked, and corrupt complete bytes are replaced.
var cacheDir = Dir(); var requests = 0;
using (var cache = Cache(cacheDir, new Handler((_, _) => { requests++; return Task.FromResult(Response(bytes)); })))
{
    var path = await cache.Get(artifact);
    Check(File.ReadAllBytes(path).SequenceEqual(bytes), "complete download incorrect");
    await cache.Get(artifact); Check(requests == 1, "valid cache downloaded again");
    File.WriteAllBytes(path, new byte[bytes.Length]);
    await cache.Get(artifact); Check(requests == 2, "corrupt cache reused");
}

// Persisted partial + strong validator resumes from exactly its current length.
cacheDir = Dir();
File.WriteAllBytes(Path.Combine(cacheDir, digest + ".partial"), bytes[..11]);
File.WriteAllText(Path.Combine(cacheDir, digest + ".etag"), "\"fixture-v1\"", new UTF8Encoding(false));
using (var cache = Cache(cacheDir, new Handler((r, _) => {
    Check(r.Headers.Range?.Ranges.Single().From == 11 && r.Headers.IfRange?.EntityTag?.Tag == "\"fixture-v1\"", "resume headers missing");
    var response = Response(bytes[11..], HttpStatusCode.PartialContent);
    response.Content.Headers.ContentRange = new ContentRangeHeaderValue(11, bytes.Length - 1, bytes.Length);
    response.Headers.ETag = new EntityTagHeaderValue("\"fixture-v1\"");
    return Task.FromResult(response);
}))) { Check(File.ReadAllBytes(await cache.Get(artifact)).SequenceEqual(bytes), "resumed artifact wrong"); }

// A server ignoring Range with 200 replaces, rather than appending to, the partial.
cacheDir = Dir(); File.WriteAllBytes(Path.Combine(cacheDir, digest + ".partial"), bytes[..7]);
using (var cache = Cache(cacheDir, new Handler((_, _) => Task.FromResult(Response(bytes)))))
    Check(File.ReadAllBytes(await cache.Get(artifact)).SequenceEqual(bytes), "200 resume fallback appended");

cacheDir = Dir(); File.WriteAllBytes(Path.Combine(cacheDir, digest + ".partial"), bytes[..7]);
using (var cache = Cache(cacheDir, new Handler((_, _) => {
    var response = Response(bytes[7..], HttpStatusCode.PartialContent);
    response.Content.Headers.ContentRange = new ContentRangeHeaderValue(6, bytes.Length - 2, bytes.Length);
    return Task.FromResult(response);
}))) await Reject(() => cache.Get(artifact), "wrong Content-Range accepted");

// An interrupted response preserves its useful prefix and resumes on the next try.
cacheDir = Dir(); requests = 0;
using (var cache = Cache(cacheDir, new Handler((r, _) => {
    requests++;
    if (requests == 1) {
        var interrupted = new HttpResponseMessage(HttpStatusCode.OK) { Content = new StreamContent(new BrokenStream(bytes[..9])) };
        interrupted.Content.Headers.ContentLength = bytes.Length;
        return Task.FromResult(interrupted);
    }
    Check(r.Headers.Range?.Ranges.Single().From == 9, "interrupted prefix not resumed");
    var response = Response(bytes[9..], HttpStatusCode.PartialContent);
    response.Content.Headers.ContentRange = new ContentRangeHeaderValue(9, bytes.Length - 1, bytes.Length);
    return Task.FromResult(response);
}))) Check(File.ReadAllBytes(await cache.Get(artifact)).SequenceEqual(bytes), "interrupted transfer did not recover");

using (var cache = Cache(Dir(), new Handler((_, _) => Task.FromResult(Response(new byte[bytes.Length])))))
    await Reject(() => cache.Get(artifact), "bad final SHA accepted");
using (var cache = Cache(Dir(), new Handler((_, _) => Task.FromResult(Response(new byte[bytes.Length + 1])))))
    await Reject(() => cache.Get(artifact), "oversized body accepted");
using (var cache = Cache(Dir(), new Handler((_, _) => {
    var response = Response([] , HttpStatusCode.Redirect); response.Headers.Location = new Uri("https://attacker.example/payload"); return Task.FromResult(response);
}))) await Reject(() => cache.Get(artifact), "untrusted redirect followed");

requests = 0;
using (var cache = Cache(Dir(), new Handler((_, _) => { requests++; return Task.FromResult(Response([], HttpStatusCode.ServiceUnavailable)); })))
    await Reject(() => cache.Get(artifact), "unbounded retries or failed service accepted");
Check(requests == 4, "retry count not bounded");
using (var cache = Cache(Dir(), new Handler(async (_, token) => { await Task.Delay(1000, token); return Response(bytes); }), TimeSpan.FromMilliseconds(30)))
    await Reject(() => cache.Get(artifact), "total transfer deadline ignored");

// Pins reject changed helpers before any process is started.
var pinned = Path.Combine(Dir(), "helper.exe"); File.WriteAllBytes(pinned, bytes);
await Reject(() => TrustVerifierInvoker.Verify(new(pinned, new string('0',64), pinned, digest,
    new Uri("https://feed.example/metadata"), new Uri("https://feed.example/targets"), Dir())), "unpinned helper launched");

#if DOORLIGHT_FEED_FIXTURE
if (args.Length != 2) throw new ArgumentException("Fixture checks require fixture and production verifier paths.");
var integration = Dir();
var inputPolicy = Path.Combine(integration, "policy.json");
File.WriteAllText(inputPolicy, $$$"""
    {"schema":1,"product":"Doorlight","channel":"stable","platform":"windows-x64","releaseSequence":1,
    "version":"1.2.3","minimumUpdaterVersion":"1.0.0","enabled":true,"rolloutBasisPoints":10000,"salt":"fixture",
    "manifest":{"url":"https://feed.example/manifest.json","length":100,"sha256":"{{{digest}}}"},
    "fullPackage":{"url":"https://feed.example/package.zip","length":{{{bytes.Length}}},"sha256":"{{{digest}}}","format":"zip"}}
    """, new UTF8Encoding(false));
var repo = Path.Combine(integration, "repository");
var start = new ProcessStartInfo { FileName = Path.GetFullPath(args[0]), UseShellExecute = false, CreateNoWindow = true };
foreach (var a in new[] { "fixture", "--policy-file", inputPolicy, "--repository-dir", repo }) start.ArgumentList.Add(a);
using (var process = Process.Start(start) ?? throw new Exception("Fixture builder did not start"))
{
    await process.WaitForExitAsync(); Check(process.ExitCode == 0, "fixture repository generation failed");
}
using (var server = new FixtureServer(repo))
{
    var trustRoot = Path.Combine(repo, "bootstrap.root.json");
    string HashFile(string p) { using var f = File.OpenRead(p); return Convert.ToHexString(SHA256.HashData(f)).ToLowerInvariant(); }
    var options = new TrustVerifierOptions(Path.GetFullPath(args[0]), HashFile(args[0]), trustRoot, HashFile(trustRoot),
        new Uri(server.Url + "metadata"), new Uri(server.Url + "targets"), Dir());
    var verified = await TrustVerifierInvoker.Verify(options);
    Check(verified.Policy.Version == "1.2.3" && verified.RootVersion == 1, "real Go process result invalid");
    var integratedFeed = new TrustedFeed(options);
    Check((await integratedFeed.Check("1.0.0", "1.0.0")).Eligible, "real subprocess feed check failed");
    options = options with { ExecutablePath = Path.GetFullPath(args[1]), ExecutableSha256 = HashFile(args[1]), StateDirectory = Dir() };
    await Reject(() => TrustVerifierInvoker.Verify(options), "production Go verifier accepted fixture HTTP");
}
#endif
Console.WriteLine($"PASS: {count} feed/cache assertions. Scratch: {root}");

sealed class Handler(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> send) : HttpMessageHandler
{
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) => send(request, cancellationToken);
}
sealed class BrokenStream(byte[] prefix) : MemoryStream(prefix)
{
    public override ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
    {
        if (Position == Length) throw new IOException("Synthetic interrupted connection.");
        return base.ReadAsync(buffer, cancellationToken);
    }
}

#if DOORLIGHT_FEED_FIXTURE
sealed class FixtureServer : IDisposable
{
    private readonly HttpListener listener = new();
    private readonly Task serving;
    public string Url { get; }
    public FixtureServer(string root)
    {
        var socket = new TcpListener(IPAddress.Loopback, 0); socket.Start();
        var port = ((IPEndPoint)socket.LocalEndpoint).Port; socket.Stop();
        Url = $"http://127.0.0.1:{port}/";
        listener.Prefixes.Add(Url); listener.Start();
        serving = Task.Run(async () => {
            while (listener.IsListening)
            {
                HttpListenerContext context;
                try { context = await listener.GetContextAsync(); } catch (Exception e) when (e is HttpListenerException or ObjectDisposedException) { break; }
                try {
                    var relative = context.Request.Url!.AbsolutePath.TrimStart('/').Replace('/', Path.DirectorySeparatorChar);
                    var path = Path.GetFullPath(Path.Combine(root, relative));
                    if (!path.StartsWith(root + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase) || !File.Exists(path)) context.Response.StatusCode = 404;
                    else { var content = File.ReadAllBytes(path); context.Response.ContentLength64 = content.Length; await context.Response.OutputStream.WriteAsync(content); }
                } finally { context.Response.Close(); }
            }
        });
    }
    public void Dispose() { listener.Close(); serving.GetAwaiter().GetResult(); }
}
#endif
