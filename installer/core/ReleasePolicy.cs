using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Doorlight.Setup;

public record ArtifactDescriptor(Uri Url, long Length, string Sha256);
public sealed record FullPackageDescriptor(Uri Url, long Length, string Sha256, string Format)
    : ArtifactDescriptor(Url, Length, Sha256);
public sealed record DeltaDescriptor(string BaseVersion, string BasePackageSha256, string BaseManifestSha256, ArtifactDescriptor Patch);
public sealed record WidgetDescriptor(Uri Url, string Version, string PackageFamily, string Publisher,
    string MinimumDesktopVersion, int MaximumProtocol);

public sealed record ReleasePolicy(int Schema, string Product, string Channel, string Platform,
    long ReleaseSequence, string Version, string MinimumUpdaterVersion, bool Enabled,
    int RolloutBasisPoints, string Salt, ArtifactDescriptor Manifest, FullPackageDescriptor FullPackage,
    IReadOnlyList<DeltaDescriptor> Deltas, WidgetDescriptor? Widget)
{
    public static ReleasePolicy Parse(JsonElement value)
    {
        try { return ParseCore(value); }
        catch (Exception error) when (error is JsonException or InvalidOperationException or KeyNotFoundException or FormatException or OverflowException)
        { throw new InvalidDataException("Invalid release policy.", error); }
    }

    private static ReleasePolicy ParseCore(JsonElement value)
    {
        FeedJson.Object(value, "schema", "product", "channel", "platform", "releaseSequence", "version",
            "minimumUpdaterVersion", "enabled", "rolloutBasisPoints", "salt", "manifest", "fullPackage", "deltas", "widget");
        var schema = FeedJson.Int(value, "schema", 1, 1);
        var product = FeedJson.Text(value, "product", 32);
        var channel = FeedJson.Text(value, "channel", 32);
        var platform = FeedJson.Text(value, "platform", 32);
        if (product != "Doorlight" || !Regex.IsMatch(channel, @"^[a-z][a-z0-9-]{0,31}\z") || platform != "windows-x64")
            throw new InvalidDataException("Unsupported release policy.");
        var sequence = FeedJson.Long(value, "releaseSequence", 1, long.MaxValue);
        var version = FeedJson.Version(value, "version");
        var minimum = FeedJson.Version(value, "minimumUpdaterVersion");
        var enabled = value.GetProperty("enabled");
        if (enabled.ValueKind is not (JsonValueKind.True or JsonValueKind.False)) throw new InvalidDataException("Invalid enabled flag.");
        var basisPoints = FeedJson.Int(value, "rolloutBasisPoints", 0, 10000);
        var salt = FeedJson.Text(value, "salt", 128);
        var manifest = ParseArtifact(value.GetProperty("manifest"), 8L << 20);
        var full = value.GetProperty("fullPackage");
        FeedJson.Object(full, "url", "length", "sha256", "format");
        var format = FeedJson.Text(full, "format", 16);
        if (format is not ("zip" or "velopack")) throw new InvalidDataException("Unsupported package format.");
        var artifact = ParseArtifact(full, 2L << 30, fullPackage: true);
        var deltas = new List<DeltaDescriptor>();
        if (value.TryGetProperty("deltas", out var list))
        {
            if (list.ValueKind != JsonValueKind.Array || list.GetArrayLength() > 16) throw new InvalidDataException("Invalid delta list.");
            var bases = new HashSet<string>(StringComparer.Ordinal);
            foreach (var delta in list.EnumerateArray())
            {
                FeedJson.Object(delta, "baseVersion", "basePackageSha256", "baseManifestSha256", "patch");
                var baseVersion = FeedJson.Version(delta, "baseVersion");
                if (System.Version.Parse(baseVersion) >= System.Version.Parse(version) || !bases.Add(baseVersion))
                    throw new InvalidDataException("Invalid delta base.");
                deltas.Add(new(baseVersion, FeedJson.Hash(delta, "basePackageSha256"), FeedJson.Hash(delta, "baseManifestSha256"), ParseArtifact(delta.GetProperty("patch"), 2L << 30)));
            }
        }
        if (format == "zip" && deltas.Count != 0) throw new InvalidDataException("ZIP releases do not carry Velopack deltas.");
        WidgetDescriptor? widget = null;
        if (value.TryGetProperty("widget", out var w) && w.ValueKind != JsonValueKind.Null)
        {
            FeedJson.Object(w, "url", "version", "packageFamily", "publisher", "minimumDesktopVersion", "maximumProtocol");
            var widgetVersion = FeedJson.Text(w, "version", 64);
            if (!Regex.IsMatch(widgetVersion, @"^\d+\.\d+\.\d+\.\d+\z") || !System.Version.TryParse(widgetVersion, out _))
                throw new InvalidDataException("Invalid widget version.");
            widget = new(FeedJson.Url(w, "url"), widgetVersion, FeedJson.Text(w, "packageFamily", 128),
                FeedJson.Text(w, "publisher", 512), FeedJson.Version(w, "minimumDesktopVersion"), FeedJson.Int(w, "maximumProtocol", 1, 1024));
        }
        return new(schema, product, channel, platform, sequence, version, minimum, enabled.GetBoolean(), basisPoints,
            salt, manifest, new(artifact.Url, artifact.Length, artifact.Sha256, format), deltas.AsReadOnly(), widget);
    }

    public static ArtifactDescriptor ParseArtifact(JsonElement value, long maximum = 2L << 30, bool fullPackage = false)
    {
        FeedJson.Object(value, fullPackage ? ["url", "length", "sha256", "format"] : ["url", "length", "sha256"]);
        return new(FeedJson.Url(value, "url"), FeedJson.Long(value, "length", 1, maximum), FeedJson.Hash(value, "sha256"));
    }

    // Rollout controls may change at the same release sequence; executable bytes may not.
    public string PayloadBinding()
    {
        var fields = new List<string> { Version, MinimumUpdaterVersion, Manifest.Sha256, Manifest.Length.ToString(System.Globalization.CultureInfo.InvariantCulture),
            FullPackage.Sha256, FullPackage.Length.ToString(System.Globalization.CultureInfo.InvariantCulture), FullPackage.Format };
        foreach (var d in Deltas.OrderBy(d => d.BaseVersion, StringComparer.Ordinal))
            fields.AddRange([d.BaseVersion, d.BasePackageSha256, d.BaseManifestSha256, d.Patch.Sha256, d.Patch.Length.ToString(System.Globalization.CultureInfo.InvariantCulture)]);
        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(string.Join('\n', fields)))).ToLowerInvariant();
    }

    public bool IncludesCohort(Guid installationId)
    {
        var bytes = SHA256.HashData(Encoding.UTF8.GetBytes(Salt + "\n" + installationId.ToString("N")));
        var bucket = System.Buffers.Binary.BinaryPrimitives.ReadUInt32BigEndian(bytes) % 10000;
        return Enabled && bucket < RolloutBasisPoints;
    }
}

internal static class FeedJson
{
    internal static void Object(JsonElement e, params string[] fields)
    {
        if (e.ValueKind != JsonValueKind.Object) throw new InvalidDataException("Expected an object.");
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var p in e.EnumerateObject())
            if (!fields.Contains(p.Name, StringComparer.Ordinal) || !seen.Add(p.Name)) throw new InvalidDataException("Unknown or duplicate field.");
    }
    internal static string Text(JsonElement e, string name, int max)
    {
        if (!e.TryGetProperty(name, out var p) || p.ValueKind != JsonValueKind.String) throw new InvalidDataException("Missing text field.");
        var s = p.GetString()!;
        if (string.IsNullOrWhiteSpace(s) || s.Length > max || s.Any(char.IsControl)) throw new InvalidDataException("Invalid text field.");
        return s;
    }
    internal static long Long(JsonElement e, string name, long min, long max)
    {
        if (!e.TryGetProperty(name, out var p) || p.ValueKind != JsonValueKind.Number || !p.TryGetInt64(out var v) || v < min || v > max) throw new InvalidDataException("Invalid integer.");
        return v;
    }
    internal static int Int(JsonElement e, string name, int min, int max) => checked((int)Long(e, name, min, max));
    internal static string Hash(JsonElement e, string name)
    {
        var s = Text(e, name, 64);
        if (!Regex.IsMatch(s, @"^[0-9a-f]{64}\z")) throw new InvalidDataException("Invalid SHA256.");
        return s;
    }
    internal static string Version(JsonElement e, string name)
    {
        var s = Text(e, name, 64);
        if (!Regex.IsMatch(s, @"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)\z") || !System.Version.TryParse(s, out _))
            throw new InvalidDataException("Invalid version.");
        return s;
    }
    internal static Uri Url(JsonElement e, string name)
    {
        if (!Uri.TryCreate(Text(e, name, 2048), UriKind.Absolute, out var u)) throw new InvalidDataException("Invalid URL.");
        ValidateUrl(u);
        return u;
    }
    internal static void ValidateUrl(Uri u, bool testHttp = false)
    {
#if DOORLIGHT_FEED_FIXTURE
        // This symbol is exclusively for separately named local fixture builds.
        testHttp = true;
#endif
        if (!u.IsAbsoluteUri || u.UserInfo != "" || u.Fragment != "" ||
            !(u.Scheme == "https" && u.IsDefaultPort || testHttp && u.Scheme == "http" && u.Host == "127.0.0.1"))
            throw new InvalidDataException("Unsafe download URL.");
    }
}
