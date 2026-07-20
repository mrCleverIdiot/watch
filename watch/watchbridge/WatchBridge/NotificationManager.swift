import Foundation
import UserNotifications

/// Manages notification forwarding to Samsung Galaxy Watch
class NotificationManager: NSObject {
    static let shared = NotificationManager()
    
    private let notificationCenter = UNUserNotificationCenter.current()
    
    override init() {
        super.init()
        notificationCenter.delegate = self
    }
    
    // MARK: - Public Methods
    
    func registerForNotifications() {
        notificationCenter.requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            print("Notification permission: \(granted)")
        }
    }
    
    func forwardNotification(appName: String, title: String, body: String) {
        // Create notification data for watch
        let notificationData = NotificationData(
            appName: appName,
            title: title,
            body: body,
            timestamp: Date().timeIntervalSince1970,
            iconBase64: nil // Would need to encode app icon
        )
        
        // Send to watch via BLE
        BLEManager.shared.sendNotification(notificationData)
        
        // Also show local notification on phone (optional)
        let content = UNMutableNotificationContent()
        content.title = "Forwarded to Watch"
        content.body = title
        content.sound = .default
        
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        
        notificationCenter.add(request) { error in
            if let error = error {
                print("Error showing notification: \(error.localizedDescription)")
            }
        }
    }
    
    // Note: iOS doesn't provide direct access to other apps' notifications
    // This is a major limitation. Merge likely uses some combination of:
    // 1. ANCS (Apple Notification Center Service) via MFi accessory program
    // 2. Requesting users to enable notification forwarding for specific apps
    // 3. Using undocumented APIs (risky for App Store approval)
    
    // This manager will only handle notifications sent TO our app
    // Full notification mirroring would require additional workarounds
}

// MARK: - UNUserNotificationCenterDelegate

extension NotificationManager: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        // Forward to watch
        forwardNotification(
            appName: notification.request.content.categoryIdentifier,
            title: notification.request.content.title,
            body: notification.request.content.body
        )
        
        completionHandler([.banner, .sound])
    }
    
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }
}

