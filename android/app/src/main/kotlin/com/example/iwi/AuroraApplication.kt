package com.geogram.aurora

import android.app.Application
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel

/**
 * Application subclass that can run the Flutter app headlessly (no Activity).
 *
 * On boot (see [BootReceiver] -> [BgService]) we create a cached FlutterEngine
 * and run `main()`, so autostart background wapps come up and keep receiving
 * (BLE / APRS-IS) without the user opening the UI. When the user later opens the
 * app, [MainActivity] reuses this same cached engine instead of spawning a second
 * isolate (which would double the BLE stack and memory).
 */
class AuroraApplication : Application() {
    companion object {
        const val ENGINE_ID = "aurora_engine"
        private const val TAG = "AuroraApplication"

        @Volatile
        var instance: AuroraApplication? = null

        /**
         * The bg_service channel bound to whichever engine is live (headless or
         * Activity-owned). [BgService] uses it to ping Dart (`onTick`).
         */
        @Volatile
        var bgChannel: MethodChannel? = null
    }

    override fun onCreate() {
        super.onCreate()
        instance = this
    }

    /**
     * Create + cache a headless FlutterEngine running the default Dart entrypoint
     * (`main()`), then wire the bg_service channel. No-op if one already exists.
     */
    @Synchronized
    fun ensureFlutterEngine() {
        val cached = FlutterEngineCache.getInstance().get(ENGINE_ID)
        if (cached != null) {
            NativeBridgeRegistry.attach(this, cached)
            Log.d(TAG, "FlutterEngine already cached")
            return
        }
        Log.d(TAG, "Creating headless FlutterEngine")
        try {
            // Default constructor auto-registers the generated plugins, which
            // main() needs immediately (path_provider, shared_preferences, …).
            val engine = FlutterEngine(this)
            FlutterEngineCache.getInstance().put(ENGINE_ID, engine)
            NativeBridgeRegistry.attach(this, engine)
            engine.dartExecutor.executeDartEntrypoint(
                DartExecutor.DartEntrypoint.createDefault(),
            )
            Log.d(TAG, "Headless FlutterEngine created and cached as $ENGINE_ID")
        } catch (t: Throwable) {
            Log.e(TAG, "Failed to create headless FlutterEngine: ${t.message}", t)
        }
    }

    /**
     * Remember an Activity-created engine as the process engine. This lets the
     * foreground service keep the same Dart isolate/native bridges alive after
     * the UI is detached instead of creating a competing headless engine.
     */
    @Synchronized
    fun rememberFlutterEngine(engine: FlutterEngine) {
        val cache = FlutterEngineCache.getInstance()
        val cached = cache.get(ENGINE_ID)
        if (cached == null) {
            cache.put(ENGINE_ID, engine)
            Log.d(TAG, "Activity FlutterEngine cached as $ENGINE_ID")
        }
        NativeBridgeRegistry.attach(this, cached ?: engine)
    }
}
