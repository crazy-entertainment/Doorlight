using System.Net;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Doorlight.Setup;

public sealed record ReleaseAsset(string Name, Uri Url, long Size, string Digest);

public static class ReleaseDownload
{
    public const string Repository = "https://github.com/crazy-entertainment/Doorlight";

    public static ReleaseAsset ReadAsset(JsonElement release, string version, string name)
    {
        if (!Regex.IsMatch(version, @"^\d+\.\d+\.\d+\z") ||
            release.GetProperty("tag_name").GetString() != "v" + version ||
            release.GetProperty("draft").GetBoolean() || release.GetProperty("prerelease").GetBoolean())
            throw new InvalidDataException("Unsupported release.");
        var matches = release.GetProperty("assets").EnumerateArray()
            .Where(asset => asset.GetProperty("name").GetString() == name).ToArray();
        if (matches.Length != 1) throw new InvalidDataException("Release asset is missing or duplicated.");
        var asset = matches[0];
        var url = asset.GetProperty("browser_download_url").GetString();
        var digest = asset.GetProperty("digest").GetString();
        var size = asset.GetProperty("size").GetInt64();
        if (url != $"{Repository}/releases/download/v{version}/{name}" ||
            digest is null || !Regex.IsMatch(digest, @"^sha256:[0-9a-f]{64}\z") ||
            size <= 0 || size > (name.EndsWith(".json") ? 8 * 1024 * 1024 : 2L * 1024 * 1024 * 1024))
            throw new InvalidDataException("Invalid release asset.");
        return new(name, new Uri(url), size, digest[7..]);
    }

    public static HttpClient CreateClient()
    {
        var client = new HttpClient(new HttpClientHandler { AllowAutoRedirect = false }) {
            Timeout = TimeSpan.FromMinutes(20),
        };
        client.DefaultRequestHeaders.UserAgent.ParseAdd("Doorlight-Updater/1.0");
        client.DefaultRequestHeaders.Accept.ParseAdd("application/vnd.github+json");
        return client;
    }

    public static async Task<JsonDocument> ReadRelease(HttpClient client, string version, CancellationToken token,
        TimeSpan? timeout = null)
    {
        if (!Regex.IsMatch(version, @"^\d+\.\d+\.\d+\z")) throw new InvalidDataException("Invalid version.");
        var caller = token;
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(caller);
        deadline.CancelAfter(timeout ?? TimeSpan.FromSeconds(30));
        token = deadline.Token;
        try
        {
            using var response = await client.GetAsync(
                $"https://api.github.com/repos/crazy-entertainment/Doorlight/releases/tags/v{version}",
                HttpCompletionOption.ResponseHeadersRead, token);
            response.EnsureSuccessStatusCode();
            using var input = await response.Content.ReadAsStreamAsync(token);
            using var bytes = new MemoryStream();
            await CopyBounded(input, bytes, 2 * 1024 * 1024, token);
            return JsonDocument.Parse(bytes.ToArray());
        }
        catch (OperationCanceledException error) when (deadline.IsCancellationRequested && !caller.IsCancellationRequested)
        {
            throw new TimeoutException("Checking for updates timed out.", error);
        }
    }

    public static async Task Download(HttpClient client, ReleaseAsset asset, string destination,
        IProgress<InstallProgress> progress, CancellationToken token, TimeSpan? timeout = null)
    {
        // ResponseHeadersRead ends HttpClient.Timeout coverage at the headers.
        // One deadline covers redirects and the complete response body.
        var caller = token;
        using var deadline = CancellationTokenSource.CreateLinkedTokenSource(caller);
        deadline.CancelAfter(timeout ?? TimeSpan.FromMinutes(20));
        token = deadline.Token;
        try
        {
            var url = asset.Url;
            for (var redirects = 0; redirects <= 3; redirects++)
            {
                using var response = await client.GetAsync(url, HttpCompletionOption.ResponseHeadersRead, token);
                if (response.StatusCode is HttpStatusCode.Redirect or HttpStatusCode.MovedPermanently or HttpStatusCode.TemporaryRedirect)
                {
                    var next = response.Headers.Location;
                    if (next is null || !next.IsAbsoluteUri || next.Scheme != "https" ||
                        next.UserInfo != "" || !next.IsDefaultPort ||
                        next.Host is not ("github.com" or "release-assets.githubusercontent.com" or "objects.githubusercontent.com"))
                        throw new InvalidDataException("Untrusted download redirect.");
                    url = next;
                    continue;
                }
                response.EnsureSuccessStatusCode();
                using var input = await response.Content.ReadAsStreamAsync(token);
                using var output = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None);
                using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
                var buffer = new byte[81920];
                long written = 0;
                int count;
                while ((count = await input.ReadAsync(buffer, token)) != 0)
                {
                    written += count;
                    if (written > asset.Size) throw new InvalidDataException("Download exceeds its declared size.");
                    await output.WriteAsync(buffer.AsMemory(0, count), token);
                    hash.AppendData(buffer, 0, count);
                    progress.Report(new(asset.Name, written, asset.Size));
                }
                if (written != asset.Size || !CryptographicOperations.FixedTimeEquals(hash.GetHashAndReset(), Convert.FromHexString(asset.Digest)))
                    throw new InvalidDataException("Download failed integrity verification.");
                output.Flush(true);
                return;
            }
            throw new InvalidDataException("Too many download redirects.");
        }
        catch (OperationCanceledException error) when (deadline.IsCancellationRequested && !caller.IsCancellationRequested)
        {
            throw new TimeoutException("Downloading the update timed out.", error);
        }
    }

    private static async Task CopyBounded(Stream input, Stream output, long maximum, CancellationToken token)
    {
        var buffer = new byte[8192];
        int count;
        while ((count = await input.ReadAsync(buffer, token)) != 0)
        {
            if (output.Length + count > maximum) throw new InvalidDataException("Release metadata is too large.");
            await output.WriteAsync(buffer.AsMemory(0, count), token);
        }
    }
}
