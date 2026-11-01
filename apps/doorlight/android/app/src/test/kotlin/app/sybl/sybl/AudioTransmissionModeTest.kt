package app.sybl.sybl

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AudioTransmissionModeTest {
    @Test
    fun `wire values are exact and reject fallback spellings`() {
        assertEquals(AudioTransmissionMode.OPEN, AudioTransmissionMode.parse("open"))
        assertEquals(
            AudioTransmissionMode.VOICE_ACTIVATED,
            AudioTransmissionMode.parse("voiceActivated"),
        )
        assertNull(AudioTransmissionMode.parse(""))
        assertNull(AudioTransmissionMode.parse("voice-activated"))
        assertNull(AudioTransmissionMode.parse("VOICE_ACTIVATED"))
    }

    @Test
    fun `only the exact current winner owns transmission controls`() {
        assertTrue(ownsAudioTransmissionCall("call-a", "call-a", "call-a"))
        assertFalse(ownsAudioTransmissionCall("", "", ""))
        assertFalse(ownsAudioTransmissionCall("call-a", "call-b", "call-a"))
        assertFalse(ownsAudioTransmissionCall("call-a", "call-a", "call-b"))
        assertFalse(ownsAudioTransmissionCall("call-a", null, null))
    }
}
