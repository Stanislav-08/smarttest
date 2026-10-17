package com.example.smart_test_ai

import android.app.*
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.Bitmap
import android.graphics.PixelFormat
import android.hardware.display.DisplayManager
import android.hardware.display.VirtualDisplay
import android.media.ImageReader
import android.media.projection.MediaProjection
import android.media.projection.MediaProjectionManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import java.io.ByteArrayOutputStream

class CaptureService : Service() {

    companion object {
        private var projection: MediaProjection? = null
        private var reader: ImageReader? = null
        private var virtualDisplay: VirtualDisplay? = null
        private var width = 0
        private var height = 0

        fun isReady() = reader != null

        /** Blocking: call from a background thread. Returns JPEG bytes or null. */
        fun capture(): ByteArray? {
            val r = reader ?: return null
            var image = r.acquireLatestImage()
            var tries = 0
            while (image == null && tries < 15) {
                Thread.sleep(100); tries++
                image = r.acquireLatestImage()
            }
            val img = image ?: return null
            try {
                val plane = img.planes[0]
                val rowPadding = plane.rowStride - plane.pixelStride * width
                val full = Bitmap.createBitmap(
                    width + rowPadding / plane.pixelStride, height, Bitmap.Config.ARGB_8888
                )
                full.copyPixelsFromBuffer(plane.buffer)
                val cropped = Bitmap.createBitmap(full, 0, 0, width, height)
                val out = ByteArrayOutputStream()
                cropped.compress(Bitmap.CompressFormat.JPEG, 80, out)
                return out.toByteArray()
            } finally {
                img.close()
            }
        }

        private fun release() {
            virtualDisplay?.release(); virtualDisplay = null
            reader?.close(); reader = null
            val p = projection
            projection = null // clear first so the onStop callback can't re-enter
            p?.stop()
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val nm = getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= 26) {
            nm.createNotificationChannel(
                NotificationChannel("capture", "Screen capture", NotificationManager.IMPORTANCE_LOW)
            )
        }
        val notification = Notification.Builder(this, "capture")
            .setContentTitle("AI Assistant")
            .setContentText("Screen capture is available")
            .setSmallIcon(android.R.drawable.ic_menu_camera)
            .build()

        // Must be in the foreground BEFORE getMediaProjection() on Android 14+.
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(2001, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION)
        } else {
            startForeground(2001, notification)
        }

        val code = intent?.getIntExtra("code", Activity.RESULT_CANCELED) ?: return START_NOT_STICKY
        @Suppress("DEPRECATION")
        val data = intent.getParcelableExtra<Intent>("data") ?: return START_NOT_STICKY

        release()
        val mpm = getSystemService(Context.MEDIA_PROJECTION_SERVICE) as MediaProjectionManager
        val p = mpm.getMediaProjection(code, data) ?: return START_NOT_STICKY
        // Android 14+: callback must be registered before createVirtualDisplay.
        p.registerCallback(object : MediaProjection.Callback() {
            override fun onStop() { release(); stopSelf() }
        }, Handler(Looper.getMainLooper()))
        projection = p

        val m = resources.displayMetrics
        width = m.widthPixels; height = m.heightPixels
        reader = ImageReader.newInstance(width, height, PixelFormat.RGBA_8888, 2)
        // Android 14+ allows only ONE VirtualDisplay per projection token, so we keep it
        // alive and just grab the latest frame on demand.
        virtualDisplay = p.createVirtualDisplay(
            "ai-assistant-capture", width, height, m.densityDpi,
            DisplayManager.VIRTUAL_DISPLAY_FLAG_AUTO_MIRROR, reader!!.surface, null, null
        )
        return START_NOT_STICKY
    }

    override fun onDestroy() { release(); super.onDestroy() }
}