import AppKit
import Foundation
import UserNotifications

final class FlipNotificationService: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = FlipNotificationService()

    private let center: UNUserNotificationCenter

    private override init() {
        center = .current()
        super.init()
        center.delegate = self
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        let settings = await center.notificationSettings()
        switch settings.authorizationStatus {
        case .authorized, .provisional:
            return true
        case .notDetermined:
            return (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        default:
            return false
        }
    }

    func sendFlipReminder(file: String) async {
        guard await requestAuthorization() else { return }
        let request = UNNotificationRequest(
            identifier: "paper-flip-\(UUID().uuidString)",
            content: Self.makeContent(file: file),
            trigger: nil
        )
        try? await center.add(request)
    }

    static func makeContent(file: String) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = "Đã in xong mặt lẻ"
        content.subtitle = file
        content.body = "Hãy lật và nạp lại giấy, sau đó quay lại ứng dụng để in mặt chẵn."
        content.sound = .default
        content.categoryIdentifier = "PAPER_FLIP_REQUIRED"
        return content
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        completionHandler()
    }
}
