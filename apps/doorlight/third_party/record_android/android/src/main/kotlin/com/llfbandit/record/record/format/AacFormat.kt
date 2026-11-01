package com.llfbandit.record.record.format

import android.media.MediaCodecInfo
import android.media.MediaFormat
import android.media.MediaMuxer
import com.llfbandit.record.record.model.RecordConfig
import com.llfbandit.record.record.container.IContainerWriter
import com.llfbandit.record.record.container.MuxerContainer

class AacFormat : Format() {
  override val mimeTypeAudio: String = MediaFormat.MIMETYPE_AUDIO_AAC

  override fun getMediaFormat(config: RecordConfig): MediaFormat {
    return MediaFormat().apply {
      setString(MediaFormat.KEY_MIME, mimeTypeAudio)
      setInteger(MediaFormat.KEY_SAMPLE_RATE, config.sampleRate)
      setInteger(MediaFormat.KEY_CHANNEL_COUNT, config.numChannels)
      setInteger(MediaFormat.KEY_BIT_RATE, config.bitRate)

      setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC)
    }
  }

  override fun createWriter(mediaFormat: MediaFormat, path: String?): IContainerWriter {
    requireNotNull(path) { "Streaming recording is not available" }
    return MuxerContainer(path, true, MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4)
  }
}
