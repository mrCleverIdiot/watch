package com.watchbridge

import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothProfile
import android.content.Context
import android.os.Build
import android.util.Log
import java.util.ArrayDeque
import java.util.UUID

/**
 * Consumes Apple Notification Center Service (ANCS) from a connected + bonded iPhone.
 *
 * Topology: the iPhone is the GAP central that connects to our GATT server (for heart
 * rate). ANCS is exposed by iOS as a GATT *server* on that same link, so here we open a
 * GATT *client* back to the iPhone and read notifications/calls from it. This is the
 * canonical accessory model (Pebble/Amazfit/etc.) — no topology change required.
 *
 * Emits parsed notifications via [onAdded] and dismissals via [onRemoved]. Call
 * [performAction] to answer/decline a call (ANCS PerformNotificationAction).
 */
class AncsClient(
    private val context: Context,
    private val onAdded: (AncsNotification) -> Unit,
    private val onRemoved: (Int) -> Unit,
) {
    companion object {
        private const val TAG = "AncsClient"

        val ANCS_SERVICE: UUID = UUID.fromString("7905F431-B5CE-4E99-A40F-4B1E122D00D0")
        val NOTIFICATION_SOURCE: UUID = UUID.fromString("9FBF120D-6301-42D9-8C58-25E699A21DBD")
        val CONTROL_POINT: UUID = UUID.fromString("69D1D8F3-45E1-49A8-9821-9BBDFDAAD9D9")
        val DATA_SOURCE: UUID = UUID.fromString("22EAC6E9-24D6-4BB5-BE44-B36ACE7C7BFB")
        private val CCCD: UUID = UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

        // EventID
        private const val EVENT_ADDED = 0
        private const val EVENT_REMOVED = 2
        // EventFlags bits
        private const val FLAG_PREEXISTING = 1 shl 2
        private const val FLAG_POSITIVE_ACTION = 1 shl 3
        private const val FLAG_NEGATIVE_ACTION = 1 shl 4
        // CommandIDs
        private const val CMD_GET_NOTIFICATION_ATTRIBUTES = 0
        private const val CMD_PERFORM_NOTIFICATION_ACTION = 2
        // AttributeIDs
        private const val ATTR_APP_ID = 0
        private const val ATTR_TITLE = 1
        private const val ATTR_MESSAGE = 3
        private const val ATTR_DATE = 5

        const val CATEGORY_INCOMING_CALL = 1

        const val ACTION_POSITIVE = 0 // Answer
        const val ACTION_NEGATIVE = 1 // Decline
    }

    private var gatt: BluetoothGatt? = null

    // GATT allows one outstanding operation at a time; serialize them.
    private val opQueue = ArrayDeque<() -> Unit>()
    private var opInFlight = false

    // Data Source responses can span multiple packets — accumulate then parse.
    private val dataBuffer = ArrayList<Byte>()

    fun connect(device: BluetoothDevice) {
        close()
        Log.d(TAG, "Opening ANCS client to ${device.address}")
        gatt = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            device.connectGatt(context, false, callback, BluetoothDevice.TRANSPORT_LE)
        } else {
            device.connectGatt(context, false, callback)
        }
    }

    fun close() {
        try { gatt?.close() } catch (_: Exception) {}
        gatt = null
        opQueue.clear()
        opInFlight = false
        dataBuffer.clear()
    }

    /** Answer/decline the call notification identified by [uid]. */
    fun performAction(uid: Int, actionId: Int) {
        val cp = ByteArray(6)
        cp[0] = CMD_PERFORM_NOTIFICATION_ACTION.toByte()
        writeUid(cp, 1, uid)
        cp[5] = actionId.toByte()
        enqueue { writeControlPoint(cp) }
    }

    // ---- GATT callback ----------------------------------------------------
    private val callback = object : BluetoothGattCallback() {
        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) {
            if (newState == BluetoothProfile.STATE_CONNECTED) {
                Log.d(TAG, "ANCS client connected — negotiating MTU")
                g.requestMtu(185)
            } else if (newState == BluetoothProfile.STATE_DISCONNECTED) {
                Log.d(TAG, "ANCS client disconnected")
            }
        }

        override fun onMtuChanged(g: BluetoothGatt, mtu: Int, status: Int) {
            Log.d(TAG, "ANCS MTU=$mtu — discovering services")
            g.discoverServices()
        }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) {
            Log.d(TAG, "ANCS onServicesDiscovered status=$status services=${g.services.map { it.uuid }}")
            val svc = g.getService(ANCS_SERVICE)
            if (svc == null) {
                Log.w(TAG, "❌ iPhone did NOT expose ANCS. status=$status — check bonding, or iOS may need the ANCS solicitation / a re-pair.")
                return
            }
            Log.d(TAG, "✅ ANCS service found — subscribing")
            // Enable Data Source first, then Notification Source (serialized).
            svc.getCharacteristic(DATA_SOURCE)?.let { enqueue { enableNotify(g, it) } }
            svc.getCharacteristic(NOTIFICATION_SOURCE)?.let { enqueue { enableNotify(g, it) } }
        }

        override fun onDescriptorWrite(g: BluetoothGatt, d: BluetoothGattDescriptor, status: Int) {
            Log.d(TAG, "ANCS notifications enabled on ${d.characteristic.uuid} (status=$status)")
            operationComplete()
        }

        override fun onCharacteristicWrite(g: BluetoothGatt, c: BluetoothGattCharacteristic, status: Int) {
            operationComplete()
        }

        @Deprecated("Deprecated in API 33")
        override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic) {
            @Suppress("DEPRECATION")
            handleChanged(c.uuid, c.value ?: ByteArray(0))
        }

        override fun onCharacteristicChanged(g: BluetoothGatt, c: BluetoothGattCharacteristic, value: ByteArray) {
            handleChanged(c.uuid, value)
        }
    }

    private fun handleChanged(uuid: UUID, value: ByteArray) {
        when (uuid) {
            NOTIFICATION_SOURCE -> onNotificationSource(value)
            DATA_SOURCE -> onDataSource(value)
        }
    }

    // ---- Notification Source: 8-byte tuple --------------------------------
    private fun onNotificationSource(v: ByteArray) {
        if (v.size < 8) return
        val eventId = v[0].toInt() and 0xFF
        val flags = v[1].toInt() and 0xFF
        val categoryId = v[2].toInt() and 0xFF
        val uid = readUid(v, 4)
        Log.d(TAG, "📨 NotificationSource event=$eventId category=$categoryId flags=$flags uid=$uid")

        when (eventId) {
            EVENT_REMOVED -> onRemoved(uid)
            EVENT_ADDED -> {
                if (flags and FLAG_PREEXISTING != 0) {
                    Log.d(TAG, "  ↳ pre-existing notification, skipping (uid=$uid)")
                    return // don't replay the backlog on (re)connect
                }
                requestAttributes(uid, categoryId, flags)
            }
        }
    }

    private fun requestAttributes(uid: Int, categoryId: Int, flags: Int) {
        // GetNotificationAttributes: cmd, uid(4), then (attrId[, maxLen(2)])...
        val req = ArrayList<Byte>()
        req.add(CMD_GET_NOTIFICATION_ATTRIBUTES.toByte())
        val uidBytes = ByteArray(4); writeUid(uidBytes, 0, uid); req.addAll(uidBytes.toList())
        req.add(ATTR_APP_ID.toByte())
        req.add(ATTR_TITLE.toByte()); req.add(0x20); req.add(0x00)      // max 32
        req.add(ATTR_MESSAGE.toByte()); req.add(0x80.toByte()); req.add(0x00) // max 128
        req.add(ATTR_DATE.toByte())
        // Stash context per-UID so onDataSource labels the right notification even
        // when several requests are in flight.
        pendingMeta[uid] = categoryId to flags
        enqueue { writeControlPoint(req.toByteArray()) }
    }

    private val pendingMeta = HashMap<Int, Pair<Int, Int>>() // uid -> (category, flags)

    // ---- Data Source: attribute response (may be multi-packet) ------------
    private fun onDataSource(v: ByteArray) {
        dataBuffer.addAll(v.toList())
        val parsed = tryParseAttributes(dataBuffer) ?: run {
            Log.d(TAG, "DataSource +${v.size}B — awaiting more (buffered=${dataBuffer.size})")
            return
        }
        dataBuffer.clear()

        val meta = pendingMeta.remove(parsed.uid)
        val categoryId = meta?.first ?: 0
        val flags = meta?.second ?: 0
        val notif = AncsNotification(
            uid = parsed.uid,
            categoryId = categoryId,
            appId = parsed.attrs[ATTR_APP_ID] ?: "",
            title = parsed.attrs[ATTR_TITLE] ?: "",
            message = parsed.attrs[ATTR_MESSAGE] ?: "",
            positiveAction = flags and FLAG_POSITIVE_ACTION != 0,
            negativeAction = flags and FLAG_NEGATIVE_ACTION != 0,
        )
        Log.d(TAG, "✅ Parsed notification uid=${notif.uid} app=${notif.appId} title='${notif.title}' isCall=${notif.categoryId == CATEGORY_INCOMING_CALL}")
        onAdded(notif)
    }

    private class ParsedAttrs(val uid: Int, val attrs: Map<Int, String>)

    /** Returns null if the buffer doesn't yet contain all 4 requested attributes. */
    private fun tryParseAttributes(buf: List<Byte>): ParsedAttrs? {
        if (buf.size < 5) return null
        val arr = buf.toByteArray()
        var i = 1 // skip commandId
        val uid = readUid(arr, i); i += 4
        val attrs = HashMap<Int, String>()
        var count = 0
        while (count < 4) {
            if (i + 3 > arr.size) return null // need attrId + 2-byte length
            val attrId = arr[i].toInt() and 0xFF
            val len = (arr[i + 1].toInt() and 0xFF) or ((arr[i + 2].toInt() and 0xFF) shl 8)
            i += 3
            if (i + len > arr.size) return null // value not fully arrived yet
            if (len > 0) attrs[attrId] = String(arr, i, len, Charsets.UTF_8)
            else attrs[attrId] = ""
            i += len
            count++
        }
        return ParsedAttrs(uid, attrs)
    }

    // ---- op queue + low-level writes --------------------------------------
    private fun enqueue(op: () -> Unit) {
        opQueue.add(op)
        if (!opInFlight) runNext()
    }

    private fun runNext() {
        val op = opQueue.poll() ?: return
        opInFlight = true
        try { op() } catch (e: Exception) { Log.e(TAG, "op failed: ${e.message}"); operationComplete() }
    }

    private fun operationComplete() {
        opInFlight = false
        runNext()
    }

    private fun enableNotify(g: BluetoothGatt, c: BluetoothGattCharacteristic) {
        g.setCharacteristicNotification(c, true)
        val cccd = c.getDescriptor(CCCD) ?: run { operationComplete(); return }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            g.writeDescriptor(cccd, BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE)
        } else {
            @Suppress("DEPRECATION")
            run {
                cccd.value = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
                g.writeDescriptor(cccd)
            }
        }
    }

    private fun writeControlPoint(bytes: ByteArray) {
        val g = gatt ?: run { operationComplete(); return }
        val c = g.getService(ANCS_SERVICE)?.getCharacteristic(CONTROL_POINT) ?: run { operationComplete(); return }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            g.writeCharacteristic(c, bytes, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT)
        } else {
            @Suppress("DEPRECATION")
            run {
                c.writeType = BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT
                c.value = bytes
                g.writeCharacteristic(c)
            }
        }
    }

    private fun readUid(b: ByteArray, off: Int): Int =
        (b[off].toInt() and 0xFF) or ((b[off + 1].toInt() and 0xFF) shl 8) or
                ((b[off + 2].toInt() and 0xFF) shl 16) or ((b[off + 3].toInt() and 0xFF) shl 24)

    private fun writeUid(b: ByteArray, off: Int, uid: Int) {
        b[off] = (uid and 0xFF).toByte()
        b[off + 1] = ((uid shr 8) and 0xFF).toByte()
        b[off + 2] = ((uid shr 16) and 0xFF).toByte()
        b[off + 3] = ((uid shr 24) and 0xFF).toByte()
    }
}

data class AncsNotification(
    val uid: Int,
    val categoryId: Int,
    val appId: String,
    val title: String,
    val message: String,
    val positiveAction: Boolean,
    val negativeAction: Boolean,
)
