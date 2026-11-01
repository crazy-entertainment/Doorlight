package app.sybl.sybl

import java.io.ByteArrayInputStream
import java.io.File
import java.io.IOException
import java.io.InputStream
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Test

class BoundedFileCopyTest {
    @Test
    fun `actual bytes over the bound delete the partial destination`() {
        val destination = tempDestination()

        assertFalse(copyBoundedToFile(ByteArrayInputStream(ByteArray(9)), destination, 8))
        assertFalse(destination.exists())
    }

    @Test
    fun `mid-stream failure deletes the partial destination`() {
        val destination = tempDestination()
        val failing = object : InputStream() {
            private var first = true

            override fun read(): Int = throw IOException("unexpected scalar read")

            override fun read(buffer: ByteArray, offset: Int, length: Int): Int {
                if (!first) throw IOException("provider failed")
                first = false
                repeat(4) { buffer[offset + it] = it.toByte() }
                return 4
            }
        }

        assertThrows(IOException::class.java) {
            copyBoundedToFile(failing, destination, 8)
        }
        assertFalse(destination.exists())
    }

    private fun tempDestination() = File.createTempFile("sybl-bounded-copy", ".tmp").apply {
        delete()
        deleteOnExit()
    }
}
