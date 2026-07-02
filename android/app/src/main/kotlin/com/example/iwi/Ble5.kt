package com.geogram.aurora

import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothGattServer
import android.bluetooth.BluetoothGattServerCallback
import android.bluetooth.BluetoothGattService
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.le.AdvertiseCallback
import android.bluetooth.le.AdvertiseData
import android.bluetooth.le.AdvertiseSettings
import android.bluetooth.le.AdvertisingSet
import android.bluetooth.le.AdvertisingSetCallback
import android.bluetooth.le.AdvertisingSetParameters
import android.bluetooth.le.BluetoothLeAdvertiser
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.Context
import android.os.Build
import android.os.Handler
import android.os.Looper
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

/**
 * BLE 5 extended advertising + scanning, used as a SHARED connectionless
 * broadcast bus for every subsystem (Reticulum announces AND APRS group chat).
 *
 * One advertising set, MULTIPLEXED: many phones cannot sustain two concurrent
 * extended advertising sets, and two independent writers of one set just clobber
 * each other's data. So callers register keyed frames (each with a subtype + a
 * TTL) and a single rotation round-robins setAdvertisingData among the active
 * frames, dropping them when they expire. APRS messages and RNS announces are
 * sparse, so each frame still gets plenty of on-air time.
 *
 * MethodChannel  com.geogram.aurora/ble5      : supported / advertiseFrame /
 *                                               removeFrame / stopAdvertise /
 *                                               startScan / stopScan
 * EventChannel   com.geogram.aurora/ble5_scan : inbound frames as a map
 *                {addr:String, rssi:Int, subtype:Int, data:ByteArray}
 *
 * Wire framing of the manufacturer data (company id 0xFFFF):
 *   [0x3E marker][subtype][payload...]
 * Subtypes in use: 0x55 = Reticulum packet, 0x41 = APRS broadcast parcel.
 */
class Ble5(context: Context, messenger: BinaryMessenger) {
    companion object {
        private const val METHOD_CHANNEL = "com.geogram.aurora/ble5"
        private const val EVENT_CHANNEL = "com.geogram.aurora/ble5_scan"
        // GATT-client events (connected/disconnected/data) to the Dart side.
        private const val GATT_EVENT_CHANNEL = "com.geogram.aurora/ble5_gatt"
        private const val COMPANY_ID = 0xFFFF
        private const val MARKER = 0x3E.toByte()
        private const val TAG = "Ble5"
        // How long each active frame stays on air before the rotation advances.
        // Long enough for a peer's duty-cycled scan to catch it, short enough to
        // cycle a few frames within a message's TTL.
        private const val ROTATE_MS = 1200L
        // GATT parcel service (matches the ble_peripheral server + the old client).
        private val SVC_UUID  = UUID.fromString("0000ffe0-0000-1000-8000-00805f9b34fb")
        private val FFF1_UUID = UUID.fromString("0000fff1-0000-1000-8000-00805f9b34fb")
        private val FFF2_UUID = UUID.fromString("0000fff2-0000-1000-8000-00805f9b34fb")
        private val CCCD_UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")
    }

    private val appContext: Context = context.applicationContext

    private class Frame(var mfg: ByteArray, var expiresAt: Long)

    private val adapter: BluetoothAdapter? =
        (context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager)?.adapter
    private val main = Handler(Looper.getMainLooper())
    private var events: EventChannel.EventSink? = null

    private var advertisingSet: AdvertisingSet? = null
    private var advertiseCallback: AdvertisingSetCallback? = null
    private var starting = false
    private var scanner: BluetoothLeScanner? = null
    private var scanCallback: ScanCallback? = null

    // Active broadcast frames keyed by an opaque caller key (insertion-ordered for
    // a stable round-robin). All access is on the main thread.
    private val frames = LinkedHashMap<String, Frame>()
    private var rotateIdx = 0
    private var rotating = false
    private var lastHex: String? = null // last data put on air (skip redundant sets)

    // ── GATT client (native) ────────────────────────────────────────────────
    private var gatt: BluetoothGatt? = null
    private var writeChar: BluetoothGattCharacteristic? = null
    private var notifyChar: BluetoothGattCharacteristic? = null
    private var gattEvents: EventChannel.EventSink? = null

    // ── GATT server (native) ────────────────────────────────────────────────
    private var gattServer: BluetoothGattServer? = null
    private var serverNotifyChar: BluetoothGattCharacteristic? = null
    private var serverCentral: BluetoothDevice? = null
    private var legacyAdvertiser: BluetoothLeAdvertiser? = null
    private var legacyAdvCb: AdvertiseCallback? = null
    private var legacyScanner: BluetoothLeScanner? = null
    private var legacyScanCb: ScanCallback? = null
    private var serverCallsign: String = "AURORA"
    // Android GATT writes must be serialized: issue the next only after the
    // previous onCharacteristicWrite (with a watchdog fallback). Queue + pump
    // enforces that. WRITE_TYPE_NO_RESPONSE is used so the link is NOT bonded
    // (write-with-response on an unbonded link makes Android pop a pairing
    // dialog — exactly what auto-pairing must avoid).
    private val writeQueue = ArrayDeque<ByteArray>()
    private var writeBusy = false
    private var writeGen = 0

    init {
        MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler { call, result ->
            when (call.method) {
                "supported" -> result.success(isSupported())
                // Real per-frame payload cap for THIS controller: many chips
                // report far less than the BLE5 spec max (e.g. 255 vs 1650),
                // and an oversized frame is rejected, not truncated — the size
                // router must know the true ceiling or messages silently drop.
                "maxPayload" -> result.success(maxDataLen() - 8)
                "gattConnect" -> {
                    val addr = call.argument<String>("address")
                    if (addr == null) result.error("ARG", "address required", null)
                    else { gattConnect(addr); result.success(true) }
                }
                "gattWrite" -> {
                    val data = call.argument<ByteArray>("data")
                    if (data == null) result.error("ARG", "data required", null)
                    else result.success(gattWrite(data))
                }
                "gattDisconnect" -> { gattDisconnect(); result.success(true) }
                "startServer" -> {
                    val cs = call.argument<String>("callsign") ?: "AURORA"
                    result.success(startServer(cs))
                }
                "stopServer" -> { stopServer(); result.success(true) }
                "serverNotify" -> {
                    val data = call.argument<ByteArray>("data")
                    if (data == null) result.error("ARG", "data required", null)
                    else result.success(serverNotify(data))
                }
                "startLegacyScan" -> result.success(startLegacyScan())
                "stopLegacyScan" -> { stopLegacyScan(); result.success(true) }
                "advertiseFrame" -> {
                    val key = call.argument<String>("key")
                    val subtype = call.argument<Int>("subtype")
                    val data = call.argument<ByteArray>("data")
                    val ttlMs = call.argument<Int>("ttlMs") ?: 30000
                    if (key == null || subtype == null || data == null) {
                        result.error("ARG", "key/subtype/data required", null)
                    } else {
                        result.success(advertiseFrame(key, subtype, data, ttlMs.toLong()))
                    }
                }
                "removeFrame" -> {
                    val key = call.argument<String>("key")
                    if (key != null) removeFrame(key)
                    result.success(true)
                }
                "stopAdvertise" -> { stopAdvertise(); result.success(true) }
                "startScan" -> result.success(startScan())
                "stopScan" -> { stopScan(); result.success(true) }
                else -> result.notImplemented()
            }
        }
        EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, sink: EventChannel.EventSink?) {
                    events = sink
                }
                override fun onCancel(args: Any?) { events = null }
            },
        )
        EventChannel(messenger, GATT_EVENT_CHANNEL).setStreamHandler(
            object : EventChannel.StreamHandler {
                override fun onListen(args: Any?, sink: EventChannel.EventSink?) {
                    gattEvents = sink
                }
                override fun onCancel(args: Any?) { gattEvents = null }
            },
        )
    }

    private fun isSupported(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        val a = adapter ?: return false
        return a.isLeExtendedAdvertisingSupported
    }

    private fun maxDataLen(): Int {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return 31
        return adapter?.leMaximumAdvertisingDataLength ?: 31
    }

    /**
     * Register/refresh a keyed broadcast frame. It is multiplexed onto the single
     * advertising set with all other active frames and aired until [ttlMs]
     * elapses (callers refresh periodically to keep it alive).
     */
    private fun advertiseFrame(key: String, subtype: Int, payload: ByteArray, ttlMs: Long): Boolean {
        if (!isSupported()) return false
        val mfg = ByteArray(payload.size + 2)
        mfg[0] = MARKER
        mfg[1] = subtype.toByte()
        System.arraycopy(payload, 0, mfg, 2, payload.size)
        // 6 bytes of envelope overhead (length/type/company id) on top of mfg.
        if (mfg.size + 6 > maxDataLen()) {
            android.util.Log.e(TAG, "frame too large for one advert: ${mfg.size}B")
            return false
        }
        val now = System.currentTimeMillis()
        frames[key] = Frame(mfg, now + ttlMs)
        ensureRotating()
        // Air immediately so a just-sent message doesn't wait a full rotation.
        rotateTick()
        return true
    }

    private fun removeFrame(key: String) {
        frames.remove(key)
        if (frames.isEmpty()) stopAdvertise()
    }

    private fun ensureRotating() {
        if (rotating) return
        rotating = true
        main.post(rotateRunnable)
    }

    private val rotateRunnable = object : Runnable {
        override fun run() {
            if (!rotating) return
            rotateTick()
            if (frames.isEmpty()) { rotating = false; return }
            main.postDelayed(this, ROTATE_MS)
        }
    }

    /** Drop expired frames, then put the next active frame on air. */
    private fun rotateTick() {
        val now = System.currentTimeMillis()
        val it = frames.entries.iterator()
        while (it.hasNext()) {
            if (it.next().value.expiresAt <= now) it.remove()
        }
        if (frames.isEmpty()) {
            stopAdvertise()
            return
        }
        val keys = frames.keys.toList()
        if (rotateIdx >= keys.size) rotateIdx = 0
        val frame = frames[keys[rotateIdx]] ?: return
        rotateIdx = (rotateIdx + 1) % keys.size
        airData(frame.mfg)
    }

    /** Put one manufacturer-data blob on the single advertising set. */
    private fun airData(mfg: ByteArray) {
        val advertiser = adapter?.bluetoothLeAdvertiser ?: return
        val data = AdvertiseData.Builder()
            .addManufacturerData(COMPANY_ID, mfg)
            .setIncludeDeviceName(false)
            .build()
        val existing = advertisingSet
        if (existing != null) {
            val hex = mfg.joinToString("") { "%02x".format(it) }
            if (hex == lastHex) return // already on air with this exact frame
            lastHex = hex
            try { existing.setAdvertisingData(data) } catch (_: Exception) {}
            return
        }
        if (starting) return
        starting = true
        lastHex = mfg.joinToString("") { "%02x".format(it) }
        val params = AdvertisingSetParameters.Builder()
            .setLegacyMode(false)
            // NON-connectable: this extended set carries ONLY the connectionless
            // broadcast (APRS + RNS announces). GATT large-file transfer uses the
            // separate LEGACY connectable presence beacon (ble_peripheral). Android
            // permits only a limited number of connectable advertisers; a
            // connectable extended set here would starve the legacy beacon's
            // connectability, so a discovered peer's GATT connect would time out
            // (status 147). Non-connectable also frees more advert payload room.
            .setConnectable(false)
            .setScannable(false)
            .setInterval(AdvertisingSetParameters.INTERVAL_MEDIUM)
            .setTxPowerLevel(AdvertisingSetParameters.TX_POWER_HIGH)
            .setPrimaryPhy(BluetoothDevice.PHY_LE_1M)
            // Keep the AUX payload on 1M so every scanner (incl. BlueZ/Linux)
            // reliably reads it; 2M-only aux is missed by some controllers.
            .setSecondaryPhy(BluetoothDevice.PHY_LE_1M)
            .build()
        val cb = object : AdvertisingSetCallback() {
            override fun onAdvertisingSetStarted(set: AdvertisingSet?, txPower: Int, status: Int) {
                starting = false
                if (status == ADVERTISE_SUCCESS && set != null) {
                    advertisingSet = set
                } else {
                    lastHex = null
                    android.util.Log.e(TAG, "advertising set start failed status=$status")
                }
            }
        }
        advertiseCallback = cb
        try {
            advertiser.startAdvertisingSet(params, data, null, null, null, cb)
        } catch (e: Exception) {
            starting = false
            lastHex = null
            android.util.Log.e(TAG, "startAdvertisingSet: ${e.message}")
        }
    }

    private fun stopAdvertise() {
        frames.clear()
        rotating = false
        rotateIdx = 0
        lastHex = null
        val advertiser = adapter?.bluetoothLeAdvertiser
        val cb = advertiseCallback
        if (advertiser != null && cb != null) {
            try { advertiser.stopAdvertisingSet(cb) } catch (_: Exception) {}
        }
        advertisingSet = null
        advertiseCallback = null
    }

    /** Scan for extended advertisements carrying our company id; deliver every
     *  0x3E-marker frame as [subtype, payload...] so Dart demuxes by subtype. */
    private fun startScan(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return false
        val s = adapter?.bluetoothLeScanner ?: return false
        if (scanCallback != null) return true // already scanning
        val filter = ScanFilter.Builder()
            .setManufacturerData(COMPANY_ID, byteArrayOf())
            .build()
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .setLegacy(false) // receive extended advertisements
            .setPhy(ScanSettings.PHY_LE_ALL_SUPPORTED)
            .build()
        val cb = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult?) {
                val mfg = result?.scanRecord?.getManufacturerSpecificData(COMPANY_ID)
                    ?: return
                if (mfg.size < 2 || mfg[0] != MARKER) return
                val subtype = mfg[1].toInt() and 0xFF
                val payload = mfg.copyOfRange(2, mfg.size)
                val addr = result.device?.address ?: ""
                val rssi = result.rssi
                main.post {
                    events?.success(
                        mapOf(
                            "addr" to addr,
                            "rssi" to rssi,
                            "subtype" to subtype,
                            "data" to payload,
                        ),
                    )
                }
            }
        }
        scanCallback = cb
        return try {
            s.startScan(listOf(filter), settings, cb)
            scanner = s
            true
        } catch (e: Exception) {
            android.util.Log.e(TAG, "startScan: ${e.message}")
            scanCallback = null
            false
        }
    }

    private fun stopScan() {
        val cb = scanCallback ?: return
        try { scanner?.stopScan(cb) } catch (_: Exception) {}
        scanCallback = null
    }

    // ── GATT client ─────────────────────────────────────────────────────────
    // Connect to a peer's FFE0 GATT server by address (learned from the extended
    // scan), so the connectable extended advert above can serve BOTH broadcast
    // and connections — no legacy advert, no second advertiser.

    private fun emitGatt(map: Map<String, Any?>) { main.post { gattEvents?.success(map) } }

    private fun gattConnect(address: String) {
        if (gatt != null) return // one link at a time
        val dev: BluetoothDevice = try {
            adapter?.getRemoteDevice(address) ?: return
        } catch (e: Exception) {
            android.util.Log.e(TAG, "getRemoteDevice($address): ${e.message}"); return
        }
        try {
            gatt = dev.connectGatt(appContext, false, gattCb, BluetoothDevice.TRANSPORT_LE)
        } catch (e: Exception) {
            android.util.Log.e(TAG, "connectGatt: ${e.message}")
            emitGatt(mapOf("event" to "disconnected"))
        }
    }

    private fun gattWrite(data: ByteArray): Boolean {
        if (gatt == null || writeChar == null) {
            android.util.Log.e(TAG, "gattWrite: not connected"); return false
        }
        main.post { writeQueue.add(data); pumpWrites() }
        return true
    }

    // Issue one queued write WITH RESPONSE so each parcel is flow-controlled:
    // the next is sent only after onCharacteristicWrite confirms the ATT response.
    // Write-WITHOUT-response has no flow control — rapid parcels overrun the
    // controller buffer and only the first lands. With-response on the peer's
    // PLAIN (unencrypted) FFF1 does NOT trigger pairing. A watchdog advances if
    // the stack fails to call back.
    private fun pumpWrites() {
        if (writeBusy) return
        val g = gatt ?: return
        val ch = writeChar ?: return
        val data = writeQueue.removeFirstOrNull() ?: return
        writeBusy = true
        val gen = ++writeGen
        ch.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
        val ok = try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                val rc = g.writeCharacteristic(ch, data,
                    BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT)
                if (rc != BluetoothGatt.GATT_SUCCESS)
                    android.util.Log.w(TAG, "writeCharacteristic rc=$rc props=${ch.properties}")
                rc == BluetoothGatt.GATT_SUCCESS
            } else {
                @Suppress("DEPRECATION") run { ch.value = data; g.writeCharacteristic(ch) }
            }
        } catch (e: Exception) {
            android.util.Log.e(TAG, "writeCharacteristic: ${e.message}"); false
        }
        if (!ok) {
            writeBusy = false
            writeQueue.addFirst(data)
            main.postDelayed({ pumpWrites() }, 60)
        } else {
            // Watchdog: if onCharacteristicWrite never fires, advance anyway. Give a
            // with-response write longer (the ATT round-trip + peer processing).
            main.postDelayed({
                if (writeBusy && writeGen == gen) { writeBusy = false; pumpWrites() }
            }, 1500)
        }
    }

    private fun gattDisconnect() {
        val g = gatt ?: return
        try { g.disconnect() } catch (_: Exception) {}
        try { g.close() } catch (_: Exception) {}
        gatt = null
        writeChar = null
        notifyChar = null
        writeQueue.clear()
        writeBusy = false
    }

    private val gattCb = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                try { g.requestMtu(512) } catch (_: Exception) {}
                // discoverServices is kicked off after MTU (onMtuChanged); if MTU
                // request fails to call back, discover here as a fallback.
                if (Build.VERSION.SDK_INT < Build.VERSION_CODES.LOLLIPOP) g.discoverServices()
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                try { g.close() } catch (_: Exception) {}
                if (gatt === g) { gatt = null; writeChar = null }
                writeQueue.clear(); writeBusy = false
                emitGatt(mapOf("event" to "disconnected"))
            }
        }

        override fun onMtuChanged(g: BluetoothGatt, mtu: Int, status: Int) {
            android.util.Log.i(TAG, "client MTU=$mtu status=$status")
            try { g.discoverServices() } catch (_: Exception) {}
        }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            val svc = g.getService(SVC_UUID)
            val write = svc?.getCharacteristic(FFF1_UUID)
            val notify = svc?.getCharacteristic(FFF2_UUID)
            if (write == null || notify == null) {
                android.util.Log.e(TAG, "peer missing FFE0/FFF1/FFF2")
                gattDisconnect(); emitGatt(mapOf("event" to "disconnected")); return
            }
            writeChar = write
            notifyChar = notify
            android.util.Log.i(TAG, "GATT discovered FFE0 on ${g.device?.address} " +
                "fff1.props=${write.properties}")
            // Subscribe to FFF2 notifications so receipts flow back. The peer's
            // server is now NATIVE with a PLAIN (unencrypted) CCCD, so writing the
            // CCCD does NOT trigger pairing. Emit "connected" only after the CCCD
            // write completes (onDescriptorWrite) so the first parcel isn't issued
            // while the descriptor write is still pending (which bounces as BUSY).
            try {
                g.setCharacteristicNotification(notify, true)
                val cccd = notify.getDescriptor(CCCD_UUID)
                if (cccd != null) {
                    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                        g.writeDescriptor(cccd,
                            BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
                    } else {
                        @Suppress("DEPRECATION") run {
                            cccd.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                            g.writeDescriptor(cccd)
                        }
                    }
                } else {
                    emitGatt(mapOf("event" to "connected")) // no CCCD → ready anyway
                }
            } catch (e: Exception) {
                android.util.Log.e(TAG, "CCCD subscribe: ${e.message}")
                emitGatt(mapOf("event" to "connected"))
            }
        }

        override fun onDescriptorWrite(
            g: BluetoothGatt, descriptor: BluetoothGattDescriptor, status: Int,
        ) {
            if (descriptor.uuid == CCCD_UUID) {
                android.util.Log.i(TAG, "CCCD write status=$status — link ready")
                emitGatt(mapOf("event" to "connected"))
            }
        }

        @Deprecated("compat for < TIRAMISU")
        override fun onCharacteristicChanged(g: BluetoothGatt, ch: BluetoothGattCharacteristic) {
            if (ch.uuid == FFF2_UUID) {
                @Suppress("DEPRECATION")
                emitGatt(mapOf("event" to "data", "data" to (ch.value ?: ByteArray(0))))
            }
        }

        override fun onCharacteristicChanged(
            g: BluetoothGatt, ch: BluetoothGattCharacteristic, value: ByteArray,
        ) {
            if (ch.uuid == FFF2_UUID) emitGatt(mapOf("event" to "data", "data" to value))
        }

        override fun onCharacteristicWrite(
            g: BluetoothGatt, ch: BluetoothGattCharacteristic, status: Int,
        ) {
            if (status != BluetoothGatt.GATT_SUCCESS)
                android.util.Log.w(TAG, "onCharacteristicWrite status=$status")
            // Previous write finished — release the lock and issue the next.
            main.post { writeBusy = false; pumpWrites() }
        }
    }

    // ── GATT server (native) ────────────────────────────────────────────────
    // A single coordinated native server is what makes dual-role reliable: the
    // two-plugin approach (ble_peripheral server + bluetooth_low_energy client)
    // confused Android's per-device GATT handle cache so only the first write
    // landed and notify failed with "Device not found". Plain (unencrypted)
    // characteristics mean no pairing dialog.

    private fun startServer(callsign: String): Boolean {
        serverCallsign = if (callsign.isEmpty()) "AURORA" else callsign
        val mgr = appContext.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
            ?: return false
        if (gattServer == null) {
            val server = try { mgr.openGattServer(appContext, gattServerCb) } catch (e: Exception) {
                android.util.Log.e(TAG, "openGattServer: ${e.message}"); null
            } ?: return false
            val svc = BluetoothGattService(SVC_UUID, BluetoothGattService.SERVICE_TYPE_PRIMARY)
            val fff1 = BluetoothGattCharacteristic(
                FFF1_UUID,
                BluetoothGattCharacteristic.PROPERTY_WRITE or
                    BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE,
                BluetoothGattCharacteristic.PERMISSION_WRITE, // PLAIN — no encryption
            )
            val fff2 = BluetoothGattCharacteristic(
                FFF2_UUID,
                BluetoothGattCharacteristic.PROPERTY_NOTIFY or
                    BluetoothGattCharacteristic.PROPERTY_READ,
                BluetoothGattCharacteristic.PERMISSION_READ,
            )
            val cccd = BluetoothGattDescriptor(
                CCCD_UUID,
                BluetoothGattDescriptor.PERMISSION_READ or
                    BluetoothGattDescriptor.PERMISSION_WRITE, // PLAIN — no encryption
            )
            fff2.addDescriptor(cccd)
            svc.addCharacteristic(fff1)
            svc.addCharacteristic(fff2)
            try { server.addService(svc) } catch (e: Exception) {
                android.util.Log.e(TAG, "addService: ${e.message}")
            }
            gattServer = server
            serverNotifyChar = fff2
        }
        startLegacyAdvert()
        startLegacyScan()
        return true
    }

    private fun stopServer() {
        stopLegacyAdvert()
        try { gattServer?.close() } catch (_: Exception) {}
        gattServer = null
        serverNotifyChar = null
        serverCentral = null
    }

    private val gattServerCb = object : BluetoothGattServerCallback() {
        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                serverCentral = device
                emitGatt(mapOf("event" to "server_connected", "address" to device.address))
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                if (serverCentral?.address == device.address) serverCentral = null
                emitGatt(mapOf("event" to "server_disconnected", "address" to device.address))
            }
        }

        override fun onMtuChanged(device: BluetoothDevice, mtu: Int) {
            android.util.Log.i(TAG, "server MTU=$mtu (${device.address})")
        }

        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice, requestId: Int, ch: BluetoothGattCharacteristic,
            preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray,
        ) {
            if (ch.uuid == FFF1_UUID) {
                serverCentral = device
                emitGatt(mapOf("event" to "server_data", "address" to device.address,
                    "data" to value))
            }
            if (responseNeeded) {
                try {
                    gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS,
                        offset, value)
                } catch (_: Exception) {}
            }
        }

        override fun onDescriptorWriteRequest(
            device: BluetoothDevice, requestId: Int, descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray,
        ) {
            // CCCD subscription from a central — just acknowledge (plain, no auth).
            if (responseNeeded) {
                try {
                    gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS,
                        offset, value)
                } catch (_: Exception) {}
            }
        }
    }

    /** Notify the connected central on FFF2 (receipts / reverse-direction data). */
    private fun serverNotify(data: ByteArray): Boolean {
        val server = gattServer ?: return false
        val ch = serverNotifyChar ?: return false
        val dev = serverCentral ?: return false
        return try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                server.notifyCharacteristicChanged(dev, ch, false, data)
                    .let { it == BluetoothStatusOk }
            } else {
                @Suppress("DEPRECATION") run {
                    ch.value = data
                    server.notifyCharacteristicChanged(dev, ch, false)
                }
            }
        } catch (e: Exception) {
            android.util.Log.e(TAG, "serverNotify: ${e.message}"); false
        }
    }

    private val BluetoothStatusOk: Int
        get() = android.bluetooth.BluetoothStatusCodes.SUCCESS

    // ── Legacy connectable presence beacon + discovery scan ─────────────────
    // The GATT path uses a LEGACY connectable advert (separate from the extended
    // broadcast set) so peers can discover and connect. Beacon manufacturer data:
    // [0x3E, deviceId(1..15), callsign...] — the geogram presence format.

    private fun startLegacyAdvert() {
        val advertiser = adapter?.bluetoothLeAdvertiser ?: return
        stopLegacyAdvert()
        val cs = serverCallsign.take(6)
        val csBytes = cs.toByteArray(Charsets.UTF_8)
        val mfg = ByteArray(2 + csBytes.size)
        mfg[0] = MARKER
        mfg[1] = deviceId(serverCallsign).toByte()
        System.arraycopy(csBytes, 0, mfg, 2, csBytes.size)
        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_HIGH)
            .setConnectable(true)
            .build()
        val data = AdvertiseData.Builder()
            .addManufacturerData(COMPANY_ID, mfg)
            .setIncludeDeviceName(false)
            .build()
        val cb = object : AdvertiseCallback() {
            override fun onStartFailure(errorCode: Int) {
                android.util.Log.e(TAG, "legacy advert failed: $errorCode")
            }
        }
        legacyAdvCb = cb
        legacyAdvertiser = advertiser
        try { advertiser.startAdvertising(settings, data, cb) } catch (e: Exception) {
            android.util.Log.e(TAG, "startAdvertising: ${e.message}")
        }
    }

    private fun stopLegacyAdvert() {
        val a = legacyAdvertiser ?: return
        val cb = legacyAdvCb ?: return
        try { a.stopAdvertising(cb) } catch (_: Exception) {}
        legacyAdvCb = null
    }

    /** Legacy scan for peers' connectable presence beacons → emit "discovered". */
    private fun startLegacyScan(): Boolean {
        val s = adapter?.bluetoothLeScanner ?: return false
        if (legacyScanCb != null) return true
        val filter = ScanFilter.Builder()
            .setManufacturerData(COMPANY_ID, byteArrayOf())
            .build()
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .build()
        val cb = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult?) {
                val mfg = result?.scanRecord?.getManufacturerSpecificData(COMPANY_ID) ?: return
                // Presence beacon: [0x3E, deviceId 1..15, callsign...].
                if (mfg.size < 3 || mfg[0] != MARKER) return
                val id = mfg[1].toInt() and 0xFF
                if (id < 1 || id > 15) return
                val callsign = String(mfg, 2, mfg.size - 2, Charsets.UTF_8).trim()
                val addr = result.device?.address ?: return
                main.post {
                    gattEvents?.success(mapOf(
                        "event" to "discovered", "address" to addr, "callsign" to callsign))
                }
            }
        }
        legacyScanCb = cb
        legacyScanner = s
        return try {
            s.startScan(listOf(filter), settings, cb); true
        } catch (e: Exception) {
            android.util.Log.e(TAG, "legacy startScan: ${e.message}"); legacyScanCb = null; false
        }
    }

    private fun stopLegacyScan() {
        val cb = legacyScanCb ?: return
        try { legacyScanner?.stopScan(cb) } catch (_: Exception) {}
        legacyScanCb = null
    }

    // Small non-zero device id (1..15) from the callsign — matches the Dart
    // BleGattServer scheme (FNV-1a, value need only be stable, not unique).
    private fun deviceId(cs: String): Int {
        var h = 2166136261L
        for (b in cs.toByteArray(Charsets.UTF_8)) {
            h = (h xor (b.toLong() and 0xFF)) * 16777619L and 0xffffffffL
        }
        return (h % 15).toInt() + 1
    }
}
