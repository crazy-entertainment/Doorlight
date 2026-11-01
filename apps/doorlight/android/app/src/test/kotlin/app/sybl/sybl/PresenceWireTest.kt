package app.sybl.sybl

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PresenceWireTest {
    @Test
    fun `every profile palette color survives native presence round trip`() {
        val colors = listOf("amber", "coral", "rose", "violet", "sky", "teal", "sage", "lime", "red", "orange", "yellow", "green", "emerald", "mint", "cyan", "ice", "azure", "blue", "cobalt", "navy", "indigo", "magenta", "slate", "ivory")
        assertEquals(24, colors.toSet().size)
        for (color in colors) {
            val body = PresenceWire.encode("ping", false, 42, color = color)
            assertEquals(color, PresenceWire.decode(body, 42)?.color)
        }
        assertEquals(0xFF6386E5.toInt(), IdentityColorWire.argb("blue"))
    }

    @Test
    fun `android golden round trip carries bounded platform metadata`() {
        val encoded = PresenceWire.encode(
            type = "ping",
            foreground = false,
            timestampMs = 42,
            activity = "Café",
            color = "sage",
        )
        assertEquals(
            PresencePacket(3, "ping", 0, 42, "android", "Café", "sage", ""),
            PresenceWire.decode(encoded, nowMs = 42),
        )
        assertEquals(0xFF8FBE83.toInt(), IdentityColorWire.argb("sage"))
    }

    @Test
    fun `windows activity is accepted without window-title control text`() {
        assertEquals(
            PresencePacket(0, "pong", 1, 99, "windows", "Team Fortress 2", "", ""),
            PresenceWire.decode(
                """{"t":"pong","fg":1,"ts":99,"platform":"windows","activity":"Team Fortress 2"}""",
                nowMs = 99,
            ),
        )
        assertNull(PresenceWire.decode(
            """{"t":"pong","fg":1,"ts":99,"platform":"windows","activity":"chat \"secret\""}""",
            nowMs = 99,
        ))
        assertNull(PresenceWire.decode(
            """{"t":"pong","fg":1,"ts":99,"platform":"windows","activity":"\tEditor\t"}""",
            nowMs = 99,
        ))
    }

    @Test
    fun `timestamp must be fresh at the receiving boundary`() {
        val body = """{"v":1,"t":"pong","fg":1,"ts":100000,"platform":"windows","activity":""}"""
        assertEquals(PresencePacket(1, "pong", 1, 100000, "windows", "", "", ""), PresenceWire.decode(body, 100000))
        assertNull(PresenceWire.decode(body, 100000 + PresenceWire.MAX_CLOCK_DELTA_MS + 1))
        assertNull(PresenceWire.decode(body, 100000 - PresenceWire.MAX_CLOCK_DELTA_MS - 1))
    }

    @Test
    fun `malformed unknown and oversized payloads fail closed`() {
        assertNull(PresenceWire.decode("garbage"))
        assertNull(PresenceWire.decode("""{"t":"maybe"}"""))
        assertNull(PresenceWire.decode("x".repeat(PresenceWire.MAX_BODY_BYTES + 1)))
        assertNull(PresenceWire.decode("""{"v":2,"t":"ping","fg":1,"ts":1,"platform":"android","activity":""}"""))
        assertNull(PresenceWire.decode("""{"v":2,"t":"ping","fg":1,"ts":1,"platform":"android","activity":"","color":"ultraviolet"}"""))
        assertNull(PresenceWire.decode("""{"v":1,"t":"ping","fg":1,"ts":1,"platform":"android","activity":"","color":"sage"}"""))
        assertNull(PresenceWire.decode("""{"v":1,"t":"ping","fg":-1,"ts":1,"platform":"android","activity":""}"""))
        assertNull(PresenceWire.decode("""{"v":1,"t":"ping","fg":1.0,"ts":1,"platform":"android","activity":""}"""))
        assertNull(PresenceWire.decode("""{"v":1,"t":"ping","fg":1,"ts":0,"platform":"android","activity":""}"""))
        assertNull(PresenceWire.decode("""{"v":1,"t":"ping","fg":1,"ts":1,"platform":"android","activity":"","extra":1}"""))
        assertNull(PresenceWire.decode("""{"v":1,"v":1,"t":"ping","fg":1,"ts":1,"platform":"android","activity":""}"""))
        assertNull(PresenceWire.decode("""{"v":1,"\u0076":1,"t":"ping","fg":1,"ts":1,"platform":"android","activity":""}"""))
        assertNull(PresenceWire.decode("""{'v':1,'t':'ping','fg':1,'ts':1,'platform':'android','activity':''}"""))
        assertNull(PresenceWire.decode("""{v:1,t:"ping",fg:1,ts:1,platform:"android",activity:""}"""))
        assertNull(PresenceWire.decode("""{"v":1,"t":"ping","fg":1,"ts":1,"platform":"android","activity":"",}"""))
        assertNull(PresenceWire.decode("""{"v":1,"t":"ping","fg":1,"ts":1,"platform":"android","activity":""}garbage"""))
        assertNull(PresenceWire.decode("""{"v":1,"t":"ping","fg":1,"ts":1,"platform":"android","activity":"\ud800"}""", 1))
    }

    @Test
    fun `legacy one remains a metadata-free ping`() {
        assertEquals(
            PresencePacket(0, "ping", -1, 0, "", "", "", ""),
            PresenceWire.decode("1"),
        )
    }

    @Test
    fun `wake capability is exact base64url and does not weaken old versions`() {
        val handle = "A".repeat(43)
        val body = PresenceWire.encode(
            type = "wake",
            foreground = false,
            timestampMs = 200,
            color = "amber",
            wake = handle,
        )
        assertEquals(
            PresencePacket(3, "wake", 0, 200, "android", "", "amber", handle),
            PresenceWire.decode(body, 200),
        )
        assertNull(PresenceWire.decode(body.replace(handle, "not-a-handle"), 200))
        assertNull(PresenceWire.decode(
            """{"v":2,"t":"wake","fg":0,"ts":200,"platform":"android","activity":"","color":"amber"}""",
            200,
        ))
    }
}
