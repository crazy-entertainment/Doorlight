package app.sybl.sybl

import android.Manifest
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import androidx.activity.result.ActivityResultLauncher
import androidx.activity.result.contract.ActivityResultContracts
import androidx.core.content.FileProvider
import androidx.lifecycle.Lifecycle
import io.flutter.embedding.android.FlutterFragmentActivity
import java.io.File
import java.util.UUID
import java.util.concurrent.ArrayBlockingQueue
import java.util.concurrent.ThreadPoolExecutor
import java.util.concurrent.TimeUnit

/** Each launch has its own registry key. Restored Android results cannot be
 * mistaken for a newly selected composer's request after Activity recreation. */
internal class MessagingCameraCapture(private val activity: FlutterFragmentActivity) {
    companion object {
        private val worker = ThreadPoolExecutor(1, 1, 0, TimeUnit.SECONDS,
            ArrayBlockingQueue(1), ThreadPoolExecutor.AbortPolicy())
        private val noncePattern = Regex("[0-9a-f]{32}")
    }
    private val preferences = activity.getSharedPreferences("sybl_camera_output", Context.MODE_PRIVATE)
    private val rawRoot = File(activity.filesDir, "camera-raw")
    private var pending: Request? = null
    private var closed = false
    private class Request(val nonce: String, val raw: File, val uri: Uri,
        val lease: MessagingCaptureLease, val reply: (String?) -> Unit) {
        var camera: ActivityResultLauncher<Uri>? = null
        var permission: ActivityResultLauncher<String>? = null
        var processing = false
    }

    init {
        // Process/Activity replacement has no retained Dart owner. Clean only
        // the one journaled camera output; never recover it into a new draft.
        preferences.getString("pending", null)?.takeIf(noncePattern::matches)?.let { nonce ->
            val raw = File(rawRoot, "$nonce.jpg")
            runCatching { revoke(FileProvider.getUriForFile(activity, "${activity.packageName}.fileprovider", raw)) }
            raw.delete()
        }
        preferences.edit().remove("pending").commit()
    }

    fun capture(expectedAccountId: String, reply: (String?) -> Unit) {
        if (closed || pending != null ||
            !activity.lifecycle.currentState.isAtLeast(Lifecycle.State.RESUMED)) {
            reply(null); return
        }
        val lease = JamiCore.beginMessagingCapture(expectedAccountId)
        if (lease == null) { reply(null); return }
        if (!JamiCore.ownsMessagingCapture(lease)) {
            JamiCore.retireMessagingCapture(lease); reply(null); return
        }
        var request: Request? = null
        try {
            if (!rawRoot.isDirectory && !rawRoot.mkdirs()) throw IllegalStateException()
            val nonce = UUID.randomUUID().toString().replace("-", "")
            val raw = File(rawRoot, "$nonce.jpg")
            val uri = FileProvider.getUriForFile(activity, "${activity.packageName}.fileprovider", raw)
            if (!raw.createNewFile()) throw IllegalStateException()
            val owned = Request(nonce, raw, uri, lease, reply)
            request = owned
            pending = owned
            if (!preferences.edit().putString("pending", nonce).commit()) throw IllegalStateException()
            owned.camera = activity.activityResultRegistry.register("sybl-photo-$nonce",
                object : ActivityResultContracts.TakePicture() {
                    override fun createIntent(context: Context, input: Uri): Intent =
                        super.createIntent(context, input).apply {
                            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION)
                            clipData = ClipData.newRawUri("Photo output", input)
                        }
                }) { accepted -> received(owned, accepted) }
            owned.permission = activity.activityResultRegistry.register("sybl-photo-permission-$nonce",
                ActivityResultContracts.RequestPermission()) { granted ->
                if (granted && current(owned)) launch(owned) else finish(owned, null)
            }
            if (activity.checkSelfPermission(Manifest.permission.CAMERA) == PackageManager.PERMISSION_GRANTED) {
                launch(owned)
            } else owned.permission?.launch(Manifest.permission.CAMERA)
        } catch (_: Exception) {
            if (request != null) finish(request, null)
            else { JamiCore.retireMessagingCapture(lease); reply(null) }
        }
    }

    private fun current(request: Request) = !closed && pending === request &&
        JamiCore.ownsMessagingCapture(request.lease)

    private fun launch(request: Request) {
        if (!current(request)) { finish(request, null); return }
        try { request.camera?.launch(request.uri) }
        catch (_: Exception) { finish(request, null) }
    }

    private fun received(request: Request, accepted: Boolean) {
        if (request.processing) return
        revoke(request.uri)
        if (!accepted || !current(request)) { finish(request, null); return }
        request.processing = true
        try {
            worker.execute {
                val output = if (JamiCore.ownsMessagingCapture(request.lease))
                    CameraPhotoProcessor.prepare(request.raw, File(activity.filesDir, "outgoing")) else null
                activity.runOnUiThread {
                    if (current(request)) finish(request, output?.absolutePath)
                    else {
                        output?.let { deleteOwnedPickerStagingFile(File(activity.filesDir, "outgoing"), it) }
                        finish(request, null)
                    }
                }
            }
        } catch (_: Exception) { finish(request, null) }
    }

    private fun revoke(uri: Uri) {
        runCatching { activity.revokeUriPermission(uri,
            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION) }
    }

    private fun finish(request: Request, path: String?) {
        revoke(request.uri)
        request.raw.delete()
        request.camera?.unregister()
        request.permission?.unregister()
        JamiCore.retireMessagingCapture(request.lease)
        if (pending !== request) return
        pending = null
        if (preferences.getString("pending", null) == request.nonce) {
            preferences.edit().remove("pending").commit()
        }
        request.reply(path)
    }

    fun close() {
        closed = true
        pending?.let { finish(it, null) }
    }
}
