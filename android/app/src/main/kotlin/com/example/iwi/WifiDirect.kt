package com.geogram.aurora

import android.Manifest
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.net.NetworkInfo
import android.net.wifi.p2p.WifiP2pConfig
import android.net.wifi.p2p.WifiP2pGroup
import android.net.wifi.p2p.WifiP2pInfo
import android.net.wifi.p2p.WifiP2pManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel

/**
 * WiFi Direct (WifiP2p) link management for the mesh bulk data plane.
 *
 * BLE coordinates; this class only forms/joins groups and reports state. The
 * silent, no-dialog path (both sides, API 29+):
 *   - group owner: createGroup() (autonomous group — no prompt), read the live
 *     SSID/passphrase from requestGroupInfo; GO IP is always 192.168.49.1.
 *   - client: connect() with WifiP2pConfig.Builder().setNetworkName(ssid)
 *     .setPassphrase(psk) — a credential join, no prompt on either device.
 *
 * SINGLE-GROUP INVARIANT: ensureGroup() reuses an existing group (never
 * remove+recreate on the happy path) so repeated negotiations cannot pollute
 * the P2P stack with group churn. Teardown happens only by explicit
 * removeGroup()/disconnect() policy calls.
 *
 * MethodChannel  com.geogram.aurora/wifidirect :
 *   supported / ensureGroup / removeGroup / connectToGroup / disconnect /
 *   groupInfo
 * EventChannel   com.geogram.aurora/wifidirect_events : maps
 *   {event:'p2pState', enabled:Bool}
 *   {event:'connection', connected:Bool, isGo:Bool, goIp:String?}
 *   {event:'group', active:Bool, isGo:Bool, ssid:String?, clientCount:Int}
 */
class WifiDirect(context: Context, messenger: BinaryMessenger) {
    companion object {
        private const val METHOD_CHANNEL = "com.geogram.aurora/wifidirect"
        private const val EVENT_CHANNEL = "com.geogram.aurora/wifidirect_events"
        private const val TAG = "WifiDirect"
    }

    private val appContext: Context = context.applicationContext
    private val main = Handler(Looper.getMainLooper())

    private val manager: WifiP2pManager? =
        appContext.getSystemService(Context.WIFI_P2P_SERVICE) as? WifiP2pManager
    private var channel: WifiP2pManager.Channel? = null

    private var events: EventChannel.EventSink? = null
    private var p2pEnabled = false
    // Latest connection/group state (from broadcasts), for groupInfo().
    @Volatile private var lastInfo: WifiP2pInfo? = null
    @Volatile private var lastGroup: WifiP2pGroup? = null

    private val receiver = object : BroadcastReceiver() {
        override fun onReceive(ctx: Context?, intent: Intent?) {
            when (intent?.action) {
                WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION -> {
                    val state = intent.getIntExtra(WifiP2pManager.EXTRA_WIFI_STATE, -1)
                    p2pEnabled = state == WifiP2pManager.WIFI_P2P_STATE_ENABLED
                    emit(mapOf("event" to "p2pState", "enabled" to p2pEnabled))
                }
                WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION -> {
                    @Suppress("DEPRECATION")
                    val net = intent.getParcelableExtra<NetworkInfo>(
                        WifiP2pManager.EXTRA_NETWORK_INFO)
                    val ch = channel ?: return
                    if (net?.isConnected == true) {
                        try {
                            manager?.requestConnectionInfo(ch) { info ->
                                lastInfo = info
                                refreshGroup()
                                emit(mapOf(
                                    "event" to "connection",
                                    "connected" to true,
                                    "isGo" to (info?.isGroupOwner == true),
                                    "goIp" to info?.groupOwnerAddress?.hostAddress,
                                ))
                            }
                        } catch (e: SecurityException) {
                            Log.w(TAG, "requestConnectionInfo: $e")
                        }
                    } else {
                        lastInfo = null
                        lastGroup = null
                        emit(mapOf("event" to "connection", "connected" to false))
                    }
                }
            }
        }
    }

    init {
        channel = manager?.initialize(appContext, Looper.getMainLooper(), null)

        MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler { call, result ->
            try {
                when (call.method) {
                    "supported" -> result.success(supported())
                    "ensureGroup" -> ensureGroup(result)
                    "removeGroup" -> removeGroup(result)
                    "connectToGroup" -> connectToGroup(
                        call.argument<String>("ssid") ?: "",
                        call.argument<String>("psk") ?: "", result)
                    "disconnect" -> removeGroup(result) // client leave == removeGroup on our channel
                    "groupInfo" -> groupInfo(result)
                    else -> result.notImplemented()
                }
            } catch (e: Exception) {
                Log.e(TAG, "method ${call.method} failed", e)
                result.error("wfd", e.message, null)
            }
        }

        EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, sink: EventChannel.EventSink?) {
                    events = sink
                }
                override fun onCancel(args: Any?) { events = null }
            })

        // Receiver on the application context — works with the headless engine
        // and the screen off.
        val filter = IntentFilter().apply {
            addAction(WifiP2pManager.WIFI_P2P_STATE_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_CONNECTION_CHANGED_ACTION)
            addAction(WifiP2pManager.WIFI_P2P_THIS_DEVICE_CHANGED_ACTION)
        }
        appContext.registerReceiver(receiver, filter)
    }

    private fun emit(m: Map<String, Any?>) = main.post { events?.success(m) }

    private fun hasPermission(): Boolean {
        val perm = if (Build.VERSION.SDK_INT >= 33)
            Manifest.permission.NEARBY_WIFI_DEVICES
        else
            Manifest.permission.ACCESS_FINE_LOCATION
        return appContext.checkSelfPermission(perm) == PackageManager.PERMISSION_GRANTED
    }

    private fun supported(): Boolean =
        manager != null && channel != null && Build.VERSION.SDK_INT >= 29 &&
            appContext.packageManager.hasSystemFeature(PackageManager.FEATURE_WIFI_DIRECT)

    /** Refresh lastGroup from the framework (best-effort, permission-gated). */
    private fun refreshGroup(cb: ((WifiP2pGroup?) -> Unit)? = null) {
        val ch = channel ?: run { cb?.invoke(null); return }
        if (!hasPermission()) { cb?.invoke(null); return }
        try {
            manager?.requestGroupInfo(ch) { g ->
                lastGroup = g
                if (g != null) emit(mapOf(
                    "event" to "group", "active" to true,
                    "isGo" to g.isGroupOwner, "ssid" to g.networkName,
                    "clientCount" to g.clientList.size))
                cb?.invoke(g)
            }
        } catch (e: SecurityException) {
            Log.w(TAG, "requestGroupInfo: $e"); cb?.invoke(null)
        }
    }

    /**
     * Single-group ensure: reuse the live group if one exists (creds re-read
     * fresh), else create an autonomous group and wait for its info. Replies
     * {ok, reused, isGo, ssid, psk, goIp}.
     */
    private fun ensureGroup(result: MethodChannel.Result) {
        val ch = channel
        if (manager == null || ch == null) { result.error("wfd", "no p2p manager", null); return }
        if (!supported()) { result.error("wfd", "wifi direct unsupported", null); return }
        if (!hasPermission()) { result.error("wfd", "missing nearby-wifi permission", null); return }

        refreshGroup { existing ->
            if (existing != null && existing.isGroupOwner) {
                // Happy path: reuse — never churn the group.
                result.success(mapOf(
                    "ok" to true, "reused" to true, "isGo" to true,
                    "ssid" to existing.networkName, "psk" to existing.passphrase,
                    "goIp" to "192.168.49.1"))
                return@refreshGroup
            }
            if (existing != null) {
                // We are a CLIENT in someone else's group — cannot host too.
                result.success(mapOf(
                    "ok" to false, "reused" to false, "error" to "client-in-group",
                    "ssid" to existing.networkName))
                return@refreshGroup
            }
            createGroupWithRetry(ch, result, attempt = 0)
        }
    }

    private fun createGroupWithRetry(
        ch: WifiP2pManager.Channel, result: MethodChannel.Result, attempt: Int) {
        try {
            manager!!.createGroup(ch, object : WifiP2pManager.ActionListener {
                override fun onSuccess() {
                    // Group info can lag a moment after onSuccess — poll briefly.
                    pollGroupInfo(result, tries = 10)
                }
                override fun onFailure(reason: Int) {
                    if (reason == WifiP2pManager.BUSY && attempt == 0) {
                        Log.w(TAG, "createGroup BUSY, retrying once")
                        main.postDelayed({ createGroupWithRetry(ch, result, 1) }, 1000)
                    } else {
                        result.success(mapOf(
                            "ok" to false, "reused" to false,
                            "error" to "createGroup failed reason=$reason"))
                    }
                }
            })
        } catch (e: SecurityException) {
            result.error("wfd", "createGroup: $e", null)
        }
    }

    private fun pollGroupInfo(result: MethodChannel.Result, tries: Int) {
        refreshGroup { g ->
            if (g != null && g.isGroupOwner && !g.passphrase.isNullOrEmpty()) {
                result.success(mapOf(
                    "ok" to true, "reused" to false, "isGo" to true,
                    "ssid" to g.networkName, "psk" to g.passphrase,
                    "goIp" to "192.168.49.1"))
            } else if (tries > 0) {
                main.postDelayed({ pollGroupInfo(result, tries - 1) }, 500)
            } else {
                result.success(mapOf(
                    "ok" to false, "reused" to false, "error" to "group info timeout"))
            }
        }
    }

    /** Silent credential join (API 29+): no dialogs on either side. */
    private fun connectToGroup(ssid: String, psk: String, result: MethodChannel.Result) {
        val ch = channel
        if (manager == null || ch == null) { result.error("wfd", "no p2p manager", null); return }
        if (Build.VERSION.SDK_INT < 29) { result.error("wfd", "needs API 29+", null); return }
        if (!hasPermission()) { result.error("wfd", "missing nearby-wifi permission", null); return }
        if (ssid.isEmpty() || psk.isEmpty()) { result.error("wfd", "ssid/psk required", null); return }

        // Already a member of this very group? No-op success.
        val g = lastGroup
        if (g != null && !g.isGroupOwner && g.networkName == ssid) {
            result.success(mapOf("ok" to true, "already" to true))
            return
        }

        doConnect(ch, ssid, psk, result, retried = false)
    }

    private fun doConnect(
        ch: WifiP2pManager.Channel, ssid: String, psk: String,
        result: MethodChannel.Result, retried: Boolean) {
        val config = WifiP2pConfig.Builder()
            .setNetworkName(ssid)
            .setPassphrase(psk)
            .build()
        try {
            manager!!.connect(ch, config, object : WifiP2pManager.ActionListener {
                override fun onSuccess() {
                    // Join INITIATED. The 'connection' event (broadcast) reports
                    // the actual link-up with the GO address.
                    result.success(mapOf("ok" to true, "already" to false))
                }
                override fun onFailure(reason: Int) {
                    // BUSY/ERROR usually = a stale group/membership from a prior
                    // run. Clear it ONCE (removeGroup) then retry the join.
                    if (!retried) {
                        manager.removeGroup(ch, object : WifiP2pManager.ActionListener {
                            override fun onSuccess() { retryConnect(ch, ssid, psk, result) }
                            override fun onFailure(r: Int) { retryConnect(ch, ssid, psk, result) }
                        })
                    } else {
                        result.success(mapOf("ok" to false, "error" to "connect failed reason=$reason"))
                    }
                }
            })
        } catch (e: SecurityException) {
            result.error("wfd", "connect: $e", null)
        }
    }

    private fun retryConnect(
        ch: WifiP2pManager.Channel, ssid: String, psk: String,
        result: MethodChannel.Result) {
        lastGroup = null; lastInfo = null
        main.postDelayed({ doConnect(ch, ssid, psk, result, retried = true) }, 1500)
    }

    /** Tear down our group / leave the joined group (policy calls only). */
    private fun removeGroup(result: MethodChannel.Result) {
        val ch = channel
        if (manager == null || ch == null) { result.error("wfd", "no p2p manager", null); return }
        manager.removeGroup(ch, object : WifiP2pManager.ActionListener {
            override fun onSuccess() {
                lastGroup = null; lastInfo = null
                emit(mapOf("event" to "group", "active" to false))
                result.success(true)
            }
            override fun onFailure(reason: Int) {
                // "no group" style failures are fine — report success=false quietly.
                result.success(false)
            }
        })
    }

    private fun groupInfo(result: MethodChannel.Result) {
        refreshGroup { g ->
            if (g == null) {
                result.success(null)
            } else {
                result.success(mapOf(
                    "active" to true,
                    "isGo" to g.isGroupOwner,
                    "ssid" to g.networkName,
                    "psk" to (if (g.isGroupOwner) g.passphrase else null),
                    "clientCount" to g.clientList.size,
                    "iface" to g.`interface`,
                    "goIp" to lastInfo?.groupOwnerAddress?.hostAddress,
                ))
            }
        }
    }
}
