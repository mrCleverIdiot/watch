package com.watchbridge

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.os.Build
import android.os.IBinder
import androidx.core.app.NotificationCompat
import kotlinx.coroutines.*
import android.content.pm.PackageManager
import android.Manifest

class BLEConnectionService : Service() {
    private val serviceScope = CoroutineScope(Dispatchers.Default + SupervisorJob())
    private lateinit var bleManager: BLEManager
    
    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
        bleManager = BLEManager.getInstance(this)

        // Do not start BLE until runtime permissions are granted (Android 12+)
        if (!hasBlePermissions()) {
            // Wait for app to request permissions in Activity; stop for now
            stopSelf()
            return
        }

        serviceScope.launch {
            bleManager.startHosting()
            // Don't start scanning - we're server-only now
            // iOS connects to us as the peripheral
        }
    }
    
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(1001, createNotification(), android.content.pm.ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC)
        } else {
            startForeground(1001, createNotification())
        }
        return START_STICKY
    }
    
    override fun onBind(intent: Intent?): IBinder? = null
    
    override fun onDestroy() {
        super.onDestroy()
        serviceScope.cancel()
        bleManager.stopHosting()
    }

    private fun hasBlePermissions(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.S) return true
        val hasConnect = checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED
        val hasScan = checkSelfPermission(Manifest.permission.BLUETOOTH_SCAN) == PackageManager.PERMISSION_GRANTED
        val hasAdv = checkSelfPermission(Manifest.permission.BLUETOOTH_ADVERTISE) == PackageManager.PERMISSION_GRANTED
        return hasConnect && hasScan && hasAdv
    }
    
    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel = NotificationChannel("ble_connection", "BLE Connection", NotificationManager.IMPORTANCE_LOW)
            getSystemService(NotificationManager::class.java).createNotificationChannel(channel)
        }
    }
    
    private fun createNotification(): Notification {
        val intent = Intent(this, MainActivity::class.java)
        val pendingIntent = PendingIntent.getActivity(this, 0, intent, PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT)
        
        return NotificationCompat.Builder(this, "ble_connection")
            .setContentTitle("WatchBridge")
            .setContentText("BLE service active")
            .setSmallIcon(R.drawable.ic_stat_pulse)
            .setContentIntent(pendingIntent)
            .setOngoing(true)
            .build()
    }
}

