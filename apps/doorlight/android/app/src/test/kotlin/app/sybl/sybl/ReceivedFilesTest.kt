package app.sybl.sybl

import java.io.File
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

class ReceivedFilesTest {
    @Test fun privateReceivesAndLegacyReceiptsRemainOpenable() {
        val fixture = Files.createTempDirectory("received-files-test").toFile()
        try {
            val internal = File(fixture, "internal").apply { mkdirs() }
            val external = File(fixture, "external").apply { mkdirs() }
            val root = receivedFilesDirectory(internal)
            assertEquals(File(internal, "received-files"), root)
            val fresh = File(root, "report.txt").apply { writeText("verified") }
            val legacy = File(external, "Syb-L Received/report.txt").apply {
                parentFile.mkdirs(); writeText("old verified receipt")
            }
            assertEquals(fresh, openableReceivedFile(internal, null, fresh.path))
            assertEquals(legacy, openableReceivedFile(internal, external, legacy.path))
            assertNull(openableReceivedFile(internal, null, legacy.path))
            assertEquals("old verified receipt", legacy.readText())
        } finally { fixture.deleteRecursively() }
    }

    @Test fun onlyRegularDirectChildrenOfTheNarrowReceiveRootsAreExposed() {
        val fixture = Files.createTempDirectory("received-files-test").toFile()
        try {
            val internal = File(fixture, "internal").apply { mkdirs() }
            val root = receivedFilesDirectory(internal)
            val secret = File(internal, "identity.key").apply { writeText("private") }
            val nested = File(root, "nested/file.txt").apply { parentFile.mkdirs(); writeText("nested") }
            for (path in listOf(secret.path, File(root, "../identity.key").path,
                root.path, nested.path, File(root, "missing").path)) {
                assertNull(openableReceivedFile(internal, null, path))
            }
        } finally { fixture.deleteRecursively() }
    }
}
