package com.llfbandit.record.record.format

import android.media.MediaCodecList
import android.media.MediaFormat
import com.llfbandit.record.record.model.AudioEncoder

object AudioFormats {
  fun isEncoderSupported(mimeType: String?): Boolean {
    if (mimeType == null) {
      return false
    }
    val mcl = MediaCodecList(MediaCodecList.REGULAR_CODECS)
    for (info in mcl.codecInfos) {
      if (info.isEncoder) {
        for (supportedType in info.supportedTypes) {
          if (supportedType.equals(mimeType, ignoreCase = true)) {
            return true
          }
        }
      }
    }
    return false
  }

  fun getMimeType(encoder: String?): String? {
    return when (encoder) {
      AudioEncoder.AacLc.value -> MediaFormat.MIMETYPE_AUDIO_AAC
      else -> null
    }
  }
}
