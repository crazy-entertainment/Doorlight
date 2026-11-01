package app.sybl.sybl

internal data class BackgroundWakeDecision(
    val keepAccountActive: Boolean,
    val keepOnlineForegroundService: Boolean,
    val nextCheckMs: Long?,
)

internal object BackgroundWakeLifetime {
    fun decide(
        nowMs: Long,
        pushEnabled: Boolean,
        appVisible: Boolean,
        accountEnabled: Boolean,
        callActive: Boolean,
        taskRemoved: Boolean,
        backgroundAtMs: Long?,
        messagePushAtMs: Long?,
        callPushAtMs: Long?,
    ): BackgroundWakeDecision {
        if (!accountEnabled) return BackgroundWakeDecision(false, false, null)
        if (!pushEnabled) return BackgroundWakeDecision(true, true, null)
        if (callActive) return BackgroundWakeDecision(true, true, null)
        if (appVisible) return BackgroundWakeDecision(true, false, null)
        if (taskRemoved) return BackgroundWakeDecision(false, false, null)
        val deadline = listOfNotNull(
            backgroundAtMs?.plus(BACKGROUND_GRACE_MS),
            messagePushAtMs?.plus(MESSAGE_GRACE_MS),
            callPushAtMs?.plus(CALL_GRACE_MS),
        ).maxOrNull()
        val remaining = deadline?.minus(nowMs)?.coerceAtLeast(0L) ?: 0L
        return if (remaining > 0L) {
            BackgroundWakeDecision(true, true, remaining)
        } else {
            BackgroundWakeDecision(false, false, null)
        }
    }

    private const val BACKGROUND_GRACE_MS = 5_000L
    private const val MESSAGE_GRACE_MS = 30_000L
    private const val CALL_GRACE_MS = 60_000L
}
