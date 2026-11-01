package app.sybl.sybl

import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

class ArchiveTemporarySnapshotTest {
    @Test fun snapshotRestoresSettingsBeforeReportingSuccess() {
        val calls = mutableListOf<String>()
        assertTrue(exportWithRestoredAccountDetails(mapOf("mode" to "original"), mapOf("mode" to "backup"),
            setDetails = { calls += it.getValue("mode") },
            export = { calls += "export"; true }))
        assertEquals(listOf("backup", "export", "original"), calls)
    }

    @Test fun settingsRestorationFailureCannotReportSuccessfulBackup() {
        assertFalse(exportWithRestoredAccountDetails(mapOf("mode" to "original"), mapOf("mode" to "backup"),
            setDetails = { if (it["mode"] == "original") throw IllegalStateException("restore failed") },
            export = { true }))
    }

    @Test fun uncertainTemporaryWriteStillAttemptsOriginalSettingsRestoration() {
        val calls = mutableListOf<String>()
        assertFalse(exportWithRestoredAccountDetails(mapOf("mode" to "original"), mapOf("mode" to "backup"),
            setDetails = {
                calls += it.getValue("mode")
                if (it["mode"] == "backup") throw IllegalStateException("write acknowledged uncertainly")
            },
            export = { fail("Must not export after a rejected settings write"); false }))
        assertEquals(listOf("backup", "original"), calls)
    }

    @Test fun exporterExceptionStillRestoresOriginalSettings() {
        val calls = mutableListOf<String>()
        assertFalse(exportWithRestoredAccountDetails(mapOf("mode" to "original"), mapOf("mode" to "backup"),
            setDetails = { calls += it.getValue("mode") },
            export = { throw IllegalStateException("export failed") }))
        assertEquals(listOf("backup", "original"), calls)
    }

    @Test fun overlappingActivityExportsKeepTheirOwnBytesAndCleanup() {
        val directory = Files.createTempDirectory("archive-overlap").toFile()
        try {
            val old = checkNotNull(exportTemporaryArchiveSnapshot(directory) {
                it.writeText("original protected snapshot"); true
            })
            val next = checkNotNull(exportTemporaryArchiveSnapshot(directory) {
                it.writeText("new explicitly unprotected snapshot"); true
            })
            assertNotEquals(old, next)
            assertEquals("original protected snapshot", old.readText())
            assertEquals("new explicitly unprotected snapshot", next.readText())
            assertTrue(old.delete())
            assertEquals("new explicitly unprotected snapshot", next.readText())
        } finally { directory.deleteRecursively() }
    }

    @Test fun failedReplacementCannotEraseAPreviousSuccessfulExport() {
        val directory = Files.createTempDirectory("archive-failure").toFile()
        try {
            val old = checkNotNull(exportTemporaryArchiveSnapshot(directory) {
                it.writeText("owned completed snapshot"); true
            })
            assertNull(exportTemporaryArchiveSnapshot(directory) {
                it.writeText("partial rejected snapshot"); false
            })
            assertEquals("owned completed snapshot", old.readText())
            assertEquals(listOf(old), directory.listFiles()!!.toList())
        } finally { directory.deleteRecursively() }
    }

    @Test fun throwingExportCleansOnlyItsOwnPartialSnapshot() {
        val directory = Files.createTempDirectory("archive-exception").toFile()
        try {
            val old = checkNotNull(exportTemporaryArchiveSnapshot(directory) {
                it.writeText("owned completed snapshot"); true
            })
            try {
                exportTemporaryArchiveSnapshot(directory) {
                    it.writeText("partial snapshot"); throw IllegalStateException("fixture export failed")
                }
                fail("Expected exporter failure")
            } catch (_: IllegalStateException) { }
            assertEquals("owned completed snapshot", old.readText())
            assertEquals(listOf(old), directory.listFiles()!!.toList())
        } finally { directory.deleteRecursively() }
    }
}
