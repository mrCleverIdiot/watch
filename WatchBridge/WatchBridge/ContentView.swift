import SwiftUI
import CoreBluetooth
import HealthKit
import Contacts
import UserNotifications

struct ContentView: View {
    @StateObject private var bleManager = BLEManager.shared
    @State private var showingSettings = false
    @State private var showingContacts = false
    
    var body: some View {
        NavigationView {
            ScrollView {
                VStack(spacing: 20) {
                    // Connection Status Card
                    connectionStatusCard
                    
                    // Quick Actions
                    quickActionsGrid
                    
                    // Features List
                    featuresList
                    
                    Spacer()
                }
                .padding()
            }
            .navigationTitle("WatchBridge")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: { showingSettings = true }) {
                        Image(systemName: "gearshape.fill")
                    }
                }
            }
            .sheet(isPresented: $showingSettings) {
                SettingsView()
            }
        }
    }
    
    // MARK: - Subviews
    
    private var connectionStatusCard: some View {
        VStack(spacing: 12) {
            Circle()
                .fill(bleManager.isConnected ? Color.green : Color.red)
                .frame(width: 60, height: 60)
                .overlay(
                    Image(systemName: bleManager.isConnected ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundColor(.white)
                        .font(.system(size: 30))
                )
            
            Text(bleManager.connectionStatus)
                .font(.headline)
                .foregroundColor(bleManager.isConnected ? .green : .red)
            
            if !bleManager.isConnected {
                Button("Connect Watch") {
                    bleManager.startScanning()
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(16)
    }
    
    private var quickActionsGrid: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Quick Actions")
                .font(.headline)
            
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                QuickActionCard(
                    icon: "bell.fill",
                    title: "Sync Contacts",
                    color: .blue
                ) {
                    ContactsManager.shared.syncContactsToWatch()
                }
                
                QuickActionCard(
                    icon: "antenna.radiowaves.left.and.right",
                    title: "Find Watch",
                    color: .orange
                ) {
                    BLEManager.shared.sendFindDeviceCommand()
                }
                
                QuickActionCard(
                    icon: "heart.fill",
                    title: "Health",
                    color: .pink
                ) {
                    // Open health app
                }
                
                QuickActionCard(
                    icon: "music.note",
                    title: "Media",
                    color: .purple
                ) {
                    // Show now playing
                }
            }
        }
    }
    
    private var featuresList: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Features")
                .font(.headline)
            
            FeatureRow(icon: "message.fill", title: "Notifications", isEnabled: bleManager.isConnected)
            FeatureRow(icon: "phone.fill", title: "Calls", isEnabled: bleManager.isConnected)
            FeatureRow(icon: "heart.fill", title: "Health Sync", isEnabled: bleManager.isConnected)
            FeatureRow(icon: "music.note", title: "Media Control", isEnabled: bleManager.isConnected)
            FeatureRow(icon: "person.fill", title: "Contacts", isEnabled: bleManager.isConnected)
        }
    }
}

struct QuickActionCard: View {
    let icon: String
    let title: String
    let color: Color
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.title)
                    .foregroundColor(color)
                
                Text(title)
                    .font(.caption)
                    .foregroundColor(.primary)
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color(.systemGray6))
            .cornerRadius(12)
        }
    }
}

struct FeatureRow: View {
    let icon: String
    let title: String
    let isEnabled: Bool
    
    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(isEnabled ? .green : .gray)
                .frame(width: 24)
            
            Text(title)
            
            Spacer()
            
            Image(systemName: isEnabled ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundColor(isEnabled ? .green : .gray)
        }
        .padding()
        .background(Color(.systemGray6))
        .cornerRadius(12)
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var bluetoothPermission = false
    @State private var healthPermission = false
    @State private var contactsPermission = false
    @State private var notificationsPermission = false
    
    var body: some View {
        NavigationView {
            List {
                Section("Permissions") {
                    PermissionRow(
                        name: "Bluetooth",
                        granted: bluetoothPermission,
                        action: requestBluetoothPermission
                    )
                    
                    PermissionRow(
                        name: "Health",
                        granted: healthPermission,
                        action: requestHealthPermission
                    )
                    
                    PermissionRow(
                        name: "Contacts",
                        granted: contactsPermission,
                        action: requestContactsPermission
                    )
                    
                    PermissionRow(
                        name: "Notifications",
                        granted: notificationsPermission,
                        action: requestNotificationsPermission
                    )
                }
                
                Section("About") {
                    HStack {
                        Text("Version")
                        Spacer()
                        Text("1.0.0")
                    }
                    
                    HStack {
                        Text("Device")
                        Spacer()
                        Text("iPhone")
                    }
                }
                
                Section("Watch Connection") {
                    Button("Reconnect Watch") {
                        BLEManager.shared.stopScanning()
                        BLEManager.shared.startScanning()
                    }
                    
                    Button("Sync Contacts Now") {
                        ContactsManager.shared.syncContactsToWatch()
                    }
                }
            }
            .navigationTitle("Settings")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .onAppear {
                checkPermissions()
            }
        }
    }
    
    private func checkPermissions() {
        // Check Bluetooth
        let bluetoothAuth = CBCentralManager.authorization
        bluetoothPermission = bluetoothAuth == .allowedAlways
        
        // Check Health
        let healthAuth = HKHealthStore().authorizationStatus(for: HKQuantityType(.heartRate))
        healthPermission = healthAuth != .notDetermined
        
        // Check Contacts
        contactsPermission = CNContactStore.authorizationStatus(for: .contacts) == .authorized
        
        // Check Notifications
        // Check sync in onAppear
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            DispatchQueue.main.async {
                notificationsPermission = settings.authorizationStatus == .authorized
            }
        }
    }
    
    private func requestBluetoothPermission() {
        let alert = UIAlertController(
            title: "Bluetooth Permission Required",
            message: "Please enable Bluetooth in Settings > Privacy & Security > Bluetooth",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "Open Settings", style: .default) { _ in
            UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!)
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        
        if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
           let rootViewController = windowScene.windows.first?.rootViewController {
            rootViewController.present(alert, animated: true)
        }
    }
    
    private func requestHealthPermission() {
        let healthStore = HKHealthStore()
        let typesToRead: Set<HKObjectType> = [
            HKQuantityType(.heartRate),
            HKQuantityType(.stepCount),
            HKObjectType.workoutType()
        ]

        let typesToWrite: Set<HKSampleType> = [
            HKQuantityType(.heartRate),
            HKQuantityType(.stepCount),
            HKObjectType.workoutType()
        ]
        
        healthStore.requestAuthorization(toShare: typesToWrite, read: typesToRead) { success, _ in
            DispatchQueue.main.async {
                healthPermission = success
            }
        }
    }
    
    private func requestContactsPermission() {
        ContactsManager.shared.requestContactsPermission { granted in
            DispatchQueue.main.async {
                contactsPermission = granted
            }
        }
    }
    
    private func requestNotificationsPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            DispatchQueue.main.async {
                notificationsPermission = granted
            }
        }
    }
}

struct PermissionRow: View {
    let name: String
    let granted: Bool
    let action: () -> Void
    
    var body: some View {
        HStack {
            Text(name)
            Spacer()
            
            if granted {
                Text("Granted")
                    .foregroundColor(.green)
            } else {
                Button("Grant") {
                    action()
                }
                .foregroundColor(.orange)
            }
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}

