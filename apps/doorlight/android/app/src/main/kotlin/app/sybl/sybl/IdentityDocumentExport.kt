package app.sybl.sybl

import java.io.InputStream
import java.io.OutputStream

internal enum class IdentityDocumentExportResult { SAVED, CLEANED, RESIDUE }

/** A failed close is a failed export too. Never report cleanup without evidence. */
internal object IdentityDocumentExport {
    fun copy(
        input: () -> InputStream,
        output: () -> OutputStream?,
        delete: () -> Boolean,
        truncate: () -> Boolean,
        current: () -> Boolean = { true },
    ): IdentityDocumentExportResult {
        try {
            input().use { source ->
                val destination = output() ?: throw java.io.IOException("No destination stream")
                destination.use { source.copyTo(it) }
            }
            return if (current()) IdentityDocumentExportResult.SAVED else cleanup(delete, truncate)
        } catch (_: Exception) {
            return cleanup(delete, truncate)
        }
    }

    fun cleanup(delete: () -> Boolean, truncate: () -> Boolean): IdentityDocumentExportResult {
        if (try { delete() } catch (_: Exception) { false }) return IdentityDocumentExportResult.CLEANED
        if (try { truncate() } catch (_: Exception) { false }) return IdentityDocumentExportResult.CLEANED
        return IdentityDocumentExportResult.RESIDUE
    }
}
