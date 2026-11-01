package app.sybl.sybl

import java.util.ArrayDeque
import java.util.LinkedHashMap
import java.util.concurrent.Executor
import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

/** Fixed labels only: diagnostic output must never inherit a MethodChannel name, peer value, or payload. */
internal enum class DaemonOperation(val stallAfterMs: Long = 5_000L) {
    BOOT(30_000L),
    REVIVE,
    GOODBYE,
    ENSURE_ACCOUNT(15_000L),
    READ_IDENTITY,
    READ_PEER,
    READ_DEVICES,
    REVOKE_DEVICE,
    PAIR_DEVICE(120_000L),
    UPDATE_PROFILE,
    GROUP_MUTATION,
    PLACE_CALL,
    ANSWER_CALL,
    HANG_UP,
    REFUSE_CALL,
    SEND_CALL_MESSAGE,
    SEND_CALL_REQUEST,
    SEND_CHAT_MESSAGE,
    SUBSCRIBE_PRESENCE,
    PROBE_PRESENCE,
    SEND_COMPOSER_ACTIVITY,
    SEND_FILE_THUMBNAIL,
    SEND_FILE_DECISION,
    SEND_HOLOGRAM_CONTROL,
    CONNECTIVITY_SWEEP(15_000L),
    SET_MIC_MUTED,
    SET_AUDIO_TRANSMISSION_MODE,
    SET_AUDIO_METER,
    SET_APPEAR_OFFLINE,
    SET_CONNECTION_PROFILE(15_000L),
    SET_BACKGROUND_WAKE,
    START_VIDEO,
    STOP_VIDEO,
    SWITCH_CAMERA,
    DISABLE_VIDEO,
    QUERY_CAMERA_ADOPTION,
    SEND_FILE(30_000L),
    ACCEPT_FILE,
    CANCEL_FILE,
    FILE_INFO,
    LOAD_FOLDER(30_000L),
    LOAD_CHAT(30_000L),
    ACCEPT_CONNECT,
    DECLINE_CONNECT,
    REPLAY_CONNECT_REQUESTS,
    REMOVE_CONTACT,
    EXPORT_IDENTITY(120_000L),
    RESTORE_IDENTITY(120_000L),
    DISMISS_FROM_RECENTS,
    SEND_PONG,
    FILE_PROGRESS,
    FOLDER_UPDATE,
    CONVERSATION_READY,
    ANSWER_MEDIA_CHANGE,
    RETIRE_SIBLING,
    RETIRE_STALE_CURRENT,
    REAPPLY_MUTE,
    MEDIA_NEGOTIATED,
    CALLBACK_REFUSE,
    GENERIC(30_000L),
}

internal enum class DiagnosticPhase { QUEUED, RUNNING }

internal data class DiagnosticStall(
    val lane: String,
    val sequence: Long,
    val operation: String,
    val callToken: String?,
    val phase: DiagnosticPhase,
    val elapsedMs: Long,
    val thread: Thread?,
)

private data class MutableDiagnosticTask(
    val sequence: Long,
    val operation: String,
    val callToken: String?,
    val stallAfterMs: Long,
    val queuedAtMs: Long,
    var startedAtMs: Long? = null,
    var thread: Thread? = null,
    var queuedStallReported: Boolean = false,
    var runningStallReported: Boolean = false,
)

/**
 * Pure bookkeeping for a serialized lane. It owns no timers and never interrupts work; a separate observer calls
 * [pollStalls]. All strings passed here must already be fixed labels or process-local opaque tokens.
 */
internal class DiagnosticTaskTracker(
    private val lane: String,
    private val recentLimit: Int = 64,
    private val sink: (String) -> Unit = {},
) {
    private val lock = Any()
    private val nextSequence = AtomicLong(0L)
    private val tasks = LinkedHashMap<Long, MutableDiagnosticTask>()
    private val recent = ArrayDeque<String>()

    fun queued(
        operation: String,
        callToken: String?,
        stallAfterMs: Long,
        nowMs: Long,
        thread: Thread? = null,
    ): Long {
        val sequence = nextSequence.incrementAndGet()
        val line: String
        synchronized(lock) {
            tasks[sequence] = MutableDiagnosticTask(
                sequence, operation, callToken, stallAfterMs, nowMs, thread = thread,
            )
            line = "QUEUE lane=$lane seq=$sequence op=$operation${tokenPart(callToken)} depth=${tasks.size}"
            rememberLocked(line)
        }
        sink(line)
        return sequence
    }

    fun started(sequence: Long, nowMs: Long, thread: Thread = Thread.currentThread()) {
        val line: String
        synchronized(lock) {
            val task = tasks[sequence] ?: return
            task.startedAtMs = nowMs
            task.thread = thread
            line = "START lane=$lane seq=$sequence op=${task.operation}${tokenPart(task.callToken)} " +
                "waitMs=${nonNegative(nowMs - task.queuedAtMs)}"
            rememberLocked(line)
        }
        sink(line)
    }

    fun finished(sequence: Long, nowMs: Long, failure: Throwable? = null) {
        val line: String
        synchronized(lock) {
            val task = tasks.remove(sequence) ?: return
            val startedAt = task.startedAtMs ?: nowMs
            val outcome = failure?.javaClass?.simpleName?.take(48) ?: "ok"
            line = "FINISH lane=$lane seq=$sequence op=${task.operation}${tokenPart(task.callToken)} " +
                "runMs=${nonNegative(nowMs - startedAt)} outcome=$outcome depth=${tasks.size}"
            rememberLocked(line)
        }
        sink(line)
    }

    fun pollStalls(nowMs: Long): List<DiagnosticStall> = synchronized(lock) {
        val out = ArrayList<DiagnosticStall>()
        for (task in tasks.values) {
            val startedAt = task.startedAtMs
            if (startedAt == null) {
                val elapsed = nonNegative(nowMs - task.queuedAtMs)
                if (!task.queuedStallReported && elapsed >= task.stallAfterMs) {
                    task.queuedStallReported = true
                    out += task.toStall(DiagnosticPhase.QUEUED, elapsed)
                }
            } else {
                val elapsed = nonNegative(nowMs - startedAt)
                if (!task.runningStallReported && elapsed >= task.stallAfterMs) {
                    task.runningStallReported = true
                    out += task.toStall(DiagnosticPhase.RUNNING, elapsed)
                }
            }
        }
        out
    }

    fun pendingSummary(limit: Int = 12): String = synchronized(lock) {
        if (tasks.isEmpty()) return@synchronized "none"
        tasks.values.take(limit).joinToString(",") { task ->
            "${task.sequence}:${task.operation}${task.callToken?.let { ":$it" } ?: ""}:" +
                if (task.startedAtMs == null) "Q" else "R"
        }
    }

    fun recentEvents(): List<String> = synchronized(lock) { recent.toList() }

    private fun MutableDiagnosticTask.toStall(phase: DiagnosticPhase, elapsedMs: Long) = DiagnosticStall(
        lane, sequence, operation, callToken, phase, elapsedMs, thread,
    )

    private fun rememberLocked(line: String) {
        while (recent.size >= recentLimit) recent.removeFirst()
        recent.addLast(line)
    }

    private fun tokenPart(token: String?): String = token?.let { " call=$it" } ?: ""
    private fun nonNegative(value: Long): Long = value.coerceAtLeast(0L)
}

/** Maintains only opaque, process-local correlation labels and bounds retained daemon call identifiers. */
internal class DiagnosticCallTokens(private val limit: Int = 128) {
    private val lock = Any()
    private val next = AtomicLong(0L)
    private val tokens = object : LinkedHashMap<String, String>(16, 0.75f, true) {
        override fun removeEldestEntry(eldest: MutableMap.MutableEntry<String, String>?): Boolean = size > limit
    }

    fun token(callId: String?): String? {
        if (callId.isNullOrEmpty()) return null
        return synchronized(lock) { tokens.getOrPut(callId) { "c${next.incrementAndGet()}" } }
    }
}

/** Serial execution is unchanged; this wrapper only brackets enabled tasks in [DiagnosticTaskTracker]. */
internal class ObservedSerialExecutor(
    private val delegate: Executor,
    private val tracker: DiagnosticTaskTracker,
    private val enabled: () -> Boolean,
    private val nowMs: () -> Long,
) {
    private val workerThread = AtomicReference<Thread?>(null)

    fun execute(operation: DaemonOperation, callToken: String? = null, block: () -> Unit) {
        if (!enabled()) {
            delegate.execute(block)
            return
        }
        val sequence = tracker.queued(operation.name, callToken, operation.stallAfterMs, nowMs())
        try {
            delegate.execute {
                val thread = Thread.currentThread()
                workerThread.set(thread)
                tracker.started(sequence, nowMs(), thread)
                var failure: Throwable? = null
                try {
                    block()
                } catch (t: Throwable) {
                    failure = t
                    throw t
                } finally {
                    tracker.finished(sequence, nowMs(), failure)
                }
            }
        } catch (t: Throwable) {
            tracker.finished(sequence, nowMs(), t)
            throw t
        }
    }

    fun thread(): Thread? = workerThread.get()
}
