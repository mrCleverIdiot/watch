package com.watchbridge

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.compose.setContent
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.wear.compose.material.*
import com.watchbridge.ui.theme.WatchBridgeTheme

class MainActivity : ComponentActivity() {
    private val permissionsRequestCode = 100

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        val bleManager = BLEManager.getInstance(this)
        ensureBleReady()

        setContent {
            // Get initial state from singleton
            var isConnected by remember { mutableStateOf(bleManager.isConnected) }
            
            // Observe BLE connection state
            DisposableEffect(Unit) {
                bleManager.connectionCallback = { connected ->
                    isConnected = connected
                }
                onDispose { bleManager.connectionCallback = null }
            }
            WatchBridgeApp(isConnected = isConnected)
        }
    }

    private fun ensureBleReady() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val needs = mutableListOf<String>()
            if (checkSelfPermission(Manifest.permission.BLUETOOTH_CONNECT) != PackageManager.PERMISSION_GRANTED) {
                needs.add(Manifest.permission.BLUETOOTH_CONNECT)
            }
            if (checkSelfPermission(Manifest.permission.BLUETOOTH_ADVERTISE) != PackageManager.PERMISSION_GRANTED) {
                needs.add(Manifest.permission.BLUETOOTH_ADVERTISE)
            }
            if (checkSelfPermission(Manifest.permission.BLUETOOTH_SCAN) != PackageManager.PERMISSION_GRANTED) {
                needs.add(Manifest.permission.BLUETOOTH_SCAN)
            }
            // Heart-rate sensor permission
            if (checkSelfPermission(Manifest.permission.BODY_SENSORS) != PackageManager.PERMISSION_GRANTED) {
                needs.add(Manifest.permission.BODY_SENSORS)
            }
            // Posting mirrored notifications (Android 13+)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
                checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) != PackageManager.PERMISSION_GRANTED) {
                needs.add(Manifest.permission.POST_NOTIFICATIONS)
            }
            if (needs.isNotEmpty()) {
                requestPermissions(needs.toTypedArray(), permissionsRequestCode)
                return
            }
        }
        startBleService()
    }

    private fun startBleService() {
        val intent = Intent(this, BLEConnectionService::class.java)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == permissionsRequestCode) {
            val allGranted = grantResults.isNotEmpty() && grantResults.all { it == PackageManager.PERMISSION_GRANTED }
            if (allGranted) {
                startBleService()
            } else {
                android.util.Log.w("MainActivity", "Required permissions not granted: ${permissions.zip(grantResults.toTypedArray()).toList()}")
            }
        }
    }
}

@Composable
fun WatchBridgeApp(isConnected: Boolean) {
    Scaffold(
        timeText = { TimeText() },
        vignette = { Vignette(vignettePosition = VignettePosition.TopAndBottom) }
    ) {
        Column(
            modifier = Modifier
                .fillMaxSize()
                .background(MaterialTheme.colors.background)
                .padding(16.dp),
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center
        ) {
            Text(
                text = "WatchBridge",
                style = MaterialTheme.typography.title1,
                textAlign = TextAlign.Center
            )
            
            Spacer(modifier = Modifier.height(8.dp))
            
            if (isConnected) {
                Text("Connected to iPhone", style = MaterialTheme.typography.body2)
            } else {
                Text("Searching for iPhone...", style = MaterialTheme.typography.body2)
            }
        }
    }
}

@Composable
fun IncomingCallView(callerName: String, callerNumber: String) {
    Column(
        modifier = Modifier.fillMaxSize().padding(16.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        Text("Incoming Call", style = MaterialTheme.typography.title2)
        Spacer(modifier = Modifier.height(8.dp))
        Text(callerName, style = MaterialTheme.typography.title1)
        Text(callerNumber, style = MaterialTheme.typography.body2)
        
        Spacer(modifier = Modifier.height(24.dp))
        
        Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceEvenly) {
            Button(onClick = { /* Answer */ }) { Text("Answer") }
            Button(onClick = { /* Reject */ }) { Text("Reject") }
        }
    }
}

