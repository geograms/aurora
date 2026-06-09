package com.geogram.aurora

import android.content.Context
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        // Held so the foreground service can ping Dart ('onTick') even while
        // the activity is backgrounded. Mirrors AuroraApplication.bgChannel.
        var channel: MethodChannel? = null
    }

    /**
     * Reuse the headless engine created at boot (if any) so opening the UI does
     * not spawn a second isolate that would run BLE/APRS twice. Returns null on a
     * normal cold start, letting the framework create a fresh engine.
     */
    override fun provideFlutterEngine(context: Context): FlutterEngine? {
        return FlutterEngineCache.getInstance().get(AuroraApplication.ENGINE_ID)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        // For a pre-warmed (boot) engine, plugins were already registered when it
        // was created — calling super again double-registers and can spawn a 2nd
        // engine. Only register for a fresh engine.
        val isPreWarmed =
            FlutterEngineCache.getInstance().get(AuroraApplication.ENGINE_ID) === flutterEngine
        if (!isPreWarmed) {
            super.configureFlutterEngine(flutterEngine)
        }

        // Bind the bg_service channel (idempotent) and mirror it for the service.
        BgBridge.attach(this, flutterEngine)
        channel = AuroraApplication.bgChannel
    }
}
