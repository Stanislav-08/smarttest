package com.example.smart_test_ai

import android.content.Context
import android.content.Intent
import android.media.projection.MediaProjectionManager
import android.os.Handler
import android.os.Looper
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private val channelName = "ai_assistant/screen_capture"
    // Tag the flutter_overlay_window plugin uses for its overlay engine (OverlayConstants.CACHED_TAG).
    private val overlayEngineTag = "myCachedEngine"
    private val reqProjection = 4242
    private var pending: MethodChannel.Result? = null
    private val main = Handler(Looper.getMainLooper())

    /** Capture methods: registered on BOTH the main engine and the overlay engine. */
    private fun handleCapture(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "isReady" -> result.success(CaptureService.isReady())
            "capture" -> Thread {
                val bytes = try { CaptureService.capture() } catch (e: Exception) { null }
                main.post { result.success(bytes) }
            }.start()
            else -> result.notImplemented()
        }
    }

    /** The overlay runs in its own engine, so give that engine the same channel. */
    private fun attachOverlay(result: MethodChannel.Result, attempt: Int = 0) {
        val engine = FlutterEngineCache.getInstance().get(overlayEngineTag)
        if (engine != null) {
            MethodChannel(engine.dartExecutor.binaryMessenger, channelName)
                .setMethodCallHandler { call, res -> handleCapture(call, res) }
            result.success(true)
        } else if (attempt < 20) {
            main.postDelayed({ attachOverlay(result, attempt + 1) }, 250)
        } else {
            result.success(false)
        }
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, channelName)
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "requestPermission" -> {
                        pending = result
                        val mpm = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
                        @Suppress("DEPRECATION")
                        startActivityForResult(mpm.createScreenCaptureIntent(), reqProjection)
                    }
                    "attachOverlay" -> attachOverlay(result)
                    "stopCapture" -> {
                        stopService(Intent(this, CaptureService::class.java))
                        result.success(true)
                    }
                    else -> handleCapture(call, result)
                }
            }
    }

    @Deprecated("Deprecated in Java")
    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        super.onActivityResult(requestCode, resultCode, data)
        if (requestCode == reqProjection) {
            if (resultCode == RESULT_OK && data != null) {
                val i = Intent(this, CaptureService::class.java)
                    .putExtra("code", resultCode).putExtra("data", data)
                ContextCompat.startForegroundService(this, i)
                pending?.success(true)
            } else {
                pending?.success(false)
            }
            pending = null
        }
    }
}