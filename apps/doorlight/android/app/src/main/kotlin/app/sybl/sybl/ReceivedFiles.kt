package app.sybl.sybl

import java.io.File
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS

/** Ordinary receives use internal storage, where atomic nonreplacement is supported. */
internal fun receivedFilesDirectory(filesDir: File): File {
    val root = File(filesDir, "received-files").toPath().toAbsolutePath().normalize()
    Files.createDirectories(root)
    require(Files.isDirectory(root, NOFOLLOW_LINKS))
    return root.toFile()
}

/** Keep old external receipts openable without exposing unrelated private files. */
internal fun openableReceivedFile(filesDir: File, externalFilesDir: File?, supplied: String): File? = try {
    val file = File(supplied).toPath().toAbsolutePath().normalize()
    val roots = listOfNotNull(
        File(filesDir, "received-files"),
        externalFilesDir?.let { File(it, "Syb-L Received") },
    )
    if (!Files.isRegularFile(file, NOFOLLOW_LINKS) || roots.none {
            val root = it.toPath().toAbsolutePath().normalize()
            file.parent == root && Files.isDirectory(root, NOFOLLOW_LINKS)
        }) null else file.toFile()
} catch (_: Throwable) { null }
