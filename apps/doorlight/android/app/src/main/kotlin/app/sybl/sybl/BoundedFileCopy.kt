package app.sybl.sybl

import java.io.File
import java.io.InputStream

/** Copies an untrusted stream without ever retaining an incomplete destination. */
internal fun copyBoundedToFile(
    input: InputStream,
    destination: File,
    maxBytes: Long,
): Boolean {
    require(maxBytes >= 0)
    var complete = false
    try {
        destination.outputStream().buffered().use { output ->
            val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
            var total = 0L
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                if (read == 0) {
                    val byte = input.read()
                    if (byte < 0) break
                    if (total == maxBytes) return false
                    output.write(byte)
                    total++
                } else {
                    if (read.toLong() > maxBytes - total) return false
                    output.write(buffer, 0, read)
                    total += read
                }
            }
        }
        complete = true
        return true
    } finally {
        if (!complete) destination.delete()
    }
}
