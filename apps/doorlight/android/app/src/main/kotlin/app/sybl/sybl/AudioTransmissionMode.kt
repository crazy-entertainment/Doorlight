package app.sybl.sybl

/**
 * The exact call-scoped transmission modes exported by libjami.
 *
 * Explicit microphone mute remains an independent media control: push-to-talk
 * therefore uses [OPEN], while [VOICE_ACTIVATED] delegates gating to the
 * daemon's existing WebRTC/Speex voice detector.
 */
internal enum class AudioTransmissionMode(val daemonValue: String) {
    OPEN("open"),
    VOICE_ACTIVATED("voiceActivated");

    companion object {
        fun parse(value: String): AudioTransmissionMode? =
            entries.firstOrNull { it.daemonValue == value }
    }
}

/** One process-global audio device may only be controlled by its CURRENT winner. */
internal fun ownsAudioTransmissionCall(
    requestedCallId: String,
    activeCallId: String?,
    winnerCallId: String?,
): Boolean =
    requestedCallId.isNotEmpty() &&
        requestedCallId == activeCallId &&
        requestedCallId == winnerCallId
