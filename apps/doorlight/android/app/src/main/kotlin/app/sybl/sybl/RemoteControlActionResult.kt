package app.sybl.sybl

internal enum class RemoteControlActionResult { APPLIED, REFUSED, STALE }

/** An authority guard and an OS Boolean acknowledgement are distinct results. */
internal fun executeRemoteControlAction(
    withAuthority: (() -> Unit) -> Boolean,
    action: () -> Boolean,
): RemoteControlActionResult {
    var accepted = false
    val owned = withAuthority {
        accepted = try { action() } catch (_: Throwable) { false }
    }
    return when {
        !owned -> RemoteControlActionResult.STALE
        accepted -> RemoteControlActionResult.APPLIED
        else -> RemoteControlActionResult.REFUSED
    }
}
