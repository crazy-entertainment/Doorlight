using System.Text.Json;
using System.Text.RegularExpressions;

namespace Doorlight.Setup;

public sealed record InstallTransaction(string Id, string Version, string Stage, string? Previous);
public sealed record InstallRecovery(string? Version, bool FirstInstall, bool Rejected);

// The caller holds exclusive setup/profile leases and runs outside the bundle.
// No operation here opens profiles, terminates processes or follows links.
public static class BundleInstall
{
    internal sealed record Journal(int Schema, string Id, string Version, string Stage,
        string? Previous, bool HadHelper, string State, bool Rejected = false);
    private const string JournalName = "install-pending.json";
    private const string HelperName = "DoorlightUpdater.exe";
    private const string RejectedName = "rejected-versions.json";

    public static InstallTransaction Apply(string root, string stage, string version,
        bool allowRepair = false, Action<string>? checkpoint = null)
    {
        root = Root(root);
        stage = Path.GetFullPath(stage);
        if (!string.Equals(Path.GetDirectoryName(stage), root, StringComparison.OrdinalIgnoreCase) ||
            !IsStage(Path.GetFileName(stage)))
            throw new InvalidDataException("The staged bundle must belong to this installation.");
        if (File.Exists(Path.Combine(root, JournalName)))
            throw new IOException("Recover the pending installation before starting another.");
        PackageStage.RejectLinkedAncestors(stage);
        ValidateVersion(version);
        if (PackageStage.ReadVersion(stage) != version || !File.Exists(Path.Combine(stage, "sybl.exe")))
            throw new InvalidDataException("The staged bundle version does not match.");
        var candidateHelper = Path.Combine(stage, "_setup", HelperName);
        PackageStage.RejectLinkedAncestors(candidateHelper);
        if (!File.Exists(candidateHelper)) throw new InvalidDataException("The staged updater is missing.");
        var current = Owned(root, "current");
        if (Directory.Exists(current))
        {
            var comparison = System.Version.Parse(version).CompareTo(System.Version.Parse(PackageStage.ReadVersion(current)));
            if (comparison < 0 || (comparison == 0 && !allowRepair))
                throw new InvalidDataException("Only a newer version can replace this installation.");
        }
        var id = Guid.NewGuid().ToString("N");
        var helper = Owned(root, HelperName);
        var journal = new Journal(2, id, version, Path.GetFileName(stage),
            Directory.Exists(current) ? "previous-" + id : null, File.Exists(helper), "Pending");
        if (journal.HadHelper) CopyDurable(helper, Owned(root, BackupName(journal)));
        WriteJournal(root, journal);
        checkpoint?.Invoke("journal");
        if (journal.Previous is not null) Directory.Move(current, Owned(root, journal.Previous));
        checkpoint?.Invoke("old-renamed");
        Directory.Move(stage, current);
        checkpoint?.Invoke("candidate-promoted");
        ReplaceHelper(root, Path.Combine(current, "_setup", HelperName), journal);
        checkpoint?.Invoke("helper-replaced");
        return new(id, version, journal.Stage, journal.Previous);
    }

    public static void Accept(string root, string transactionId, Action<string>? checkpoint = null)
    {
        root = Root(root);
        var journal = ReadJournal(root);
        if (journal.Id != transactionId || journal.State != "Pending")
            throw new InvalidDataException("The ready acknowledgment does not match the pending installation.");
        if (PackageStage.ReadVersion(Owned(root, "current")) != journal.Version)
            throw new InvalidDataException("The installed candidate changed before acknowledgment.");
        journal = journal with { State = "Accepted" };
        WriteJournal(root, journal);
        checkpoint?.Invoke("accepted");
        Finish(root, journal);
    }

    public static void Rollback(string root, string transactionId)
    {
        root = Root(root);
        var journal = ReadJournal(root);
        if (journal.Id != transactionId || journal.State != "Pending")
            throw new InvalidDataException("The rollback request does not match the pending installation.");
        WriteJournal(root, journal with { State = "Rollback", Rejected = true });
        Recover(root);
    }

    public static InstallRecovery? Recover(string root, Action<string>? checkpoint = null)
    {
        root = Root(root);
        var path = Owned(root, JournalName);
        if (!File.Exists(path)) return null;
        using (var document = JsonDocument.Parse(ReadBounded(path, 4096)))
        {
            if (!document.RootElement.TryGetProperty("Schema", out _))
                return RecoverLegacy(root, document.RootElement);
        }
        var journal = ReadJournal(root);
        if (journal.State == "Accepted")
        {
            Finish(root, journal);
            return null;
        }
        var current = Owned(root, "current");
        var stage = Owned(root, journal.Stage);
        var previous = journal.Previous is null ? null : Owned(root, journal.Previous);
        if (journal.State == "Pending")
        {
            journal = journal with { State = "Rollback", Rejected = !Directory.Exists(stage) ||
                (previous is not null && Directory.Exists(previous)) };
            WriteJournal(root, journal);
        }
        checkpoint?.Invoke("rollback-journal");
        if (previous is not null)
        {
            if (Directory.Exists(previous))
            {
                if (Directory.Exists(current))
                {
                    if (Directory.Exists(stage)) throw new IOException("Recovery found conflicting candidate directories.");
                    Directory.Move(current, stage);
                    checkpoint?.Invoke("candidate-preserved");
                }
                Directory.Move(previous, current);
                checkpoint?.Invoke("previous-restored");
            }
            else if (!Directory.Exists(current) || !Directory.Exists(stage))
                throw new IOException("The previous bundle cannot be safely identified. Keep this installation for recovery.");
        }
        else if (Directory.Exists(current))
        {
            if (Directory.Exists(stage)) throw new IOException("Recovery found conflicting initial-install directories.");
            Directory.Move(current, stage);
            checkpoint?.Invoke("candidate-preserved");
        }
        if (journal.HadHelper)
        {
            var backup = Owned(root, BackupName(journal));
            if (!File.Exists(backup)) throw new IOException("The previous launcher backup is missing.");
            ReplaceHelper(root, backup, journal);
        }
        checkpoint?.Invoke("helper-restored");
        if (journal.Rejected) RejectVersion(root, journal.Version);
        checkpoint?.Invoke("rejection-recorded");
        Finish(root, journal);
        return new(journal.Version, journal.Previous is null, journal.Rejected);
    }

    public static bool IsRejected(string root, string version)
    {
        ValidateVersion(version);
        return ReadRejected(Root(root)).Contains(version, StringComparer.Ordinal);
    }

    private static void RejectVersion(string root, string version)
    {
        var versions = ReadRejected(root).Where(item => item != version).Append(version).TakeLast(32).ToArray();
        WriteAtomic(Owned(root, RejectedName), JsonSerializer.SerializeToUtf8Bytes(versions, CoreJsonContext.Default.StringArray));
    }

    private static string[] ReadRejected(string root)
    {
        var path = Owned(root, RejectedName);
        if (!File.Exists(path)) return [];
        var versions = JsonSerializer.Deserialize(ReadBounded(path, 4096), CoreJsonContext.Default.StringArray);
        if (versions is null || versions.Length > 32) throw new InvalidDataException("Invalid rejected-version record.");
        foreach (var version in versions) ValidateVersion(version);
        return versions;
    }

    private static InstallRecovery RecoverLegacy(string root, JsonElement record)
    {
        var stageName = record.GetProperty("Stage").GetString();
        var previousName = record.GetProperty("Previous").GetString();
        if (!IsStage(stageName) || previousName is null || !Regex.IsMatch(previousName, @"^previous-[0-9a-f]{32}\z"))
            throw new InvalidDataException("Invalid legacy recovery paths.");
        var current = Owned(root, "current");
        var stage = Owned(root, stageName!);
        var previous = Owned(root, previousName);
        if (Directory.Exists(previous))
        {
            if (Directory.Exists(current))
            {
                if (Directory.Exists(stage)) throw new IOException("Legacy recovery found conflicting candidates.");
                Directory.Move(current, stage);
            }
            Directory.Move(previous, current);
        }
        else if (!Directory.Exists(current) || !Directory.Exists(stage))
            throw new IOException("Legacy recovery cannot identify the previous bundle. Run the installer again.");
        File.Delete(Owned(root, JournalName));
        return new(null, false, false);
    }

    private static Journal ReadJournal(string root)
    {
        var journal = JsonSerializer.Deserialize(ReadBounded(Owned(root, JournalName), 4096), CoreJsonContext.Default.Journal);
        if (journal is null || journal.Schema != 2 || journal.Id is null ||
            !Regex.IsMatch(journal.Id, @"^[0-9a-f]{32}\z") || !IsStage(journal.Stage) ||
            (journal.Previous is not null && journal.Previous != "previous-" + journal.Id) ||
            journal.State is not ("Pending" or "Rollback" or "Accepted"))
            throw new InvalidDataException("Invalid installation recovery record.");
        ValidateVersion(journal.Version);
        return journal;
    }

    private static void ReplaceHelper(string root, string source, Journal journal)
    {
        PackageStage.RejectLinkedAncestors(source);
        var temporary = Owned(root, ".helper-" + journal.Id + ".tmp");
        if (File.Exists(temporary)) File.Delete(temporary);
        CopyDurable(source, temporary);
        File.Move(temporary, Owned(root, HelperName), overwrite: true);
    }

    private static void CopyDurable(string source, string destination)
    {
        using var input = new FileStream(source, FileMode.Open, FileAccess.Read, FileShare.Read);
        using var output = new FileStream(destination, FileMode.CreateNew, FileAccess.Write, FileShare.None);
        input.CopyTo(output);
        output.Flush(flushToDisk: true);
    }

    private static string BackupName(Journal journal) => ".helper-" + journal.Id + ".bak";
    private static void Finish(string root, Journal journal)
    {
        // A leftover backup is harmless; a missing backup with a live rollback
        // journal would make interrupted recovery ambiguous.
        File.Delete(Owned(root, JournalName));
        if (journal.State == "Accepted")
        {
            CleanupAfterAcceptance(root, journal);
            return;
        }
        File.Delete(Owned(root, BackupName(journal)));
        File.Delete(Owned(root, ".helper-" + journal.Id + ".tmp"));
    }

    private static void CleanupAfterAcceptance(string root, Journal journal)
    {
        void BestEffort(string path, Action cleanup)
        {
            try { cleanup(); }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException or InvalidDataException)
            {
                System.Diagnostics.Trace.TraceWarning("Accepted Doorlight installation retained cleanup item {0}: {1}", path, error.Message);
            }
        }

        BestEffort(BackupName(journal), () => File.Delete(Owned(root, BackupName(journal))));
        var temporary = ".helper-" + journal.Id + ".tmp";
        BestEffort(temporary, () => File.Delete(Owned(root, temporary)));
        // Never remove older recovery options unless the immediate predecessor
        // is still a complete bundle. No failed candidates or profiles are pruned.
        if (journal.Previous is null) return;
        BestEffort(root, () => {
            RequireBundle(Owned(root, journal.Previous));
            foreach (var directory in Directory.EnumerateDirectories(root))
            {
                var name = Path.GetFileName(directory);
                if (name == journal.Previous || !Regex.IsMatch(name, @"^previous-[0-9a-f]{32}\z")) continue;
                BestEffort(directory, () => {
                    var owned = Owned(root, name);
                    RequireBundle(owned);
                    var entries = new List<string> { owned };
                    for (var index = 0; index < entries.Count; index++)
                    {
                        var entry = entries[index];
                        PackageStage.RejectLinkedAncestors(entry);
                        var attributes = File.GetAttributes(entry);
                        if ((attributes & FileAttributes.ReparsePoint) != 0)
                            throw new IOException("Older bundle contains a link.");
                        if ((attributes & FileAttributes.Directory) == 0) continue;
                        foreach (var child in Directory.EnumerateFileSystemEntries(entry))
                        {
                            if (entries.Count >= PackageManifest.MaximumFiles * 2)
                                throw new IOException("Older bundle exceeds the cleanup entry limit.");
                            entries.Add(child);
                        }
                    }
                    // Preflight the whole tree before deleting anything. Each
                    // deletion is nonrecursive, so links are never traversed.
                    for (var index = entries.Count - 1; index >= 0; index--)
                    {
                        var entry = entries[index];
                        PackageStage.RejectLinkedAncestors(entry);
                        var attributes = File.GetAttributes(entry);
                        if ((attributes & FileAttributes.ReparsePoint) != 0)
                            throw new IOException("Older bundle changed during cleanup.");
                        if ((attributes & FileAttributes.Directory) != 0) Directory.Delete(entry);
                        else File.Delete(entry);
                    }
                });
            }
        });
    }

    private static void RequireBundle(string directory)
    {
        PackageStage.ReadVersion(directory);
        foreach (var name in new[] { "sybl.exe", "_setup/" + HelperName })
        {
            var path = Path.Combine(directory, name);
            PackageStage.RejectLinkedAncestors(path);
            if (!File.Exists(path)) throw new IOException("Older bundle is incomplete; retained for inspection.");
        }
    }

    private static void WriteJournal(string root, Journal journal) =>
        WriteAtomic(Owned(root, JournalName), JsonSerializer.SerializeToUtf8Bytes(journal, CoreJsonContext.Default.Journal));

    private static void WriteAtomic(string path, byte[] bytes)
    {
        var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            using (var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                output.Write(bytes);
                output.Flush(flushToDisk: true);
            }
            File.Move(temporary, path, overwrite: true);
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }

    private static byte[] ReadBounded(string path, int maximum)
    {
        using var input = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        if (input.Length > maximum) throw new InvalidDataException("Installation record is too large.");
        var bytes = new byte[(int)input.Length];
        input.ReadExactly(bytes);
        return bytes;
    }

    private static bool IsStage(string? name) => name is not null && Regex.IsMatch(name, @"^\.stage-[0-9a-f]{32}\z");
    private static void ValidateVersion(string? version)
    {
        if (version is null || version.Length > 64 || !Regex.IsMatch(version, @"^\d+\.\d+\.\d+\z") ||
            !System.Version.TryParse(version, out _)) throw new InvalidDataException("Invalid bundle version.");
    }

    private static string Root(string root)
    {
        root = Path.TrimEndingDirectorySeparator(Path.GetFullPath(root));
        PackageStage.RejectLinkedAncestors(root);
        return root;
    }

    private static string Owned(string root, string name)
    {
        var path = Path.Combine(root, name);
        PackageStage.RejectLinkedAncestors(path);
        return path;
    }
}
