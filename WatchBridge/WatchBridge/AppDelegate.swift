import UIKit
import UserNotifications
import HealthKit
import CallKit
import CoreBluetooth

class AppDelegate: UIResponder, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        
        // Request notification permissions
        UNUserNotificationCenter.current().delegate = self
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
            print("Notification permission: \(granted)")
        }
        
        // Start BLE early so CoreBluetooth can restore connections in background
        BLEManager.shared.start()

        // Request HealthKit permissions (now that capability is enabled)
        if HKHealthStore.isHealthDataAvailable() {
            let healthStore = HKHealthStore()
            let toRead: Set<HKObjectType> = [HKQuantityType(.heartRate)]
            let toWrite: Set<HKSampleType> = [HKQuantityType(.heartRate)]
            healthStore.requestAuthorization(toShare: toWrite, read: toRead) { success, error in
                print("HealthKit permission: \(success)")
                if let error = error { print("HealthKit auth error: \(error.localizedDescription)") }
            }
        }
        
        return true
    }
    
    // MARK: - Background Modes
    
    func applicationDidEnterBackground(_ application: UIApplication) {
        print("App entered background - maintaining BLE connection")
    }
    
    func applicationWillEnterForeground(_ application: UIApplication) {
        print("App entering foreground")
    }
    
    // MARK: - UNUserNotificationCenterDelegate
    
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        // Show notifications even when app is in foreground
        completionHandler([.banner, .sound, .badge])
    }
    
    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        completionHandler()
    }
}

