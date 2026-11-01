package com.llfbandit.record

import org.junit.Assert.*
import org.junit.Test

class NativeRecordingLeaseTest {
  private var now = 0L
  private var owner = Any()
  private val leases = NativeRecordingLease<Any>({ now }, { it === owner })
  private var stopCalls = 0
  private var completeStop: ((Boolean) -> Unit)? = null
  private fun begin(): NativeRecordingLease.Ticket<Any> {
    leases.setForeground(true)
    return leases.begin(owner, "recorder") { done -> stopCalls++; completeStop = done }!!
  }

  @Test fun stalledDartExpiresWithoutFreeingHardware() {
    val ticket = begin()
    now = 2000
    leases.tick()
    assertEquals(1, stopCalls)
    assertFalse(leases.renew(ticket))
    assertTrue(leases.occupied)
    assertFalse(leases.revoke().isDone)
    leases.tick()
    assertEquals(1, stopCalls)
    completeStop!!(true)
    assertFalse(leases.occupied)
  }

  @Test fun renewalCannotExtendTheNativeMaximumDuration() {
    val ticket = begin()
    for (second in 1..119) {
      now = second * 1000L
      assertTrue(leases.renew(ticket))
    }
    now = 120000
    leases.tick()
    assertEquals(1, stopCalls)
    assertFalse(leases.current(ticket))
  }

  @Test fun callAnswerWaitsForReleaseAndFailureKeepsTheSlotBlocked() {
    begin()
    val result = leases.blockForCall()
    assertFalse(result.isDone)
    completeStop!!(false)
    assertFalse(result.get())
    leases.clearCallBlock()
    assertTrue(leases.occupied)
    assertNull(leases.begin(owner, "next") {})
    completeStop!!(true) // A repeated callback cannot reverse a failed release.
    assertTrue(leases.occupied)
  }

  @Test fun backgroundAndAccountLossRevokeWithoutRevivingTheOldTicket() {
    val first = begin()
    leases.setForeground(false)
    leases.setForeground(true)
    assertFalse(leases.current(first))
    completeStop!!(true)
    val second = begin()
    owner = Any()
    leases.tick()
    assertFalse(leases.current(second))
    assertEquals(2, stopCalls)
  }

  @Test fun staleReleaseCannotReleaseAnotherRecording() {
    val first = begin()
    leases.released(first, true)
    val second = begin()
    leases.released(first, true)
    assertTrue(leases.current(second))
    assertNull(leases.begin(owner, "parallel") {})
  }
}
