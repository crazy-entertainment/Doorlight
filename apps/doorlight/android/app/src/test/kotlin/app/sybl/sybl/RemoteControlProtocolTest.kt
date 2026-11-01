package app.sybl.sybl

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RemoteControlProtocolTest {
    private val tokenHex = "0123456789abcdef".repeat(4)
    private val token = ByteArray(32) { index -> index.toByte() }

    @Test
    fun screenSourceAnnouncementUsesTheReservedScreenEpoch() {
        val owner = "0123456789abcdef0123456789abcdef01234567"

        assertEquals(
            "{\"v\":1,\"t\":\"src\",\"sourceKind\":\"screen\",\"platform\":\"android\"," +
                "\"sourceOwner\":\"$owner\",\"sourceRevision\":42}",
            AndroidRemoteControlPolicy.sourceAnnouncement(owner, 42, "screen"),
        )
        assertNull(AndroidRemoteControlPolicy.sourceAnnouncement("not-an-id", 42, "screen"))
        assertNull(AndroidRemoteControlPolicy.sourceAnnouncement(owner, 0, "screen"))
        assertNull(AndroidRemoteControlPolicy.sourceAnnouncement(owner, 42, "off"))
    }

    @Test
    fun requestGoldenVectorParsesEveryKnownCapability() {
        val packet = AndroidRemoteControlPacketParser.parse(
            """{"v":1,"t":"req","caps":["mouse","keyboard","text","clipboard","back","home","recents"],"sourceRevision":42,"color":"sage"}""",
        ) as? AndroidRemoteControlRequest

        assertNotNull(packet)
        assertEquals(127, packet?.capabilities)
        assertEquals(42L, packet?.sourceRevision)
        assertEquals("sage", packet?.identityColor)
        assertEquals(
            AndroidRemoteControlProtocol.ANDROID_CAPABILITIES,
            AndroidRemoteControlPolicy.negotiatedCapabilities(packet!!.capabilities),
        )
        assertEquals(
            0,
            AndroidRemoteControlPolicy.negotiatedCapabilities(
                AndroidRemoteControlProtocol.CAP_KEYBOARD or
                    AndroidRemoteControlProtocol.CAP_CLIPBOARD,
            ),
        )
    }

    @Test
    fun inputGoldenVectorParsesSupportedEventsExactly() {
        val packet = AndroidRemoteControlPacketParser.parse(
            inputPacket(
                """["m",0.25,0.75],["d","left"],["u","left"],["w",-120],""" +
                    """["t","hello\n\u2603"],["a","back"],["a","home"],["a","recents"]""",
            ),
        ) as? AndroidRemoteControlInput

        assertNotNull(packet)
        assertArrayEquals(hexToBytes(tokenHex), packet?.token)
        assertEquals(9L, packet?.epoch)
        assertEquals(1L, packet?.sequence)
        assertEquals(42L, packet?.sourceRevision)
        assertEquals(
            listOf(
                AndroidRemoteControlMove(0.25, 0.75),
                AndroidRemoteControlButton("left", true),
                AndroidRemoteControlButton("left", false),
                AndroidRemoteControlWheel(-120),
                AndroidRemoteControlText("hello\n\u2603"),
                AndroidRemoteControlAction("back"),
                AndroidRemoteControlAction("home"),
                AndroidRemoteControlAction("recents"),
            ),
            packet?.events,
        )
    }

    @Test
    fun endGoldenVectorIsDirectionStrict() {
        assertEquals(
            AndroidRemoteControlEnd,
            AndroidRemoteControlPacketParser.parse("""{"v":1,"t":"end"}"""),
        )
        assertNull(
            AndroidRemoteControlPacketParser.parse(
                """{"v":1,"t":"grant","token":"$tokenHex","epoch":9,"sourceRevision":42,"caps":["mouse"]}""",
            ),
        )
    }

    @Test
    fun rootGrammarRejectsDuplicateUnknownMissingAndTrailingFields() {
        val rejected = listOf(
            """{"v":1,"v":1,"t":"end"}""",
            """{"v":1,"t":"end","extra":false}""",
            """{"v":1}""",
            """{"v":2,"t":"end"}""",
            """{"v":1,"t":"end"} true""",
            """[{"v":1,"t":"end"}]""",
            """{"v":01,"t":"end"}""",
            """{"v":1.0,"t":"end"}""",
        )
        rejected.forEach { value ->
            assertNull(value, AndroidRemoteControlPacketParser.parse(value))
        }
    }

    @Test
    fun commentsOutsideStringsAreRejectedAndLiteralSlashesArePreserved() {
        val comments = listOf(
            """{/*member*/"v":1,"t":"end"}""",
            """{"v":1,/*member*/"t":"end"}""",
            """{"v":1,"t":/*value*/"end"}""",
            """{"v":1,"t":"end"/*tail*/}""",
            "{\"v\":1,//member\n\"t\":\"end\"}",
            """{"v":1,"t":"req","caps":[/*item*/"mouse"],"color":"amber","sourceRevision":4}""",
        )
        comments.forEach { packet ->
            assertNull(packet, AndroidRemoteControlPacketParser.parse(packet))
        }
        val parsed = AndroidRemoteControlPacketParser.parse(
            inputPacket(
                """["t","http://peer/a /* text */ // text"],["t","quote: \" // text"],["t","slash: \\ // text"],["t","escaped slash: \/"]""",
            ),
        ) as? AndroidRemoteControlInput
        assertNotNull(parsed)
        assertEquals(
            listOf(
                AndroidRemoteControlText("http://peer/a /* text */ // text"),
                AndroidRemoteControlText("quote: \" // text"),
                AndroidRemoteControlText("slash: \\ // text"),
                AndroidRemoteControlText("escaped slash: /"),
            ),
            parsed!!.events,
        )
    }

    @Test
    fun packetByteBoundaryIsExactly6000ForAsciiAndMultibyteText() {
        assertEquals(6000, AndroidRemoteControlProtocol.MAX_PACKET_BYTES)
        for (packet in listOf("""{"v":1,"t":"end"}""", inputPacket("""["t","é"]"""))) {
            val padded = packet + " ".repeat(6000 - packet.toByteArray(Charsets.UTF_8).size)
            assertEquals(6000, padded.toByteArray(Charsets.UTF_8).size)
            assertNotNull(AndroidRemoteControlPacketParser.parse(padded))
            assertNull(AndroidRemoteControlPacketParser.parse("$padded "))
        }
    }

    @Test
    fun malformedNumbersEscapesAndDeepPacketsFailClosed() {
        assertEquals(20, AndroidRemoteControlProtocol.MAX_JSON_DEPTH)
        for (levels in listOf(19, 20, 21, 200)) {
            val source = "{\"a\":".repeat(levels - 1) + "0" + "}".repeat(levels - 1)
            if (levels <= 20) {
                assertNotNull(StrictJson(source).parseObjectDocument())
            } else {
                org.junit.Assert.assertThrows(IllegalArgumentException::class.java) {
                    StrictJson(source).parseObjectDocument()
                }
            }
        }
        for (number in listOf("01", "+1", ".1", "1.", "1e", "1e+", "-", "NaN", "Infinity", "-Infinity", "1e9999")) {
            assertNull(number, AndroidRemoteControlPacketParser.parse(inputPacket("""["m",$number,0.5]""")))
        }
        for (event in listOf("""["t","\x41"]""", """["t","\u12"]""", """["t","\u12xz"]""", """["m",0.5,0.5,]""")) {
            assertNull(event, AndroidRemoteControlPacketParser.parse(inputPacket(event)))
        }
        for (depth in listOf(19, 20, 21, 200)) {
            for (nested in listOf(
                "[".repeat(depth) + "0" + "]".repeat(depth),
                "{\"a\":".repeat(depth) + "0" + "}".repeat(depth),
                "[".repeat(depth) + "0",
            )) {
                val packet = """{"v":1,"t":"end","extra":$nested}"""
                assertTrue(packet.toByteArray(Charsets.UTF_8).size < 6000)
                assertNull(AndroidRemoteControlPacketParser.parse(packet))
            }
        }
    }

    @Test
    fun requestMutationsFailClosed() {
        val rejected = listOf(
            """{"v":1,"t":"req","caps":[],"color":"amber","sourceRevision":42}""",
            """{"v":1,"t":"req","caps":["mouse","mouse"],"color":"amber","sourceRevision":42}""",
            """{"v":1,"t":"req","caps":["camera"],"color":"amber","sourceRevision":42}""",
            """{"v":1,"t":"req","caps":["mouse"],"color":"amber","sourceRevision":0}""",
            """{"v":1,"t":"req","caps":["mouse"],"color":"amber","sourceRevision":-1}""",
            """{"v":1,"t":"req","caps":["mouse"],"color":"amber","sourceRevision":1.5}""",
            """{"v":1,"t":"req","caps":["mouse"],"sourceRevision":42}""",
            """{"v":1,"t":"req","caps":["mouse"],"color":"ultraviolet","sourceRevision":42}""",
        )
        rejected.forEach { value ->
            assertNull(value, AndroidRemoteControlPacketParser.parse(value))
        }
    }

    @Test
    fun jsonNumbersUseOnlyAsciiDigits() {
        for (number in listOf("1١", "4１", "1.١", "1e١")) {
            assertNull(number, AndroidRemoteControlPacketParser.parse(
                """{"v":1,"t":"req","caps":["mouse"],"color":"amber","sourceRevision":$number}""",
            ))
        }
        assertNotNull(AndroidRemoteControlPacketParser.parse(
            """{"v":1,"t":"req","caps":["mouse"],"color":"amber","sourceRevision":11}""",
        ))
    }

    @Test
    fun tokenEpochSequenceAndRevisionMutationsFailClosed() {
        val rejected = listOf(
            inputPacket("""["m",0.5,0.5]""", token = tokenHex.uppercase()),
            inputPacket("""["m",0.5,0.5]""", token = "ab".repeat(15)),
            inputPacket("""["m",0.5,0.5]""", epoch = 0),
            inputPacket("""["m",0.5,0.5]""", sequence = 0),
            inputPacket("""["m",0.5,0.5]""", revision = 0),
        )
        rejected.forEach { value ->
            assertNull(value, AndroidRemoteControlPacketParser.parse(value))
        }
    }

    @Test
    fun eventMutationsFailClosed() {
        val tooManyEvents = (0..64).joinToString(",") { """["m",0.5,0.5]""" }
        val longText = "x".repeat(AndroidRemoteControlProtocol.MAX_TEXT_BYTES + 1)
        val rejectedEvents = listOf(
            "",
            tooManyEvents,
            """["m",-0.01,0.5]""",
            """["m",0.5,1.01]""",
            """["m",0.5,0.5,"extra"]""",
            """["d","primary"]""",
            """["d","middle"]""",
            """["d","x1"]""",
            """["w",0]""",
            """["w",12001]""",
            """["t",""]""",
            """["t","$longText"]""",
            """["t","\u0001"]""",
            """["a","power"]""",
            """["k",65,true]""",
            """["unknown"]""",
        )
        rejectedEvents.forEach { events ->
            assertNull(events, AndroidRemoteControlPacketParser.parse(inputPacket(events)))
        }
    }

    @Test
    fun packetSizeLimitFailsClosed() {
        val oversized = """{"v":1,"t":"end","padding":"${"x".repeat(6_000)}"}"""
        assertTrue(oversized.toByteArray().size > AndroidRemoteControlProtocol.MAX_PACKET_BYTES)
        assertNull(AndroidRemoteControlPacketParser.parse(oversized))
    }

    @Test
    fun exactAuthorityBindingAcceptsOnlyTheNextAuthorizedInput() {
        val binding = binding()
        val events = listOf(AndroidRemoteControlMove(0.5, 0.5))

        assertTrue(
            authorizes(
                expectedBinding = binding,
                presentedBinding = binding,
                events = events,
            ),
        )
        assertFalse(
            authorizes(
                expectedBinding = null,
                presentedBinding = binding,
                events = events,
            ),
        )
        assertFalse(
            authorizes(
                expectedBinding = binding,
                presentedBinding = binding,
                presentedToken = token.copyOf().also { it[0] = 99 },
                events = events,
            ),
        )
        assertFalse(
            authorizes(
                expectedBinding = binding,
                presentedBinding = binding,
                presentedEpoch = 10,
                events = events,
            ),
        )
        assertFalse(
            authorizes(
                expectedBinding = binding,
                presentedBinding = binding,
                presentedSequence = 1,
                lastSequence = 1,
                events = events,
            ),
        )
        assertFalse(
            authorizes(
                expectedBinding = binding,
                presentedBinding = binding,
                presentedSequence = 3,
                lastSequence = 1,
                events = events,
            ),
        )
    }

    @Test
    fun everyIdentityAndSourceGeometryMutationIsRejected() {
        val expected = binding()
        val mutations = listOf(
            expected.copy(callId = "other-call"),
            expected.copy(localAccount = "other-local"),
            expected.copy(controllerAccount = "other-controller"),
            expected.copy(controllerDevice = "other-device"),
            expected.copy(source = expected.source.copy(callId = "other-call")),
            expected.copy(source = expected.source.copy(revision = 43)),
            expected.copy(source = expected.source.copy(frameWidth = 1079)),
            expected.copy(source = expected.source.copy(frameHeight = 2399)),
            expected.copy(source = expected.source.copy(displayWidth = 1079)),
            expected.copy(source = expected.source.copy(displayHeight = 2399)),
            expected.copy(source = expected.source.copy(safeLeft = 1)),
            expected.copy(source = expected.source.copy(safeTop = 73)),
            expected.copy(source = expected.source.copy(safeRight = 1079)),
            expected.copy(source = expected.source.copy(safeBottom = 2399)),
            expected.copy(source = expected.source.copy(rotation = 1)),
        )
        val events = listOf(AndroidRemoteControlMove(0.5, 0.5))

        mutations.forEach { mutation ->
            assertFalse(
                mutation.toString(),
                authorizes(
                    expectedBinding = expected,
                    presentedBinding = mutation,
                    events = events,
                ),
            )
        }
    }

    @Test
    fun controlRequiresExactFullDisplayCaptureBounds() {
        assertTrue(AndroidRemoteControlPolicy.ownsFullDisplay(1080, 2400, 1080, 2400))
        listOf(
            intArrayOf(0, 2400, 1080, 2400),
            intArrayOf(1080, 0, 1080, 2400),
            intArrayOf(1079, 2400, 1080, 2400),
            intArrayOf(1080, 2399, 1080, 2400),
            intArrayOf(2400, 1080, 1080, 2400),
            intArrayOf(1080, 2400, 2400, 1080),
        ).forEach { dimensions ->
            assertFalse(
                dimensions.contentToString(),
                AndroidRemoteControlPolicy.ownsFullDisplay(
                    dimensions[0],
                    dimensions[1],
                    dimensions[2],
                    dimensions[3],
                ),
            )
        }
    }

    @Test
    fun sourceActivationIsIdempotentUntilAuthorityIsRetiredOrReplaced() {
        assertFalse(AndroidRemoteControlPolicy.needsSourceActivation(7, 42, 7))
        assertTrue(AndroidRemoteControlPolicy.needsSourceActivation(7, 0, 7))
        assertTrue(AndroidRemoteControlPolicy.needsSourceActivation(-1, 42, 7))
        assertTrue(AndroidRemoteControlPolicy.needsSourceActivation(7, 42, 8))
    }

    @Test
    fun discretePointerInputRequiresAValidMoveFromTheExactAuthority() {
        val source = binding().source
        assertTrue(AndroidRemoteControlPolicy.ownsPointer(7, source, 7, source))
        assertFalse(AndroidRemoteControlPolicy.ownsPointer(0, source, 7, source))
        assertFalse(AndroidRemoteControlPolicy.ownsPointer(6, source, 7, source))
        assertFalse(AndroidRemoteControlPolicy.ownsPointer(7, null, 7, source))
        assertFalse(
            AndroidRemoteControlPolicy.ownsPointer(
                7,
                source.copy(revision = source.revision + 1),
                7,
                source,
            ),
        )
    }

    @Test
    fun sharedFrameMappingRejectsBarsAndMapsTheContainedDisplay() {
        val letterboxed = AndroidRemoteControlPolicy.mapSharedFramePoint(
            0.5,
            0.5,
            frameWidth = 1920,
            frameHeight = 1080,
            displayWidth = 2400,
            displayHeight = 1080,
        )
        assertEquals(1200.0, letterboxed?.first ?: -1.0, 0.001)
        assertEquals(540.0, letterboxed?.second ?: -1.0, 0.001)
        assertNull(
            AndroidRemoteControlPolicy.mapSharedFramePoint(
                0.5, 0.05, 1920, 1080, 2400, 1080,
            ),
        )

        val pillarboxed = AndroidRemoteControlPolicy.mapSharedFramePoint(
            0.5,
            0.5,
            frameWidth = 2400,
            frameHeight = 1080,
            displayWidth = 1920,
            displayHeight = 1080,
        )
        assertEquals(960.0, pillarboxed?.first ?: -1.0, 0.001)
        assertEquals(540.0, pillarboxed?.second ?: -1.0, 0.001)
        assertNull(
            AndroidRemoteControlPolicy.mapSharedFramePoint(
                0.05, 0.5, 2400, 1080, 1920, 1080,
            ),
        )
        assertNull(
            AndroidRemoteControlPolicy.mapSharedFramePoint(
                Double.NaN, 0.5, 1920, 1080, 1920, 1080,
            ),
        )
        assertNull(
            AndroidRemoteControlPolicy.mapSharedFramePoint(
                0.5, 0.5, 0, 1080, 1920, 1080,
            ),
        )
    }

    @Test
    fun directPointerInputIncludesVisibleSystemNavigation() {
        assertArrayEquals(
            intArrayOf(0, 0, 1080, 2400),
            AndroidRemoteControlPolicy.fullDisplayGestureBounds(1080, 2400),
        )
    }

    @Test
    fun localTouchFeedbackNeedsAnActiveHostAndAndroid13() {
        assertTrue(
            AndroidRemoteControlPolicy.localTouchFeedbackAvailable(
                sdk = 33,
                hostActive = true,
                identityColor = "sage",
            ),
        )
        assertFalse(
            AndroidRemoteControlPolicy.localTouchFeedbackAvailable(
                sdk = 32,
                hostActive = true,
                identityColor = "sage",
            ),
        )
        assertFalse(
            AndroidRemoteControlPolicy.localTouchFeedbackAvailable(
                sdk = 33,
                hostActive = false,
                identityColor = "sage",
            ),
        )
        assertFalse(
            AndroidRemoteControlPolicy.localTouchFeedbackAvailable(
                sdk = 33,
                hostActive = true,
                identityColor = "unknown",
            ),
        )
    }

    @Test
    fun directPointerInputMayActivateOnlyVisibleSystemControls() {
        assertTrue(
            AndroidRemoteControlPolicy.directSystemControlAllowed(
                systemWindow = true,
                packageName = "com.android.systemui",
                ownPackage = "app.sybl.sybl",
                visible = true,
                clickable = true,
            ),
        )
        assertFalse(
            AndroidRemoteControlPolicy.directSystemControlAllowed(
                systemWindow = false,
                packageName = "com.example.app",
                ownPackage = "app.sybl.sybl",
                visible = true,
                clickable = true,
            ),
        )
        assertFalse(
            AndroidRemoteControlPolicy.directSystemControlAllowed(
                systemWindow = true,
                packageName = "app.sybl.sybl",
                ownPackage = "app.sybl.sybl",
                visible = true,
                clickable = true,
            ),
        )
    }

    @Test
    fun threeButtonNavigationUsesTheLiveBottomInset() {
        assertEquals(
            "back",
            AndroidRemoteControlPolicy.threeButtonNavigationAction(
                x = 120,
                y = 2_300,
                width = 1_080,
                height = 2_400,
                bottomInset = 247,
                threeButtonMode = true,
            ),
        )
        assertEquals(
            "home",
            AndroidRemoteControlPolicy.threeButtonNavigationAction(
                540, 2_300, 1_080, 2_400, 247, true,
            ),
        )
        assertEquals(
            "recents",
            AndroidRemoteControlPolicy.threeButtonNavigationAction(
                960, 2_300, 1_080, 2_400, 247, true,
            ),
        )
        assertNull(
            AndroidRemoteControlPolicy.threeButtonNavigationAction(
                540, 2_000, 1_080, 2_400, 247, true,
            ),
        )
        assertNull(
            AndroidRemoteControlPolicy.threeButtonNavigationAction(
                540, 2_300, 1_080, 2_400, 247, false,
            ),
        )
    }

    @Test
    fun navigationInsetFallsBackToTheVisibleApplicationBottom() {
        assertEquals(
            247,
            AndroidRemoteControlPolicy.navigationBottomInset(
                systemInset = 0,
                displayHeight = 2_400,
                applicationBottom = 2_153,
            ),
        )
        assertEquals(
            180,
            AndroidRemoteControlPolicy.navigationBottomInset(
                systemInset = 180,
                displayHeight = 2_400,
                applicationBottom = 2_400,
            ),
        )
    }

    @Test
    fun AndroidCapabilityEnforcementRejectsUnnegotiatedEventFamilies() {
        val binding = binding()
        val cases = listOf(
            AndroidRemoteControlMove(0.5, 0.5) to AndroidRemoteControlProtocol.CAP_MOUSE,
            AndroidRemoteControlButton("left", true) to AndroidRemoteControlProtocol.CAP_MOUSE,
            AndroidRemoteControlWheel(120) to AndroidRemoteControlProtocol.CAP_MOUSE,
            AndroidRemoteControlText("safe") to AndroidRemoteControlProtocol.CAP_TEXT,
            AndroidRemoteControlAction("back") to AndroidRemoteControlProtocol.CAP_BACK,
            AndroidRemoteControlAction("home") to AndroidRemoteControlProtocol.CAP_HOME,
            AndroidRemoteControlAction("recents") to AndroidRemoteControlProtocol.CAP_RECENTS,
        )

        cases.forEach { (event, requiredCapability) ->
            assertTrue(
                authorizes(
                    expectedBinding = binding,
                    presentedBinding = binding,
                    capabilities = requiredCapability,
                    events = listOf(event),
                ),
            )
            assertFalse(
                authorizes(
                    expectedBinding = binding,
                    presentedBinding = binding,
                    capabilities = AndroidRemoteControlProtocol.ANDROID_CAPABILITIES xor
                        requiredCapability,
                    events = listOf(event),
                ),
            )
        }
        assertFalse(
            AndroidRemoteControlPolicy.eventsMatchCapabilities(
                listOf(AndroidRemoteControlAction("power")),
                AndroidRemoteControlProtocol.ANDROID_CAPABILITIES,
            ),
        )
    }

    @Test
    fun ownCallScreenMayShowConsentAndOnlyReceiveExitNavigation() {
        val own = "app.sybl.sybl"
        assertTrue(
            AndroidRemoteControlPolicy.packageAllowed(
                "com.example.ordinaryapp",
                own,
            ),
        )
        assertFalse(AndroidRemoteControlPolicy.packageAllowed(own, own))
        assertTrue(
            AndroidRemoteControlPolicy.packageAllowed(
                own,
                own,
                allowOwnPackage = true,
            ),
        )
        listOf(
            "android",
            "com.android.systemui",
            "com.android.settings",
            "com.android.permissioncontroller",
        ).forEach { systemPackage ->
            assertTrue(
                systemPackage,
                AndroidRemoteControlPolicy.packageAllowed(
                    systemPackage,
                    own,
                    allowOwnPackage = true,
                ),
            )
        }
    }

    @Test
    fun legacyGrantCodecPreservesExactDeviceIdentity() {
        val now = 1_800_000_000_000L
        val grant = AndroidRemoteControlGrant(
            localAccount = "a".repeat(40),
            controllerAccount = "b".repeat(40),
            controllerDevice = "c".repeat(40),
            createdAtMs = now - 1_000,
            lastUsedAtMs = now - 500,
        )
        val decoded = AndroidRemoteControlGrantPolicy.decode(
            AndroidRemoteControlGrantPolicy.encode(listOf(grant)),
        )
        assertEquals(listOf(grant), decoded)
        assertTrue(AndroidRemoteControlGrantPolicy.validIdentity(
            grant.localAccount, grant.controllerAccount, grant.controllerDevice))
        assertFalse(AndroidRemoteControlGrantPolicy.validIdentity(
            grant.localAccount, grant.controllerAccount, "d".repeat(39)))
    }

    private fun inputPacket(
        events: String,
        token: String = tokenHex,
        epoch: Long = 9,
        sequence: Long = 1,
        revision: Long = 42,
    ): String =
        """{"v":1,"t":"input","token":"$token","epoch":$epoch,"seq":$sequence,"sourceRevision":$revision,"ev":[$events]}"""

    @Test fun authenticatedGapIsTerminalButDuplicatesAndForeignTokensAreNotGaps() {
        val owner = binding()
        fun gap(sequence: Long, suppliedToken: ByteArray = token,
                suppliedOwner: AndroidRemoteControlBinding = owner) =
            AndroidRemoteControlPolicy.authenticatedSequenceGap(
                owner, suppliedOwner, token, suppliedToken, 9, 9, 1, sequence,
            )
        assertFalse(gap(1))
        assertFalse(gap(2))
        assertTrue(gap(3))
        assertFalse(gap(3, ByteArray(32)))
        assertFalse(gap(3, suppliedOwner = owner.copy(controllerDevice = "other-device")))
    }

    private fun binding() = AndroidRemoteControlBinding(
        callId = "call",
        localAccount = "local-account",
        controllerAccount = "controller-account",
        controllerDevice = "controller-device",
        source = AndroidRemoteControlSourceIdentity(
            callId = "call",
            revision = 42,
            frameWidth = 1080,
            frameHeight = 2400,
            displayWidth = 1080,
            displayHeight = 2400,
            safeLeft = 0,
            safeTop = 72,
            safeRight = 1080,
            safeBottom = 2400,
            rotation = 0,
        ),
    )

    private fun authorizes(
        expectedBinding: AndroidRemoteControlBinding?,
        presentedBinding: AndroidRemoteControlBinding,
        presentedToken: ByteArray = token,
        presentedEpoch: Long = 9,
        lastSequence: Long = 0,
        presentedSequence: Long = 1,
        capabilities: Int = AndroidRemoteControlProtocol.ANDROID_CAPABILITIES,
        events: List<AndroidRemoteControlEvent>,
    ): Boolean = AndroidRemoteControlPolicy.authorizesInput(
        expectedBinding = expectedBinding,
        presentedBinding = presentedBinding,
        expectedToken = token,
        presentedToken = presentedToken,
        expectedEpoch = 9,
        presentedEpoch = presentedEpoch,
        lastSequence = lastSequence,
        presentedSequence = presentedSequence,
        capabilities = capabilities,
        events = events,
    )

    private fun hexToBytes(value: String): ByteArray =
        ByteArray(value.length / 2) { index ->
            value.substring(index * 2, index * 2 + 2).toInt(16).toByte()
        }
}
