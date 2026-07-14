package com.geogram.aurora

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat

/**
 * Foreground service that keeps the app process alive (with a persistent
 * notification) so background wapps keep receiving with the screen off / app
 * backgrounded. It drives a periodic heartbeat into Dart ('onTick' on the
 * bg_service channel) because Dart Timers are throttled in the background
 * while this native Handler is not — see BackgroundWappManager.tickAllFromNative.
 */
class BgService : Service() {
    private val handler = Handler(Looper.getMainLooper())
    private var wakeLock: PowerManager.WakeLock? = null
    private var wifiLock: WifiManager.WifiLock? = null

    private val ticker = object : Runnable {
        override fun run() {
            try {
                // Prefer the shared channel (set whether the engine is headless
                // from boot or owned by the Activity); fall back to the Activity's.
                (AuroraApplication.bgChannel ?: MainActivity.channel)
                    ?.invokeMethod("onTick", null)
            } catch (_: Throwable) {
            }
            handler.postDelayed(this, TICK_MS)
        }
    }

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val text = intent?.getStringExtra("text") ?: "Running in background"
        startAsForeground(text)

        // There may be no Activity (boot/system restart), so make sure a cached
        // Flutter engine exists and has the native BLE/WiFi bridges attached.
        AuroraApplication.instance?.ensureFlutterEngine()
        if (wakeLock == null) {
            val pm = getSystemService(POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "aurora:bg")
                .apply { setReferenceCounted(false); acquire() }
        }
        // Keep WiFi fully powered with the screen off. The wake lock alone keeps
        // the CPU running, but WiFi power-save still stops the device from
        // serving INCOMING connections (Blossom / BitTorrent seeds) and adds
        // latency to pushed APRS-IS data. A high-perf WiFi lock keeps the radio
        // up so a backgrounded/asleep device stays reachable by other devices.
        if (wifiLock == null) {
            val wm = applicationContext.getSystemService(WIFI_SERVICE) as WifiManager
            @Suppress("DEPRECATION")
            wifiLock = wm.createWifiLock(WifiManager.WIFI_MODE_FULL_HIGH_PERF, "aurora:wifi")
                .apply { setReferenceCounted(false); acquire() }
        }
        handler.removeCallbacks(ticker)
        handler.postDelayed(ticker, TICK_MS)
        return START_STICKY
    }

    override fun onDestroy() {
        handler.removeCallbacks(ticker)
        wakeLock?.let { if (it.isHeld) it.release() }
        wakeLock = null
        wifiLock?.let { if (it.isHeld) it.release() }
        wifiLock = null
        super.onDestroy()
    }

    private fun startAsForeground(text: String) {
        val type = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE
        } else {
            0
        }
        ServiceCompat.startForeground(this, NOTIF_ID, buildNotification(text), type)
    }

    private fun buildNotification(text: String): Notification {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(NotificationManager::class.java)
            if (nm.getNotificationChannel(CHANNEL_ID) == null) {
                nm.createNotificationChannel(
                    NotificationChannel(
                        CHANNEL_ID,
                        "Background services",
                        NotificationManager.IMPORTANCE_LOW,
                    ),
                )
            }
        }
        val pi = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        return NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Aurora")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.stat_notify_sync)
            .setOngoing(true)
            .setContentIntent(pi)
            .build()
    }

    companion object {
        private const val CHANNEL_ID = "aurora_bg"
        private const val NOTIF_ID = 7001
        private const val TICK_MS = 2000L
        const val ACTION_START_FROM_BOOT = "com.geogram.aurora.START_FROM_BOOT"

        /** Start the service from the boot receiver (no Activity available). */
        fun startFromBoot(context: Context) {
            val i = Intent(context, BgService::class.java).apply {
                action = ACTION_START_FROM_BOOT
                putExtra("text", "Aurora running in background")
            }
            ContextCompat.startForegroundService(context, i)
        }
    }
}
