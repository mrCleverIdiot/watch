import Foundation
import Combine

/// Tracks which iOS apps have sent notifications to the watch (reported by the watch
/// over BLE) and which the user has muted. The muted list is pushed to the watch, where
/// it is enforced before any notification is shown. Persisted in UserDefaults.
final class NotificationFilterStore: ObservableObject {
    static let shared = NotificationFilterStore()

    @Published private(set) var discoveredApps: [String] = []
    @Published private(set) var blockedApps: Set<String> = []

    private let discoveredKey = "notif.discoveredApps"
    private let blockedKey = "notif.blockedApps"

    private init() {
        discoveredApps = UserDefaults.standard.stringArray(forKey: discoveredKey) ?? []
        blockedApps = Set(UserDefaults.standard.stringArray(forKey: blockedKey) ?? [])
    }

    /// Called when the watch reports an app id it has seen (SEEN_APP control message).
    func noteSeen(_ appId: String) {
        let id = appId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return }
        DispatchQueue.main.async {
            guard !self.discoveredApps.contains(id) else { return }
            self.discoveredApps.append(id)
            self.discoveredApps.sort()
            UserDefaults.standard.set(self.discoveredApps, forKey: self.discoveredKey)
        }
    }

    func isBlocked(_ appId: String) -> Bool { blockedApps.contains(appId) }

    func setBlocked(_ appId: String, _ blocked: Bool) {
        DispatchQueue.main.async {
            if blocked { self.blockedApps.insert(appId) } else { self.blockedApps.remove(appId) }
            UserDefaults.standard.set(Array(self.blockedApps), forKey: self.blockedKey)
            // Re-sync the watch immediately so the change takes effect.
            BLEManager.shared.pushNotificationFilter()
        }
    }
}
