import Foundation
import UserNotifications
import AppKit

public final class NotificationManager: NSObject, UNUserNotificationCenterDelegate, Sendable {
    public static let shared = NotificationManager()

    // UNUserNotificationCenter aborts the process when the executable is not
    // inside a .app bundle (e.g. `swift run` during development), so fall back
    // to osascript notifications in that case.
    private let hasBundle = Bundle.main.bundleIdentifier != nil

    private override init() {
        super.init()
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().delegate = self
        }
    }

    public func requestAuthorization() {
        guard hasBundle else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, error in
            if let error = error {
                print("Notification authorization error: \(error)")
            }
        }
    }

    func send(title: String, body: String, url: URL?) {
        guard hasBundle else {
            sendFallback(title: title, body: body)
            return
        }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if let url { content.userInfo = ["url": url.absoluteString] }
        let request = UNNotificationRequest(
            identifier: "deployhawk-\(UUID().uuidString)",
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Error adding notification: \(error)")
            }
        }
    }

    private func sendFallback(title: String, body: String) {
        let escapedBody = body.replacingOccurrences(of: "\"", with: "\\\"")
        let escapedTitle = title.replacingOccurrences(of: "\"", with: "\\\"")
        let script = "display notification \"\(escapedBody)\" with title \"\(escapedTitle)\" sound name \"default\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        try? process.run()
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if let urlString = response.notification.request.content.userInfo["url"] as? String,
           let url = URL(string: urlString) {
            NSWorkspace.shared.open(url)
        }
        completionHandler()
    }
}
