package app.sybl.sybl

import android.app.Activity
import android.content.Context
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.os.Build
import android.view.Surface
import io.flutter.plugin.common.EventChannel
import kotlin.math.hypot

/**
 * Streams the device's downward pull and its own acceleration, both in current screen axes (x right,
 * y down, m/s²), for the `/gravity` easter egg. The sensors run only while Dart listens and the activity
 * is resumed.
 */
class GravitySensor(private val activity: Activity) : EventChannel.StreamHandler, SensorEventListener {
    private val sensors = activity.getSystemService(Context.SENSOR_SERVICE) as SensorManager
    private val gravity: Sensor? = sensors.getDefaultSensor(Sensor.TYPE_GRAVITY)
    private val sensor: Sensor? = gravity ?: sensors.getDefaultSensor(Sensor.TYPE_ACCELEROMETER)
    private val linear: Sensor? = gravity?.let { sensors.getDefaultSensor(Sensor.TYPE_LINEAR_ACCELERATION) }
    private val smooth = FloatArray(2)
    // The strongest device acceleration since the last sample sent, so a quick shake is not missed.
    private val peak = FloatArray(2)
    private var sink: EventChannel.EventSink? = null
    private var resumed = false
    private var registered = false

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        update()
    }

    override fun onCancel(arguments: Any?) {
        sink = null
        update()
    }

    fun setResumed(value: Boolean) {
        resumed = value
        update()
    }

    private fun update() {
        val want = sink != null && resumed && sensor != null
        if (want == registered) return
        registered = want
        if (want) {
            sensors.registerListener(this, sensor, SAMPLE_US)
            linear?.let { sensors.registerListener(this, it, SensorManager.SENSOR_DELAY_GAME) }
        } else {
            sensors.unregisterListener(this)
        }
        peak.fill(0f)
    }

    override fun onSensorChanged(event: SensorEvent) {
        val x = event.values[0]
        val y = event.values[1]
        if (event.sensor.type == Sensor.TYPE_LINEAR_ACCELERATION) {
            if (hypot(x, y) > hypot(peak[0], peak[1])) {
                peak[0] = x
                peak[1] = y
            }
            return
        }
        if (gravity == null) {
            // Raw accelerometer: low-pass away hand shake and motion; the rest is the shake.
            smooth[0] += LOW_PASS * (x - smooth[0])
            smooth[1] += LOW_PASS * (y - smooth[1])
            peak[0] = x - smooth[0]
            peak[1] = y - smooth[1]
        }
        val (gx, gy) = screen(if (gravity == null) smooth[0] else x, if (gravity == null) smooth[1] else y)
        val (ax, ay) = screen(peak[0], peak[1])
        peak.fill(0f)
        // The gravity reading points up and acceleration along the motion, both with y up; Flutter wants
        // the pull down and the motion with y down.
        sink?.success(listOf(-gx.toDouble(), gy.toDouble(), ax.toDouble(), -ay.toDouble()))
    }

    // Sensor axes are fixed to the natural orientation; turn them with the drawn screen.
    private fun screen(x: Float, y: Float): Pair<Float, Float> {
        val rotation = if (Build.VERSION.SDK_INT >= 30) activity.display?.rotation ?: Surface.ROTATION_0
                       else @Suppress("DEPRECATION") activity.windowManager.defaultDisplay.rotation
        return when (rotation) {
            Surface.ROTATION_90 -> -y to x
            Surface.ROTATION_180 -> -x to -y
            Surface.ROTATION_270 -> y to -x
            else -> x to y
        }
    }

    override fun onAccuracyChanged(sensor: Sensor?, accuracy: Int) = Unit

    private companion object {
        const val SAMPLE_US = 33_333 // ~30 Hz
        const val LOW_PASS = 0.2f
    }
}
