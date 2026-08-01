import Foundation
import Observation

/// Checks GitHub releases for a newer version once at launch and every 24 h.
@Observable
@MainActor
final class UpdateChecker {
    var latestVersion: String?
    var updateAvailable = false

    static let releasesURL = URL(string: "https://github.com/jcsuen/deployhawk/releases/latest")!
    private static let api = URL(string: "https://api.github.com/repos/jcsuen/deployhawk/releases/latest")!

    private var task: Task<Void, Never>?

    private struct Release: Decodable {
        let tag_name: String
    }

    func start() {
        task = Task {
            while !Task.isCancelled {
                await check()
                try? await Task.sleep(for: .seconds(86_400))
            }
        }
    }

    private func check() async {
        // No bundle version under `swift run` — nothing to compare against.
        guard let current = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String else { return }
        if ProcessInfo.processInfo.environment["DEPLOYHAWK_FAKE_UPDATE"] != nil {
            latestVersion = "99.0.0"
            updateAvailable = true
            return
        }
        guard let release = try? await HTTP.get(Self.api, bearer: "", as: Release.self) else { return }
        let latest = release.tag_name.hasPrefix("v") ? String(release.tag_name.dropFirst()) : release.tag_name
        latestVersion = latest
        updateAvailable = Self.isNewer(latest, than: current)
    }

    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").compactMap { Int($0) }
        let b = current.split(separator: ".").compactMap { Int($0) }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0
            let y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }
}
