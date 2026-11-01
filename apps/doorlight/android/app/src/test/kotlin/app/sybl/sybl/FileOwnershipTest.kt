package app.sybl.sybl

import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FileOwnershipTest {
    @Test fun rejectsSymlinkLeavesAndStageDirectories() {
        val base = Files.createTempDirectory("sybl-picker-symlink-test").toFile()
        try {
            val root = File(base, "outgoing").apply { mkdirs() }
            val real = Files.createTempDirectory(root.toPath(), "picked-").toFile()
            val file = File(real, "voice.m4a").apply { writeText("retain") }
            val link = File(real, "link.m4a")
            try { Files.createSymbolicLink(link.toPath(), file.toPath()) }
            catch (error: java.nio.file.FileSystemException) {
                org.junit.Assume.assumeNoException("Host lacks symlink privilege", error)
            }
            assertFalse(isOwnedPickerStagingFile(root, link))
            assertFalse(deleteOwnedPickerStagingFile(root, link))
            val directoryLink = File(root, "picked-link")
            Files.createSymbolicLink(directoryLink.toPath(), real.toPath())
            assertFalse(isOwnedPickerStagingFile(root, File(directoryLink, file.name)))
            assertFalse(deleteOwnedPickerStagingFile(root, File(directoryLink, file.name)))
            assertTrue(file.exists())
            Files.delete(directoryLink.toPath())
            Files.delete(link.toPath())
        } finally { base.deleteRecursively() }
    }
    @Test
    fun acceptsOnlyExactDirectChildren() {
        val base = Files.createTempDirectory("sybl-owned-file-test").toFile()
        try {
            val root = File(base, "outgoing").apply { mkdirs() }

            assertTrue(isOwnedDirectChild(root, File(root, "offer.txt")))
            assertFalse(isOwnedDirectChild(root, File(root, "nested/offer.txt")))
            assertFalse(isOwnedDirectChild(root, File(base, "outgoing-sibling/offer.txt")))
        } finally {
            base.deleteRecursively()
        }
    }

    @Test
    fun validatesAndDeletesOnlyGeneratedPickerChildren() {
        val base = Files.createTempDirectory("sybl-picker-owner-test").toFile()
        try {
            val root = File(base, "outgoing").apply { mkdirs() }
            val stage = Files.createTempDirectory(root.toPath(), "picked-").toFile()
            val picked = File(stage, "offer.txt").apply { writeText("payload") }
            val direct = File(root, "direct.txt").apply { writeText("keep") }
            val sibling = File(base, "picked-sibling/offer.txt")

            assertTrue(isOwnedPickerStagingFile(root, picked))
            assertFalse(isOwnedPickerStagingFile(root, direct))
            assertFalse(isOwnedPickerStagingFile(root, sibling))
            assertFalse(deleteOwnedPickerStagingFile(root, direct))
            assertTrue(direct.exists())
            assertTrue(deleteOwnedPickerStagingFile(root, picked))
            assertFalse(picked.exists())
            assertFalse(stage.exists())
        } finally {
            base.deleteRecursively()
        }
    }
}
