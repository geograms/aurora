package com.geogram.aurora

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Shared wiring for the `bg_service` method channel and for posting user-visible
 * event notifications.
 *
 * The same channel logic is used whether the Flutter engine was created by the
 * Activity (normal launch) or headlessly by [AuroraApplication] at boot, so the
 * background service behaves identically in both cases. The resulting channel is
 * published on [AuroraApplication.bgChannel] so [BgService] can drive `onTick`
 * (and any other native -> Dart pings) without needing an Activity.
 */
object BgBridge {
    private const val TAG = "BgBridge"
    const val CHANNEL_NAME = "com.geogram.aurora/bg_service"
    private const val EVENT_CHANNEL_ID = "aurora_events"
    const val PREFS_NAME = "FlutterSharedPreferences"
    const val AUTO_START_KEY = "flutter.autoStartOnBoot"

    /**
     * Attach the bg_service channel + handler to [engine] and publish it for the
     * service. Idempotent — safe to call again when the Activity reuses a
     * pre-warmed engine.
     */
    fun attach(context: Context, engine: FlutterEngine) {
        val appCtx = context.applicationContext
        val ch = MethodChannel(engine.dartExecutor.binaryMessenger, CHANNEL_NAME)
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val text = call.argument<String>("text") ?: "Running in background"
                    val i = Intent(appCtx, BgService::class.java).putExtra("text", text)
                    ContextCompat.startForegroundService(appCtx, i)
                    result.success(true)
                }
                "stop" -> {
                    appCtx.stopService(Intent(appCtx, BgService::class.java))
                    result.success(true)
                }
                "notify" -> {
                    val id = call.argument<Int>("id") ?: (System.currentTimeMillis() and 0x7fffffff).toInt()
                    val title = call.argument<String>("title") ?: "Aurora"
                    val body = call.argument<String>("body")
                    notify(appCtx, id, title, body)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
        AuroraApplication.bgChannel = ch
        Log.d(TAG, "bg_service channel attached")
    }

    /** Post a heads-up notification for a message/event. Tapping opens the app. */
    fun notify(context: Context, id: Int, title: String, body: String?) {
        val nm = context.getSystemService(NotificationManager::class.java) ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
            nm.getNotificationChannel(EVENT_CHANNEL_ID) == null
        ) {
            val channel = NotificationChannel(
                EVENT_CHANNEL_ID,
                "Messages & events",
                NotificationManager.IMPORTANCE_HIGH,
            ).apply { description = "New messages and events from background wapps" }
            nm.createNotificationChannel(channel)
        }
        val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
        val pi = if (launch != null) {
            PendingIntent.getActivity(
                context, 0, launch,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
        } else null
        val n: Notification = NotificationCompat.Builder(context, EVENT_CHANNEL_ID)
            .setContentTitle(title)
            .apply { if (!body.isNullOrEmpty()) setContentText(body) }
            .setSmallIcon(android.R.drawable.stat_notify_chat)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .apply { if (pi != null) setContentIntent(pi) }
            .build()
        nm.notify(id, n)
    }
}
