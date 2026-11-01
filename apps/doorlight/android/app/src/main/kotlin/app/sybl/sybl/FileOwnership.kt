package app.sybl.sybl

import java.io.File
import java.nio.file.Files
import java.nio.file.LinkOption

/** Whether [candidate] is an exact direct child owned by [root], with canonical paths blocking prefix/symlink escapes. */
internal fun isOwnedDirectChild(root: File, candidate: File): Boolean = try {
    candidate.canonicalFile.parentFile == root.canonicalFile
} catch (_: Throwable) {
    false
}

/** Whether [candidate] is the regular-file leaf of one generated picker directory directly below [root]. */
internal fun isOwnedPickerStagingFile(root: File, candidate: File): Boolean = try {
    val file = candidate.canonicalFile
    val directory = file.parentFile
    !Files.isSymbolicLink(candidate.toPath()) &&
        candidate.parentFile?.let { !Files.isSymbolicLink(it.toPath()) } == true &&
        Files.isRegularFile(candidate.toPath(), LinkOption.NOFOLLOW_LINKS) &&
        directory != null &&
        directory.name.startsWith("picked-") &&
        directory.parentFile == root.canonicalFile
} catch (_: Throwable) {
    false
}

/** Delete one validated picker file and its now-empty generated directory. */
internal fun deleteOwnedPickerStagingFile(root: File, candidate: File): Boolean = try {
    if (!isOwnedPickerStagingFile(root, candidate)) {
        false
    } else {
        val directory = candidate.canonicalFile.parentFile
        if (directory == null || (!candidate.delete() && candidate.exists())) {
            false
        } else {
            directory.delete() || !directory.exists()
        }
    }
} catch (_: Throwable) {
    false
}
