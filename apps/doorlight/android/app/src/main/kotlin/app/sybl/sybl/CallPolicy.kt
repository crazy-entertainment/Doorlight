package app.sybl.sybl

internal const val DENY_SECOND_CALL_KEY = "Account.denySecondCall"

/** Pin the product's one-connected-call policy without rewriting an unchanged account. */
internal fun pinDenySecondCall(details: MutableMap<String, String>): Boolean {
    if (details[DENY_SECOND_CALL_KEY] == "true") return false
    details[DENY_SECOND_CALL_KEY] = "true"
    return true
}

/** A ring alerts through SystemUI only while the app cannot show its own incoming-call controls. */
internal fun shouldShowIncomingCallNotification(
    activeCallId: String?,
    activityResumed: Boolean,
): Boolean = activeCallId == null && !activityResumed

/** Retry a retained ring only after a terminal transition leaves native with no active media owner. */
internal fun shouldSurfacePendingIncomingCall(isTerminal: Boolean, activeCallId: String?): Boolean =
    isTerminal && activeCallId == null

internal enum class IncomingCallAdmission {
    ACCEPT_FIRST,
    SAME_PEER_GLARE,
    REJECT_CROSS_PEER_BUSY,
    REJECT_UNTRUSTED,
}

/**
 * libjami owns same-peer crossed-call arbitration before CURRENT. Syb-L owns admission to its one global call slot
 * across different peers, including while a placement/ring is still pre-CURRENT and denySecondCall does not apply.
 */
internal fun incomingCallAdmission(
    trusted: Boolean,
    incomingPeerId: String,
    reservedPeerId: String?,
): IncomingCallAdmission = when {
    !trusted -> IncomingCallAdmission.REJECT_UNTRUSTED
    reservedPeerId == null -> IncomingCallAdmission.ACCEPT_FIRST
    reservedPeerId == incomingPeerId -> IncomingCallAdmission.SAME_PEER_GLARE
    else -> IncomingCallAdmission.REJECT_CROSS_PEER_BUSY
}

/** Once a global CURRENT winner exists, every other known native leg is stale, regardless of peer. */
internal fun allSiblingCallIds(callPeers: Map<String, String>, winnerCallId: String): Set<String> =
    callPeers.keys.filterTo(linkedSetOf()) { it != winnerCallId }

/** Exact current-call ownership proof. Do not infer camera transfer from global flags or speculate with a media
 * request whose later peer rejection cannot be observed reliably by this libjami build. */
internal fun mediaOwnsLocalCamera(media: List<Map<String, String>>, source: String): Boolean = media.any {
    it["MEDIA_TYPE"] == "MEDIA_TYPE_VIDEO" && it["ENABLED"] == "true" &&
        it["MUTED"] == "false" && it["HOLD"] == "false" && it["SOURCE"] == source
}
