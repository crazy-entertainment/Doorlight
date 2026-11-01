package com.llfbandit.record.record.format

import android.media.MediaFormat
import com.llfbandit.record.record.model.AudioEncoder
import com.llfbandit.record.record.model.RecordConfig
import com.llfbandit.record.record.container.IContainerWriter
import com.llfbandit.record.record.encoder.EncoderListener
import com.llfbandit.record.record.encoder.IEncoder

/**
 * Represents an audio format.
 * This class is responsible for creating the encoder and container for the specified format.
 * It also provides the [MediaFormat] for the encoded audio stream.
 */
sealed class Format {
  /**
   * The MIME type of the encoded audio stream inside the container.
   */
  abstract val mimeTypeAudio: String

  /**
   * Create a [MediaFormat] representing the encoded audio with parameters matching the specified
   * input PCM audio format.
   */
  abstract fun getMediaFormat(config: RecordConfig): MediaFormat

  /**
   * Create a container to write the encoded data.
   *
   * @param path The output path if the container writes to file.
   * @param mediaFormat The final negotiated [MediaFormat] for the encoded stream.
   */
  abstract fun createWriter(mediaFormat: MediaFormat, path: String?): IContainerWriter

  companion object {
    const val KEY_X_FRAME_SIZE_IN_BYTES = "x-frame-size-in-bytes"

    /**
     * Throws [IllegalArgumentException] if [config] requests stream mode but
     * the selected format does not support it.
     */
    fun checkStreamSupport(config: RecordConfig) {
      requireNotNull(config.path) { "Streaming recording is not available" }
    }

    /**
     * Create an encoder that produces [MediaFormat] output.
     */
    fun createEncoder(
      config: RecordConfig,
      listener: EncoderListener
    ): Pair<IEncoder, MediaFormat> {
      val format = selectFormat(config)
      return FormatCodecSelector.findCodec(format, config, listener)
    }

    private fun selectFormat(config: RecordConfig): Format {
      require(config.encoder == AudioEncoder.AacLc) { "Only AAC-LC recording is available" }
      return AacFormat()
    }
  }
}
