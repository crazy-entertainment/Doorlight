package app.sybl.sybl

import java.io.ByteArrayOutputStream
import java.io.IOException
import org.junit.Assert.*
import org.junit.Test

class CameraPhotoPolicyTest {
    @Test fun rawAdmissionBoundsPixelsBeforeDecodeWithoutIntegerOverflow() {
        assertTrue(CameraPhotoPolicy.accepts(32L * 1024 * 1024, 8000, 4000))
        assertFalse(CameraPhotoPolicy.accepts(32L * 1024 * 1024 + 1, 1, 1))
        assertFalse(CameraPhotoPolicy.accepts(1, 8001, 4000))
        assertFalse(CameraPhotoPolicy.accepts(1, Int.MAX_VALUE, Int.MAX_VALUE))
        assertFalse(CameraPhotoPolicy.accepts(1, 0, 1))
        assertFalse(CameraPhotoPolicy.accepts(0, 1, 1))
    }

    @Test fun resizeKeepsAspectAndNeverUpscales() {
        assertEquals(2048 to 1024, CameraPhotoPolicy.outputSize(8000, 4000))
        assertEquals(1024 to 2048, CameraPhotoPolicy.outputSize(4000, 8000))
        assertEquals(640 to 480, CameraPhotoPolicy.outputSize(640, 480))
        assertEquals(1 to 2048, CameraPhotoPolicy.outputSize(1, 32_000_000))
        assertNull(CameraPhotoPolicy.outputSize(-1, 512))
        assertEquals(2, CameraPhotoPolicy.sampleSize(8000, 4000))
        assertEquals(0, CameraPhotoPolicy.sampleSize(Int.MAX_VALUE, Int.MAX_VALUE))
    }

    @Test fun outputRefusesTheFirstByteBeyondTheLimit() {
        val bytes = ByteArrayOutputStream()
        val stream = LimitedPhotoOutput(bytes, 4)
        stream.write(byteArrayOf(1, 2, 3), 0, 3)
        stream.write(4)
        try { stream.write(5); fail("limit was not enforced") } catch (_: IOException) { }
        try { stream.write(byteArrayOf(6, 7), 0, 2); fail("limit was not enforced") } catch (_: IOException) { }
        assertArrayEquals(byteArrayOf(1, 2, 3, 4), bytes.toByteArray())
    }
}
