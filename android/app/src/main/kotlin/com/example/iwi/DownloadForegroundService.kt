package com.geogram.aurora

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat

/**
 * Keeps an in-app update download alive (and shows its progress) when the app is
 * backgrounded during the download. Mirrors geogram's DownloadForegroundService.
 * Controlled from Dart via the com.geogram.aurora/updates MethodChannel.
 */
class DownloadForegroundService : Service() {
    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val text = intent?.getStringExtra("text") ?: "Downloading update"
        val progress = intent?.getIntExtra("progress", -1) ?: -1
        startAsForeground(text, progress)
        return START_NOT_STICKY
    }

    private fun startAsForeground(text: String, progress: Int) {
        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
        } else {
            0
        }
        ServiceCompat.startForeground(this, NOTIF_ID, build(text, progress), type)
    }

    private fun build(text: String, progress: Int): Notification {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(NotificationManager::class.java)
            if (nm.getNotificationChannel(CHANNEL_ID) == null) {
                nm.createNotificationChannel(
                    NotificationChannel(
                        CHANNEL_ID, "Updates", NotificationManager.IMPORTANCE_LOW,
                    ),
                )
            }
        }
        val b = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Geogram Aurora")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_sys_download)
            .setOngoing(true)
            .setOnlyAlertOnce(true)
        if (progress in 0..100) {
            b.setProgress(100, progress, false)
        } else {
            b.setProgress(0, 0, true)
        }
        return b.build()
    }

    companion object {
        private const val CHANNEL_ID = "aurora_download"
        private const val NOTIF_ID = 7002

        fun start(context: Context, text: String) {
            ContextCompat.startForegroundService(
                context,
                Intent(context, DownloadForegroundService::class.java)
                    .putExtra("text", text),
            )
        }

        fun updateProgress(context: Context, progress: Int, status: String) {
            ContextCompat.startForegroundService(
                context,
                Intent(context, DownloadForegroundService::class.java)
                    .putExtra("text", status)
                    .putExtra("progress", progress),
            )
        }

        fun stop(context: Context) {
            context.stopService(Intent(context, DownloadForegroundService::class.java))
        }
    }
}
