package com.geogram.aurora

import android.content.Intent
import androidx.core.content.ContextCompat
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    companion object {
        // Held so the foreground service can ping Dart ('onTick') even while
        // the activity is backgrounded (the FlutterEngine/isolate stays alive
        // because the foreground service keeps the process up).
        var channel: MethodChannel? = null
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        val ch = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.geogram.aurora/bg_service",
        )
        channel = ch
        ch.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    val text = call.argument<String>("text") ?: "Running in background"
                    val i = Intent(this, BgService::class.java).putExtra("text", text)
                    ContextCompat.startForegroundService(this, i)
                    result.success(true)
                }
                "stop" -> {
                    stopService(Intent(this, BgService::class.java))
                    result.success(true)
                }
                else -> result.notImplemented()
            }
        }
    }
}
