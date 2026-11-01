package app.sybl.sybl

import java.nio.ByteBuffer

internal object NearbyRadioFrame {
    const val MAX_DATA = 508
    fun encode(sequence: Int, data: ByteArray): ByteArray {
        require(data.size in 1..MAX_DATA)
        return ByteBuffer.allocate(data.size + 4).putInt(sequence).put(data).array()
    }
    fun valid(frame: ByteArray) = frame.size in 5..512
}
