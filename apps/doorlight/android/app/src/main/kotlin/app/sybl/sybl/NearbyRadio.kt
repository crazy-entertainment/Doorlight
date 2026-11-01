package app.sybl.sybl

import android.Manifest
import android.annotation.SuppressLint
import android.app.Activity
import android.bluetooth.*
import android.bluetooth.le.*
import android.content.pm.PackageManager
import android.net.wifi.WifiManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.os.SystemClock
import android.util.Log
import com.google.android.gms.nearby.Nearby
import com.google.android.gms.nearby.connection.*
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodChannel
import java.util.UUID
import java.util.concurrent.atomic.AtomicInteger

@SuppressLint("MissingPermission")
class NearbyRadio(private val activity: Activity, messenger: BinaryMessenger) {
    companion object {
        private val SERVICE = UUID.fromString("6a5ed9b0-067d-4f88-b27c-5f3f45239ef0")
        private val ANNOUNCEMENT = UUID.fromString("6a5ed9b1-067d-4f88-b27c-5f3f45239ef0")
        private val EVENT = UUID.fromString("6a5ed9b2-067d-4f88-b27c-5f3f45239ef0")
        private const val GOOGLE_SERVICE = "app.sybl.sybl.sonar.v1"
        private const val PERMISSION_REQUEST = 17431
    }
    private val handler = Handler(Looper.getMainLooper())
    private val channel = MethodChannel(messenger, "syb.l/nearby_radio")
    private val events = EventChannel(messenger, "syb.l/nearby_radio_events")
    private var sink: EventChannel.EventSink? = null
    private val ingress = AtomicInteger()
    private val manager = activity.getSystemService(BluetoothManager::class.java)
    private val adapter get() = manager?.adapter
    private val googleClient = lazy { Nearby.getConnectionsClient(activity) }
    private val google by googleClient
    private var running = false
    private var visible = false
    private var generation = 0
    private var revealGeneration = 0
    private var sequence = 0
    private var permissionPending = false
    private var permissionAttempted = false
    private var permissionRevealBlocked = false
    private val announcements = NearbyRadioAnnouncements()
    private val serverMtus = linkedMapOf<String, Int>()
    private var event = byteArrayOf()
    private var eventExpires = 0L
    private var scanner: BluetoothLeScanner? = null
    private var scanCallback: ScanCallback? = null
    private var advertiser: BluetoothLeAdvertiser? = null
    private var advertiseCallback: AdvertiseCallback? = null
    private var server: BluetoothGattServer? = null
    private var googleStarted = false
    private var googleAllowed = false
    private val googleStarts = NearbyRadioStarts()
    private val endpoints = linkedSetOf<String>()
    private val connected = linkedSetOf<String>()
    private val pendingDeadlines = linkedMapOf<String, Long>()
    private data class Candidate(val device: BluetoothDevice, var seen: Long, var nextAttempt: Long = 0)
    private val candidates = linkedMapOf<String, Candidate>()
    private val peers = linkedMapOf<String, Peer>()
    private data class ReadSnapshot(val frame: ByteArray, val expires: Long)
    private val snapshots = linkedMapOf<String, ReadSnapshot>()

    init {
        events.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, eventSink: EventChannel.EventSink) { sink = eventSink }
            override fun onCancel(arguments: Any?) { stop(); sink = null }
        })
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    googleAllowed = call.argument<Boolean>("googleAllowed") == true
                    if (!googleAllowed) stopGoogle()
                    result.success(start())
                }
                "setGoogleAllowed" -> {
                    googleAllowed = call.argument<Boolean>("enabled") == true
                    if (!googleAllowed) stopGoogle()
                    // Consent never reveals the device or starts discovery by itself.
                    result.success(true)
                }
                "send" -> {
                    val data = call.argument<ByteArray>("data")
                    val kind = call.argument<String>("kind")
                    result.success(if (data == null || kind == null) false else send(data, kind))
                }
                "stop" -> { stop(); result.success(null) }
                else -> result.notImplemented()
            }
        }
    }

    // Bound Binder/SDK callbacks before they enter the main-thread queue.
    private fun dispatch(block: () -> Unit) {
        if (ingress.incrementAndGet() > 128) { ingress.decrementAndGet(); return }
        handler.post { try { block() } finally { ingress.decrementAndGet() } }
    }
    private fun emit(source: String, bytes: ByteArray) {
        if (running && NearbyRadioFrame.valid(bytes)) sink?.success(mapOf("source" to source, "frame" to bytes))
    }
    private fun permissions(): Array<String> = buildList {
        if (Build.VERSION.SDK_INT >= 31) {
            add(Manifest.permission.BLUETOOTH_SCAN)
            add(Manifest.permission.BLUETOOTH_CONNECT)
            add(Manifest.permission.BLUETOOTH_ADVERTISE)
        }
        if (Build.VERSION.SDK_INT <= 32) {
            add(Manifest.permission.ACCESS_COARSE_LOCATION)
            add(Manifest.permission.ACCESS_FINE_LOCATION)
        }
        if (Build.VERSION.SDK_INT >= 33) add(Manifest.permission.NEARBY_WIFI_DEVICES)
        if (Build.VERSION.SDK_INT >= 37 && activity.applicationInfo.targetSdkVersion >= 37)
            add("android.permission.ACCESS_LOCAL_NETWORK")
    }.toTypedArray()
    private fun allowed() = permissions().all { activity.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED }
    private fun bleAllowed(advertise: Boolean) = (if (Build.VERSION.SDK_INT >= 31) buildList {
        add(Manifest.permission.BLUETOOTH_SCAN); add(Manifest.permission.BLUETOOTH_CONNECT)
        if (advertise) add(Manifest.permission.BLUETOOTH_ADVERTISE)
    } else listOf(Manifest.permission.ACCESS_FINE_LOCATION)).all {
        activity.checkSelfPermission(it) == PackageManager.PERMISSION_GRANTED
    }
    fun onRequestPermissionsResult(requestCode: Int): Boolean {
        if (requestCode != PERMISSION_REQUEST) return false
        permissionPending = false
        // Permission UI pauses the activity: a fresh deliberate reveal is required.
        return true
    }
    private fun start(): Boolean {
        if (!permissionPending) permissionRevealBlocked = false
        if (!running) { running = true; generation++; handler.post(tick) }
        startScan()
        return true
    }
    private fun send(data: ByteArray, kind: String): Boolean {
        if (kind == "bye") { hide(); return true }
        if (!running || data.size !in 1..NearbyRadioFrame.MAX_DATA || kind !in setOf("announce", "ping", "missile")) return false
        if (permissionRevealBlocked) return false
        if (!allowed() && !permissionAttempted) {
            if (kind in setOf("announce", "ping") && !permissionPending) {
                permissionPending = true
                permissionAttempted = true
                permissionRevealBlocked = true
                sink?.success(mapOf("permissionRequired" to true))
                try { activity.requestPermissions(permissions(), PERMISSION_REQUEST) }
                catch (_: RuntimeException) { permissionPending = false }
            }
            return false
        }
        if (!bleAllowed(true) && !allowed()) return false
        if (kind == "missile" && !visible) return false
        val frame = NearbyRadioFrame.encode(++sequence, data)
        if (kind == "announce" || kind == "ping") {
            announcements.put(frame, kind == "ping", SystemClock.elapsedRealtime())
            if (!visible) {
                visible = true; revealGeneration++
                if (bleAllowed(true)) startServer()
                if (allowed()) startGoogle()
            }
            startScan()
        } else { event = frame; eventExpires = SystemClock.elapsedRealtime() + 4000 }
        if (googleStarted && connected.isNotEmpty()) {
            try { google.sendPayload(connected.toList(), Payload.fromBytes(frame)) } catch (_: RuntimeException) {}
        }
        return server != null || googleStarted
    }
    private val tick = object : Runnable {
        override fun run() {
            if (!running) return
            if (googleStarted && !googleRadiosEnabled()) stopGoogle()
            val now = SystemClock.elapsedRealtime()
            if (eventExpires != 0L && now >= eventExpires) { event = byteArrayOf(); eventExpires = 0L }
            pendingDeadlines.filterValues { now >= it }.keys.toList().forEach { id ->
                pendingDeadlines.remove(id); endpoints.remove(id)
                if (googleStarted) try { google.disconnectFromEndpoint(id) } catch (_: RuntimeException) {}
            }
            candidates.entries.removeAll { now - it.value.seen > 6000 && it.key !in peers }
            peers.values.toList().forEach { peer ->
                if (peer.deadline != 0L && now >= peer.deadline) drop(peer)
                else if (peer.ready && peer.deadline == 0L && now >= peer.nextRead) read(peer)
            }
            candidates.entries.toList().forEach { (address, candidate) ->
                if (peers.size < 4 && address !in peers && now >= candidate.nextAttempt && now - candidate.seen <= 6000) {
                    candidate.nextAttempt = now + 6000
                    connect(candidate.device, address)
                }
            }
            handler.postDelayed(this, 100)
        }
    }
    private fun startScan() {
        if (!running || scanCallback != null || !bleAllowed(false)) return
        val current = generation
        val callback = object : ScanCallback() {
            override fun onScanResult(callbackType: Int, result: ScanResult) {
                val device = result.device
                dispatch {
                    if (!running || current != generation) return@dispatch
                    val address = try { device.address } catch (_: RuntimeException) { return@dispatch }
                    val now = SystemClock.elapsedRealtime()
                    candidates[address]?.let { it.seen = now; return@dispatch }
                    candidates.entries.removeAll { now - it.value.seen > 6000 && it.key !in peers }
                    if (candidates.size < 64) candidates[address] = Candidate(device, now)
                }
            }
            override fun onScanFailed(errorCode: Int) { dispatch {
                Log.w("DoorlightNearby", "scan_failed $errorCode")
                if (current == generation && scanCallback === this) { scanCallback = null; scanner = null }
            } }
        }
        try {
            val radio = adapter?.bluetoothLeScanner ?: return
            scanner = radio; scanCallback = callback
            radio.startScan(listOf(ScanFilter.Builder().setServiceUuid(ParcelUuid(SERVICE)).build()),
                ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_POWER).build(), callback)
            Log.i("DoorlightNearby", "scan_started")
        } catch (_: RuntimeException) {
            Log.w("DoorlightNearby", "scan_exception")
            scanner = null; scanCallback = null
        }
    }
    private inner class Peer(val address: String, val epoch: Int) {
        var gatt: BluetoothGatt? = null
        var ready = false
        var deadline = SystemClock.elapsedRealtime() + 4000
        var nextRead = 0L
        var readingEvent = false
        var announce: BluetoothGattCharacteristic? = null
        var event: BluetoothGattCharacteristic? = null
        fun active(gatt: BluetoothGatt) = running && epoch == generation && peers[address] === this && this.gatt === gatt
    }
    private fun connect(device: BluetoothDevice, address: String) {
        val peer = Peer(address, generation)
        peers[address] = peer
        val callback = object : BluetoothGattCallback() {
            override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) { dispatch {
                Log.i("DoorlightNearby", "connection $status $newState")
                if (!peer.active(gatt)) return@dispatch
                if (status != BluetoothGatt.GATT_SUCCESS || newState == BluetoothProfile.STATE_DISCONNECTED) { drop(peer); return@dispatch }
                if (newState == BluetoothProfile.STATE_CONNECTED) {
                    try { if (!gatt.requestMtu(517)) discover(peer, gatt) } catch (_: RuntimeException) { drop(peer) }
                }
            } }
            override fun onMtuChanged(gatt: BluetoothGatt, mtu: Int, status: Int) { dispatch {
                if (peer.active(gatt)) discover(peer, gatt)
            } }
            override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) { dispatch {
                Log.i("DoorlightNearby", "services $status")
                if (!peer.active(gatt)) return@dispatch
                val service = gatt.getService(SERVICE)
                peer.announce = service?.getCharacteristic(ANNOUNCEMENT)
                peer.event = service?.getCharacteristic(EVENT)
                if (status != BluetoothGatt.GATT_SUCCESS || listOf(peer.announce, peer.event).any {
                    it == null || it.properties and BluetoothGattCharacteristic.PROPERTY_READ == 0
                }) { drop(peer); return@dispatch }
                peer.ready = true; peer.deadline = 0L
            } }
            @Deprecated("Legacy callback required before API 33")
            override fun onCharacteristicRead(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, status: Int) {
                if (Build.VERSION.SDK_INT < 33) received(gatt, characteristic.uuid, characteristic.value ?: byteArrayOf(), status)
            }
            override fun onCharacteristicRead(gatt: BluetoothGatt, characteristic: BluetoothGattCharacteristic, value: ByteArray, status: Int) {
                received(gatt, characteristic.uuid, value, status)
            }
            private fun received(gatt: BluetoothGatt, uuid: UUID, value: ByteArray, status: Int) {
                if (value.size > 512) { dispatch { if (peer.active(gatt)) drop(peer) }; return }
                val frame = value.copyOf()
                dispatch {
                    if (!peer.active(gatt)) return@dispatch
                    val expected = if (peer.readingEvent) EVENT else ANNOUNCEMENT
                    if (status != BluetoothGatt.GATT_SUCCESS || uuid != expected) { drop(peer); return@dispatch }
                    emit("ble:${peer.address}", frame)
                    peer.deadline = 0L
                    peer.nextRead = SystemClock.elapsedRealtime() + if (peer.readingEvent) 750 else 50
                    peer.readingEvent = !peer.readingEvent
                }
            }
        }
        try {
            peer.gatt = device.connectGatt(activity, false, callback, BluetoothDevice.TRANSPORT_LE)
            if (peer.gatt == null) drop(peer)
        } catch (_: RuntimeException) { drop(peer) }
    }
    private fun discover(peer: Peer, gatt: BluetoothGatt) {
        peer.deadline = SystemClock.elapsedRealtime() + 4000
        try { if (!gatt.discoverServices()) drop(peer) } catch (_: RuntimeException) { drop(peer) }
    }
    private fun read(peer: Peer) {
        val characteristic = if (peer.readingEvent) peer.event else peer.announce
        peer.deadline = SystemClock.elapsedRealtime() + 4000
        try { if (characteristic == null || peer.gatt?.readCharacteristic(characteristic) != true) drop(peer) }
        catch (_: RuntimeException) { drop(peer) }
    }
    private fun drop(peer: Peer) {
        if (peers[peer.address] !== peer) return
        peers.remove(peer.address)
        candidates[peer.address]?.nextAttempt = SystemClock.elapsedRealtime() + 6000
        try { peer.gatt?.disconnect() } catch (_: RuntimeException) {}
        try { peer.gatt?.close() } catch (_: RuntimeException) {}
        peer.gatt = null
    }

    private fun startServer() {
        val epoch = revealGeneration
        try {
            val callback = object : BluetoothGattServerCallback() {
                override fun onMtuChanged(device: BluetoothDevice, mtu: Int) { dispatch {
                    if (!visible || epoch != revealGeneration) return@dispatch
                    if (device.address in serverMtus || serverMtus.size < 64) serverMtus[device.address] = mtu.coerceIn(23, 517)
                } }
                override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) { dispatch {
                    if (epoch == revealGeneration && newState == BluetoothProfile.STATE_DISCONNECTED) serverMtus.remove(device.address)
                } }

                override fun onServiceAdded(status: Int, service: BluetoothGattService) { dispatch {
                    Log.i("DoorlightNearby", "server_added $status")
                    if (!visible || epoch != revealGeneration || server == null) return@dispatch
                    if (status == BluetoothGatt.GATT_SUCCESS) startAdvertising(epoch)
                    else closeServer()
                } }
                override fun onCharacteristicReadRequest(device: BluetoothDevice, requestId: Int, offset: Int, characteristic: BluetoothGattCharacteristic) { dispatch {
                    if (!visible || epoch != revealGeneration) return@dispatch
                    val uuid = characteristic.uuid
                    if (uuid != ANNOUNCEMENT && uuid != EVENT) return@dispatch
                    val now = SystemClock.elapsedRealtime()
                    snapshots.entries.removeAll { it.value.expires <= now }
                    val key = "${device.address}:$uuid"
                    if (offset == 0) {
                        if (snapshots.size >= 64 && key !in snapshots) return@dispatch
                        val frame = if (uuid == ANNOUNCEMENT) {
                            // Unknown clients beyond the bounded MTU cache retain ordinary presence.
                            if (device.address !in serverMtus && serverMtus.size < 64) serverMtus[device.address] = 23
                            if (device.address in serverMtus) announcements.read("ble:${device.address}", now) else announcements.latest
                        } else if (now < eventExpires) event else byteArrayOf()
                        snapshots[key] = ReadSnapshot(frame, if (uuid == EVENT && frame.isNotEmpty()) eventExpires else minOf(now + 4000, announcements.deadline(frame)))
                    }
                    val frame = snapshots[key]?.frame
                    val valid = frame != null && offset in 0..frame.size
                    try {
                        val accepted = server?.sendResponse(device, requestId,
                            if (valid) BluetoothGatt.GATT_SUCCESS else BluetoothGatt.GATT_INVALID_OFFSET,
                            offset, if (valid) frame!!.copyOfRange(offset, frame.size) else null) == true
                        val mtu = serverMtus[device.address] ?: 23
                        if (valid && uuid == ANNOUNCEMENT) {
                            announcements.servedRead("ble:${device.address}", frame!!, offset, mtu, accepted, now)
                        }
                    }
                    catch (_: RuntimeException) {}
                } }
                override fun onCharacteristicWriteRequest(device: BluetoothDevice, requestId: Int, characteristic: BluetoothGattCharacteristic, preparedWrite: Boolean, responseNeeded: Boolean, offset: Int, value: ByteArray) {
                    if (responseNeeded) dispatch {
                        if (visible && epoch == revealGeneration) try {
                            server?.sendResponse(device, requestId, BluetoothGatt.GATT_WRITE_NOT_PERMITTED, offset, null)
                        } catch (_: RuntimeException) {}
                    }
                }
            }
            val opened = manager?.openGattServer(activity, callback) ?: return
            server = opened
            val service = BluetoothGattService(SERVICE, BluetoothGattService.SERVICE_TYPE_PRIMARY)
            for (uuid in listOf(ANNOUNCEMENT, EVENT)) service.addCharacteristic(BluetoothGattCharacteristic(uuid,
                BluetoothGattCharacteristic.PROPERTY_READ, BluetoothGattCharacteristic.PERMISSION_READ))
            if (!opened.addService(service)) closeServer()
        } catch (_: RuntimeException) { closeServer() }
    }
    private fun startAdvertising(epoch: Int) {
        try {
            val radio = adapter?.bluetoothLeAdvertiser ?: return
            val callback = object : AdvertiseCallback() {
                override fun onStartSuccess(settingsInEffect: AdvertiseSettings) {
                    Log.i("DoorlightNearby", "advertising_started")
                }
                override fun onStartFailure(errorCode: Int) { dispatch {
                    Log.w("DoorlightNearby", "advertising_failed $errorCode")
                    if (epoch == revealGeneration) { advertiseCallback = null; advertiser = null; closeServer() }
                } }
            }
            advertiseCallback = callback; advertiser = radio
            radio.startAdvertising(AdvertiseSettings.Builder().setConnectable(true)
                .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_POWER).setTimeout(0).build(),
                AdvertiseData.Builder().addServiceUuid(ParcelUuid(SERVICE)).setIncludeDeviceName(false).build(), callback)
        } catch (_: RuntimeException) { closeServer() }
    }
    private fun closeServer() {
        try { advertiseCallback?.let { advertiser?.stopAdvertising(it) } } catch (_: RuntimeException) {}
        advertiseCallback = null; advertiser = null
        try { server?.close() } catch (_: RuntimeException) {}
        server = null; snapshots.clear()
    }

    private fun googleRadiosEnabled(): Boolean = try {
        activity.applicationContext.getSystemService(WifiManager::class.java)?.isWifiEnabled == true &&
            adapter?.isEnabled == true
    } catch (_: RuntimeException) { false }

    private fun startGoogle() {
        // Older Play services enable disabled radios; use direct BLE when Wi-Fi is off.
        if (!googleAllowed || googleStarts.pending != 0 || !googleRadiosEnabled()) return
        val epoch = revealGeneration
        fun active() = googleAllowed && running && visible && revealGeneration == epoch && googleStarted && googleRadiosEnabled()
        val payloads = object : PayloadCallback() {
            override fun onPayloadReceived(endpointId: String, payload: Payload) {
                if (payload.type != Payload.Type.BYTES) return
                val bytes = payload.asBytes() ?: return
                if (!NearbyRadioFrame.valid(bytes)) return
                val frame = bytes.copyOf()
                dispatch { if (active() && endpointId in connected) emit("google:$endpointId", frame) }
            }
            override fun onPayloadTransferUpdate(endpointId: String, update: PayloadTransferUpdate) {}
        }
        val lifecycle = object : ConnectionLifecycleCallback() {
            override fun onConnectionInitiated(endpointId: String, info: ConnectionInfo) { dispatch {
                if (!active() || (endpointId !in endpoints && endpoints.size >= 8)) {
                    try { google.rejectConnection(endpointId) } catch (_: RuntimeException) {}
                    return@dispatch
                }
                endpoints.add(endpointId)
                pendingDeadlines[endpointId] = SystemClock.elapsedRealtime() + 4000
                try { google.acceptConnection(endpointId, payloads).addOnFailureListener {
                    dispatch { if (active()) { endpoints.remove(endpointId); connected.remove(endpointId); pendingDeadlines.remove(endpointId) } }
                } } catch (_: RuntimeException) { endpoints.remove(endpointId); pendingDeadlines.remove(endpointId) }
            } }
            override fun onConnectionResult(endpointId: String, resolution: ConnectionResolution) { dispatch {
                if (!active()) {
                    if (!visible || !running) try { google.disconnectFromEndpoint(endpointId) } catch (_: RuntimeException) {}
                    return@dispatch
                }
                pendingDeadlines.remove(endpointId)
                if (!resolution.status.isSuccess || endpointId !in endpoints) {
                    endpoints.remove(endpointId); connected.remove(endpointId); return@dispatch
                }
                connected.add(endpointId)
                try {
                    val now = SystemClock.elapsedRealtime()
                    val frame = announcements.read("google:$endpointId", now)
                    if (frame.isNotEmpty()) {
                        google.sendPayload(endpointId, Payload.fromBytes(frame))
                        announcements.served("google:$endpointId", frame, now)
                    }
                    if (announcements.latest.isNotEmpty() && !announcements.latest.contentEquals(frame)) {
                        google.sendPayload(endpointId, Payload.fromBytes(announcements.latest))
                    }
                }
                catch (_: RuntimeException) {}
            } }
            override fun onDisconnected(endpointId: String) { dispatch {
                if (active()) { endpoints.remove(endpointId); connected.remove(endpointId); pendingDeadlines.remove(endpointId) }
            } }
        }
        val discovery = object : EndpointDiscoveryCallback() {
            override fun onEndpointFound(endpointId: String, info: DiscoveredEndpointInfo) { dispatch {
                if (!active() || info.serviceId != GOOGLE_SERVICE || endpointId in endpoints || endpoints.size >= 8) return@dispatch
                endpoints.add(endpointId)
                pendingDeadlines[endpointId] = SystemClock.elapsedRealtime() + 4000
                try { google.requestConnection("Doorlight", endpointId, lifecycle).addOnFailureListener {
                    dispatch { if (active()) { endpoints.remove(endpointId); pendingDeadlines.remove(endpointId) } }
                } } catch (_: RuntimeException) { endpoints.remove(endpointId); pendingDeadlines.remove(endpointId) }
            } }
            override fun onEndpointLost(endpointId: String) {}
        }
        try {
            googleStarted = true
            googleStarts.begin()
            val advertising = google.startAdvertising("Doorlight", GOOGLE_SERVICE, lifecycle,
                AdvertisingOptions.Builder().setStrategy(Strategy.P2P_CLUSTER).build())
            googleStarts.submitted()
            advertising.addOnCompleteListener { task -> handler.post { googleStartFinished(epoch, task.isSuccessful) } }
            val discoveryTask = google.startDiscovery(GOOGLE_SERVICE, discovery,
                DiscoveryOptions.Builder().setStrategy(Strategy.P2P_CLUSTER).build())
            googleStarts.submitted()
            discoveryTask.addOnCompleteListener { task -> handler.post { googleStartFinished(epoch, task.isSuccessful) } }
        } catch (_: RuntimeException) { googleStarts.fail(); stopGoogle() }
    }
    private fun googleStartFinished(epoch: Int, success: Boolean) {
        val current = epoch == revealGeneration && visible && running && googleStarted && googleRadiosEnabled()
        if (googleStarts.finished(success, current)) stopGoogle()
        if (googleStarts.pending != 0) return
        if (googleStarts.failed || !current) {
            stopGoogle()
            // A new reveal waits for all old starts and their cleanup before using the same SDK client.
            if (epoch != revealGeneration && visible && running && allowed()) startGoogle()
        }
    }
    private fun stopGoogle() {
        if (googleClient.isInitialized()) {
            googleStarted = false
            try { google.stopAdvertising() } catch (_: RuntimeException) {}
            try { google.stopDiscovery() } catch (_: RuntimeException) {}
            try { google.stopAllEndpoints() } catch (_: RuntimeException) {}
        }
        endpoints.clear(); connected.clear(); pendingDeadlines.clear()
    }
    private fun hide() {
        permissionRevealBlocked = false
        visible = false; revealGeneration++
        announcements.clear(); serverMtus.clear(); event = byteArrayOf(); eventExpires = 0L
        closeServer(); stopGoogle()
    }
    fun stop() {
        running = false; generation++
        handler.removeCallbacks(tick)
        hide()
        try { scanCallback?.let { scanner?.stopScan(it) } } catch (_: RuntimeException) {}
        scanCallback = null; scanner = null
        peers.values.toList().forEach { drop(it) }
        candidates.clear()
    }
    fun close() {
        stop(); sink = null
        channel.setMethodCallHandler(null); events.setStreamHandler(null)
    }
}
