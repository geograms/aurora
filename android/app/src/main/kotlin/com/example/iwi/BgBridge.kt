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
                    notify(
                        appCtx, id, title, body,
                        wapp = call.argument<String>("wapp"),
                        convo = call.argument<String>("convo"),
                    )
                    result.success(true)
                }
                // The user read their notifications in-app (notification center
                // opened / cleared): the shade must agree. Cancels every event
                // notification this process posted; the ongoing foreground-
                // service and media notifications are untouched.
                "notify_clear" -> {
                    clearEvents(appCtx)
                    result.success(true)
                }
                "media.update" -> {
                    MediaController.update(
                        appCtx,
                        state = call.argument<String>("state") ?: "playing",
                        title = call.argument<String>("title") ?: "",
                        artist = call.argument<String>("artist") ?: "",
                        durationMs = (call.argument<Number>("durationMs") ?: 0).toLong(),
                        positionMs = (call.argument<Number>("positionMs") ?: 0).toLong(),
                        canNext = call.argument<Boolean>("canNext") ?: false,
                        canPrev = call.argument<Boolean>("canPrev") ?: false,
                    )
                    result.success(true)
                }
                "media.stop" -> {
                    MediaController.stop(appCtx)
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
        AuroraApplication.bgChannel = ch
        Log.d(TAG, "bg_service channel attached")
    }

    /** Ids of event notifications posted by this process, so notify_clear can
     * cancel exactly them (never the foreground-service / media entries). */
    private val postedEventIds = mutableSetOf<Int>()

    /** Cancel every event notification we posted — the in-app notification
     * center was read, and a shade that still shows them is lying. Also sweeps
     * the whole event id range (9000..9099, see platform_io._androidNotifId):
     * a previous process (headless boot) may have posted entries this process
     * never saw. Service/media notifications live at 7001/7002 — untouched. */
    fun clearEvents(context: Context) {
        val nm = context.getSystemService(NotificationManager::class.java) ?: return
        synchronized(postedEventIds) {
            for (id in postedEventIds) nm.cancel(id)
            postedEventIds.clear()
        }
        for (id in 9000..9099) nm.cancel(id)
    }

    /** Post a heads-up notification for a message/event. Tapping opens the
     * app — and when [wapp] is given, deep-links straight to that wapp (and
     * to [convo] inside it) via geogram://open, the same route the in-app
     * notification center takes. A notification that names a conversation
     * must open that conversation, not a front page. */
    fun notify(
        context: Context,
        id: Int,
        title: String,
        body: String?,
        wapp: String? = null,
        convo: String? = null,
    ) {
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
        if (launch != null && !wapp.isNullOrEmpty()) {
            val uri = android.net.Uri.Builder()
                .scheme("geogram").authority("open")
                .appendQueryParameter("wapp", wapp)
                .apply { if (!convo.isNullOrEmpty()) appendQueryParameter("convo", convo) }
                .build()
            launch.action = Intent.ACTION_VIEW
            launch.data = uri
        }
        val pi = if (launch != null) {
            // requestCode = id: each notification keeps its OWN target intent
            // (a shared requestCode would collapse them all onto the last one).
            PendingIntent.getActivity(
                context, id, launch,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
        } else null
        val n: Notification = NotificationCompat.Builder(context, EVENT_CHANNEL_ID)
            .setContentTitle(title)
            .apply { if (!body.isNullOrEmpty()) setContentText(body) }
            .setSmallIcon(R.drawable.ic_stat_geogram)
            .setAutoCancel(true)
            .setPriority(NotificationCompat.PRIORITY_HIGH)
            .apply { if (pi != null) setContentIntent(pi) }
            .build()
        synchronized(postedEventIds) { postedEventIds.add(id) }
        nm.notify(id, n)
    }
}
