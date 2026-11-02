using System.Diagnostics;
using System.Text.Json;
using System.Text.RegularExpressions;
using System.Text.Json.Serialization;
using System.Text.Json.Serialization.Metadata;

namespace Doorlight.Setup;

internal sealed record UpdateRequest(int Schema, int AppPid, string Version,
    string InstalledVersion, bool Automatic, string Identity, bool Motion, bool RetryRejected,
    long? ReleaseSequence = null, string? ManifestSha256 = null);
internal sealed record UpdateCheck(int Schema, int WorkerPid, string Version, bool Eligible,
    long ReleaseSequence, string ManifestSha256, string Message, string State);
internal sealed record UpdateCommand(int Schema, string Action,
    [property: System.Text.Json.Serialization.JsonIgnore(Condition = System.Text.Json.Serialization.JsonIgnoreCondition.WhenWritingNull)] string? Identity = null);
internal sealed record UpdateStatus(int Schema, string State, int WorkerPid, string Version,
    string File, long Completed, long Total, string Message);
internal sealed record StartupReady(int Schema, int Pid, string Version, string Identity, bool Ready);
internal sealed record EngineStatus(int Schema, string State, string Stage,
    long Completed, long Total, string File, string Message);

internal sealed class SetupSession
{
    internal static string Parent => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Doorlight", "setup-sessions");
    internal string Id { get; }
    internal string DirectoryPath { get; }
    internal string WorkerPath => Path.Combine(DirectoryPath, "DoorlightUpdater.exe");
    private UpdateStatus? lastStatus;
    private long lastPublish;

    internal SetupSession(string? id)
    {
        Id = id ?? Guid.NewGuid().ToString("N");
        if (!Regex.IsMatch(Id, @"^[0-9a-f]{32}\z")) throw new ArgumentException("Invalid setup session.");
        DirectoryPath = Path.Combine(Parent, Id);
        PackageStage.RejectLinkedAncestors(DirectoryPath);
        Directory.CreateDirectory(DirectoryPath);
        PackageStage.RejectLinkedAncestors(DirectoryPath);
    }

    internal T? Read<T>(string name, JsonTypeInfo<T> type, int maximum = 16384) where T : class
    {
        var path = Path.Combine(DirectoryPath, name);
        PackageStage.RejectLinkedAncestors(path);
        if (!File.Exists(path)) return null;
        using var input = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        if (input.Length > maximum) throw new InvalidDataException("Setup message is too large.");
        return JsonSerializer.Deserialize(input, type);
    }

    internal void Write<T>(string name, T value, JsonTypeInfo<T> type)
    {
        var destination = Path.Combine(DirectoryPath, name);
        PackageStage.RejectLinkedAncestors(destination);
        var temporary = destination + "." + Guid.NewGuid().ToString("N");
        try
        {
            using (var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                JsonSerializer.Serialize(output, value, type);
                output.Flush(true);
            }
            for (var attempt = 0; ; attempt++)
            {
                try { File.Move(temporary, destination, true); break; }
                catch (Exception exception) when (attempt < 9 &&
                    exception is IOException or UnauthorizedAccessException &&
                    (exception.HResult & 0xffff) is 5 or 32 or 33)
                {
                    Thread.Sleep(20);
                }
            }
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }

    internal void Publish(string state, string version = "", InstallProgress? progress = null, string message = "")
    {
        var status = new UpdateStatus(1, state, Environment.ProcessId, version,
            progress?.File ?? "", progress?.CompletedBytes ?? 0, progress?.TotalBytes ?? 0, message);
        if (lastStatus?.State == state && Environment.TickCount64 - lastPublish < 100) return;
        lastStatus = status;
        Write("status.json", status, WindowsJsonContext.Default.UpdateStatus);
        lastPublish = Environment.TickCount64;
    }

    internal void Heartbeat()
    {
        if (lastStatus is null) return;
        Write("status.json", lastStatus, WindowsJsonContext.Default.UpdateStatus);
        lastPublish = Environment.TickCount64;
    }

    internal static void Cleanup(string id)
    {
        if (!Regex.IsMatch(id, @"^[0-9a-f]{32}\z")) throw new ArgumentException("Invalid cleanup session.");
        var directory = Path.Combine(Parent, id);
        PackageStage.RejectLinkedAncestors(directory);
        if (!Directory.Exists(directory)) return;
        // Sessions are flat. Never recursively remove an unexpected tree.
        foreach (var entry in Directory.EnumerateFileSystemEntries(directory))
        {
            PackageStage.RejectLinkedAncestors(entry);
            if (Directory.Exists(entry)) return;
        }
        // On Windows a loaded executable cannot be deleted. Test it first so a
        // stale cleanup request cannot remove a live worker's protocol files.
        var worker = Path.Combine(directory, "DoorlightUpdater.exe");
        if (File.Exists(worker)) File.Delete(worker);
        foreach (var file in Directory.EnumerateFiles(directory)) File.Delete(file);
        Directory.Delete(directory);
    }

    internal static void Prune()
    {
        PackageStage.RejectLinkedAncestors(Parent);
        if (!Directory.Exists(Parent)) return;
        var cutoff = DateTime.UtcNow.AddDays(-2);
        foreach (var directory in Directory.EnumerateDirectories(Parent).Take(32))
        {
            var id = Path.GetFileName(directory);
            if (!Regex.IsMatch(id, @"^[0-9a-f]{32}\z")) continue;
            try
            {
                PackageStage.RejectLinkedAncestors(directory);
                if (Directory.GetLastWriteTimeUtc(directory) >= cutoff ||
                    Directory.EnumerateFiles(directory).Any(file => File.GetLastWriteTimeUtc(file) >= cutoff)) continue;
                Cleanup(id);
            }
            catch (IOException) { /* Active or unexpected sessions remain untouched. */ }
            catch (UnauthorizedAccessException) { /* Cleanup is optional. */ }
        }
    }
}

internal sealed record SetupFailure(string Type, string Details);
internal sealed record EngineWorker(int Schema, int Pid);

[JsonSourceGenerationOptions(PropertyNamingPolicy = JsonKnownNamingPolicy.CamelCase, PropertyNameCaseInsensitive = true)]
[JsonSerializable(typeof(UpdateRequest))]
[JsonSerializable(typeof(UpdateCheck))]
[JsonSerializable(typeof(UpdateCommand))]
[JsonSerializable(typeof(UpdateStatus))]
[JsonSerializable(typeof(StartupReady))]
[JsonSerializable(typeof(EngineStatus))]
[JsonSerializable(typeof(SetupFailure))]
[JsonSerializable(typeof(EngineWorker))]
internal partial class WindowsJsonContext : JsonSerializerContext { }
