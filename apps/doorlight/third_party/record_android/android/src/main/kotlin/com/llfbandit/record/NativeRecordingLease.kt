package com.llfbandit.record

import java.util.concurrent.CompletableFuture

/** Native authority, independent of Dart timers. A failed/unknown device release
 * retains its slot. Callers may time out waiting, but may not infer silence. */
class NativeRecordingLease<Owner>(
  private val nowMilliseconds: () -> Long,
  private val ownerCurrent: (Owner) -> Boolean,
) {
  class Ticket<Owner> internal constructor(
    val owner: Owner,
    val recorderId: String,
    internal val started: Long,
    internal var deadline: Long,
    internal val stop: ((Boolean) -> Unit) -> Unit,
  ) {
    internal var revoked = false
    internal var stopRequested = false
    internal var completionObserved = false
    internal val completion = CompletableFuture<Boolean>()
  }

  private val lock = Any()
  private var active: Ticket<Owner>? = null
  private var foreground = false
  private var callBlocked = false

  val occupied: Boolean get() = synchronized(lock) { active != null }

  fun begin(owner: Owner, recorderId: String, stop: ((Boolean) -> Unit) -> Unit): Ticket<Owner>? =
    synchronized(lock) {
      if (!foreground || callBlocked || active != null || !ownerCurrent(owner) ||
        recorderId.isEmpty() || recorderId.length > 128) return@synchronized null
      val now = nowMilliseconds()
      Ticket(owner, recorderId, now, now + 2000, stop).also { active = it }
    }

  fun current(ticket: Ticket<Owner>): Boolean = synchronized(lock) {
    val now = nowMilliseconds()
    active === ticket && !ticket.revoked && foreground && !callBlocked &&
      now >= ticket.started && now < ticket.deadline && now - ticket.started < 120000 && ownerCurrent(ticket.owner)
  }

  fun renew(ticket: Ticket<Owner>): Boolean = synchronized(lock) {
    if (!current(ticket)) return@synchronized false
    ticket.deadline = minOf(nowMilliseconds() + 2000, ticket.started + 120000)
    true
  }

  fun setForeground(value: Boolean) {
    synchronized(lock) { foreground = value }
    if (!value) revoke()
  }

  /** Set before call reservation/answer. Wait for the returned future before
   * allowing Jami to acquire the microphone, including notification answers. */
  fun blockForCall(): CompletableFuture<Boolean> {
    synchronized(lock) { callBlocked = true }
    return revoke()
  }

  fun clearCallBlock() { synchronized(lock) { callBlocked = false } }

  /** Called by a native periodic watchdog, also checking account/restore loss. */
  fun tick() {
    val expired = synchronized(lock) { active?.takeUnless(::current) }
    if (expired != null) revoke(expired)
  }

  fun revoke(): CompletableFuture<Boolean> {
    val ticket = synchronized(lock) { active }
      ?: return CompletableFuture.completedFuture(true)
    return revoke(ticket)
  }

  private fun revoke(ticket: Ticket<Owner>): CompletableFuture<Boolean> {
    val stop = synchronized(lock) {
      if (active !== ticket) return ticket.completion
      ticket.revoked = true
      if (ticket.stopRequested || ticket.completionObserved) false
      else { ticket.stopRequested = true; true }
    }
    if (stop) {
      try { ticket.stop { released(ticket, it) } }
      catch (_: Throwable) { released(ticket, false) }
    }
    return ticket.completion
  }

  /** Only the exact engine's completed stop/dispose may report this result. */
  fun released(ticket: Ticket<Owner>, success: Boolean) {
    synchronized(lock) {
      if (active !== ticket || ticket.completionObserved) return
      ticket.completionObserved = true
      ticket.revoked = true
      if (success) active = null
    }
    ticket.completion.complete(success)
  }
}
