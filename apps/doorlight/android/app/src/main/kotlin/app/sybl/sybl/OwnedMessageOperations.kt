package app.sybl.sybl

internal data class OwnedMessageOperation(
    val scope: NativeAccountScope,
    val peer: String,
    val conversationId: String,
    val operationId: String,
)

/** Callback correlation only; durable reconciliation belongs to Jami and the command journal. */
internal class OwnedMessageOperations {
    private val pending = mutableMapOf<String, OwnedMessageOperation>()
    private val terminal = linkedSetOf<String>()

    @Synchronized fun begin(operation: OwnedMessageOperation): Boolean {
        if (!ID.matches(operation.operationId) || pending.size >= 256 ||
            pending.containsKey(operation.operationId) || terminal.contains(operation.operationId)) return false
        pending[operation.operationId] = operation
        return true
    }

    @Synchronized fun complete(accountId: String, conversationId: String, operationId: String, terminalOutcome: Boolean = true): OwnedMessageOperation? {
        val operation = pending[operationId] ?: return null
        if (operation.scope.accountId != accountId || operation.conversationId != conversationId) return null
        if (!terminalOutcome) return operation
        pending.remove(operationId)
        terminal.add(operationId)
        if (terminal.size > 1024) terminal.remove(terminal.first())
        return operation
    }

    private companion object { val ID = Regex("^[0-9a-f]{32}$") }
}
