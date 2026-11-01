package app.sybl.sybl

import org.junit.Assert.*
import org.junit.Test

class DevicePairingFlowTest {
    private val operation = 123456L
    private val uri = "jami-auth://${"a".repeat(64)}/$operation/doorlight-v1"
    private val identity = mapOf("peer_id" to "b".repeat(40),
        "peer_device" to "c".repeat(64), "device_id" to "d".repeat(64))
    private val scheme = mapOf("auth_scheme" to "doorlight-code-v1")
    private fun destination() = DevicePairingFlow("flow", "reserved", true).also {
        assertTrue(it.bindOperation(operation))
        assertTrue(it.accept(operation, 1, scheme + mapOf("operation" to "$operation", "token" to uri)))
    }
    private fun prepared() = destination().also {
        assertTrue(it.accept(operation, 3, scheme + identity))
        assertTrue(it.submittingCode())
        assertTrue(it.accept(operation, 4, identity + ("prepared" to "true")))
    }

    @Test fun closingBeforeAdmissionOrPrivacyRetirementCannotStartALateVisit() {
        val visits = DevicePairingVisits()
        val a = "a".repeat(64); val b = "b".repeat(64)
        val epoch = visits.capture()
        assertTrue(visits.allows(a, epoch))
        visits.retire(a)
        assertFalse(visits.allows(a, epoch))
        assertTrue(visits.allows(b, epoch))
        visits.retireAll()
        assertFalse(visits.allows(b, epoch))
        assertTrue(visits.allows(b, visits.capture()))
        assertFalse(visits.allows("malformed", visits.capture()))
    }

    @Test fun onlyVersionedOffersAndExactAsciiCodesAreAccepted() {
        assertTrue(DevicePairingFlow.validOffer(uri))
        for (value in listOf(uri + "?x=1", uri.replace("/doorlight-v1", ""),
            uri.replace("123456", "012345"), uri.uppercase(), "$uri\n", "https://example.invalid"))
            assertFalse(value, DevicePairingFlow.validOffer(value))
        assertTrue(DevicePairingFlow.validCode("00123456"))
        for (value in listOf("1234567", "123456789", "1234 678", "\uff11\uff12\uff13\uff14\uff15\uff16\uff17\uff18", "12345678\n"))
            assertFalse(DevicePairingFlow.validCode(value))
    }

    @Test fun exactOperationCannotBeReboundOrCompletedByAnotherAttempt() {
        val flow = destination()
        assertFalse(flow.bindOperation(operation + 1))
        assertFalse(flow.accept(operation + 1, 5, mapOf("error" to "timeout")))
        assertFalse(flow.terminal)
        assertEquals("waiting", flow.status)
        assertFalse(DevicePairingFlow("f", "a", true).bindOperation(1))
        assertFalse(DevicePairingFlow("f", "a", false).bindOperation(0))
    }

    @Test fun sourceRequiresExplicitCodeIssuanceAndCannotIssueTwice() {
        val flow = DevicePairingFlow("flow", "source", false)
        assertTrue(flow.bindOperation(7))
        assertFalse(flow.issuedCode("00123456"))
        assertTrue(flow.accept(7, 2, emptyMap()))
        assertFalse(flow.accept(7, 4, emptyMap()))
        assertTrue(flow.accept(7, 3, scheme))
        assertTrue(flow.issuedCode("00123456"))
        assertFalse(flow.issuedCode("87654321"))
        assertEquals("00123456", flow.projection()["code"])
        assertTrue(flow.accept(7, 4, emptyMap()))
        assertEquals("", flow.projection()["code"])
        assertTrue(flow.accept(7, 5, identity + ("error" to "")))
        assertEquals("complete", flow.status)
        assertFalse(flow.accept(7, 3, scheme))
    }

    @Test fun onlyNativeRetryReopensCodeEntryAndPeerIdentityCannotChange() {
        val flow = destination()
        assertTrue(flow.accept(operation, 3, scheme + identity))
        assertTrue(flow.submittingCode())
        assertFalse(flow.submittingCode())
        assertFalse(flow.accept(operation, 3, scheme + identity + ("peer_id" to "e".repeat(40))))
        assertTrue(flow.accept(operation, 3, scheme + identity + ("auth_error" to "invalid_code")))
        assertEquals(true, flow.projection()["invalidCode"])
        assertTrue(flow.submittingCode())
        assertFalse(flow.accept(operation, 4, identity + mapOf("prepared" to "true", "device_id" to "c".repeat(64))))
    }

    @Test fun nativeLinkSuccessIsNotApplicationActivationOrDurablePrivacy() {
        val premature = prepared()
        assertTrue(premature.accept(operation, 5, identity + ("error" to "")))
        assertFalse(premature.acknowledgedDurably())
        assertEquals("confirming", premature.status)
        val flow = prepared()
        assertFalse(flow.acknowledgedDurably())
        assertTrue(flow.preparedPrivacy())
        assertFalse(flow.preparedPrivacy())
        assertTrue(flow.accept(operation, 5, identity + ("error" to "")))
        assertEquals("confirming", flow.status)
        assertTrue(flow.acknowledgedDurably())
        assertEquals("ready", flow.status)
    }

    @Test fun retirementErasesPrivateMaterialButKeepsTerminalOwnership() {
        val flow = destination()
        flow.retire()
        assertEquals("", flow.projection()["uri"])
        assertEquals("retired", flow.projection()["status"])
        assertFalse(flow.accept(operation, 3, scheme + identity))
        assertFalse(flow.terminal)
        assertTrue(flow.accept(operation, 5, mapOf("error" to "canceled")))
        assertTrue(flow.terminal)
        assertEquals("retired", flow.projection()["status"])
    }

    @Test fun uncertainObservationIsNeverSuccessFailureOrRetryAuthority() {
        val flow = prepared()
        flow.unconfirmed()
        assertFalse(flow.terminal)
        assertEquals("unconfirmed", flow.status)
        assertFalse(flow.submittingCode())
        assertFalse(flow.acknowledgedDurably())
        assertTrue(flow.accept(operation, 5, mapOf("error" to "network")))
        assertEquals("ended", flow.status)
        assertFalse(flow.nativeSucceeded)
        assertEquals("DevicePairingFlow(<private>)", flow.toString())
    }
}
