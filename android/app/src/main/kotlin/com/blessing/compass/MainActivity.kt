package com.blessing.compass

import android.content.Context
import android.content.Intent
import android.hardware.GeomagneticField
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.Settings
import androidx.core.view.WindowCompat
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * Streams the phone's heading and tilt to Dart as
 * `[azimuthDeg, pitchDeg, rollDeg, accuracy, fieldMicroTesla]`.
 *
 * Uses the fused rotation-vector sensor (accelerometer + magnetometer + gyro),
 * which is smoother than raw magnetometer maths and needs no permission. Falls
 * back to the geomagnetic rotation vector on phones without a gyroscope.
 * Heading is MAGNETIC north; Dart adds the declination (below) for true north
 * once the user has opted in to location.
 *
 * A FlutterFragmentActivity, as in the Clock app: the `location` plugin's
 * in-app "turn on location" dialog throws ActivityNotFoundException from a
 * plain FlutterActivity, so the button silently did nothing.
 */
class MainActivity : FlutterFragmentActivity() {
    private var listener: SensorEventListener? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Edge to edge on every Android version. Dart's SystemUiMode.edgeToEdge
        // does nothing below Android 10, so without this the app stopped
        // short of both bars there: a white strip under the dark app, and the
        // top padding read as zero, cramping everything under the status bar.
        WindowCompat.setDecorFitsSystemWindows(window, false)
        @Suppress("DEPRECATION")
        window.statusBarColor = android.graphics.Color.TRANSPARENT
        @Suppress("DEPRECATION")
        window.navigationBarColor = android.graphics.Color.TRANSPARENT
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            window.isNavigationBarContrastEnforced = false
            window.isStatusBarContrastEnforced = false
        }
        lockHighRefreshRate()
    }

    override fun onPostResume() {
        super.onPostResume()
        // Flutter's PlatformPlugin rewrites the decor flags on every resume to
        // LAYOUT_STABLE | LAYOUT_FULLSCREEN, dropping LAYOUT_HIDE_NAVIGATION
        // below Android 10 (its edge-to-edge mode returns early there). The
        // app then stopped above an opaque white navigation bar. Put the flag
        // back after it. Seen on an Android 9 emulator, 360 x 640.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.Q) {
            val decor = window.decorView
            @Suppress("DEPRECATION")
            decor.systemUiVisibility = decor.systemUiVisibility or
                android.view.View.SYSTEM_UI_FLAG_LAYOUT_STABLE or
                android.view.View.SYSTEM_UI_FLAG_LAYOUT_FULLSCREEN or
                android.view.View.SYSTEM_UI_FLAG_LAYOUT_HIDE_NAVIGATION
            // Then ask for the insets again once the window is laid out.
            // Below Android 11 Flutter guesses "keyboard" when the bottom
            // inset is 18% or more of the root view height, and on the
            // first pass that height is still 0: the 48 dp nav bar reads
            // as a keyboard and the Scaffold shrinks, clipping the page
            // above an empty strip. Light mode hid it (setting the light
            // nav-icon flag re-sends the insets); dark kept the wrong value.
            decor.post { decor.requestApplyInsets() }
        }
    }

    private fun lockHighRefreshRate() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val display = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                display
            } else {
                @Suppress("DEPRECATION")
                windowManager.defaultDisplay
            }
            display?.let { d ->
                val highestMode = d.supportedModes.maxByOrNull { it.refreshRate }
                highestMode?.let { mode ->
                    val layoutParams = window.attributes
                    layoutParams.preferredDisplayModeId = mode.modeId
                    window.attributes = layoutParams
                }
            }
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        EventChannel(flutterEngine.dartExecutor.binaryMessenger, "compass/heading")
            .setStreamHandler(object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, sink: EventChannel.EventSink) = start(sink)
                override fun onCancel(args: Any?) = stop()
            })
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "compass/native")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    // Degrees to ADD to a magnetic heading to get true north,
                    // from the World Magnetic Model built into Android.
                    "declination" -> {
                        val lat = call.argument<Double>("lat")!!
                        val lon = call.argument<Double>("lon")!!
                        val alt = call.argument<Double>("alt") ?: 0.0
                        val f = GeomagneticField(
                            lat.toFloat(), lon.toFloat(), alt.toFloat(),
                            System.currentTimeMillis(),
                        )
                        result.success(f.declination.toDouble())
                    }
                    // For a permission refused for good: the OS will not ask
                    // again, so the only way back is the app's settings page.
                    "openAppSettings" -> {
                        startActivity(
                            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS)
                                .setData(Uri.fromParts("package", packageName, null))
                                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                        )
                        result.success(null)
                    }
                    // True after exactly one refusal. Read before and after a
                    // request, it tells a second refusal (true -> false, the OS
                    // will not ask again) from the prompt closed with Back
                    // (false -> false, the OS will ask again next time).
                    "locationRationale" -> result.success(
                        shouldShowRequestPermissionRationale(
                            android.Manifest.permission.ACCESS_FINE_LOCATION
                        )
                    )
                    else -> result.notImplemented()
                }
            }
    }

    private fun start(sink: EventChannel.EventSink) {
        val sm = getSystemService(Context.SENSOR_SERVICE) as SensorManager
        val rotation = sm.getDefaultSensor(Sensor.TYPE_ROTATION_VECTOR)
            ?: sm.getDefaultSensor(Sensor.TYPE_GEOMAGNETIC_ROTATION_VECTOR)
        if (rotation == null) {
            sink.error("no_sensor", "This phone has no compass sensor.", null)
            return
        }
        val magnetic = sm.getDefaultSensor(Sensor.TYPE_MAGNETIC_FIELD)
        val matrix = FloatArray(9)
        val angles = FloatArray(3)
        // The rotation vector's own accuracy is unreliable on many phones; the
        // magnetometer's is what says "needs calibrating".
        var accuracy = SensorManager.SENSOR_STATUS_ACCURACY_HIGH
        // Strength of the magnetic field the phone sits in. Earth's is
        // 25-65 uT; far above that means metal or a magnet nearby.
        var field = 0.0

        val l = object : SensorEventListener {
            override fun onSensorChanged(e: SensorEvent) {
                if (e.sensor.type == Sensor.TYPE_MAGNETIC_FIELD) {
                    val (x, y, z) = e.values
                    field = Math.sqrt((x * x + y * y + z * z).toDouble())
                    return
                }
                SensorManager.getRotationMatrixFromVector(matrix, e.values)
                SensorManager.getOrientation(matrix, angles)
                var az = Math.toDegrees(angles[0].toDouble())
                if (az < 0) az += 360.0
                sink.success(
                    listOf(
                        az,
                        Math.toDegrees(angles[1].toDouble()),
                        Math.toDegrees(angles[2].toDouble()),
                        accuracy,
                        field,
                    )
                )
            }

            override fun onAccuracyChanged(s: Sensor, acc: Int) {
                if (s.type == Sensor.TYPE_MAGNETIC_FIELD) accuracy = acc
            }
        }
        sm.registerListener(l, rotation, SensorManager.SENSOR_DELAY_GAME)
        magnetic?.let { sm.registerListener(l, it, SensorManager.SENSOR_DELAY_UI) }
        listener = l
    }

    private fun stop() {
        val sm = getSystemService(Context.SENSOR_SERVICE) as SensorManager
        listener?.let { sm.unregisterListener(it) }
        listener = null
    }

    override fun onDestroy() {
        stop()
        super.onDestroy()
    }
}
