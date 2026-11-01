package com.llfbandit.record

import android.os.SystemClock
import com.llfbandit.record.record.model.AudioEncoder
import com.llfbandit.record.record.model.RecordConfig
import java.util.concurrent.CompletableFuture
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit

/** The app grants one exact private output path to one native account lifetime.
 * The package cannot start capture without that grant, including startStream. */
object SybLRecordingBridge {
  private data class Permit(val owner: Any, val path: String, val expires: Long)
  private val lock = Any()
  @Volatile private var ownerCurrent: (Any) -> Boolean = { false }
  @Volatile private var ownerReleased: (Any) -> Unit = {}
  private val leases = NativeRecordingLease<Any>(SystemClock::elapsedRealtime) { ownerCurrent(it) }
  private var pending: Permit? = null
  private var active: NativeRecordingLease.Ticket<Any>? = null
  private var activePath: String? = null
  @Volatile private var foreground = false
  private val watchdog = Executors.newSingleThreadScheduledExecutor { task ->
    Thread(task, "sybl-recording-watchdog").apply { isDaemon = true }
  }

  init {
    watchdog.scheduleWithFixedDelay({
      try {
        expirePermit()
        leases.tick()
      } catch (_: Throwable) {
        leases.revoke()
      }
    }, 100, 100, TimeUnit.MILLISECONDS)
  }

  fun configure(current: (Any) -> Boolean, released: (Any) -> Unit) {
    ownerCurrent = current
    ownerReleased = released
  }

  fun offer(owner: Any, path: String): Boolean = synchronized(lock) {
    if (!foreground || pending != null || leases.occupied || !ownerCurrent(owner) || path.isEmpty()) false
    else { pending = Permit(owner, path, SystemClock.elapsedRealtime() + 2000); true }
  }

  private fun expirePermit(force: Boolean = false) {
    val expired = synchronized(lock) {
      pending?.takeIf { force || SystemClock.elapsedRealtime() >= it.expires || !ownerCurrent(it.owner) }
        ?.also { pending = null }
    }
    expired?.let { ownerReleased(it.owner) }
  }

  internal fun begin(recorderId: String, config: RecordConfig,
    stop: ((Boolean) -> Unit) -> Unit): NativeRecordingLease.Ticket<Any>? {
    if (config.encoder != AudioEncoder.AacLc || config.path == null || config.useLegacy ||
      config.sampleRate != 48000 || config.numChannels != 1 || config.bitRate != 96000) return null
    val ticket = synchronized(lock) {
      val permit = pending ?: return null
      if (permit.path != config.path || SystemClock.elapsedRealtime() >= permit.expires) return null
      val admitted = leases.begin(permit.owner, recorderId, stop) ?: return null
      pending = null
      active = admitted
      activePath = permit.path
      admitted
    }
    ticket.completion.thenAccept { released ->
      if (released) {
        synchronized(lock) {
          if (active === ticket) { active = null; activePath = null }
        }
        ownerReleased(ticket.owner)
      }
    }
    return ticket
  }

  internal fun current(ticket: NativeRecordingLease.Ticket<Any>) = leases.current(ticket)
  internal fun released(ticket: NativeRecordingLease.Ticket<Any>, success: Boolean) = leases.released(ticket, success)

  fun renew(path: String): Boolean = synchronized(lock) {
    val ticket = active ?: return false
    path == activePath && leases.renew(ticket)
  }

  fun setForeground(value: Boolean) {
    foreground = value
    if (!value) expirePermit(force = true)
    leases.setForeground(value)
  }

  fun revoke(): CompletableFuture<Boolean> {
    expirePermit(force = true)
    return leases.revoke()
  }
}
