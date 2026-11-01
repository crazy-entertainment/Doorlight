package com.llfbandit.record.record.recorder.engine

import android.media.MediaFormat
import com.llfbandit.record.record.audio_manager.AudioEnvironment
import com.llfbandit.record.record.audio_manager.EnvironmentEvent
import com.llfbandit.record.record.encoder.IEncoder
import com.llfbandit.record.record.model.RecordConfig
import com.llfbandit.record.record.model.RecordState
import com.llfbandit.record.record.recorder.PcmInput
import com.llfbandit.record.record.recorder.RecorderController
import com.llfbandit.record.record.recorder.RecorderSink
import com.llfbandit.record.testRecordConfig
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [30])
class PcmCaptureReleaseTest {
  private class Reader : PcmInput {
    var startError: Exception? = null
    var releaseError: Exception? = null
    var releases = 0
    val read = CountDownLatch(1)
    override fun start() { startError?.let { throw it } }
    override fun read(): ByteArray { read.countDown(); return byteArrayOf() }
    override fun getAmplitude() = -160.0
    override fun release() { releases++; releaseError?.let { throw it } }
    override fun close() = release()
  }

  private class Encoder : IEncoder {
    var starts = 0
    var stops = 0
    var pending: ((Exception?) -> Unit)? = null
    val stopping = CountDownLatch(1)
    override fun startEncoding() { starts++ }
    override fun encode(bytes: ByteArray) {}
    override fun stopEncoding(done: (Exception?) -> Unit) {
      stops++
      pending = done
      stopping.countDown()
    }
  }

  private val reader = Reader()
  private val encoder = Encoder()
  private val config = testRecordConfig()
  private val engine = PcmCaptureEngine(config, { _, _ -> },
    { _, _ -> encoder to MediaFormat() }, { _, _ -> reader })

  private fun failedStart() {
    reader.startError = IllegalStateException("start failed")
    assertSame(reader.startError, runCatching { engine.start() }.exceptionOrNull())
  }

  @Test fun startupCleanupMustCompleteBeforeAnyStopAcknowledgesRelease() {
    failedStart()
    val results = mutableListOf<Throwable?>()
    engine.stop(false) { results += it }
    engine.stop(false) { results += it }
    assertTrue(results.isEmpty())
    assertEquals(1, reader.releases)
    assertEquals(1, encoder.stops)
    encoder.pending!!(null)
    assertEquals(listOf<Throwable?>(null, null), results)
    engine.stop(false) { results += it }
    assertEquals(3, results.size)
    assertEquals(1, reader.releases)
    assertEquals(1, encoder.stops)
  }

  @Test fun startupReaderReleaseFailureSurvivesSubsequentStopAndDuplicateCompletion() {
    val failure = IllegalStateException("reader release failed")
    reader.releaseError = failure
    failedStart()
    val results = mutableListOf<Throwable?>()
    engine.stop(false) { results += it }
    assertTrue(results.isEmpty())
    encoder.pending!!(null)
    encoder.pending!!(null)
    engine.stop(false) { results += it }
    assertEquals(2, results.size)
    assertTrue(results.all { it === failure })
  }

  @Test fun controllerCannotClearDeviceOwnershipWhileFailedStartupCleanupIsPendingOrFailed() {
    val environment = object : AudioEnvironment {
      override var onEvent: (EnvironmentEvent) -> Unit = {}
      override fun prepare(config: RecordConfig, onReady: () -> Unit) = onReady()
      override fun activate(config: RecordConfig) {}
      override fun release(config: RecordConfig) {}
      override fun dispose() {}
    }
    val sink = object : RecorderSink {
      override fun onState(state: RecordState) {}
      override fun onError(error: Throwable) {}
      override fun onConfigChanged(config: RecordConfig) {}
    }
    val controller = RecorderController(environment, { engine }, sink, { it() })
    reader.startError = IllegalStateException("start failed")
    var replies = 0
    controller.start(config) { replies++ }
    controller.stop { replies++ }
    assertEquals(0, replies)
    assertFalse(controller.deviceReleased)
    encoder.pending!!(IllegalStateException("encoder release failed"))
    assertEquals(2, replies)
    assertFalse(controller.deviceReleased)
    controller.start(config) { assertNotNull(it); replies++ }
    assertEquals(3, replies)
    assertEquals(1, reader.releases)
  }

  @Test fun ordinaryRecordingAndOverlappingStopsShareOneCompletedTeardown() {
    engine.start()
    assertTrue(reader.read.await(2, TimeUnit.SECONDS))
    val results = mutableListOf<Throwable?>()
    engine.stop(false) { results += it }
    assertTrue(encoder.stopping.await(2, TimeUnit.SECONDS))
    engine.stop(false) { results += it }
    assertTrue(results.isEmpty())
    assertEquals(1, reader.releases)
    assertEquals(1, encoder.stops)
    encoder.pending!!(null)
    assertEquals(listOf<Throwable?>(null, null), results)
    assertEquals(1, encoder.starts)
  }

  @Test fun captureFailureStillWaitsForTheOriginalTeardown() {
    engine.start()
    assertTrue(reader.read.await(2, TimeUnit.SECONDS))
    val failure = IllegalStateException("capture failed")
    engine.onEncoderFailure(failure)
    assertTrue(encoder.stopping.await(2, TimeUnit.SECONDS))
    val results = java.util.concurrent.CopyOnWriteArrayList<Throwable?>()
    val answered = CountDownLatch(1)
    engine.stop(false) { results += it; answered.countDown() }
    assertTrue(results.isEmpty())
    encoder.pending!!(null)
    assertTrue(answered.await(2, TimeUnit.SECONDS))
    assertEquals(1, results.size)
    assertSame(failure, results.single())
    assertEquals(1, reader.releases)
    assertEquals(1, encoder.stops)
  }
}
