package app.sybl.sybl

internal enum class DeviceRevocationStatus(val wireName: String) {
    REVOKED("revoked"),
    CREDENTIALS("credentials"),
    NETWORK("network"),
    TIMEOUT("timeout"),
    PENDING("pending"),
    REFUSED("refused"),
    ACCOUNT_CHANGED("account-changed"),
    UNAVAILABLE("unavailable"),
}

internal data class DeviceRevocationResult(
    val accountId: String,
    val deviceId: String,
    val status: DeviceRevocationStatus,
) {
    fun toWire(): Map<String, String> = mapOf(
        "accountId" to accountId,
        "deviceId" to deviceId,
        "status" to status.wireName,
    )
}

/** DeviceRevocationEnded has no operation id. An issued request with an unknown
 * result keeps its exact account/device slot until the old callback is consumed.
 * Activity disposal retires its reply, not this process-lifetime callback guard. */
internal class DeviceRevocationRegistry {
    companion object {
        const val TIMEOUT_MS = 30_000L
    }

    data class Admission(
        val ticket: Long = 0,
        val status: DeviceRevocationStatus = DeviceRevocationStatus.UNAVAILABLE,
    )

    data class Completion(
        val result: DeviceRevocationResult,
        val reply: ((DeviceRevocationResult) -> Unit)?,
    )

    private data class Entry(
        val ticket: Long,
        val deadline: Long,
        var replyOwner: Any?,
        var reply: ((DeviceRevocationResult) -> Unit)?,
        var issued: Boolean = false,
        var terminal: Boolean = false,
        var delivered: Boolean = false,
        var outcome: DeviceRevocationStatus? = null,
    )

    private var selectedAccount: String? = null
    private var nextTicket = 0L
    private val entries = linkedMapOf<Pair<String, String>, Entry>()

    @Synchronized
    fun selectAccount(accountId: String?) {
        if (selectedAccount == accountId) return
        selectedAccount = accountId
        for (entry in entries.values) {
            if (entry.outcome == null) entry.outcome = DeviceRevocationStatus.ACCOUNT_CHANGED
        }
    }

    @Synchronized
    fun begin(
        accountId: String,
        deviceId: String,
        nowMs: Long,
        replyOwner: Any,
        reply: (DeviceRevocationResult) -> Unit,
    ): Admission {
        if (accountId.isEmpty() || accountId != selectedAccount) {
            return Admission(status = DeviceRevocationStatus.ACCOUNT_CHANGED)
        }
        if (!KnownDeviceWire.isDeviceId(deviceId)) {
            return Admission(status = DeviceRevocationStatus.REFUSED)
        }
        if (entries.size >= KnownDeviceWire.MAX_DEVICES || entries.containsKey(accountId to deviceId)) {
            return Admission(status = DeviceRevocationStatus.PENDING)
        }
        if (nowMs < 0 || nowMs > Long.MAX_VALUE - TIMEOUT_MS || nextTicket == Long.MAX_VALUE) {
            return Admission()
        }
        val ticket = ++nextTicket
        entries[accountId to deviceId] = Entry(ticket, nowMs + TIMEOUT_MS, replyOwner, reply)
        return Admission(ticket, DeviceRevocationStatus.PENDING)
    }

    @Synchronized
    fun pending(ticket: Long): Boolean = entries.values.any {
        it.ticket == ticket && it.outcome == null
    }

    @Synchronized
    fun hasPendingReplies(): Boolean = entries.values.any { !it.delivered }

    @Synchronized
    fun refuse(ticket: Long, status: DeviceRevocationStatus) {
        entries.values.firstOrNull { it.ticket == ticket }?.let {
            if (!it.issued && it.outcome == null) it.outcome = status
        }
    }

    fun invoke(ticket: Long, nowMs: Long, request: () -> Boolean) {
        synchronized(this) {
            val entry = entries.values.firstOrNull { it.ticket == ticket } ?: return
            if (entry.outcome != null || entry.issued) return
            if (nowMs >= entry.deadline) {
                entry.outcome = DeviceRevocationStatus.TIMEOUT
                return
            }
            entry.issued = true
        }
        try {
            // ArchiveAccountManager can return false after scheduling work.
            // Neither Boolean value is an authoritative completion or refusal.
            request()
        } catch (_: Throwable) {
            synchronized(this) {
                entries.values.firstOrNull { it.ticket == ticket }?.let {
                    if (it.outcome == null) it.outcome = DeviceRevocationStatus.UNAVAILABLE
                }
            }
        }
    }

    @Synchronized
    fun ended(accountId: String, deviceId: String, status: Int, nowMs: Long) {
        val entry = entries[accountId to deviceId] ?: return
        if (!entry.issued || entry.terminal) return
        entry.terminal = true
        if (entry.outcome == null) {
            entry.outcome = when {
                nowMs >= entry.deadline -> DeviceRevocationStatus.TIMEOUT
                status == 0 -> DeviceRevocationStatus.REVOKED
                status == 1 -> DeviceRevocationStatus.CREDENTIALS
                status == 2 -> DeviceRevocationStatus.NETWORK
                else -> DeviceRevocationStatus.UNAVAILABLE
            }
        }
    }

    @Synchronized
    fun cancelOwner(replyOwner: Any) {
        for (entry in entries.values) {
            if (entry.replyOwner === replyOwner && entry.outcome == null) {
                entry.outcome = DeviceRevocationStatus.UNAVAILABLE
            }
        }
    }

    @Synchronized
    fun failPending() {
        for (entry in entries.values) {
            if (entry.outcome == null) entry.outcome = DeviceRevocationStatus.UNAVAILABLE
        }
    }

    /** Callers deliver these replies outside the registry lock on the main thread. */
    @Synchronized
    fun takeReady(nowMs: Long): List<Completion> {
        val ready = ArrayList<Completion>(entries.size)
        val iterator = entries.iterator()
        while (iterator.hasNext()) {
            val (key, entry) = iterator.next()
            if (entry.outcome == null && nowMs >= entry.deadline) {
                entry.outcome = DeviceRevocationStatus.TIMEOUT
            }
            entry.outcome?.let { status ->
                if (!entry.delivered) {
                    ready += Completion(DeviceRevocationResult(key.first, key.second, status), entry.reply)
                    entry.reply = null
                    entry.replyOwner = null
                    entry.delivered = true
                }
            }
            if (entry.delivered && (!entry.issued || entry.terminal)) iterator.remove()
        }
        return ready
    }
}
