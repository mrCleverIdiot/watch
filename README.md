# Watch Bridge

Bridge a **Samsung Galaxy Watch (Wear OS)** to an **iPhone** over Bluetooth Low
Energy — no cloud, no account, all data stays on-device.

The watch acts as the BLE **peripheral** (advertises + hosts a GATT service); the
iPhone acts as the **central** that connects, reads and writes.

---

## Features

| Feature | Status |
|---|---|
| ❤️ **Heart-rate → Apple Health** — watch streams HR, iPhone writes `HKQuantitySample` | ✅ Working end-to-end |
| 🔔 **Notification mirroring** — all iPhone notifications appear on the watch via ANCS | ✅ Working |
| 📞 **Incoming-call alerts + Answer/Decline** — from the watch, via ANCS actions | ✅ Working |
| 🔕 **Per-app filter** — phone settings screen to mute apps (keep OTP/bank on phone only) | ✅ Working |
| 🔐 **Encrypted + bonded link** — LE Secure Connections (MITM); unbonded devices rejected | ✅ Working |
| 🔗 **Auto reconnect + keepalive** | ✅ Working |
| 🎵 Media control | 🔧 In progress |
| 👤 Contacts sync (caller ID) | 🔧 In progress |
| 📍 Find-my-device ring | 🔧 In progress |

> **How notifications/calls work:** the watch is a BLE peripheral (for heart rate) and
> *also* a GATT client that reads Apple's **ANCS** from the bonded iPhone — the standard
> accessory model. iOS exposes ANCS only over an encrypted, bonded link, so mirroring is
> gated behind pairing.

> **Privacy by design:** communication is Bluetooth-only (no `INTERNET` permission on the
> watch), the link is encrypted + MITM-authenticated, health data stays in the local Apple
> Health store, Android backup is disabled, and any app can be muted so sensitive
> notifications (banking / OTP) never leave the phone.

---

## Project structure

```
watch_bridge/
├── README.md                      ← you are here
├── .gitignore                     ← ignores build output + signing secrets
├── WatchBridge/                   ← iOS app (Xcode project)
│   ├── WatchBridge/               ← Swift sources, Assets, Info.plist, PrivacyInfo
│   └── WatchBridge.xcodeproj/
└── watch/
    ├── PRODUCTION_CHECKLIST.md     ← launch-readiness tracker
    ├── tools/gen_icons.py          ← regenerates all app icons (bridge + pulse)
    └── wearos/WatchBridge/         ← Wear OS (Android) app — Gradle project
```

## Tech stack

- **iOS:** Swift, SwiftUI, CoreBluetooth, HealthKit, CallKit — deployment target iOS 15+
- **Wear OS:** Kotlin, Jetpack Compose for Wear OS, foreground service — minSdk 30 (Wear OS 3)
- Build: Xcode 16, AGP 8.7 / Kotlin 2.0 / Gradle 8.9, `compileSdk` 35

---

## Getting started

### Requirements
- macOS with **Xcode 16+** (iOS) and **Android Studio** (Wear OS)
- A physical **iPhone** (iOS 15+) — BLE does not work in the Simulator
- A **Samsung Galaxy Watch 4+** (Wear OS 3+) or a Wear OS emulator

### iOS app
1. Open `WatchBridge/WatchBridge.xcodeproj` in Xcode.
2. Select the **WatchBridge** target → **Signing & Capabilities** → set your **Team**.
   (Capabilities are already configured: HealthKit + Background Delivery, Background
   Modes for BLE central/peripheral.)
3. Plug in your iPhone, select it as the run destination, and press ▶.
4. On first launch, trust the developer cert on the phone:
   *Settings → General → VPN & Device Management*.

### Wear OS app
1. Open `watch/wearos/WatchBridge` in Android Studio and let Gradle sync.
2. Connect a watch (Developer options → Wireless debugging → `adb connect …`) or start
   a Wear OS emulator.
3. Press ▶, or from the command line:
   ```bash
   cd watch/wearos/WatchBridge
   ./gradlew installDebug
   ```

### Using them together
Launch the **watch** app first (it advertises), then the **iPhone** app connects.
Grant the permission prompts on both. Heart rate should begin flowing into Apple Health.

---

## Release signing

### Wear OS (Android)
Create `watch/wearos/WatchBridge/keystore.properties` (git-ignored):
```properties
storeFile=/absolute/path/to/release.jks
storePassword=••••••
keyAlias=watchbridge
keyPassword=••••••
```
Then `./gradlew :app:assembleRelease` produces a signed, minified (R8) build. Without
this file, release assembly is unsigned and debug builds are unaffected.

### iOS
Signing is managed by Xcode (automatic). Archive via **Product → Archive** and upload
through the Organizer / App Store Connect.

---

## Regenerating app icons

Icons use a "bridge + heartbeat pulse" motif on an indigo→cyan gradient, generated
reproducibly:
```bash
python3 watch/tools/gen_icons.py   # requires Pillow
```
This writes the iOS `AppIcon.appiconset` (light/dark/tinted) and all Wear OS mipmaps.

---

## Roadmap & known limits

See [`watch/PRODUCTION_CHECKLIST.md`](watch/PRODUCTION_CHECKLIST.md) for the full
launch-readiness list, including the BLE transport work (MTU negotiation + chunking)
required before notification/contacts payloads can be delivered reliably, and the iOS
platform constraints around third-party notification/call/media access.

## License

MIT
