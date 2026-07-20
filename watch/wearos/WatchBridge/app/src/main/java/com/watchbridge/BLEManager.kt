package com.watchbridge

import android.Manifest
import android.bluetooth.*
import android.bluetooth.le.*
import android.content.BroadcastReceiver
import android.content.Context
import android.content.IntentFilter
import android.content.pm.PackageManager
import androidx.core.content.IntentCompat
import android.os.Build
import android.os.ParcelUuid
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.core.app.ActivityCompat
import java.util.*
import org.json.JSONObject
import android.content.Intent
import android.provider.Settings
import android.hardware.Sensor
import android.hardware.SensorEvent
import android.hardware.SensorEventListener
import android.hardware.SensorManager

class BLEManager private constructor(private val context: Context) {
    private val bluetoothManager: BluetoothManager? = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
    private var bluetoothAdapter: BluetoothAdapter? = bluetoothManager?.adapter
    private var bluetoothLeScanner: BluetoothLeScanner? = bluetoothAdapter?.bluetoothLeScanner
    private var bluetoothGatt: BluetoothGatt? = null
    private var advertiser: BluetoothLeAdvertiser? = bluetoothAdapter?.bluetoothLeAdvertiser
    private var gattServer: BluetoothGattServer? = null
    private val keepAliveHandler = Handler(Looper.getMainLooper())
    private var keepAliveRunnable: Runnable? = null
    private var sensorManager: SensorManager? = null
    private var heartRateSensor: Sensor? = null
    private var heartListener: SensorEventListener? = null
    private var lastHrSentMs: Long = 0

    // WatchBridge service + characteristics (must match iOS)
    private val serviceUUID = UUID.fromString("A8B01C3E-4D5F-6A7B-8C9D-0E1F2A3B4C5D")
    private val notificationCharUUID = UUID.fromString("0000FF01-0000-1000-8000-00805F9B34FB")
    private val callCharUUID = UUID.fromString("0000FF02-0000-1000-8000-00805F9B34FB")
    private val healthCharUUID = UUID.fromString("0000FF03-0000-1000-8000-00805F9B34FB")
    private val mediaCharUUID = UUID.fromString("0000FF04-0000-1000-8000-00805F9B34FB")
    private val contactsCharUUID = UUID.fromString("0000FF05-0000-1000-8000-00805F9B34FB")
    private val findDeviceCharUUID = UUID.fromString("0000FF06-0000-1000-8000-00805F9B34FB")
    private val controlCharUUID = UUID.fromString("0000FF07-0000-1000-8000-00805F9B34FB")

    var isConnected = false
    var connectionCallback: ((Boolean) -> Unit)? = null
    private var clientConnecting = false
    private var isServerConnected = false // Track GATT server state
    private var connectedDevice: BluetoothDevice? = null
    private var bondReceiver: BroadcastReceiver? = null

    // ANCS (iPhone notification/call mirroring) — active only once bonded.
    private var ancsClient: AncsClient? = null
    private var notificationForwarder: NotificationForwarder? = null
    /** App identifiers (iOS bundle IDs) the user has muted; pushed from the phone. */
    @Volatile var blockedApps: Set<String> = emptySet()

    companion object {
        private const val TAG = "BLEManager"
        
        @Volatile private var INSTANCE: BLEManager? = null
        
        fun getInstance(context: Context): BLEManager {
            return INSTANCE ?: synchronized(this) {
                INSTANCE ?: BLEManager(context.applicationContext).also { INSTANCE = it }
            }
        }
    }

    // Client mode scan (DISABLED - we're server-only now)
    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) {
            // Don't auto-connect as client; we're hosting the GATT server
            Log.d(TAG, "Found (ignored): ${result.device.name}")
        }
    }

    // Client mode GATT callback
    private val gattCallback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
            when (newState) {
                BluetoothProfile.STATE_CONNECTED -> {
                    clientConnecting = false
                    isConnected = true
                    connectionCallback?.invoke(true)
                    gatt.discoverServices()
                }
                BluetoothProfile.STATE_DISCONNECTED -> {
                    clientConnecting = false
                    isConnected = false
                    connectionCallback?.invoke(false)
                    // Retry with delay to avoid spam
                    android.os.Handler(android.os.Looper.getMainLooper()).postDelayed({
                        startScanning()
                    }, 1500)
                }
            }
        }

        override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
            if (status == BluetoothGatt.GATT_SUCCESS) {
                setupCharacteristics(gatt)
            }
        }
    }

    fun startScanning() {
        val scanFilter = ScanFilter.Builder().setServiceUuid(ParcelUuid(serviceUUID)).build()
        val scanSettings = ScanSettings.Builder().setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY).build()
        bluetoothLeScanner?.startScan(listOf(scanFilter), scanSettings, scanCallback)
    }

    fun stopScanning() {
        bluetoothLeScanner?.stopScan(scanCallback)
    }

    private fun connectToDevice(device: BluetoothDevice) {
        if (clientConnecting) return
        clientConnecting = true
        bluetoothGatt = device.connectGatt(context, false, gattCallback)
    }

    private fun setupCharacteristics(gatt: BluetoothGatt) {
        val service = gatt.getService(serviceUUID) ?: return
        for (characteristic in service.characteristics) {
            if (characteristic.properties and BluetoothGattCharacteristic.PROPERTY_NOTIFY != 0) {
                gatt.setCharacteristicNotification(characteristic, true)
            }
        }
    }

    // Server mode: advertise + GATT server so iPhone can discover us
    fun startHosting() {
        registerBondReceiver()
        startGattServer()
        startAdvertising()
        sensorManager = context.getSystemService(Context.SENSOR_SERVICE) as? SensorManager
        heartRateSensor = sensorManager?.getDefaultSensor(Sensor.TYPE_HEART_RATE)
    }

    fun stopHosting() {
        advertiser?.stopAdvertising(advertiseCallback)
        gattServer?.close()
        bondReceiver?.let { try { context.unregisterReceiver(it) } catch (_: Exception) {} }
        bondReceiver = null
    }

    /** Begin streaming + notification mirroring once the link is bonded/encrypted. */
    private fun startSecureSession(device: BluetoothDevice) {
        Log.d(TAG, "🔐 Secure session established with ${device.address} — streaming")
        startServerKeepAlive(device)
        startHeartRateStream(device)
        startAncs(device)
    }

    /** Open a GATT client back to the (bonded) iPhone and mirror its ANCS notifications. */
    private fun startAncs(device: BluetoothDevice) {
        val forwarder = notificationForwarder ?: NotificationForwarder(context).also { notificationForwarder = it }
        ancsClient?.close()
        Log.d(TAG, "Starting ANCS client for ${device.address} (bond=${device.bondState}) in 1s")
        ancsClient = AncsClient(
            context,
            onAdded = onAdded@{ n ->
                reportSeenApp(n.appId) // let the phone list this app in settings
                if (blockedApps.any { n.appId.equals(it, ignoreCase = true) }) {
                    Log.d(TAG, "Muted app, not mirroring: ${n.appId}")
                    return@onAdded
                }
                if (n.categoryId == AncsClient.CATEGORY_INCOMING_CALL) forwarder.postCall(n)
                else forwarder.post(n)
            },
            onRemoved = { uid -> forwarder.cancel(uid) }
        )
        // Let the freshly-bonded link settle (MTU/CCCD writes on the server side)
        // before opening the second GATT-client role to the iPhone.
        keepAliveHandler.postDelayed({ ancsClient?.connect(device) }, 1000)
    }

    private fun stopAncs() {
        ancsClient?.close()
        ancsClient = null
    }

    /** Answer/decline a mirrored call (invoked from the call notification actions). */
    fun performAncsAction(uid: Int, actionId: Int) {
        ancsClient?.performAction(uid, actionId)
    }

    private val seenApps = java.util.Collections.synchronizedSet(HashSet<String>())

    /** Report a newly-seen iOS app id up to the phone so it can appear in the filter UI. */
    private fun reportSeenApp(appId: String) {
        if (appId.isBlank() || !seenApps.add(appId)) return
        val ctrl = gattServer?.getService(serviceUUID)?.getCharacteristic(controlCharUUID) ?: return
        val dev = connectedDevice ?: return
        val json = JSONObject().put("type", "SEEN_APP").put("appId", appId).toString()
        notify(dev, ctrl, json.toByteArray(Charsets.UTF_8))
    }

    /** Watch for pairing completing/removal so we can start or tear down streaming. */
    private fun registerBondReceiver() {
        if (bondReceiver != null) return
        bondReceiver = object : BroadcastReceiver() {
            override fun onReceive(ctx: Context, intent: android.content.Intent) {
                if (intent.action != BluetoothDevice.ACTION_BOND_STATE_CHANGED) return
                val device = IntentCompat.getParcelableExtra(
                    intent, BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java
                ) ?: return
                when (intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, BluetoothDevice.BOND_NONE)) {
                    BluetoothDevice.BOND_BONDED ->
                        if (device.address == connectedDevice?.address) startSecureSession(device)
                    BluetoothDevice.BOND_NONE ->
                        if (device.address == connectedDevice?.address) {
                            Log.w(TAG, "Bond removed — stopping streaming and dropping ${device.address}")
                            stopServerKeepAlive()
                            stopHeartRateStream()
                            stopAncs()
                            try { gattServer?.cancelConnection(device) } catch (_: Exception) {}
                        }
                }
            }
        }
        context.registerReceiver(bondReceiver, IntentFilter(BluetoothDevice.ACTION_BOND_STATE_CHANGED))
    }

    private fun startGattServer() {
        gattServer = bluetoothManager?.openGattServer(context, gattServerCallback)
        val service = BluetoothGattService(serviceUUID, BluetoothGattService.SERVICE_TYPE_PRIMARY)

        fun rwNotify(uuid: UUID): BluetoothGattCharacteristic {
            val props = BluetoothGattCharacteristic.PROPERTY_WRITE or BluetoothGattCharacteristic.PROPERTY_NOTIFY or BluetoothGattCharacteristic.PROPERTY_READ
            // ENCRYPTED_MITM forces the Android stack to require an authenticated
            // (LE Secure Connections, numeric-comparison) pairing before any read/
            // write is honoured — so nothing is readable over the air unless the
            // iPhone is bonded, and an attacker cannot MITM the pairing.
            val perms = BluetoothGattCharacteristic.PERMISSION_WRITE_ENCRYPTED_MITM or
                    BluetoothGattCharacteristic.PERMISSION_READ_ENCRYPTED_MITM
            val characteristic = BluetoothGattCharacteristic(uuid, props, perms)
            // CCCD also requires an encrypted link, so subscribing to notifications
            // (heart rate, PONG, keepalive) forces pairing too.
            val cccd = BluetoothGattDescriptor(
                UUID.fromString("00002902-0000-1000-8000-00805f9b34fb"),
                BluetoothGattDescriptor.PERMISSION_READ_ENCRYPTED_MITM or
                        BluetoothGattDescriptor.PERMISSION_WRITE_ENCRYPTED_MITM
            )
            characteristic.addDescriptor(cccd)
            return characteristic
        }

        service.addCharacteristic(rwNotify(notificationCharUUID))
        service.addCharacteristic(rwNotify(callCharUUID))
        service.addCharacteristic(rwNotify(healthCharUUID))
        service.addCharacteristic(rwNotify(mediaCharUUID))
        service.addCharacteristic(rwNotify(contactsCharUUID))
        service.addCharacteristic(rwNotify(findDeviceCharUUID))
        service.addCharacteristic(rwNotify(controlCharUUID))

        gattServer?.addService(service)
    }

    private val gattServerCallback = object : BluetoothGattServerCallback() {
        override fun onConnectionStateChange(device: BluetoothDevice, status: Int, newState: Int) {
            Log.d(TAG, "Server conn state: $newState for ${device.address} (bond=${device.bondState})")
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                connectedDevice = device
                isConnected = true
                isServerConnected = true
                connectionCallback?.invoke(true)
                // Stop advertising once a central is connected
                advertiser?.stopAdvertising(advertiseCallback)
                if (device.bondState == BluetoothDevice.BOND_BONDED) {
                    startSecureSession(device)
                } else {
                    // Not paired yet: accessing our encrypted characteristics will
                    // trigger pairing on the iPhone. We start streaming data only
                    // once BOND_BONDED arrives (see bondReceiver).
                    Log.d(TAG, "🔒 Central not bonded — waiting for pairing before streaming")
                }
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                connectedDevice = null
                isConnected = false
                isServerConnected = false
                connectionCallback?.invoke(false)
                // Resume advertising to accept new connections
                startAdvertising()
                stopServerKeepAlive()
                stopHeartRateStream()
                stopAncs()
            }
        }

        override fun onCharacteristicWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            characteristic: BluetoothGattCharacteristic,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray
        ) {
            // Defense in depth: never process inbound data (notifications, contacts,
            // and eventually SMS/OTP) from a device that hasn't completed pairing.
            if (device.bondState != BluetoothDevice.BOND_BONDED) {
                Log.w(TAG, "Rejecting write from unbonded device ${device.address}")
                if (responseNeeded) {
                    gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_INSUFFICIENT_AUTHENTICATION, offset, null)
                }
                return
            }
            Log.d(TAG, "Write to ${characteristic.uuid}")
            if (responseNeeded) {
                gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, null)
            }
            
            if (characteristic.uuid == controlCharUUID) {
                val text = String(value, Charsets.UTF_8)
                Log.d(TAG, "Control write: $text")
                if (text == "PING") {
                    Log.d(TAG, "Received PING, responding PONG")
                    val responseChar = gattServer?.getService(serviceUUID)?.getCharacteristic(controlCharUUID)
                    responseChar?.let { notify(device, it, "PONG".toByteArray(Charsets.UTF_8)) }
                } else if (text.startsWith("{")) {
                    try {
                        val obj = JSONObject(text)
                        val type = obj.optString("type")
                        if (type == "TIME_SYNC") {
                            val epochMs = obj.optLong("epochMs")
                            val tzOffsetMinutes = obj.optInt("tzOffsetMinutes")
                            val tzId = obj.optString("tzId")
                            val now = System.currentTimeMillis()
                            val skewMs = epochMs - now
                            Log.d(TAG, "⏱️ TIME_SYNC received: epochMs=$epochMs tzId=$tzId offsetMin=$tzOffsetMinutes skewMs=$skewMs")

                            // Apps cannot set system time on Wear OS without privileged permission.
                            // If skew is large, prompt user to open Date & Time settings.
                            if (kotlin.math.abs(skewMs) > 60_000) { // > 1 minute
                                try {
                                    val intent = Intent(Settings.ACTION_DATE_SETTINGS).apply {
                                        addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
                                    }
                                    context.startActivity(intent)
                                } catch (e: Exception) {
                                    Log.e(TAG, "Failed to open date settings: ${e.message}")
                                }
                            }
                        } else if (type == "NOTIF_FILTER") {
                            // Phone pushes the muted-app list; enforce it on future ANCS notifications.
                            val arr = obj.optJSONArray("blocked")
                            val set = HashSet<String>()
                            if (arr != null) for (i in 0 until arr.length()) set.add(arr.getString(i))
                            blockedApps = set
                            Log.d(TAG, "🔕 Notification filter updated: ${set.size} muted app(s)")
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "Failed to parse control JSON: ${e.message}")
                    }
                }
            }
        }

        override fun onDescriptorWriteRequest(
            device: BluetoothDevice,
            requestId: Int,
            descriptor: BluetoothGattDescriptor,
            preparedWrite: Boolean,
            responseNeeded: Boolean,
            offset: Int,
            value: ByteArray
        ) {
            Log.d(TAG, "Descriptor write: ${descriptor.uuid} value=${value?.contentToString()}")
            // Always acknowledge CCCD writes so iOS can subscribe
            gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, null)
        }

        override fun onCharacteristicReadRequest(
            device: BluetoothDevice,
            requestId: Int,
            offset: Int,
            characteristic: BluetoothGattCharacteristic
        ) {
            // Provide a non-null value for reads to avoid stack issues
            val value = characteristic.value ?: ByteArray(0)
            gattServer?.sendResponse(device, requestId, BluetoothGatt.GATT_SUCCESS, offset, value)
        }
    }

    /**
     * Send a GATT notification with the given payload. Uses the API 33+ overload
     * that takes the value explicitly (avoiding the deprecated, race-prone
     * `characteristic.value` write) and falls back to the legacy path below it.
     */
    private fun notify(
        device: BluetoothDevice,
        characteristic: BluetoothGattCharacteristic,
        value: ByteArray
    ) {
        val server = gattServer ?: return
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            server.notifyCharacteristicChanged(device, characteristic, false, value)
        } else {
            @Suppress("DEPRECATION")
            run {
                characteristic.value = value
                server.notifyCharacteristicChanged(device, characteristic, false)
            }
        }
    }

    private fun startServerKeepAlive(device: BluetoothDevice) {
        stopServerKeepAlive()
        reportBattery(device) // send once immediately on connect
        var tick = 0
        keepAliveRunnable = object : Runnable {
            override fun run() {
                try {
                    val ctrl = gattServer?.getService(serviceUUID)?.getCharacteristic(controlCharUUID)
                    if (ctrl != null) {
                        val payload = ("KA:" + System.currentTimeMillis()).toByteArray(Charsets.UTF_8)
                        notify(device, ctrl, payload)
                    }
                } catch (e: Exception) {
                    Log.e(TAG, "KeepAlive notify failed: ${e.message}")
                }
                // Report battery every 15 minutes (every 90th 10s keepalive tick).
                if (++tick % 90 == 0) reportBattery(device)
                keepAliveHandler.postDelayed(this, 10000)
            }
        }
        keepAliveHandler.postDelayed(keepAliveRunnable!!, 10000)
    }

    /** Send the watch's battery level to the phone over the control characteristic. */
    private fun reportBattery(device: BluetoothDevice) {
        try {
            val bm = context.getSystemService(Context.BATTERY_SERVICE) as? android.os.BatteryManager ?: return
            val pct = bm.getIntProperty(android.os.BatteryManager.BATTERY_PROPERTY_CAPACITY)
            if (pct < 0 || pct > 100) return
            val ctrl = gattServer?.getService(serviceUUID)?.getCharacteristic(controlCharUUID) ?: return
            val json = JSONObject().put("type", "BATTERY").put("level", pct).toString()
            notify(device, ctrl, json.toByteArray(Charsets.UTF_8))
            Log.d(TAG, "🔋 Battery reported: $pct%")
        } catch (e: Exception) {
            Log.e(TAG, "Battery report failed: ${e.message}")
        }
    }

    private fun stopServerKeepAlive() {
        keepAliveRunnable?.let { keepAliveHandler.removeCallbacks(it) }
        keepAliveRunnable = null
    }

    private fun startHeartRateStream(device: BluetoothDevice) {
        if (heartListener != null) return
        if (ActivityCompat.checkSelfPermission(context, Manifest.permission.BODY_SENSORS) != PackageManager.PERMISSION_GRANTED) {
            Log.w(TAG, "BODY_SENSORS permission not granted; cannot stream HR")
            return
        }
        if (heartRateSensor == null) {
            Log.w(TAG, "No heart rate sensor available")
            return
        }
        heartListener = object : SensorEventListener {
            override fun onSensorChanged(event: SensorEvent) {
                if (event.sensor.type != Sensor.TYPE_HEART_RATE) return
                val bpm = event.values.firstOrNull()?.toInt() ?: return
                // 0/negative bpm or no-contact accuracy = not a real measurement
                // (sensor searching, or watch not on wrist). Don't transmit it.
                if (bpm <= 0 || event.accuracy == SensorManager.SENSOR_STATUS_NO_CONTACT) return
                val now = System.currentTimeMillis()
                if (now - lastHrSentMs < 900) return // ~1 Hz
                lastHrSentMs = now
                val json = "{" +
                        "\"type\":\"heart_rate\"," +
                        "\"bpm\":" + bpm + "," +
                        "\"ts\":" + now +
                        "}"
                val char = gattServer?.getService(serviceUUID)?.getCharacteristic(healthCharUUID)
                if (char != null) {
                    notify(device, char, json.toByteArray(Charsets.UTF_8))
                    Log.d(TAG, "❤️ HR sent: $bpm bpm")
                }
            }
            override fun onAccuracyChanged(sensor: Sensor, accuracy: Int) {}
        }
        sensorManager?.registerListener(heartListener, heartRateSensor, SensorManager.SENSOR_DELAY_NORMAL)
        Log.d(TAG, "Heart-rate streaming started")
    }

    private fun stopHeartRateStream() {
        heartListener?.let { sensorManager?.unregisterListener(it) }
        heartListener = null
        Log.d(TAG, "Heart-rate streaming stopped")
    }

    private fun startAdvertising() {
        val data = AdvertiseData.Builder()
            .addServiceUuid(ParcelUuid(serviceUUID))
            .setIncludeTxPowerLevel(false)
            .build()

        val settings = AdvertiseSettings.Builder()
            .setAdvertiseMode(AdvertiseSettings.ADVERTISE_MODE_LOW_LATENCY)
            .setTxPowerLevel(AdvertiseSettings.ADVERTISE_TX_POWER_MEDIUM)
            .setConnectable(true)
            .build()

        advertiser?.startAdvertising(settings, data, advertiseCallback)
    }

    private val advertiseCallback = object : AdvertiseCallback() {
        override fun onStartSuccess(settingsInEffect: AdvertiseSettings) {
            Log.d(TAG, "Advertising started")
        }

        override fun onStartFailure(errorCode: Int) {
            Log.e(TAG, "Advertising failed: $errorCode")
        }
    }
}

