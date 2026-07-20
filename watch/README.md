# WatchBridge - Samsung Watch to iPhone Bridge

A native iOS and Wear OS app that bridges your Samsung Galaxy Watch to your iPhone, providing:
- Real-time notification forwarding
- Call handling (answer/reject, caller ID)
- Health & workout sync to Apple Health
- Media control (play/pause/skip)
- Contacts sync
- Find My Phone/Watch

## Architecture

### iOS App (iPhone)
- **Swift** + **SwiftUI**
- Uses CoreBluetooth for BLE communication
- Implements CallKit for call handling
- HealthKit for health data sync
- UserNotifications for notification forwarding
- Background modes for persistent connection

### Wear OS App (Watch)
- **Kotlin** + **Compose for Wear OS**
- BLE client for communication with iPhone
- Background service for persistent connection
- Sensor data collection (health metrics)
- Rich notification UI

## Communication Protocol

Uses BLE (Bluetooth Low Energy) with custom GATT characteristics:
- Notification payloads
- Call events
- Health data
- Media commands
- Device finding

## Getting Started

### Prerequisites
- Xcode 14+ (iOS development)
- Android Studio (Wear OS development)
- iPhone with iOS 15+
- Samsung Galaxy Watch 4+ (Wear OS 3+)

### iOS Setup
```bash
cd ios
open WatchBridge.xcodeproj
```

### Wear OS Setup
```bash
cd wearos
# Open in Android Studio
```

## Features

### Core Features (MVP)
1. **Notification Forwarding** - Mirrors iPhone notifications to watch
2. **Call Handling** - Answer/reject calls from watch
3. **Health Sync** - Pushes workouts/metrics to Apple Health
4. **Media Control** - Control iPhone music from watch
5. **Contacts Sync** - Sync contacts for caller ID
6. **Find My Device** - Ring/alert devices

## Technical Notes

### iOS Limitations
- iOS doesn't provide direct access to other apps' notifications
- We use UserNotifications framework to capture notifications sent to our app
- Background execution is limited - must use proper background modes

### Bluetooth Communication
- Uses CoreBluetooth on iOS
- Uses BluetoothAdapter/BluetoothGatt on Android/Wear OS
- Custom GATT profile with characteristics for each data type
- Acknowledgment protocol for reliable delivery

### Privacy
- All data stays on-device (Bluetooth only)
- No cloud servers
- No data collection
- HealthKit data requires explicit user consent

## Development Roadmap

- [x] Project structure
- [x] BLE communication layer ✅
- [x] iOS app skeleton ✅
- [x] Wear OS app skeleton ✅
- [x] Core managers (Health, Call, Notification, Contacts, Media) ✅
- [ ] Device testing 🔄
- [ ] Notification forwarding 🔄
- [ ] Call handling 🔄
- [ ] Health sync 🔄
- [ ] Media control 🔄
- [ ] Contacts sync 🔄
- [ ] Find My device 🔄
- [ ] Subscription system ⏳
- [ ] Testing & polish ⏳

## Current Status

✅ **Complete**: Project structure, iOS app foundation, Wear OS app foundation, BLE protocol design  
🔄 **In Progress**: Real device testing, JSON parsing refinement  
⏳ **Pending**: Full feature testing, subscription system, store submission  

**See [PROJECT_SUMMARY.md](./PROJECT_SUMMARY.md) for detailed status.**

## License
MIT

