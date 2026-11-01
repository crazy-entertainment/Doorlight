package app.sybl.sybl

internal data class OwnedFileOperation(
    val command: OwnedMessageOperation,
    val path: String,
    val commitId: String = "",
    val fileId: String = "",
    val seedReady: Boolean = false,
)

/** Publication and seed handoff have independent lifetimes. Never evict an
 * unresolved source merely to admit a new operation. */
internal class OwnedFileOperations {
    private val entries = mutableMapOf<String, OwnedFileOperation>()
    private val terminal = linkedSetOf<String>()

    @Synchronized fun begin(operation: OwnedFileOperation): Boolean {
        val id = operation.command.operationId
        if (!Regex("^[0-9a-f]{32}$").matches(id) || operation.path.isEmpty() ||
            entries.size >= 256 || id in entries || id in terminal ||
            entries.values.any { it.path == operation.path }) return false
        entries[id] = operation
        return true
    }

    @Synchronized fun ownsPath(path: String) = entries.values.any { it.path == path }

    @Synchronized fun committed(account: String, conversation: String, id: String, commit: String): OwnedFileOperation? {
        val current = entries[id] ?: return null
        if (current.command.scope.accountId != account || current.command.conversationId != conversation ||
            commit.length > 1024 || (current.commitId.isNotEmpty() && commit.isNotEmpty() && current.commitId != commit)) return null
        if (commit.isEmpty()) return current
        return current.copy(commitId = commit).also { entries[id] = it }
    }

    @Synchronized fun seeded(account: String, conversation: String, id: String, commit: String, file: String, ready: Boolean): OwnedFileOperation? {
        if (commit.isEmpty() || file.isEmpty() || file.length > 1024) return null
        val current = committed(account, conversation, id, commit) ?: return null
        if (current.fileId.isNotEmpty() && current.fileId != file) return null
        return current.copy(fileId = file, seedReady = current.seedReady || ready).also { entries[id] = it }
    }

    @Synchronized fun ready(account: String, id: String, commit: String): OwnedFileOperation? =
        entries[id]?.takeIf { it.command.scope.accountId == account && it.commitId == commit && it.seedReady }

    /** Called only after native signed-commit/seed verification and durable
     * staging cleanup. Repair can succeed without a prior ready callback. */
    @Synchronized fun acknowledgeVerified(account: String, conversation: String, id: String, commit: String): Boolean {
        val current = entries[id] ?: return true
        if (commit.isEmpty() || current.command.scope.accountId != account ||
            current.command.conversationId != conversation ||
            (current.commitId.isNotEmpty() && current.commitId != commit)) return false
        return removeExact(current)
    }

    @Synchronized fun removeExact(operation: OwnedFileOperation): Boolean {
        val id = operation.command.operationId
        if (entries[id] != operation) return false
        entries.remove(id)
        terminal.add(id)
        if (terminal.size > 1024) terminal.remove(terminal.first())
        return true
    }
}
