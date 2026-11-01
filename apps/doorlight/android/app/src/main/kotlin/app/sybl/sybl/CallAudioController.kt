package app.sybl.sybl

import android.content.Context
import android.media.AudioAttributes
import android.media.AudioDeviceInfo
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.os.Build
import android.util.Log

/**
 * Routes audio for a daemon-owned voice call. The daemon (AAudioLayer) opens the mic/speaker itself;
 * we only put the system into communication mode, hold audio focus, and pick earpiece vs speaker.
 * One writer of audio mode — mirrors the daemon's call lifecycle (active / ended).
 */
class CallAudioController(ctx: Context) {
    private val am = ctx.getSystemService(Context.AUDIO_SERVICE) as AudioManager
    private var focus: AudioFocusRequest? = null
    private var speaker = false

    fun onCallActive() {
        am.mode = AudioManager.MODE_IN_COMMUNICATION
        val attrs = AudioAttributes.Builder()
            .setUsage(AudioAttributes.USAGE_VOICE_COMMUNICATION)
            .setContentType(AudioAttributes.CONTENT_TYPE_SPEECH)
            .build()
        val req = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN)
            .setAudioAttributes(attrs)
            .build()
        focus = req
        am.requestAudioFocus(req)
        applyRoute()
        Log.i("SybL", "audio: MODE_IN_COMMUNICATION, focus requested, speaker=$speaker")
    }

    fun onCallEnded() {
        focus?.let { am.abandonAudioFocusRequest(it) }
        focus = null
        if (Build.VERSION.SDK_INT >= 31) {
            am.clearCommunicationDevice()
        } else {
            @Suppress("DEPRECATION") run { am.isSpeakerphoneOn = false }
        }
        am.mode = AudioManager.MODE_NORMAL
        speaker = false
        Log.i("SybL", "audio: reset to MODE_NORMAL")
    }

    fun setSpeaker(on: Boolean) {
        speaker = on
        applyRoute()
    }

    private fun applyRoute() {
        if (Build.VERSION.SDK_INT >= 31) {
            val want = if (speaker) AudioDeviceInfo.TYPE_BUILTIN_SPEAKER else AudioDeviceInfo.TYPE_BUILTIN_EARPIECE
            val dev = am.availableCommunicationDevices.firstOrNull { it.type == want }
            if (dev != null) am.setCommunicationDevice(dev)
        } else {
            @Suppress("DEPRECATION") run { am.isSpeakerphoneOn = speaker }
        }
    }
}
