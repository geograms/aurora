package com.geogram.aurora

import android.content.Context
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine

/**
 * Application-owned native bridge registry for channels that must work from the
 * headless/background engine as well as the UI.
 *
 * Keeping one bridge set per FlutterEngine prevents Activity attach/detach from
 * spawning duplicate BLE scanners/advertisers. Duplicate scanners were able to
 * keep posting events into detached FlutterJNI instances and starve the UI.
 */
object NativeBridgeRegistry {
    private const val TAG = "NativeBridgeRegistry"

    private var engine: FlutterEngine? = null
    private var ble5: Ble5? = null
    private var wifiDirect: WifiDirect? = null

    @Synchronized
    fun attach(context: Context, flutterEngine: FlutterEngine) {
        val appContext = context.applicationContext

        if (engine === flutterEngine && ble5 != null && wifiDirect != null) {
            BgBridge.attach(appContext, flutterEngine)
            return
        }

        if (engine != null && engine !== flutterEngine) {
            disposeLocked()
        }

        BgBridge.attach(appContext, flutterEngine)
        ble5 = Ble5(appContext, flutterEngine.dartExecutor.binaryMessenger)
        wifiDirect = WifiDirect(appContext, flutterEngine.dartExecutor.binaryMessenger)
        engine = flutterEngine
        Log.d(TAG, "native bridges attached")
    }

    @Synchronized
    fun dispose(flutterEngine: FlutterEngine) {
        if (engine !== flutterEngine) return
        disposeLocked()
    }

    @Synchronized
    fun hasEngine(flutterEngine: FlutterEngine): Boolean = engine === flutterEngine

    private fun disposeLocked() {
        try {
            ble5?.dispose()
        } catch (t: Throwable) {
            Log.w(TAG, "BLE dispose failed: ${t.message}")
        }
        try {
            wifiDirect?.dispose()
        } catch (t: Throwable) {
            Log.w(TAG, "WiFi Direct dispose failed: ${t.message}")
        }
        ble5 = null
        wifiDirect = null
        engine = null
        Log.d(TAG, "native bridges disposed")
    }
}
