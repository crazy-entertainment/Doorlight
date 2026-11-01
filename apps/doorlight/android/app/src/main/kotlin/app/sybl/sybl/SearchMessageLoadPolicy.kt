package app.sybl.sybl

/** Current facts the core holds about the account, routing and search epoch. */
internal class SearchMessageLoadFacts(
    val accountOwned: Boolean,
    val accountActive: Boolean,
    val routingOwns: Boolean,
    val epoch: Long,
    val restorePending: Boolean,
)

/** Pure admission and completion decisions for one private-search message load. */
internal object SearchMessageLoadPolicy {
    private val commit = Regex("[0-9a-f]{40}")

    fun admit(
        account: String,
        peer: String,
        conversation: String,
        messageId: String,
        requestEpoch: Long,
        facts: SearchMessageLoadFacts,
        registryCanStart: Boolean,
    ): Boolean = account.isNotEmpty() && peer.isNotEmpty() &&
        commit.matches(conversation) && commit.matches(messageId) &&
        facts.accountOwned && facts.accountActive && facts.routingOwns &&
        !facts.restorePending && facts.epoch == requestEpoch && registryCanStart

    /** The index of the one returned message to project, or null for unavailable. */
    fun complete(
        load: SearchMessageConversationLoad,
        callbackAccount: String,
        callbackConversation: String,
        facts: SearchMessageLoadFacts,
        returnedIds: List<String>,
    ): Int? {
        if (callbackAccount != load.account || callbackConversation != load.conversationId ||
            !facts.accountOwned || !facts.accountActive || !facts.routingOwns ||
            facts.restorePending || facts.epoch != load.epoch) return null
        if (returnedIds.size != 1 || returnedIds[0] != load.messageId) return null
        return 0
    }

    fun dispatch(
        load: SearchMessageConversationLoad,
        callbackAccount: String,
        callbackConversation: String,
        facts: SearchMessageLoadFacts,
        returnedIds: List<String>,
        onProject: (Int) -> Unit,
        onUnavailable: () -> Unit,
    ) {
        val index = complete(load, callbackAccount, callbackConversation, facts, returnedIds)
        if (index == null) onUnavailable() else onProject(index)
    }
}
