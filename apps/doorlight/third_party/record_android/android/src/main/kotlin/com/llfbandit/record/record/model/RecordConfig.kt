package com.llfbandit.record.record.model

import android.content.Context
import android.media.AudioDeviceInfo
import android.media.AudioManager
import android.media.MediaRecorder
import android.os.Build
import com.llfbandit.record.record.util.DeviceUtils
import io.flutter.plugin.common.MethodCall

class RecordConfig(
  val path: String?,
  encoder: String,
  var bitRate: Int,
  var sampleRate: Int,
  var numChannels: Int,
  val device: AudioDeviceInfo?,
  val autoGain: Boolean = false,
  val echoCancel: Boolean = false,
  val noiseSuppress: Boolean = false,
  val useLegacy: Boolean = false,
  val muteAudio: Boolean = false,
  val manageBluetoothSco: Boolean = true,
  val audioSource: Int = MediaRecorder.AudioSource.DEFAULT,
  val speakerphone: Boolean = false,
  val audioManagerMode: Int = AudioManager.MODE_NORMAL,
  audioInterruption: Int,
  val streamBufferSize: Int?,
  private val rawMap: Map<String, Any?> = emptyMap(),
) {
  val audioInterruption: AudioInterruption = when (audioInterruption) {
    0 -> AudioInterruption.NONE
    1 -> AudioInterruption.PAUSE
    2 -> AudioInterruption.PAUSE_RESUME
    else -> AudioInterruption.PAUSE
  }

  val encoder: AudioEncoder = AudioEncoder.from(encoder)

  fun toMap(): Map<String, Any?> = rawMap + mapOf(
    "sampleRate" to sampleRate,
    "numChannels" to numChannels,
    "bitRate" to bitRate,
  )

  fun copy() = RecordConfig(
    path, encoder.value, bitRate, sampleRate, numChannels,
    device, autoGain, echoCancel, noiseSuppress,
    useLegacy, muteAudio, manageBluetoothSco, audioSource,
    speakerphone, audioManagerMode, audioInterruption.ordinal,
    streamBufferSize, rawMap,
  )

  fun isModified(other: RecordConfig): Boolean =
    sampleRate != other.sampleRate ||
    numChannels != other.numChannels ||
    bitRate != other.bitRate

  companion object {
    fun fromMap(call: MethodCall, context: Context): RecordConfig {
      val rawMap = (call.arguments as Map<*, *>).entries
        .associate { (k, v) -> k.toString() to v }
      val map = call.argument("androidConfig") as Map<*, *>?

      val audioSource: Int = when (map?.get("audioSource")) {
        "defaultSource" -> MediaRecorder.AudioSource.DEFAULT
        "mic" -> MediaRecorder.AudioSource.MIC
        "voiceUplink" -> MediaRecorder.AudioSource.VOICE_UPLINK
        "voiceDownlink" -> MediaRecorder.AudioSource.VOICE_DOWNLINK
        "voiceCall" -> MediaRecorder.AudioSource.VOICE_CALL
        "camcorder" -> MediaRecorder.AudioSource.CAMCORDER
        "voiceRecognition" -> MediaRecorder.AudioSource.VOICE_RECOGNITION
        "voiceCommunication" -> MediaRecorder.AudioSource.VOICE_COMMUNICATION
        "remoteSubMix" -> MediaRecorder.AudioSource.REMOTE_SUBMIX
        "unprocessed" -> MediaRecorder.AudioSource.UNPROCESSED
        "voicePerformance" -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
          MediaRecorder.AudioSource.VOICE_PERFORMANCE
        } else {
          MediaRecorder.AudioSource.DEFAULT
        }

        else -> MediaRecorder.AudioSource.DEFAULT
      }

      val audioManagerMode: Int = when (map?.get("audioManagerMode")) {
        "modeNormal" -> AudioManager.MODE_NORMAL
        "modeRingtone" -> AudioManager.MODE_RINGTONE
        "modeInCall" -> AudioManager.MODE_IN_CALL
        "modeInCommunication" -> AudioManager.MODE_IN_COMMUNICATION
        "modeCallScreening" -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
          AudioManager.MODE_CALL_SCREENING
        } else {
          AudioManager.MODE_NORMAL
        }

        "modeCallRedirect" -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
          AudioManager.MODE_CALL_REDIRECT
        } else {
          AudioManager.MODE_NORMAL
        }

        "modeCommunicationRedirect" -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
          AudioManager.MODE_COMMUNICATION_REDIRECT
        } else {
          AudioManager.MODE_NORMAL
        }

        else -> AudioManager.MODE_NORMAL
      }

      return RecordConfig(
        call.argument("path"),
        call.argument<String>("encoder") ?: "aacLc",
        call.argument<Int>("bitRate") ?: 128000,
        call.argument<Int>("sampleRate") ?: 44100,
        call.argument<Int>("numChannels") ?: 2,
        DeviceUtils.deviceInfoFromMap(context, call.argument("device")),
        call.argument<Boolean>("autoGain") ?: false,
        call.argument<Boolean>("echoCancel") ?: false,
        call.argument<Boolean>("noiseSuppress") ?: false,
        map?.get("useLegacy") as Boolean? ?: false,
        map?.get("muteAudio") as Boolean? ?: false,
        map?.get("manageBluetooth") as Boolean? ?: true,
        audioSource,
        map?.get("speakerphone") as Boolean? ?: false,
        audioManagerMode,
        call.argument<Int>("audioInterruption") ?: AudioInterruption.PAUSE.ordinal,
        call.argument("streamBufferSize"),
        rawMap,
      )
    }
  }
}

enum class AudioEncoder(val value: String) {
  AacLc("aacLc"),
  AacEld("aacEld"),
  AacHe("aacHe"),
  AmrNb("amrNb"),
  AmrWb("amrWb"),
  Flac("flac"),
  Pcm16bits("pcm16bits"),
  Opus("opus"),
  Wav("wav"),
  Unsupported("unsupported");

  companion object {
    fun from(value: String): AudioEncoder =
      entries.firstOrNull { it.value == value } ?: Unsupported
  }
}

enum class AudioInterruption {
  NONE,
  PAUSE,
  PAUSE_RESUME
}