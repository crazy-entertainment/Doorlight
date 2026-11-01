package app.sybl.sybl

import java.util.concurrent.atomic.AtomicLong

internal object DirectorCallbackFailures {
    private val total = AtomicLong()

    fun record(@Suppress("UNUSED_PARAMETER") failure: Throwable) {
        total.updateAndGet { if (it == Long.MAX_VALUE) it else it + 1 }
    }

    fun count(): Long = total.get()
}

internal inline fun guardDirectorCallback(
    onFailure: (Throwable) -> Unit = DirectorCallbackFailures::record,
    block: () -> Unit,
) {
    try {
        block()
    } catch (failure: Throwable) {
        try {
            onFailure(failure)
        } catch (_: Throwable) {
            // Nothing may escape a SWIG director back across JNI.
        }
    }
}

internal inline fun guardDirectorFillCallback(
    clear: () -> Unit,
    onFailure: (Throwable) -> Unit = DirectorCallbackFailures::record,
    block: () -> Unit,
) {
    try {
        clear()
        block()
    } catch (failure: Throwable) {
        try {
            clear()
        } catch (_: Throwable) {
            // The original callback failure still must not cross JNI.
        }
        try {
            onFailure(failure)
        } catch (_: Throwable) {
            // Diagnostic failure must not cross JNI either.
        }
    }
}
