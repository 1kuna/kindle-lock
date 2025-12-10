import UserNotifications

@MainActor
final class NotificationService {
    static let shared = NotificationService()

    private let notificationCenter = UNUserNotificationCenter.current()
    private let logger = DebugLogger.shared

    private init() {}

    // MARK: - Authorization

    /// Request notification permission. Returns true if granted.
    func requestAuthorization() async -> Bool {
        do {
            let granted = try await notificationCenter.requestAuthorization(options: [.alert, .sound, .badge])
            logger.log(.progress, "Notification authorization: \(granted ? "granted" : "denied")")
            return granted
        } catch {
            logger.log(.error, "Notification authorization failed: \(error)")
            return false
        }
    }

    /// Check current authorization status
    func checkAuthorizationStatus() async -> UNAuthorizationStatus {
        let settings = await notificationCenter.notificationSettings()
        return settings.authorizationStatus
    }

    // MARK: - Goal Achievement Notification

    /// Send notification when daily reading goal is achieved
    func sendGoalAchievedNotification() async {
        let content = UNMutableNotificationContent()
        content.title = "Goal Complete!"
        content.body = "You've reached your daily reading goal. Your apps are now unlocked."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: "goal-achieved-\(Date().timeIntervalSince1970)",
            content: content,
            trigger: nil  // Deliver immediately
        )

        do {
            try await notificationCenter.add(request)
            logger.log(.progress, "Goal achieved notification sent")
        } catch {
            logger.log(.error, "Failed to send notification: \(error)")
        }
    }

    // MARK: - Badge Management

    /// Clear the app badge
    func clearBadge() {
        UNUserNotificationCenter.current().setBadgeCount(0) { _ in }
    }
}
