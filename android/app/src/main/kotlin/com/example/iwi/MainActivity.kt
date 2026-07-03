package com.geogram.aurora

import android.app.DownloadManager
import android.content.Context
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Environment
import android.provider.DocumentsContract
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
        private const val LINKS_CHANNEL = "com.geogram.aurora/links"
    }

    // Deep-link plumbing: the URI a cold start was launched with (delivered to
    // Dart via getInitialLink), and the channel used to push later links.
    private var linksChannel: MethodChannel? = null
    private var initialLink: String? = null

    // Wi-Fi multicast lock: by default Android drops incoming broadcast/multicast
    // UDP to save power, which would stop the Reticulum LAN auto-peering
    // interface from RECEIVING peers' announces. Holding this lets co-located
    // devices discover each other on the same Wi-Fi.
    private var multicastLock: WifiManager.MulticastLock? = null

    private fun acquireMulticastLock() {
        if (multicastLock != null) return
        try {
            val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE)
                as WifiManager
            multicastLock = wifi.createMulticastLock("aurora-rns-lan").apply {
                setReferenceCounted(false)
                acquire()
            }
        } catch (_: Exception) {
        }
    }

    // Warm start (singleTop): a new deep link arrives while we're already up.
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        val link = linkFrom(intent)
        if (link != null) {
            val ch = linksChannel
            if (ch != null) ch.invokeMethod("onLink", link) else initialLink = link
        }
    }

    private fun captureLink(intent: Intent?) {
        val link = linkFrom(intent) ?: return
        initialLink = link
    }

    /** Pull a circle deep link out of an ACTION_VIEW intent, or null. */
    private fun linkFrom(intent: Intent?): String? {
        if (intent == null || intent.action != Intent.ACTION_VIEW) return null
        val data = intent.data ?: return null
        val s = data.toString()
        val ok = (data.scheme == "https" || data.scheme == "http") &&
            data.host == "geogram.radio" && (data.path?.startsWith("/circle") == true) ||
            (data.scheme == "geogram" && data.host == "circle")
        return if (ok) s else null
    }

    override fun onDestroy() {
        try {
            multicastLock?.let { if (it.isHeld) it.release() }
        } catch (_: Exception) {
        }
        multicastLock = null
        super.onDestroy()
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

        // Deep links (geogram.radio/circle/<key>): expose the launch URI and push
        // any later ones (onNewIntent) to Dart's DeepLinkService.
        linksChannel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, LINKS_CHANNEL)
            .also { ch ->
                ch.setMethodCallHandler { call, result ->
                    when (call.method) {
                        "getInitialLink" -> { result.success(initialLink); initialLink = null }
                        else -> result.notImplemented()
                    }
                }
            }
        // Capture the URI this activity was (re)started with.
        captureLink(intent)

        // Allow receiving LAN broadcast/multicast (Reticulum LAN auto-peering).
        acquireMulticastLock()
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
            "getSupportedAbis" ->
                result.success(android.os.Build.SUPPORTED_ABIS.toList())
            "openInstallPermissionSettings" -> {
                openInstallPermissionSettings(); result.success(true)
            }
            "getCurrentApkPath" ->
                result.success(applicationContext.applicationInfo.sourceDir)
            // System DownloadManager: process-independent background download that
            // survives the app being closed, auto-resumes an interrupted transfer,
            // and only reports success once the whole file has landed (so we never
            // hand a truncated APK to the installer). Used for the geogram.radio
            // HTTP(S) feed on Android; the Reticulum P2P path stays in Dart.
            "enqueueDownload" -> {
                val url = call.argument<String>("url")
                val name = call.argument<String>("filename")
                if (url == null || name == null) {
                    result.error("ARG", "url and filename required", null)
                } else {
                    val title = call.argument<String>("title") ?: "Geogram update"
                    result.success(enqueueDownload(url, name, title))
                }
            }
            "queryDownload" -> {
                val id = (call.argument<Number>("id"))?.toLong()
                if (id == null) result.error("ARG", "id required", null)
                else result.success(queryDownload(id))
            }
            "removeDownload" -> {
                val id = (call.argument<Number>("id"))?.toLong()
                if (id != null) removeDownload(id)
                result.success(true)
            }
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
            "openFolder" -> {
                val path = call.argument<String>("path")
                if (path == null) { result.error("ARG", "path required", null) }
                else result.success(openFolder(path))
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

    /** Open a folder on external storage in the system Files / a file manager so
     * the user can edit its contents directly. Maps the absolute path to a
     * Documents-UI directory URI; falls back to the primary-storage root. */
    private fun openFolder(path: String): Boolean {
        val rel = when {
            path.startsWith("/storage/emulated/0/") -> path.removePrefix("/storage/emulated/0/")
            path.startsWith("/sdcard/") -> path.removePrefix("/sdcard/")
            path == "/storage/emulated/0" || path == "/sdcard" -> ""
            else -> null
        }
        // Primary: ACTION_VIEW on the directory document URI (most file managers).
        if (rel != null && Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            try {
                val uri = DocumentsContract.buildDocumentUri(
                    "com.android.externalstorage.documents", "primary:$rel",
                )
                startActivity(
                    Intent(Intent.ACTION_VIEW)
                        .setDataAndType(uri, DocumentsContract.Document.MIME_TYPE_DIR)
                        .addFlags(
                            Intent.FLAG_ACTIVITY_NEW_TASK or
                                Intent.FLAG_GRANT_READ_URI_PERMISSION or
                                Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
                        ),
                )
                return true
            } catch (_: Exception) {
            }
        }
        // Fallback: open the Files app at the primary-storage root.
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            try {
                val root = DocumentsContract.buildRootUri(
                    "com.android.externalstorage.documents", "primary",
                )
                startActivity(
                    Intent(Intent.ACTION_VIEW)
                        .setData(root)
                        .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK),
                )
                return true
            } catch (_: Exception) {
            }
        }
        return false
    }

    private fun dm(): DownloadManager =
        getSystemService(Context.DOWNLOAD_SERVICE) as DownloadManager

    /** Enqueue a background download into the app's external files dir (no storage
     * permission needed, and readable by the FileProvider for install). Returns the
     * DownloadManager id, or -1 on failure. Cleans any stale file of the same name
     * first so a fresh enqueue doesn't collide with a partial from a prior run. */
    private fun enqueueDownload(url: String, filename: String, title: String): Long {
        return try {
            val dir = getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS)
            File(dir, filename).takeIf { it.exists() }?.delete()
            val req = DownloadManager.Request(Uri.parse(url))
                .setTitle(title)
                .setDescription(filename)
                .setNotificationVisibility(
                    DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED,
                )
                .setDestinationInExternalFilesDir(
                    this, Environment.DIRECTORY_DOWNLOADS, filename,
                )
                .setAllowedOverMetered(true)
                .setAllowedOverRoaming(true)
                .addRequestHeader("User-Agent", "geogram-aurora-updater")
            dm().enqueue(req)
        } catch (e: Exception) {
            android.util.Log.e("MainActivity", "enqueueDownload failed: ${e.message}")
            -1L
        }
    }

    /** Poll a DownloadManager job. Returns a map Dart reads:
     *   status: "pending"|"running"|"paused"|"success"|"failed"|"unknown"
     *   downloaded/total: bytes (total is -1 until the server sends Content-Length)
     *   localPath: absolute file path once successful, else null
     *   reason: the numeric failure/paused reason (0 when not applicable) */
    private fun queryDownload(id: Long): Map<String, Any?> {
        var cursor: Cursor? = null
        return try {
            cursor = dm().query(DownloadManager.Query().setFilterById(id))
            if (cursor == null || !cursor.moveToFirst()) {
                return mapOf("status" to "unknown")
            }
            fun col(name: String) = cursor.getColumnIndex(name)
            val statusCode = cursor.getInt(col(DownloadManager.COLUMN_STATUS))
            val downloaded =
                cursor.getLong(col(DownloadManager.COLUMN_BYTES_DOWNLOADED_SO_FAR))
            val total = cursor.getLong(col(DownloadManager.COLUMN_TOTAL_SIZE_BYTES))
            val reason = cursor.getInt(col(DownloadManager.COLUMN_REASON))
            var localPath: String? = null
            if (statusCode == DownloadManager.STATUS_SUCCESSFUL) {
                val localUri =
                    cursor.getString(col(DownloadManager.COLUMN_LOCAL_URI))
                if (localUri != null) localPath = Uri.parse(localUri).path
            }
            val status = when (statusCode) {
                DownloadManager.STATUS_PENDING -> "pending"
                DownloadManager.STATUS_RUNNING -> "running"
                DownloadManager.STATUS_PAUSED -> "paused"
                DownloadManager.STATUS_SUCCESSFUL -> "success"
                DownloadManager.STATUS_FAILED -> "failed"
                else -> "unknown"
            }
            mapOf(
                "status" to status,
                "downloaded" to downloaded,
                "total" to total,
                "localPath" to localPath,
                "reason" to reason,
            )
        } catch (e: Exception) {
            mapOf("status" to "unknown")
        } finally {
            cursor?.close()
        }
    }

    private fun removeDownload(id: Long) {
        try {
            dm().remove(id)
        } catch (_: Exception) {
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
