package app.sybl.sybl

import java.io.File
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.util.UUID

/** Private, generated destinations; sender filenames never participate. */
internal fun reserveReceivedMediaFile(root: File, gif: Boolean): File {
    val base = root.toPath().toAbsolutePath().normalize()
    Files.createDirectories(base)
    require(Files.isDirectory(base, NOFOLLOW_LINKS))
    val directory = Files.createDirectory(base.resolve("received-" + UUID.randomUUID().toString().replace("-", "")))
    // Reserve the private directory, not a placeholder file. Native finalization
    // publishes without replacing an existing destination.
    return directory.resolve(if (gif) "media.gif" else "voice.m4a").toFile()
}

internal fun isPrivateReceivedMediaFile(root: File, file: File): Boolean = try {
    val base = root.toPath().toAbsolutePath().normalize()
    val path = file.toPath().toAbsolutePath().normalize()
    val parent = path.parent
    parent != null && parent.parent == base &&
        Regex("received-[0-9a-f]{32}").matches(parent.fileName.toString()) &&
        path.fileName.toString() in setOf("media.gif", "voice.m4a") &&
        Files.isDirectory(base, NOFOLLOW_LINKS) && Files.isDirectory(parent, NOFOLLOW_LINKS) &&
        Files.isRegularFile(path, NOFOLLOW_LINKS)
} catch (_: Throwable) { false }
