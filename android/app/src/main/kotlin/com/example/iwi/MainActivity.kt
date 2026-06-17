package com.geogram.aurora

import android.content.Context
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.provider.Settings
import androidx.core.content.FileProvider
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File

class MainActivity : FlutterActivity() {
    companion object {
        // Held so the foreground service can ping Dart ('onTick') even while
        // the activity is backgrounded. Mirrors AuroraApplication.bgChannel.
        var channel: MethodChannel? = null
        private const val UPDATE_CHANNEL = "com.geogram.aurora/updates"
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

        // Update Center channel: APK install + download foreground service.
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, UPDATE_CHANNEL)
            .setMethodCallHandler { call, result -> handleUpdate(call, result) }

        // BLE 5 extended advertising/scanning for the Reticulum broadcast transport.
        Ble5(applicationContext, flutterEngine.dartExecutor.binaryMessenger)
    }

    private fun handleUpdate(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "installApk" -> {
                val path = call.argument<String>("filePath")
                if (path == null) {
                    result.error("ARG", "filePath required", null); return
                }
                result.success(installApk(path))
            }
            "canInstallPackages" -> result.success(canInstallPackages())
            "openInstallPermissionSettings" -> {
                openInstallPermissionSettings(); result.success(true)
            }
            "getCurrentApkPath" ->
                result.success(applicationContext.applicationInfo.sourceDir)
            "startDownloadService" -> {
                val text = call.argument<String>("text") ?: "Downloading update"
                DownloadForegroundService.start(this, text); result.success(true)
            }
            "updateDownloadProgress" -> {
                val p = call.argument<Int>("progress") ?: 0
                val s = call.argument<String>("status") ?: "Downloading…"
                DownloadForegroundService.updateProgress(this, p, s)
                result.success(true)
            }
            "stopDownloadService" -> {
                DownloadForegroundService.stop(this); result.success(true)
            }
            // Battery-optimization (Doze) exemption — required on aggressive OEMs
            // so the foreground service + APRS-IS connection + Blossom/seed
            // servers survive deep sleep instead of being killed.
            "isIgnoringBatteryOptimizations" -> result.success(isIgnoringBattery())
            "requestIgnoreBatteryOptimizations" -> {
                requestIgnoreBattery(); result.success(true)
            }
            else -> result.notImplemented()
        }
    }

    private fun isIgnoringBattery(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val pm = getSystemService(Context.POWER_SERVICE) as android.os.PowerManager
            pm.isIgnoringBatteryOptimizations(packageName)
        } else {
            true
        }

    private fun requestIgnoreBattery() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.M || isIgnoringBattery()) return
        try {
            startActivity(
                Intent(
                    Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                    Uri.parse("package:$packageName"),
                ),
            )
        } catch (_: Exception) {
            try {
                startActivity(Intent(Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS))
            } catch (_: Exception) {
            }
        }
    }

    private fun canInstallPackages(): Boolean =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O)
            packageManager.canRequestPackageInstalls()
        else true

    private fun openInstallPermissionSettings() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startActivity(
                Intent(Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES)
                    .setData(Uri.parse("package:$packageName"))
                    .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
            )
        }
    }

    private fun installApk(filePath: String): Boolean {
        return try {
            val file = File(filePath)
            if (!file.exists() || file.length() < 1000) return false
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                !packageManager.canRequestPackageInstalls()
            ) {
                openInstallPermissionSettings()
                return false
            }
            val intent = Intent(Intent.ACTION_VIEW).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                val uri = FileProvider.getUriForFile(
                    this, "$packageName.fileprovider", file,
                )
                intent.setDataAndType(uri, "application/vnd.android.package-archive")
                intent.addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            } else {
                intent.setDataAndType(
                    Uri.fromFile(file), "application/vnd.android.package-archive",
                )
            }
            startActivity(intent)
            true
        } catch (e: Exception) {
            android.util.Log.e("MainActivity", "installApk failed: ${e.message}")
            false
        }
    }
}
