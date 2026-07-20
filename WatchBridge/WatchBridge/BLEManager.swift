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
    
    // Reconnect state
    private var reconnectAttempt = 0
    private var reconnectTimer: Timer?
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
        if peripheralManager == nil {
            peripheralManager = CBPeripheralManager(delegate: self, queue: nil)
        }
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
    
    private func scheduleReconnect() {
        reconnectTimer?.invalidate()
        
        let delay = min(pow(2.0, Double(reconnectAttempt)), 30.0) // 1s, 2s, 4s, 8s, 16s, 30s...
        reconnectAttempt = min(reconnectAttempt + 1, 6)
        
        print("Reconnecting in \(delay)s (attempt \(reconnectAttempt))")
        
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self = self, !self.isConnected else { return }
            
            if let peripheral = self.connectedDevice {
                // Direct reconnect
                self.connectionStatus = "Reconnecting..."
                self.centralManager.connect(peripheral, options: nil)
            } else if let uuidString = UserDefaults.standard.string(forKey: "lastPeripheralUUID"),
                      let uuid = UUID(uuidString: uuidString) {
                // Try to retrieve by UUID
                let retrieved = self.centralManager.retrievePeripherals(withIdentifiers: [uuid])
                if let peripheral = retrieved.first {
                    self.connectedDevice = peripheral
                    peripheral.delegate = self
                    self.connectionStatus = "Reconnecting..."
                    self.centralManager.connect(peripheral, options: nil)
                } else {
                    // Fall back to scan
                    self.startScanning()
                }
            } else {
                // No saved peripheral - scan
                self.startScanning()
            }
        }
    }
    
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
        guard isConnected,
              let peripheral = connectedDevice,
              let characteristic = discoveredCharacteristics.first(where: { $0.uuid == characteristicUUID }) else {
            // Queue message for later
            messageQueue.append(BLEData(data: data, characteristicUUID: characteristicUUID))
            return
        }
        
        peripheral.writeValue(data, for: characteristic, type: .withResponse)
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
        reconnectAttempt = 0
        reconnectTimer?.invalidate()
        
        // Start keepalive (ping every 20 seconds)
        startKeepalive()
        
        peripheral.discoverServices([serviceUUID])
    }
    
    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        print("Disconnected from: \(peripheral.name ?? "Unknown")")
        
        isConnected = false
        connectionStatus = "Disconnected"
        stopKeepalive()
        
        // Keep peripheral reference for reconnect
        // Don't set connectedDevice = nil
        
        // Reconnect with exponential backoff
        scheduleReconnect()
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
            print("Write error: \(error.localizedDescription)")
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
        switch peripheral.state {
        case .poweredOn:
            // Advertise as BLE peripheral for watch discovery
            let advertisementData: [String: Any] = [
                CBAdvertisementDataLocalNameKey: "iPhone-WatchBridge",
                CBAdvertisementDataServiceUUIDsKey: [serviceUUID]
            ]
            peripheralManager.startAdvertising(advertisementData)
        default:
            peripheralManager.stopAdvertising()
        }
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

