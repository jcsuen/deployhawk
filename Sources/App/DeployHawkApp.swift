import SwiftUI

@main
struct DeployHawkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var store: DeploymentStore
    @State private var updateChecker: UpdateChecker

    init() {
        // Start polling at launch — waiting for the popover to appear would
        // mean no notifications until the user first clicks the icon.
        let store = MainActor.assumeIsolated { DeploymentStore() }
        _store = State(initialValue: store)
        MainActor.assumeIsolated { store.start() }
        let checker = MainActor.assumeIsolated { UpdateChecker() }
        _updateChecker = State(initialValue: checker)
        MainActor.assumeIsolated { checker.start() }
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(store: store, updateChecker: updateChecker)
        } label: {
            menuBarLabel
        }
        .menuBarExtraStyle(.window)
    }

    // Template image so the system recolors it for light/dark menu bars
    static let menuBarIcon: NSImage? = {
        guard let url = Bundle.main.url(forResource: "menubar-rocket", withExtension: "png"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = true
        image.size = NSSize(width: 18, height: 18)
        return image
    }()

    @ViewBuilder
    private var menuBarLabel: some View {
        let building = store.buildingCount
        let failures = store.failureCount

        HStack(spacing: 3) {
            if let icon = Self.menuBarIcon {
                Image(nsImage: icon)
            } else {
                Image(systemName: "paperplane.fill")
            }
            if building > 0 {
                // Pulsing while builds run — the "something is happening" cue.
                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                    .foregroundColor(.orange)
                    .symbolEffect(.pulse, options: .repeating)
                Text("\(building)")
                    .font(.caption.bold())
            }
            if failures > 0 {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.red)
                Text("\(failures)")
                    .font(.caption.bold())
            }
            if building == 0 && failures == 0 && store.deployFlash {
                // Brief green tick after an instant deploy (Workers upload).
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                    .symbolEffect(.pulse, options: .repeating)
            }
        }
    }
}
