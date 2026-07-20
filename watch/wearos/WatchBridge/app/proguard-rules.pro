# WatchBridge R8/ProGuard rules.
# Components declared in AndroidManifest.xml (Activity/Service/Receiver) are kept
# automatically. Add project-specific keep rules below.

# Keep BLE GATT callback subclasses referenced only by the framework.
-keep class com.watchbridge.** extends android.bluetooth.BluetoothGattCallback { *; }
-keep class com.watchbridge.** extends android.bluetooth.BluetoothGattServerCallback { *; }

# org.json is part of the platform; no rules needed. Keep line numbers for crash
# de-obfuscation via mapping.txt.
-keepattributes SourceFile,LineNumberTable
-renamesourcefileattribute SourceFile
