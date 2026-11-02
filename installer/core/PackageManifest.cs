using System.Text.Json;
using System.Text.RegularExpressions;

namespace Doorlight.Setup;

public sealed record PackageFile(string Path, long Size, string Sha256);

public sealed record PackageManifest(int Schema, string Version, PackageFile[] Files)
{
    public const long MaximumBytes = 4L * 1024 * 1024 * 1024;
    public const int MaximumFiles = 20000;

    public static PackageManifest Read(Stream input)
    {
        // Bound metadata independently of the archive's declared file sizes.
        using var bytes = new MemoryStream();
        var buffer = new byte[8192];
        int count;
        while ((count = input.Read(buffer)) > 0)
        {
            if (bytes.Length + count > 8 * 1024 * 1024)
                throw new InvalidDataException("Package manifest is too large.");
            bytes.Write(buffer, 0, count);
        }
        var manifest = JsonSerializer.Deserialize(bytes.ToArray(), CoreJsonContext.Default.PackageManifest)
            ?? throw new InvalidDataException("Package manifest is missing.");
        manifest.Validate();
        return manifest;
    }

    public void Validate()
    {
        if (Schema != 1 || Version is null ||
            !Regex.IsMatch(Version, @"^\d+\.\d+\.\d+\z") ||
            !System.Version.TryParse(Version, out _) ||
            Files is null || Files.Length == 0 || Files.Length > MaximumFiles)
            throw new InvalidDataException("Unsupported package manifest.");
        var paths = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        long total = 0;
        foreach (var file in Files)
        {
            if (file is null) throw new InvalidDataException("Package file is missing.");
            ValidatePath(file.Path);
            if (!paths.Add(file.Path) || file.Size < 0 || file.Size > MaximumBytes ||
                file.Sha256 is null || !Regex.IsMatch(file.Sha256, @"^[0-9a-f]{64}\z"))
                throw new InvalidDataException("Invalid package file entry.");
            total += file.Size;
            if (total > MaximumBytes) throw new InvalidDataException("Package is too large.");
        }
        if (!paths.Contains("sybl.exe") || !paths.Contains("Doorlight.version") ||
            !paths.Contains("_setup/DoorlightUpdater.exe"))
            throw new InvalidDataException("Package is missing its executable, version or updater.");
        foreach (var path in paths)
        {
            var parent = path;
            while (parent.LastIndexOf('/') is var slash && slash >= 0)
            {
                parent = parent[..slash];
                if (paths.Contains(parent))
                    throw new InvalidDataException("Package path is both a file and a directory.");
            }
        }
    }

    public static void ValidatePath(string path)
    {
        if (string.IsNullOrEmpty(path) || path.Length > 220 ||
            path.Any(c => c < 32 || "\\:*?\"<>|".Contains(c)))
            throw new InvalidDataException("Invalid package path.");
        foreach (var part in path.Split('/'))
        {
            if (part.Length == 0 || part is "." or ".." || part.EndsWith('.') ||
                part.EndsWith(' ') || Regex.IsMatch(part,
                    @"^(CON|PRN|AUX|NUL|COM[1-9¹²³]|LPT[1-9¹²³])(?:\.|$)", RegexOptions.IgnoreCase))
                throw new InvalidDataException("Unsafe Windows package path.");
        }
    }
}
