package com.llfbandit.record

import android.media.MediaFormat
import com.llfbandit.record.record.format.AudioFormats
import com.llfbandit.record.record.model.AudioEncoder
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [30])
class SybLRecordingBridgeTest {
  @Test fun onlyAacLcFilesAreReportedAndAdmitted() {
    assertEquals(MediaFormat.MIMETYPE_AUDIO_AAC, AudioFormats.getMimeType("aacLc"))
    val owner = Any()
    val path = "private/voice.m4a"
    SybLRecordingBridge.configure({ it === owner }, {})
    SybLRecordingBridge.setForeground(true)
    assertTrue(SybLRecordingBridge.offer(owner, path))
    try {
      for (encoder in AudioEncoder.entries.filter { it != AudioEncoder.AacLc }.map { it.value } + "unknown") {
        assertNull(AudioFormats.getMimeType(encoder))
        assertNull(SybLRecordingBridge.begin("recorder", testRecordConfig(
          path = path, encoder = encoder, bitRate = 96000, sampleRate = 48000)) {})
      }
      for (config in listOf(
        testRecordConfig(path = null, bitRate = 96000, sampleRate = 48000),
        testRecordConfig(path = path, bitRate = 96000, sampleRate = 48000, useLegacy = true),
        testRecordConfig(path = path, bitRate = 96000, sampleRate = 48000, numChannels = 2),
        testRecordConfig(path = path, bitRate = 128000, sampleRate = 48000),
        testRecordConfig(path = path, bitRate = 96000, sampleRate = 44100),
      )) assertNull(SybLRecordingBridge.begin("recorder", config) {})
      assertNotNull(SybLRecordingBridge.begin("recorder", testRecordConfig(
        path = path, bitRate = 96000, sampleRate = 48000)) { done -> done(true) })
    } finally {
      assertTrue(SybLRecordingBridge.revoke().get())
      SybLRecordingBridge.setForeground(false)
    }
  }

  @Test fun exactGrantLifecycleAndNativeWatchdogReachTheOwnedStopCallback() {
    val owner = Any()
    val live = AtomicBoolean(true)
    val released = CountDownLatch(1)
    SybLRecordingBridge.configure({ it === owner && live.get() }, { released.countDown() })
    SybLRecordingBridge.setForeground(true)
    val config = testRecordConfig(path = "private/voice.m4a", encoder = "aacLc", bitRate = 96000, sampleRate = 48000)
    assertNull(SybLRecordingBridge.begin("recorder", config) {})
    assertTrue(SybLRecordingBridge.offer(owner, config.path!!))
    assertNull(SybLRecordingBridge.begin("recorder", testRecordConfig()) {})
    assertNull(SybLRecordingBridge.begin("recorder", testRecordConfig(
      path = "different/voice.m4a", encoder = "aacLc", bitRate = 96000, sampleRate = 48000)) {})
    val stopped = CountDownLatch(1)
    val ticket = SybLRecordingBridge.begin("recorder", config) { done ->
      stopped.countDown()
      done(true)
    }!!
    assertTrue(SybLRecordingBridge.current(ticket))
    assertFalse(SybLRecordingBridge.renew("different/voice.m4a"))
    assertTrue(SybLRecordingBridge.renew(config.path!!))
    live.set(false)
    // This is the real native scheduled watchdog, not a Dart tick or a direct
    // call to the lease's tick method.
    assertTrue(stopped.await(2, TimeUnit.SECONDS))
    assertTrue(released.await(2, TimeUnit.SECONDS))
    assertFalse(SybLRecordingBridge.current(ticket))
    assertTrue(SybLRecordingBridge.revoke().get())
    SybLRecordingBridge.setForeground(false)
  }
}
