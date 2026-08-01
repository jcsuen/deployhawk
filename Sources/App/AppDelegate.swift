import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NotificationManager.shared.requestAuthorization()
        NSApp.setActivationPolicy(.accessory)
    }
}
