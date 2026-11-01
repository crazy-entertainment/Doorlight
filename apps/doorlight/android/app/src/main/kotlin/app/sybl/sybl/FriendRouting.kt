package app.sybl.sybl

private val JAMI_ID = Regex("^[0-9a-f]{40}$")

internal fun bareJamiId(value: String?): String {
    val bare = value.orEmpty()
        .trim()
        .removePrefix("jami:")
        .substringBefore("@")
        .lowercase()
    return bare.takeIf(JAMI_ID::matches).orEmpty()
}

internal data class FriendRoute(
    val peerId: String,
    val confirmed: Boolean,
    val canonicalConversationId: String?,
    val conversationIds: Set<String>,
)

internal data class GroupRoute(
    val conversationId: String,
    val memberIds: List<String>,
    val activeMemberIds: Set<String>,
    val adminMemberIds: Set<String>,
    val invitedMemberIds: Set<String>,
    val localRole: String,
    val textRooms: Set<String> = setOf("general", "games", "clips"),
) {
    val ownerKey: String get() = groupOwnerKey(conversationId)
    // memberIds deliberately excludes the local account; the UI count includes it.
    val memberCount: Int get() = memberIds.size + 1
    val canManageMembers: Boolean get() = localRole == "admin"
}

internal data class GroupReceiptState(
    val deliveryState: Int = 1,
    val readBy: Set<String> = emptySet(),
)

internal fun foldGroupReceipt(
    group: GroupRoute,
    memberStatuses: Map<String, Int>,
): GroupReceiptState {
    var deliveryState = 1
    val readBy = sortedSetOf<String>()
    for ((rawId, rawState) in memberStatuses) {
        val id = bareJamiId(rawId)
        if (id !in group.activeMemberIds) continue
        val state = rawState.coerceIn(1, 3)
        deliveryState = maxOf(deliveryState, state)
        if (state == 3) readBy += id
    }
    return GroupReceiptState(deliveryState, readBy)
}

private const val GROUP_OWNER_PREFIX = "group:"

internal fun groupOwnerKey(conversationId: String): String =
    "$GROUP_OWNER_PREFIX$conversationId"

internal fun groupConversationId(ownerKey: String): String? =
    ownerKey.takeIf { it.startsWith(GROUP_OWNER_PREFIX) }
        ?.removePrefix(GROUP_OWNER_PREFIX)
        ?.takeIf(String::isNotEmpty)

internal data class RoutingSnapshot(
    val accountId: String,
    val selfId: String,
    val revision: Long,
    val friends: Map<String, FriendRoute>,
    val groups: Map<String, GroupRoute>,
    val peerByConversation: Map<String, String>,
) {
    fun friend(peerId: String): FriendRoute? = friends[bareJamiId(peerId)]
    fun group(conversationId: String): GroupRoute? = groups[conversationId]
    fun isTrusted(peerId: String): Boolean = friend(peerId) != null
    fun acceptsWakePeer(peerId: String): Boolean {
        val peer = bareJamiId(peerId)
        return peer.isNotEmpty() &&
            (friends.containsKey(peer) || groups.values.any { peer in it.activeMemberIds })
    }
    fun owns(ownerKey: String, conversationId: String): Boolean {
        if (conversationId.isEmpty()) return false
        val groupId = groupConversationId(ownerKey)
        return if (groupId != null) {
            groupId == conversationId && groups.containsKey(conversationId)
        } else {
            peerByConversation[conversationId] == bareJamiId(ownerKey)
        }
    }

    fun ownerKey(conversationId: String): String? =
        peerByConversation[conversationId]
            ?: groups[conversationId]?.ownerKey

    fun acceptsComposerActivity(
        eventAccountId: String,
        conversationId: String,
        participantId: String,
        status: Int,
    ): Boolean {
        val participant = bareJamiId(participantId)
        return eventAccountId == accountId &&
            (status == 0 || status == 1) &&
            participant != selfId &&
            owns(participant, conversationId)
    }

    fun acceptsAuthor(ownerKey: String, conversationId: String, authorId: String): Boolean {
        val author = bareJamiId(authorId)
        if (author.isEmpty() || !owns(ownerKey, conversationId)) return false
        val groupId = groupConversationId(ownerKey)
        return if (groupId != null) {
            group(groupId)?.activeMemberIds?.contains(author) == true
        } else {
            author == bareJamiId(ownerKey)
        }
    }

    companion object {
        fun empty(accountId: String = "", revision: Long = 0) =
            RoutingSnapshot(accountId, "", revision, emptyMap(), emptyMap(), emptyMap())
    }
}

/**
 * Builds Syb-L's immutable authorization/routing view from libjami's durable contact and conversation truth.
 *
 * Active, non-banned contacts are trusted even before reciprocity (`confirmed=false`): `addContact` is the
 * user's local trust decision in libjami. Conversation membership only expands a direct contact's allow-set when
 * the swarm is unambiguously 1:1 (self plus exactly one trusted peer). Explicit non-zero conversation modes are
 * published separately as groups when the local account is active. Malformed or unowned swarms fail closed.
 * The daemon's contact `conversationId` remains canonical when present, matching Jami's Account model.
 */
internal fun buildRoutingSnapshot(
    accountId: String,
    revision: Long,
    selfId: String,
    contacts: List<Map<String, String>>,
    conversations: Map<String, List<Map<String, String>>>,
    conversationInfos: Map<String, Map<String, String>> = emptyMap(),
): RoutingSnapshot {
    val me = bareJamiId(selfId)
    val active = linkedMapOf<String, Pair<Boolean, String?>>()
    for (contact in contacts) {
        val peer = bareJamiId(contact["id"])
        if (peer.isEmpty() || peer == me || contact["banned"] == "true") continue
        val added = contact["added"]?.toLongOrNull() ?: 0L
        val removed = contact["removed"]?.toLongOrNull() ?: 0L
        if (added <= removed) continue
        val canonical = contact["conversationId"]?.takeIf(String::isNotEmpty)
        val previous = active[peer]
        active[peer] = Pair(
            previous?.first == true || contact["confirmed"] == "true",
            canonical ?: previous?.second,
        )
    }

    val conversationsByPeer = active.keys.associateWith { linkedSetOf<String>() }.toMutableMap()
    val candidateOwner = linkedMapOf<String, String>()
    val ambiguous = hashSetOf<String>()
    val groupRoutes = sortedMapOf<String, GroupRoute>()
    for ((conversationId, members) in conversations) {
        if (conversationId.isEmpty()) continue
        val mode = conversationInfos[conversationId]?.get("mode")?.toIntOrNull()
        val normalizedMembers = members.mapNotNull { member ->
            val id = bareJamiId(member["uri"]).takeIf(String::isNotEmpty)
                ?: return@mapNotNull null
            id to member["role"].orEmpty().lowercase()
        }
        if (mode != null && mode != 0) {
            val unique = linkedMapOf<String, String>()
            for ((id, role) in normalizedMembers) {
                if (role == "banned" || role == "left") continue
                unique[id] = role
            }
            val localRole = unique[me].orEmpty()
            if (localRole == "admin" || localRole == "member") {
                val memberIds = unique.keys.filter { it != me }.sorted()
                val activeMembers = unique.entries
                    .asSequence()
                    .filter { it.key != me && (it.value == "admin" || it.value == "member") }
                    .map { it.key }
                    .toSortedSet()
                val adminMembers = unique.entries
                    .asSequence()
                    .filter { it.key != me && it.value == "admin" }
                    .map { it.key }
                    .toSortedSet()
                val invitedMembers = unique.entries
                    .asSequence()
                    .filter { it.key != me && it.value == "invited" }
                    .map { it.key }
                    .toSortedSet()
                groupRoutes[conversationId] = GroupRoute(
                    conversationId = conversationId,
                    memberIds = memberIds,
                    activeMemberIds = activeMembers,
                    adminMemberIds = adminMembers,
                    invitedMemberIds = invitedMembers,
                    localRole = localRole,
                    textRooms = GroupPolicy.textRooms(conversationInfos[conversationId]?.get("description").orEmpty()),
                )
            }
            continue
        }
        val peers = normalizedMembers.asSequence()
            .map { it.first }
            .filter { it != me }
            .toSet()
        if (peers.size != 1) continue
        val peer = peers.single()
        if (!active.containsKey(peer)) continue
        val old = candidateOwner.putIfAbsent(conversationId, peer)
        if (old != null && old != peer) ambiguous += conversationId
    }
    for (conversationId in ambiguous) candidateOwner.remove(conversationId)
    for ((conversationId, peer) in candidateOwner) conversationsByPeer.getValue(peer) += conversationId

    val routes = sortedMapOf<String, FriendRoute>()
    val ownerCandidates = linkedMapOf<String, String>()
    val ambiguousOwners = hashSetOf<String>()
    for ((peer, contact) in active.toSortedMap()) {
        val all = conversationsByPeer.getValue(peer)
        contact.second?.let(all::add)
        val canonical = contact.second ?: all.minOrNull()
        val immutable = all.toSortedSet()
        routes[peer] = FriendRoute(peer, contact.first, canonical, immutable)
        for (conversationId in immutable) {
            val old = ownerCandidates.putIfAbsent(conversationId, peer)
            if (old != null && old != peer) ambiguousOwners += conversationId
        }
    }
    for (conversationId in ambiguousOwners) ownerCandidates.remove(conversationId)
    return RoutingSnapshot(
        accountId = accountId,
        selfId = me,
        revision = revision,
        friends = routes.toMap(),
        groups = groupRoutes.toMap(),
        peerByConversation = ownerCandidates.toMap(),
    )
}

internal enum class AccountMessageIngress { FULL, WAKE_ONLY, DROP }

/**
 * Ingress decision for a non-swarm account message. A direct contact is handled in full. A non-contact that
 * [RoutingSnapshot.acceptsWakePeer] (an active group member) is admitted only when the message carries nothing
 * but a presence packet of type "wake" under [PROBE_MIME]; every other payload mix from it is dropped.
 */
internal fun classifyAccountMessage(
    snapshot: RoutingSnapshot,
    from: String,
    payloads: Map<String, String>,
    nowMs: Long = System.currentTimeMillis(),
): AccountMessageIngress {
    if (snapshot.isTrusted(from)) return AccountMessageIngress.FULL
    if (!snapshot.acceptsWakePeer(from)) return AccountMessageIngress.DROP
    if (payloads.keys != setOf(PROBE_MIME)) return AccountMessageIngress.DROP
    val packet = PresenceWire.decode(payloads.getValue(PROBE_MIME), nowMs)
    return if (packet?.type == "wake") AccountMessageIngress.WAKE_ONLY else AccountMessageIngress.DROP
}

/** Runs exactly one of the three handlers for [classifyAccountMessage]'s decision on the same arguments. */
internal fun routeAccountMessage(
    snapshot: RoutingSnapshot,
    from: String,
    payloads: Map<String, String>,
    onFull: (String, Map<String, String>) -> Unit,
    onWakeOnly: (String, Map<String, String>) -> Unit,
    onDrop: (String) -> Unit,
    nowMs: Long = System.currentTimeMillis(),
) {
    when (classifyAccountMessage(snapshot, from, payloads, nowMs)) {
        AccountMessageIngress.FULL -> onFull(from, payloads)
        AccountMessageIngress.WAKE_ONLY -> onWakeOnly(from, payloads)
        AccountMessageIngress.DROP -> onDrop(from)
    }
}
