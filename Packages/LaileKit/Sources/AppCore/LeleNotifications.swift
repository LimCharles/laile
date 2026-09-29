import Foundation
import LaileCore
import UserNotifications

/// Puts Lele's reminders on the phone (see `LeleReminders`) and opens the Lele tab when one is
/// tapped. Everything is rescheduled from scratch after each refresh, so a dose marked taken or a
/// finished session drops its reminder.
@MainActor
public final class LeleNotifications: NSObject, UNUserNotificationCenterDelegate {
    public static let shared = LeleNotifications()
    static let prefix = "lele."

    /// Called when the person taps a reminder.
    public var onOpen: (() -> Void)?

    private var center: UNUserNotificationCenter { .current() }

    public func start() {
        center.delegate = self
    }

    @discardableResult
    public func requestAuthorization() async -> Bool {
        (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    public func reschedule(_ reminders: [PlannedReminder]) async {
        let settings = await center.notificationSettings()
        let ours = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(Self.prefix) }
        center.removePendingNotificationRequests(withIdentifiers: ours)
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { return }
        for reminder in reminders.prefix(40) { // iOS keeps at most 64 pending
            let content = UNMutableNotificationContent()
            content.title = "Lele"
            content.body = reminder.body
            content.sound = .default
            content.threadIdentifier = reminder.kind.rawValue
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: reminder.date)
            let request = UNNotificationRequest(identifier: Self.prefix + reminder.id, content: content,
                                                trigger: UNCalendarNotificationTrigger(dateMatching: parts, repeats: false))
            try? await center.add(request)
        }
    }

    public func cancelAll() {
        Task {
            let ours = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(Self.prefix) }
            center.removePendingNotificationRequests(withIdentifiers: ours)
        }
    }

    nonisolated public func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async
        -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    nonisolated public func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        guard response.notification.request.identifier.hasPrefix(Self.prefix) else { return }
        await MainActor.run { onOpen?() }
    }
}
