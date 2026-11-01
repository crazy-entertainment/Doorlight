package app.sybl.sybl

/** One recent deliberate wave, independent of the regularly refreshed presence frame. */
internal class NearbyRadioAnnouncements {
    var latest = byteArrayOf()
        private set
    private var ping = byteArrayOf()
    private var expires = 0L
    private val readers = linkedSetOf<String>()

    fun put(frame: ByteArray, deliberate: Boolean, now: Long) {
        require(NearbyRadioFrame.valid(frame))
        if (!deliberate) latest = frame
        if (deliberate) {
            ping = frame
            expires = now + 30_000
            readers.clear()
        }
    }

    fun read(client: String, now: Long): ByteArray {
        expire(now)
        return if (ping.isNotEmpty() && client !in readers && readers.size < 64) ping else latest
    }

    // Call only after the last ATT chunk (or a Google payload) was accepted.
    fun served(client: String, frame: ByteArray, now: Long) {
        expire(now)
        if (ping.isNotEmpty() && frame.contentEquals(ping) && readers.size < 64) readers.add(client)
    }

    fun servedRead(client: String, frame: ByteArray, offset: Int, mtu: Int, accepted: Boolean, now: Long) {
        if (accepted && offset in 0..frame.size && frame.size - offset <= mtu.coerceIn(23, 517) - 1) {
            served(client, frame, now)
        }
    }

    fun deadline(frame: ByteArray): Long = if (ping.isNotEmpty() && frame.contentEquals(ping)) expires else Long.MAX_VALUE

    fun clear() {
        latest = byteArrayOf()
        ping = byteArrayOf()
        readers.clear()
        expires = 0
    }

    private fun expire(now: Long) {
        if (now >= expires) {
            ping = byteArrayOf()
            readers.clear()
        }
    }
}
