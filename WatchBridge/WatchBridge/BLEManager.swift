import Foundation
import CoreBluetooth
import Combine

/// Manages Bluetooth Low Energy communication with Samsung Galaxy Watch
class BLEManager: NSObject, ObservableObject {
    
    // MARK: - Singleton
    static let shared = BLEManager()
    
    // MARK: - Published Properties
    @Published var isConnected = false
    @Published var connectedDevice: CBPeripheral?
    @Published var connectionStatus: String = "Disconnected"
    @Published var watchBatteryLevel: Int?   // % reported by the watch, nil if unknown
    
    // MARK: - BLE Properties
    private var centralManager: CBCentralManager!
    private var peripheralManager: CBPeripheralManager!
    
    // GATT Service UUIDs
    private let serviceUUID = CBUUID(string: "A8B01C3E-4D5F-6A7B-8C9D-0E1F2A3B4C5D")
    
    // GATT Characteristic UUIDs
    private let notificationCharUUID = CBUUID(string: "0000FF01-0000-1000-8000-00805F9B34FB")
    private let callCharUUID = CBUUID(string: "0000FF02-0000-1000-8000-00805F9B34FB")
    private let healthCharUUID = CBUUID(string: "0000FF03-0000-1000-8000-00805F9B34FB")
    private let mediaCharUUID = CBUUID(string: "0000FF04-0000-1000-8000-00805F9B34FB")
    private let contactsCharUUID = CBUUID(string: "0000FF05-0000-1000-8000-00805F9B34FB")
    private let findDeviceCharUUID = CBUUID(string: "0000FF06-0000-1000-8000-00805F9B34FB")
    private let controlCharUUID = CBUUID(string: "0000FF07-0000-1000-8000-00805F9B34FB")
    
    private var discoveredPeripherals: [CBPeripheral] = []
    private var discoveredCharacteristics: [CBCharacteristic] = []
    
    // Message queue for when not connected
    private var messageQueue: [BLEData] = []
    
    private var keepaliveTimer: Timer?
    
    override init() {
        super.init()
        // defer initialization to start() so we can supply restoration options
    }

    /// Initialize CoreBluetooth with state restoration enabled
    func start() {
        if centralManager == nil {
            let options: [String: Any] = [
                CBCentralManagerOptionRestoreIdentifierKey: "com.watchbridge.central",
                CBCentralManagerOptionShowPowerAlertKey: true
            ]
            centralManager = CBCentralManager(delegate: self, queue: nil, options: options)
        }
        // NOTE: We intentionally do NOT start a CBPeripheralManager. The watch is the
        // GATT server and the iPhone is purely the central. Advertising the same
        // service UUID here (as the old code did) put the radio in a conflicting
        // dual role and served no one — the watch never connects back to us.
    }
    
    // MARK: - Public Methods
    
    func startScanning() {
        guard centralManager.state == .poweredOn else {
            connectionStatus = "Bluetooth unavailable"
            return
        }
        
        connectionStatus = "Scanning for watch..."
        centralManager.scanForPeripherals(withServices: [serviceUUID], options: [
            CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])
        
        // Stop scanning after 10 seconds
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            if !self.isConnected {
                self.centralManager.stopScan()
                self.connectionStatus = "No watch found"
            }
        }
    }
    
    func stopScanning() {
        centralManager.stopScan()
    }
    
    func sendNotification(_ notification: NotificationData) {
        guard let data = notification.toJSONData() else { return }
        sendData(data, characteristicUUID: notificationCharUUID)
    }
    
    func sendCallEvent(_ callEvent: CallEventData) {
        guard let data = callEvent.toJSONData() else { return }
        sendData(data, characteristicUUID: callCharUUID)
    }
    
    func sendContacts(_ contacts: [ContactData]) {
        let contactsJSON = ["contacts": contacts.map { $0.toDictionary() }]
        guard let data = try? JSONSerialization.data(withJSONObject: contactsJSON) else { return }
        sendData(data, characteristicUUID: contactsCharUUID)
    }
    
    func sendFindDeviceCommand() {
        let command = "RING"
        guard let data = command.data(using: .utf8) else { return }
        sendData(data, characteristicUUID: findDeviceCharUUID)
    }
    
    func receiveHealthData(_ data: Data) {
        // Log raw payload for debugging
        if let s = String(data: data, encoding: .utf8) {
            print("📥 [BLE] Health data received (\(data.count) bytes): \(s)")
        } else {
            print("📥 [BLE] Health data received (\(data.count) bytes)")
        }
        // Forward to HealthManager
        HealthManager.shared.processWatchData(data)
    }
    
    func receiveMediaCommand(_ data: Data) {
        // Process media commands from watch
        guard let command = String(data: data, encoding: .utf8) else { return }
        MediaControlManager.shared.executeCommand(command)
    }
    
    // MARK: - Private Methods
    
    private func startKeepalive() {
        stopKeepalive()
        keepaliveTimer = Timer.scheduledTimer(withTimeInterval: 20.0, repeats: true) { [weak self] _ in
            guard let self = self, self.isConnected else { return }
            // Send PING via control characteristic
            if let data = "PING".data(using: .utf8) {
                self.sendData(data, characteristicUUID: self.controlCharUUID)
            }
        }
    }
    
    private func stopKeepalive() {
        keepaliveTimer?.invalidate()
        keepaliveTimer = nil
    }
    
    private func sendData(_ data: Data, characteristicUUID: CBUUID) {
        // Self-heal: if our `isConnected` flag says connected but CoreBluetooth's own
        // peripheral.state disagrees (this happens if a delegate callback was somehow
        // missed), don't just silently queue forever — treat it as a real disconnect
        // and kick off the same recovery path as didDisconnectPeripheral would.
        if isConnected, let peripheral = connectedDevice, peripheral.state != .connected {
            print("⚠️ State desync detected: isConnected=true but peripheral.state=\(peripheral.state.rawValue). Forcing reconnect.")
            handleDisconnect(peripheral)
        }

        guard isConnected,
              let peripheral = connectedDevice,
              peripheral.state == .connected,
              let characteristic = discoveredCharacteristics.first(where: { $0.uuid == characteristicUUID }) else {
            // Queue message for later
            messageQueue.append(BLEData(data: data, characteristicUUID: characteristicUUID))
            return
        }

        peripheral.writeValue(data, for: characteristic, type: .withResponse)
    }

    /// Shared recovery path for any loss of connection, whether reported via
    /// didDisconnectPeripheral, didFailToConnect, or detected defensively in sendData.
    private func handleDisconnect(_ peripheral: CBPeripheral) {
        isConnected = false
        watchBatteryLevel = nil
        stopKeepalive()

        // Issue an outstanding connect(): unlike a Timer (suspended when backgrounded),
        // a pending connect to a known peripheral has no timeout and reconnects
        // automatically — even in the background — the instant the watch advertises again.
        connectionStatus = "Reconnecting..."
        centralManager.connect(peripheral, options: nil)
    }
    
    private func flushMessageQueue() {
        for queuedMessage in messageQueue {
            sendData(queuedMessage.data, characteristicUUID: queuedMessage.characteristicUUID)
        }
        messageQueue.removeAll()
    }
}

// MARK: - CBCentralManagerDelegate

extension BLEManager: CBCentralManagerDelegate {
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        // iOS will call this when restoring BLE state after app termination
        print("BLE: willRestoreState \(dict.keys)")
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let peripheral = peripherals.first {
            connectedDevice = peripheral
            connectedDevice?.delegate = self
            centralManager.connect(peripheral, options: nil)
        }
    }
    
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            connectionStatus = "Ready"
            // Try fast reconnect to saved peripheral first
            if let uuidString = UserDefaults.standard.string(forKey: "lastPeripheralUUID"),
               let uuid = UUID(uuidString: uuidString) {
                let retrieved = central.retrievePeripherals(withIdentifiers: [uuid])
                if let peripheral = retrieved.first {
                    connectedDevice = peripheral
                    peripheral.delegate = self
                    connectionStatus = "Reconnecting..."
                    central.connect(peripheral, options: nil)
                } else {
                    // Also check if already connected
                    let connected = central.retrieveConnectedPeripherals(withServices: [serviceUUID])
                    if let peripheral = connected.first {
                        connectedDevice = peripheral
                        peripheral.delegate = self
                        connectionStatus = "Connected"
                        isConnected = true
                        startKeepalive()
                        peripheral.discoverServices([serviceUUID])
                    } else {
                        startScanning()
                    }
                }
            } else {
                // Check if already connected
                let connected = central.retrieveConnectedPeripherals(withServices: [serviceUUID])
                if let peripheral = connected.first {
                    connectedDevice = peripheral
                    peripheral.delegate = self
                    connectionStatus = "Connected"
                    isConnected = true
                    startKeepalive()
                    peripheral.discoverServices([serviceUUID])
                } else {
                    startScanning()
                }
            }
        case .poweredOff:
            connectionStatus = "Bluetooth off"
        case .unauthorized:
            connectionStatus = "Bluetooth unauthorized"
        case .unsupported:
            connectionStatus = "Bluetooth unsupported"
        default:
            connectionStatus = "Bluetooth unavailable"
        }
    }
    
    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        print("Discovered: \(peripheral.name ?? "Unknown")")
        
        // Stop scanning once we found our watch
        stopScanning()
        
        if connectedDevice == nil || connectedDevice?.identifier != peripheral.identifier {
            peripheral.delegate = self
            connectedDevice = peripheral
            centralManager.connect(peripheral, options: nil)
            connectionStatus = "Connecting to watch..."
        }
    }
    
    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("Connected to: \(peripheral.name ?? "Unknown")")
        
        connectedDevice = peripheral
        isConnected = true
        connectionStatus = "Connected"
        
        // Save for fast reconnect
        UserDefaults.standard.set(peripheral.identifier.uuidString, forKey: "lastPeripheralUUID")

        // Start keepalive (ping every 20 seconds)
        startKeepalive()
        
        peripheral.discoverServices([serviceUUID])
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        // Log the reason so a recurring drop can be diagnosed (timeout vs. peer-closed vs. clean).
        if let error = error {
            print("Disconnected from \(peripheral.name ?? "Unknown"): \(error.localizedDescription)")
        } else {
            print("Disconnected from \(peripheral.name ?? "Unknown"): clean (no error)")
        }
        handleDisconnect(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        // Without this handler, a failed reconnect attempt (e.g. the watch hasn't
        // re-advertised yet after a brief drop) went completely unhandled — the app
        // would sit at "Reconnecting..." forever with no further retry. Fall back to
        // scanning, which picks up the watch's advertisement once it's back up.
        print("❌ Failed to connect to \(peripheral.name ?? "Unknown"): \(error?.localizedDescription ?? "no error") — falling back to scan")
        isConnected = false
        startScanning()
    }
}

// MARK: - CBPeripheralDelegate

extension BLEManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }
        
        for characteristic in characteristics {
            discoveredCharacteristics.append(characteristic)
            
            // Enable notifications for incoming data
            if characteristic.properties.contains(.notify) {
                peripheral.setNotifyValue(true, for: characteristic)
            }
            
            // Enable indications for bi-directional data
            if characteristic.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
        
        // Connection fully established - flush message queue
        flushMessageQueue()

        // Send initial time sync to watch after characteristics are ready
        sendTimeSync()

        // Push the current notification mute-list so the watch enforces it immediately.
        pushNotificationFilter()
    }
    
    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        
        switch characteristic.uuid {
        case healthCharUUID:
            receiveHealthData(data)
        case mediaCharUUID:
            receiveMediaCommand(data)
        case controlCharUUID:
            // Handle control commands (ping/pong, etc.)
            handleControlCommand(data)
        default:
            break
        }
    }
    
    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let error = error {
            // On the very first connection this may report an authentication error
            // while iOS is still completing pairing; it retries automatically once bonded.
            print("Write error on \(characteristic.uuid): \(error.localizedDescription)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        // Subscribing to our encrypted characteristics forces pairing. A success here
        // means the link is now bonded + encrypted (LE Secure Connections).
        if let error = error {
            print("🔒 Subscribe/pairing failed on \(characteristic.uuid): \(error.localizedDescription)")
        } else {
            print("🔐 Secured & subscribed to \(characteristic.uuid) — link is encrypted")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
        print("⚠️ Services modified, re-discovering...")
        peripheral.discoverServices([serviceUUID])
    }
    
    private func handleControlCommand(_ data: Data) {
        guard let command = String(data: data, encoding: .utf8) else { return }

        if command == "PING" {
            sendControlCommand("PONG")
            return
        }
        // JSON control messages from the watch.
        guard command.hasPrefix("{"),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        switch json["type"] as? String {
        case "SEEN_APP":
            if let appId = json["appId"] as? String { NotificationFilterStore.shared.noteSeen(appId) }
        case "BATTERY":
            if let level = json["level"] as? Int {
                DispatchQueue.main.async { self.watchBatteryLevel = level }
            }
        default:
            break
        }
    }

    /// Push the user's muted-app list to the watch, which enforces it on ANCS notifications.
    func pushNotificationFilter() {
        let payload: [String: Any] = [
            "type": "NOTIF_FILTER",
            "blocked": Array(NotificationFilterStore.shared.blockedApps)
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            sendData(data, characteristicUUID: controlCharUUID)
        }
    }
    
    private func sendControlCommand(_ command: String) {
        guard let data = command.data(using: .utf8) else { return }
        sendData(data, characteristicUUID: controlCharUUID)
    }

    private func sendTimeSync() {
        // Build a small JSON with epoch and timezone info
        let epochMs = Int(Date().timeIntervalSince1970 * 1000)
        let minutesFromGMT = TimeZone.current.secondsFromGMT() / 60
        let tzIdentifier = TimeZone.current.identifier
        let payload: [String: Any] = [
            "type": "TIME_SYNC",
            "epochMs": epochMs,
            "tzOffsetMinutes": minutesFromGMT,
            "tzId": tzIdentifier
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload) {
            sendData(data, characteristicUUID: controlCharUUID)
        }
    }
}

// MARK: - CBPeripheralManagerDelegate

extension BLEManager: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        // Intentionally unused: the iPhone is a BLE central only (see start()).
    }
}

// MARK: - Data Models

struct BLEData {
    let data: Data
    let characteristicUUID: CBUUID
}

struct NotificationData: Codable {
    let appName: String
    let title: String
    let body: String
    let timestamp: TimeInterval
    let iconBase64: String?
    
    func toJSONData() -> Data? {
        return try? JSONEncoder().encode(self)
    }
}

struct CallEventData: Codable {
    enum Action: String, Codable {
        case incoming, outgoing, answered, rejected, ended
    }
    let action: Action
    let callerName: String?
    let callerNumber: String?
    let timestamp: TimeInterval
    
    func toJSONData() -> Data? {
        return try? JSONEncoder().encode(self)
    }
}

struct ContactData: Codable {
    let name: String
    let phoneNumbers: [String]
    let emailAddresses: [String]
    
    func toDictionary() -> [String: Any] {
        return [
            "name": name,
            "phoneNumbers": phoneNumbers,
            "emailAddresses": emailAddresses
        ]
    }
}

