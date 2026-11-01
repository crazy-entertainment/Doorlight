package com.llfbandit.record.record.recorder.engine

import android.media.MediaFormat
import com.llfbandit.record.record.encoder.EncoderListener
import com.llfbandit.record.record.encoder.IEncoder
import com.llfbandit.record.record.format.Format
import com.llfbandit.record.record.model.RecordConfig
import com.llfbandit.record.record.recorder.PCMReader
import com.llfbandit.record.record.recorder.PcmInput
import com.llfbandit.record.record.util.Utils
import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.CompletableFuture
import java.util.concurrent.atomic.AtomicBoolean

/** [CaptureEngine] that records with AudioRecord + an [IEncoder] on a background loop. */
class PcmCaptureEngine internal constructor(
  config: RecordConfig,
  private val onEvent: (source: CaptureEngine, event: CaptureEvent) -> Unit,
  private val createEncoder: (RecordConfig, EncoderListener) -> Pair<IEncoder, MediaFormat>,
  private val createReader: (RecordConfig, MediaFormat) -> PcmInput,
) : CaptureEngine, EncoderListener {
  constructor(config: RecordConfig, onEvent: (CaptureEngine, CaptureEvent) -> Unit) :
    this(config, onEvent, Format::createEncoder, ::PCMReader)

  // The loop's inbox: a request from the control thread, or a failure from the encoder's.
  private sealed interface Msg {
    data object Pause : Msg
    data object Resume : Msg
    class Stop(val delete: Boolean, val done: (Throwable?) -> Unit) : Msg
    class EncoderFailed(val cause: Throwable) : Msg
  }

  // Own copy so the caller's config object is never mutated by codec renegotiation.
  private val config: RecordConfig = config.copy()
  private val inbox = LinkedBlockingQueue<Msg>()

  // Nulled by the loop, read the amplitude from control thread.
  @Volatile private var reader: PcmInput? = null
  private var encoder: IEncoder? = null
  private var thread: Thread? = null
  private val releaseStarted = AtomicBoolean(false)
  private val releaseCompletion = CompletableFuture<Throwable?>()
  private val stopRequested = AtomicBoolean(false)
  private val stopCompletion = CompletableFuture<Throwable?>()

  override val amplitude: Double get() = reader?.getAmplitude() ?: DEFAULT_AMPLITUDE_DB

  override fun start(): RecordConfig {
    try {
      Format.checkStreamSupport(config)
      val (enc, mediaFormat) = createEncoder(config, this)
      // Assigned first so a reader failure still releases the container it opened.
      encoder = enc
      val r = createReader(config, mediaFormat)
      reader = r
      r.start()
      enc.startEncoding()
    } catch (e: Exception) {
      // The throw already carries the cause.
      release {}
      throw e
    }

    thread = Thread(::pump, "record-capture").apply {
      isDaemon = true
      start()
    }
    return config
  }

  override fun pause(): Boolean = post(Msg.Pause)

  override fun resume(): Boolean = post(Msg.Resume)

  override fun stop(delete: Boolean, done: (Throwable?) -> Unit) {
    stopCompletion.thenAccept { error -> answer(delete, error, done) }
    if (!stopRequested.compareAndSet(false, true)) return
    val t = thread
    thread = null

    // Never started: only the encoder's container is left.
    if (t == null) {
      release { error -> stopCompletion.complete(error) }
      return
    }
    // The loop owns the teardown, so it answers.
    inbox.put(Msg.Stop(false) { error -> stopCompletion.complete(error) })
  }

  override fun onEncoderFailure(ex: Exception) {
    inbox.put(Msg.EncoderFailed(ex))
  }

  override fun onEncoderStream(bytes: ByteArray) = onEvent(this, CaptureEvent.Chunk(bytes))

  private fun post(msg: Msg): Boolean {
    val t = thread ?: return false
    // A loop that already failed must not report a pause as honored.
    if (!t.isAlive) return false
    inbox.put(msg)
    return true
  }

  private fun pump() {
    val reader = checkNotNull(reader)
    val encoder = checkNotNull(encoder)
    var paused = false
    var failure: Throwable

    capture@ while (true) {
      when (val msg = if (paused) inbox.take() else inbox.poll()) {
        null -> {}
        Msg.Pause -> paused = true
        Msg.Resume -> paused = false
        is Msg.Stop -> return release { error -> answer(msg.delete, error, msg.done) }
        is Msg.EncoderFailed -> { failure = msg.cause; break@capture }
      }
      if (paused) continue

      try {
        val buffer = reader.read()
        if (buffer.isNotEmpty()) encoder.encode(buffer)
      } catch (e: Exception) {
        failure = e
        break@capture
      }
    }

    // Stays alive after releasing: the stop that follows must still be answered.
    release {}
    onEvent(this, CaptureEvent.Failed(failure))
    while (true) {
      val msg = inbox.take()
      if (msg is Msg.Stop) return release { error ->
        answer(msg.delete, error ?: failure, msg.done)
      }
    }
  }

  /** Releases both halves regardless of failure; reports the first error. */
  private fun release(done: (Throwable?) -> Unit) {
    releaseCompletion.thenAccept(done)
    // Startup and failure cleanup may still be pending when stop arrives.
    // Every caller observes that exact teardown, including its first failure.
    if (!releaseStarted.compareAndSet(false, true)) return
    val r = reader
    val enc = encoder
    reader = null
    encoder = null

    var error: Throwable? = null
    try {
      r?.release()
    } catch (e: Exception) {
      error = e
    }

    if (enc == null) releaseCompletion.complete(error) else try {
      enc.stopEncoding { releaseCompletion.complete(error ?: it) }
    } catch (e: Exception) {
      releaseCompletion.complete(error ?: e)
    }
  }

  private fun answer(delete: Boolean, error: Throwable?, done: (Throwable?) -> Unit) {
    if (delete) Utils.deleteFile(config.path)
    done(error)
  }
}
