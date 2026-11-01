package app.sybl.sybl

import java.util.concurrent.CountDownLatch

internal fun canReleaseCallReservation(
    reservedPeer: String?,
    retiringPeer: String,
    placing: Boolean,
    winner: String?,
    hasNativeLeg: Boolean,
    hasRetainedRing: Boolean,
): Boolean = reservedPeer == retiringPeer && !placing && winner == null &&
    !hasNativeLeg && !hasRetainedRing

/** Retire only this placement, and always wake callbacks waiting on its terminal outcome. */
internal inline fun <T> withOutgoingPlacementCompletion(
    owner: CountDownLatch,
    lock: Any,
    currentOwner: () -> CountDownLatch?,
    retire: () -> Unit,
    operation: () -> T,
): T = try {
    operation()
} finally {
    try {
        synchronized(lock) {
            if (currentOwner() === owner) retire()
        }
    } finally {
        owner.countDown()
    }
}

/** Routing cannot be published through a restore barrier, including an offline restore. */
internal inline fun completeRestoreRoutingPublication(
    retireBarrier: () -> Unit,
    publish: () -> Unit,
    commit: () -> Map<String, Any?>,
): Map<String, Any?> {
    val result = try { commit() } finally { retireBarrier() }
    if (result["status"] == "ok") publish()
    return result
}
