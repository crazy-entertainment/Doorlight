using System.Net;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;

namespace Doorlight.Setup;

public sealed record ArtifactProgress(long Bytes, long Total);

public sealed class ArtifactCache : IDisposable
{
    private readonly string directory;
    private readonly HttpClient client;
    private readonly HashSet<string> origins;
    private readonly bool testHttp;
    private readonly TimeSpan timeout;
    private readonly Func<TimeSpan, CancellationToken, Task> delay;

    public ArtifactCache(string cacheDirectory, IEnumerable<Uri> allowedOrigins)
        : this(cacheDirectory, allowedOrigins,
            new HttpClientHandler { AllowAutoRedirect = false, UseCookies = false, UseDefaultCredentials = false }, false,
            TimeSpan.FromMinutes(20), Task.Delay) { }

    internal ArtifactCache(string cacheDirectory, IEnumerable<Uri> allowedOrigins, HttpMessageHandler handler,
        bool testHttp, TimeSpan timeout, Func<TimeSpan, CancellationToken, Task> delay)
    {
        directory = FeedFiles.Directory(cacheDirectory); this.testHttp = testHttp; this.timeout = timeout; this.delay = delay;
        origins = new(StringComparer.OrdinalIgnoreCase);
        foreach (var u in allowedOrigins) { FeedJson.ValidateUrl(u, testHttp); origins.Add(u.GetLeftPart(UriPartial.Authority)); }
        if (origins.Count == 0) throw new ArgumentException("A download origin is required.");
        client = new(handler) { Timeout = Timeout.InfiniteTimeSpan };
    }

    public async Task<string> Get(ArtifactDescriptor artifact, IProgress<ArtifactProgress>? progress = null,
        CancellationToken token = default)
    {
        FeedJson.ValidateUrl(artifact.Url, testHttp);
        if (!origins.Contains(artifact.Url.GetLeftPart(UriPartial.Authority)) || artifact.Length <= 0 || artifact.Length > 2L << 30 ||
            artifact.Sha256.Length != 64 || artifact.Sha256.Any(c => !char.IsAsciiHexDigit(c)) || artifact.Sha256 != artifact.Sha256.ToLowerInvariant())
            throw new InvalidDataException("Invalid artifact descriptor.");
        var complete = Path.Combine(directory, artifact.Sha256 + ".blob");
        var partial = Path.Combine(directory, artifact.Sha256 + ".partial");
        var validator = Path.Combine(directory, artifact.Sha256 + ".etag");
        foreach (var p in new[] { complete, partial, validator }) FeedFiles.RejectLinks(p);
        using var lease = FeedFiles.Lock(Path.Combine(directory, artifact.Sha256 + ".lock"));
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(token);
        deadline.CancelAfter(timeout);
        var ct = deadline.Token;
        try
        {
            if (await Valid(complete, artifact, ct)) { progress?.Report(new(artifact.Length, artifact.Length)); return complete; }
            if (File.Exists(complete)) File.Delete(complete);
            if (File.Exists(partial) && new FileInfo(partial).Length >= artifact.Length)
            {
                if (await Valid(partial, artifact, ct)) { File.Move(partial, complete); DeleteValidator(validator); return complete; }
                File.Delete(partial); DeleteValidator(validator);
            }
            Exception? last = null;
            for (var attempt = 0; attempt < 4; attempt++)
            {
                ct.ThrowIfCancellationRequested();
                var wait = TimeSpan.FromMilliseconds(Math.Min(8000, 500 * (1 << attempt)) + Random.Shared.Next(0, 500));
                try
                {
                    var offset = File.Exists(partial) ? new FileInfo(partial).Length : 0;
                    var etag = ReadValidator(validator);
                    using var attemptDeadline = CancellationTokenSource.CreateLinkedTokenSource(ct);
                    attemptDeadline.CancelAfter(TimeSpan.FromMinutes(5));
                    using var response = await Request(artifact.Url, offset, etag, attemptDeadline.Token);
                    if (response.StatusCode == (HttpStatusCode)429 || (int)response.StatusCode >= 500)
                    {
                        wait = RetryDelay(response, wait);
                        throw new HttpRequestException("Artifact service temporarily unavailable.");
                    }
                    if (response.StatusCode == HttpStatusCode.RequestedRangeNotSatisfiable && offset != 0)
                    { File.Delete(partial); DeleteValidator(validator); throw new HttpRequestException("Artifact range changed."); }
                    if (response.StatusCode is not (HttpStatusCode.OK or HttpStatusCode.PartialContent))
                        throw new InvalidDataException("Artifact request rejected.");
                    var resumed = response.StatusCode == HttpStatusCode.PartialContent;
                    long expectedBody;
                    if (resumed)
                    {
                        var range = response.Content.Headers.ContentRange;
                        if (offset == 0 || range is null || range.Unit != "bytes" || range.From != offset || range.Length != artifact.Length ||
                            range.To is null || range.To < offset || range.To >= artifact.Length)
                            throw new InvalidDataException("Invalid resumed range.");
                        expectedBody = range.To.Value - offset + 1;
                        if (etag is not null && response.Headers.ETag is { } returned && returned.ToString() != etag)
                            throw new InvalidDataException("Artifact validator changed during resume.");
                    }
                    else { offset = 0; expectedBody = artifact.Length; }
                    if (response.Content.Headers.ContentLength is long length && length != expectedBody)
                        throw new InvalidDataException("Invalid artifact response length.");
                    var nextTag = response.Headers.ETag;
                    if (nextTag is not null && !nextTag.IsWeak && nextTag.ToString().Length <= 512)
                        FeedFiles.Atomic(validator, Encoding.ASCII.GetBytes(nextTag.ToString()));
                    else if (!resumed) DeleteValidator(validator);
                    using (var output = new FileStream(partial, resumed ? FileMode.Open : FileMode.Create, FileAccess.Write, FileShare.None))
                    {
                        if (output.Length != offset) throw new InvalidDataException("Partial artifact changed.");
                        output.Position = offset;
                        using var input = await response.Content.ReadAsStreamAsync(attemptDeadline.Token);
                        var buffer = new byte[81920]; long read = 0; int n;
                        while ((n = await input.ReadAsync(buffer, attemptDeadline.Token)) != 0)
                        {
                            read += n;
                            if (read > expectedBody || offset + read > artifact.Length) throw new InvalidDataException("Artifact exceeds declared length.");
                            await output.WriteAsync(buffer.AsMemory(0, n), attemptDeadline.Token);
                            progress?.Report(new(offset + read, artifact.Length));
                        }
                        output.Flush(true);
                        if (read != expectedBody || offset + read != artifact.Length) throw new IOException("Artifact download was interrupted.");
                    }
                    if (!await Valid(partial, artifact, ct))
                    { File.Delete(partial); DeleteValidator(validator); throw new InvalidDataException("Artifact integrity verification failed."); }
                    File.Move(partial, complete); DeleteValidator(validator);
                    return complete;
                }
                catch (Exception e) when (e is HttpRequestException or IOException && e is not InvalidDataException)
                { last = e; }
                catch (OperationCanceledException e) when (!ct.IsCancellationRequested) { last = e; }
                if (attempt < 3) await delay(wait, ct);
            }
            throw new IOException("Artifact download failed after bounded retries.", last);
        }
        catch (OperationCanceledException error) when (!token.IsCancellationRequested)
        { throw new TimeoutException("Artifact download timed out.", error); }
    }

    private async Task<HttpResponseMessage> Request(Uri uri, long offset, string? etag, CancellationToken token)
    {
        var first = uri;
        for (var redirects = 0; redirects <= 3; redirects++)
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, uri);
            request.Headers.UserAgent.ParseAdd("Doorlight-Updater/1");
            if (offset > 0)
            {
                request.Headers.Range = new RangeHeaderValue(offset, null);
                if (etag is not null) request.Headers.IfRange = new RangeConditionHeaderValue(EntityTagHeaderValue.Parse(etag));
            }
            var response = await client.SendAsync(request, HttpCompletionOption.ResponseHeadersRead, token);
            if (response.StatusCode is not (HttpStatusCode.MovedPermanently or HttpStatusCode.Redirect or HttpStatusCode.TemporaryRedirect or HttpStatusCode.PermanentRedirect))
                return response;
            var next = response.Headers.Location;
            response.Dispose();
            if (next is null || !next.IsAbsoluteUri) throw new InvalidDataException("Invalid artifact redirect.");
            FeedJson.ValidateUrl(next, testHttp);
            if (!origins.Contains(next.GetLeftPart(UriPartial.Authority)) &&
                !(first.Host == "github.com" && next.Host is "release-assets.githubusercontent.com" or "objects.githubusercontent.com"))
                throw new InvalidDataException("Untrusted artifact redirect.");
            uri = next;
        }
        throw new InvalidDataException("Too many artifact redirects.");
    }

    private static async Task<bool> Valid(string path, ArtifactDescriptor artifact, CancellationToken token)
    {
        FeedFiles.RejectLinks(path);
        if (!File.Exists(path)) return false;
        using var f = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        return f.Length == artifact.Length && CryptographicOperations.FixedTimeEquals(await SHA256.HashDataAsync(f, token), Convert.FromHexString(artifact.Sha256));
    }
    private static string? ReadValidator(string path)
    {
        if (!File.Exists(path)) return null;
        var text = Encoding.ASCII.GetString(FeedFiles.Read(path, 512));
        if (!EntityTagHeaderValue.TryParse(text, out var tag) || tag.IsWeak) throw new InvalidDataException("Invalid cache validator.");
        return tag.ToString();
    }
    private static void DeleteValidator(string path) { if (File.Exists(path)) File.Delete(path); }
    private static TimeSpan RetryDelay(HttpResponseMessage response, TimeSpan fallback)
    {
        var retry = response.Headers.RetryAfter;
        var duration = retry?.Delta ?? (retry?.Date - DateTimeOffset.UtcNow);
        return duration is { } value ? TimeSpan.FromMilliseconds(Math.Clamp(value.TotalMilliseconds, 0, 30000)) : fallback;
    }
    public void Dispose() => client.Dispose();
}
