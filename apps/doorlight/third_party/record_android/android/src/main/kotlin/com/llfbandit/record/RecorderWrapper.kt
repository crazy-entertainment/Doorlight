package com.llfbandit.record

import android.content.Context
import android.util.Log
import com.llfbandit.record.record.audio_manager.AndroidAudioEnvironment
import com.llfbandit.record.record.audio_manager.AudioEnvironment
import com.llfbandit.record.record.audio_manager.EnvironmentEvent
import com.llfbandit.record.record.model.RecordConfig
import com.llfbandit.record.record.model.RecordState
import com.llfbandit.record.record.recorder.RecorderController
import com.llfbandit.record.record.recorder.RecorderSink
import com.llfbandit.record.record.recorder.engine.CaptureEngine
import com.llfbandit.record.record.recorder.engine.CaptureEvent
import com.llfbandit.record.record.recorder.engine.PcmCaptureEngine
import com.llfbandit.record.record.stream.RecorderRecordStreamHandler
import com.llfbandit.record.record.stream.RecorderStateStreamHandler
import com.llfbandit.record.record.util.MainThread
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/** Method-channel adapter for one recorder; delegates the work to [RecorderController]. */
class RecorderWrapper(
  context: Context,
  private val recorderId: String,
  messenger: BinaryMessenger,
) {
  companion object {
    private val TAG = RecorderWrapper::class.java.simpleName
    const val EVENTS_STATE_CHANNEL = "com.llfbandit.record/events/"
    const val EVENTS_RECORD_CHANNEL = "com.llfbandit.record/eventsRecord/"
    const val CONFIG_CHANGED_CHANNEL = "com.llfbandit.record/configChanged/"
  }

  private val dispatcher = RecorderDispatcher()
  private val handler = dispatcher.handler
  private var captureTicket: NativeRecordingLease.Ticket<Any>? = null

  private fun releaseComplete(): Boolean {
    if (!controller.deviceReleased) return false
    return try { environment.dispose(); true } catch (_: Throwable) { false }
  }

  private fun reportRelease(failed: Boolean = false): Boolean {
    val released = !failed && releaseComplete()
    captureTicket?.let { ticket ->
      SybLRecordingBridge.released(ticket, released)
      if (released) captureTicket = null
    }
    return released
  }

  private fun stopForAuthority(done: (Boolean) -> Unit) {
    dispatcher.post {
      try { controller.stop { done(releaseComplete()) } }
      catch (_: Throwable) { done(false) }
    }
  }

  private val stateStreamHandler = RecorderStateStreamHandler()
  private val recordStreamHandler = RecorderRecordStreamHandler()
  private var eventChannel: EventChannel? =
    EventChannel(messenger, EVENTS_STATE_CHANNEL + recorderId)
  private var eventRecordChannel: EventChannel? =
    EventChannel(messenger, EVENTS_RECORD_CHANNEL + recorderId)
  private val configChangedChannel =
    MethodChannel(messenger, CONFIG_CHANGED_CHANNEL + recorderId)

  private val environment: AudioEnvironment = AndroidAudioEnvironment(context, handler)

  private val controller: RecorderController = RecorderController(
    environment = environment,
    engineFactory = { config -> PcmCaptureEngine(config, ::onCaptureEvent) },
    sink = object : RecorderSink {
      override fun onState(state: RecordState) = stateStreamHandler.sendStateEvent(state)
      override fun onError(error: Throwable) {
        // The streams may have no listener; keep the cause visible in logcat.
        Log.e(TAG, "Recorder capture failed")
        val ex = Exception("Recorder capture failed")
        stateStreamHandler.sendStateErrorEvent(ex)
        recordStreamHandler.sendErrorEvent(ex)
      }
      override fun onConfigChanged(config: RecordConfig) = notifyConfigChanged(config)
    },
    post = dispatcher::post,
  )

  init {
    environment.onEvent = { event ->
      // A messaging take never auto-resumes when another audio owner releases
      // focus. Interruption requires a fresh deliberate activation.
      if (event == EnvironmentEvent.FocusLost) SybLRecordingBridge.revoke()
    }
    eventChannel?.setStreamHandler(stateStreamHandler)
    eventRecordChannel?.setStreamHandler(recordStreamHandler)
  }

  // Raised from the engine's own threads.
  private fun onCaptureEvent(source: CaptureEngine, event: CaptureEvent) {
    when (event) {
      is CaptureEvent.Chunk -> recordStreamHandler.sendRecordChunkEvent(event.bytes)
      is CaptureEvent.Failed -> handler.post {
        try { controller.onCaptureFailure(source, event.cause) }
        catch (_: Throwable) { /* A failed teardown keeps the native slot held. */ }
        // Completion remains owned by the engine; the watchdog requests stop
        // and waits through any teardown already in flight.
        SybLRecordingBridge.revoke()
      }
    }
  }

  fun startRecordingToFile(config: RecordConfig, result: MethodChannel.Result) =
    startRecording(config, result)

  fun startRecordingToStream(config: RecordConfig, result: MethodChannel.Result) {
    result.error("record_capture_denied", "Streaming recording is not available", null)
  }

  private fun startRecording(config: RecordConfig, result: MethodChannel.Result) {
    dispatcher.post {
      try {
        val ticket = SybLRecordingBridge.begin(recorderId, config, ::stopForAuthority)
        if (ticket == null) {
          result.error("record_capture_denied", "Recording is not available", null)
          return@post
        }
        captureTicket = ticket
        if (!SybLRecordingBridge.current(ticket)) {
          reportRelease()
          result.error("record_capture_expired", "Recording activation expired", null)
          return@post
        }
        controller.start(config) { error ->
          if (error == null && SybLRecordingBridge.current(ticket)) result.success(null)
          else if (error != null) {
            reportRelease()
            fail(result, error)
          } else {
            // Expiry is a stop request, not a failed-stop acknowledgement. The
            // device may have opened while the async start was completing.
            SybLRecordingBridge.revoke()
            fail(result, IllegalStateException("Recording activation expired"))
          }
        }
      } catch (e: Exception) {
        SybLRecordingBridge.revoke()
        fail(result, e)
      }
    }
  }

  fun pause(result: MethodChannel.Result) = run(result) { controller.pause() }

  fun resume(result: MethodChannel.Result) = run(result) {
    check(captureTicket?.let(SybLRecordingBridge::current) == true) { "Recording activation expired" }
    controller.resume()
  }

  // Answered once the file is finalized.
  fun stop(result: MethodChannel.Result) = runAsync(result) { done ->
    controller.stop { path ->
      if (reportRelease()) done(path)
      else result.error("record_release_unconfirmed", "Microphone release could not be confirmed", null)
    }
  }

  fun cancel(result: MethodChannel.Result) = runAsync(result) { done ->
    controller.cancel { path ->
      if (reportRelease()) done(path)
      else result.error("record_release_unconfirmed", "Microphone release could not be confirmed", null)
    }
  }

  fun isPaused(result: MethodChannel.Result) = run(result) { controller.isPaused }

  fun isRecording(result: MethodChannel.Result) = run(result) { controller.isRecording }

  fun getAmplitude(result: MethodChannel.Result) = run(result) {
    val amplitude = controller.amplitude()
    hashMapOf("current" to amplitude.current, "max" to amplitude.max)
  }

  /** Answers once the recorder is fully torn down. */
  fun dispose(result: MethodChannel.Result?) {
    dispatcher.post {
      try {
        controller.dispose {
          if (reportRelease()) result?.success(null)
          else result?.error("record_release_unconfirmed", "Microphone release could not be confirmed", null)
          dispatcher.quit()
        }
      } catch (e: Exception) {
        reportRelease(failed = true)
        result?.let { fail(it, e) }
        dispatcher.quit()
      }
    }

    eventChannel?.setStreamHandler(null)
    eventChannel = null
    eventRecordChannel?.setStreamHandler(null)
    eventRecordChannel = null
  }

  // Runs on the control thread; the block's value (Unit for actions) answers the call.
  private fun run(result: MethodChannel.Result, block: () -> Any?) {
    dispatcher.post {
      try {
        val value = block()
        result.success(if (value == Unit) null else value)
      } catch (e: Exception) {
        fail(result, e)
      }
    }
  }

  // Same, for a block that answers later.
  private fun runAsync(result: MethodChannel.Result, block: ((Any?) -> Unit) -> Unit) {
    dispatcher.post {
      try {
        block(result::success)
      } catch (e: Exception) {
        fail(result, e)
      }
    }
  }

  // `details` must be codec-encodable; a Throwable is not.
  private fun fail(result: MethodChannel.Result, error: Throwable) {
    result.error("record", "Recorder operation failed", null)
  }

  private fun notifyConfigChanged(config: RecordConfig) {
    MainThread.post {
      configChangedChannel.invokeMethod("onConfigChanged", config.toMap())
    }
  }
}
