package com.geogram.aurora

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

/**
 * Starts Aurora's background service after the device boots, so autostart wapps
 * (e.g. an always-on APRS iGate) resume receiving without the user opening the
 * app. Gated on the `autoStartOnBoot` preference, which Dart keeps in sync with
 * "is any wapp marked autostart" — so a device with no always-on wapp does no
 * work at boot.
 */
class BootReceiver : BroadcastReceiver() {
    companion object {
        private const val TAG = "BootReceiver"
    }

    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action
        Log.d(TAG, "Received: $action")
        if (action != Intent.ACTION_BOOT_COMPLETED &&
            action != "android.intent.action.QUICKBOOT_POWERON" &&
            action != "com.htc.intent.action.QUICKBOOT_POWERON"
        ) {
            return
        }

        val prefs = context.getSharedPreferences(BgBridge.PREFS_NAME, Context.MODE_PRIVATE)
        val autoStart = prefs.getBoolean(BgBridge.AUTO_START_KEY, false)
        if (!autoStart) {
            Log.i(TAG, "Boot detected, but autoStartOnBoot is off — skipping")
            return
        }

        Log.i(TAG, "Boot detected on API ${Build.VERSION.SDK_INT} — starting background service")
        try {
            BgService.startFromBoot(context)
        } catch (e: Exception) {
            Log.e(TAG, "Failed to start service from boot: ${e.message}", e)
        }
    }
}
