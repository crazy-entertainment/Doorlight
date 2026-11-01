package app.sybl.sybl

import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.media.ExifInterface
import java.io.ByteArrayInputStream
import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.io.OutputStream
import java.nio.file.Files
import java.nio.file.LinkOption

internal object CameraPhotoPolicy {
    const val MAX_RAW_BYTES = 32L * 1024 * 1024
    const val MAX_PIXELS = 32_000_000L
    const val MAX_EDGE = 2048
    const val MAX_JPEG_BYTES = 4L * 1024 * 1024

    fun accepts(bytes: Long, width: Int, height: Int): Boolean =
        bytes in 1..MAX_RAW_BYTES && width > 0 && height > 0 &&
            width.toLong() * height <= MAX_PIXELS

    fun outputSize(width: Int, height: Int): Pair<Int, Int>? {
        if (!accepts(1, width, height)) return null
        val edge = maxOf(width, height)
        if (edge <= MAX_EDGE) return width to height
        return maxOf(1, (width.toLong() * MAX_EDGE / edge).toInt()) to
            maxOf(1, (height.toLong() * MAX_EDGE / edge).toInt())
    }

    fun sampleSize(width: Int, height: Int): Int {
        if (!accepts(1, width, height)) return 0
        var sample = 1
        while (maxOf(width, height) / (sample * 2) >= MAX_EDGE) sample *= 2
        return sample
    }
}

/** Runs on a worker. The camera's writable output is snapshotted before header
 * inspection; only newly compressed pixels reach the outgoing JPEG. */
internal object CameraPhotoProcessor {
    fun prepare(raw: File, outgoingRoot: File): File? {
        var decoded: Bitmap? = null
        var oriented: Bitmap? = null
        var scaled: Bitmap? = null
        var stage: File? = null
        var output: File? = null
        var complete = false
        try {
            if (!Files.isRegularFile(raw.toPath(), LinkOption.NOFOLLOW_LINKS)) return null
            val length = Files.size(raw.toPath())
            if (length !in 1..CameraPhotoPolicy.MAX_RAW_BYTES) return null
            // Read no more than the admitted length even if the camera retains
            // a writable descriptor after its URI permission is revoked.
            val bytes = ByteArray(length.toInt())
            Files.newInputStream(raw.toPath(), LinkOption.NOFOLLOW_LINKS).use { input ->
                var offset = 0
                while (offset < bytes.size) {
                    val count = input.read(bytes, offset, bytes.size - offset)
                    if (count <= 0) return null
                    offset += count
                }
                if (input.read() != -1) return null
            }
            val bounds = BitmapFactory.Options().apply { inJustDecodeBounds = true }
            BitmapFactory.decodeByteArray(bytes, 0, bytes.size, bounds)
            if (!CameraPhotoPolicy.accepts(length, bounds.outWidth, bounds.outHeight)) return null
            val orientation = ByteArrayInputStream(bytes).use {
                ExifInterface(it).getAttributeInt(ExifInterface.TAG_ORIENTATION, ExifInterface.ORIENTATION_NORMAL)
            }
            if (orientation !in ExifInterface.ORIENTATION_UNDEFINED..ExifInterface.ORIENTATION_ROTATE_270) return null
            val options = BitmapFactory.Options().apply {
                inSampleSize = CameraPhotoPolicy.sampleSize(bounds.outWidth, bounds.outHeight)
                inPreferredConfig = Bitmap.Config.ARGB_8888
            }
            decoded = BitmapFactory.decodeByteArray(bytes, 0, bytes.size, options) ?: return null
            val matrix = Matrix().apply {
                when (orientation) {
                    ExifInterface.ORIENTATION_FLIP_HORIZONTAL -> setScale(-1f, 1f)
                    ExifInterface.ORIENTATION_ROTATE_180 -> setRotate(180f)
                    ExifInterface.ORIENTATION_FLIP_VERTICAL -> setScale(1f, -1f)
                    ExifInterface.ORIENTATION_TRANSPOSE -> { setRotate(90f); postScale(-1f, 1f) }
                    ExifInterface.ORIENTATION_ROTATE_90 -> setRotate(90f)
                    ExifInterface.ORIENTATION_TRANSVERSE -> { setRotate(-90f); postScale(-1f, 1f) }
                    ExifInterface.ORIENTATION_ROTATE_270 -> setRotate(-90f)
                }
            }
            oriented = Bitmap.createBitmap(decoded, 0, 0, decoded.width, decoded.height, matrix, true)
            val size = CameraPhotoPolicy.outputSize(oriented.width, oriented.height) ?: return null
            scaled = Bitmap.createScaledBitmap(oriented, size.first, size.second, true)
            if (!outgoingRoot.isDirectory && !outgoingRoot.mkdirs()) return null
            if (Files.isSymbolicLink(outgoingRoot.toPath())) return null
            stage = Files.createTempDirectory(outgoingRoot.toPath(), "picked-").toFile()
            output = File(stage, "photo.jpg")
            // Bitmap.compress writes a new JPEG without copying EXIF/location.
            // Fixed attempts bound CPU, and the stream bounds each output write.
            for (quality in intArrayOf(85, 70, 55)) {
                val encoded = try {
                    FileOutputStream(output).use { file ->
                        val bounded = LimitedPhotoOutput(file, CameraPhotoPolicy.MAX_JPEG_BYTES)
                        scaled.compress(Bitmap.CompressFormat.JPEG, quality, bounded).also { file.fd.sync() }
                    }
                } catch (_: IOException) { false }
                if (encoded && output.length() in 1..CameraPhotoPolicy.MAX_JPEG_BYTES) {
                    complete = true
                    return output
                }
            }
            return null
        } catch (_: OutOfMemoryError) {
            return null
        } catch (_: Exception) {
            return null
        } finally {
            val images = listOfNotNull(scaled, oriented, decoded).distinct()
            images.forEach { it.recycle() }
            if (!complete) { output?.delete(); stage?.delete() }
        }
    }
}

internal class LimitedPhotoOutput(private val output: OutputStream, private val maximum: Long) : OutputStream() {
    private var written = 0L
    override fun write(value: Int) {
        if (written >= maximum) throw IOException("Photo limit")
        output.write(value)
        written++
    }
    override fun write(bytes: ByteArray, offset: Int, count: Int) {
        if (count < 0 || count.toLong() > maximum - written) throw IOException("Photo limit")
        output.write(bytes, offset, count)
        written += count
    }
}
