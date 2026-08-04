// gen-screenshot.swift — renders the project list UI with sample data to
// docs/screenshots/projects.png for the README.
// Build: swiftc scripts/gen-screenshot.swift Sources/Models/Models.swift Sources/Views/ProjectRowView.swift -o <out>
import SwiftUI
import AppKit

@main
struct ScreenshotGen {
@MainActor
static func main() {

StaticRender.enabled = true

func item(
    _ provider: ProviderKind, _ name: String, _ state: DeployState,
    detail: String? = nil, branch: String? = nil, message: String? = nil,
    ago: TimeInterval = 3600, duration: TimeInterval? = nil, building: Bool = false
) -> ProjectItem {
    ProjectItem(
        providerAccountId: UUID(),
        provider: provider,
        name: name,
        detail: detail,
        state: state,
        lastActivity: Date().addingTimeInterval(-ago),
        branch: branch,
        commitMessage: message,
        buildStart: building ? Date().addingTimeInterval(-(duration ?? 40)) : nil,
        buildDuration: building ? nil : duration,
        previewURL: nil,
        dashboardURL: nil,
        meta: [:]
    )
}

let projects = [
    item(.cloudflare, "marketing-site", .building, detail: "Pages",
         branch: "main", message: "Add pricing page", ago: 43, duration: 43, building: true),
    item(.vercel, "dashboard", .success,
         branch: "main", message: "Fix auth redirect loop", ago: 1260, duration: 34),
    item(.railway, "postgres-sync", .failure,
         branch: "main", message: "Bump pg driver to 8.12", ago: 4200),
    item(.cloudflare, "api-gateway", .running, detail: "Worker", ago: 172_800),
    item(.hetzner, "db1", .running, detail: "cx32 · fsn1", ago: 2_592_000),
    item(.netlify, "docs-site", .success,
         branch: "main", message: "Rewrite quickstart guide", ago: 9000, duration: 51),
    item(.render, "worker-queue", .building,
         message: "Deploy triggered via API", ago: 12, duration: 12, building: true),
]

let building = projects.filter { $0.state == .building }.count
let failures = projects.filter { $0.state == .failure }.count

let header = HStack(spacing: 8) {
    Text("DeployHawk")
        .font(.headline)
    Label("\(building)", systemImage: "arrow.triangle.2.circlepath")
        .font(.caption.bold())
        .foregroundStyle(.orange)
    Label("\(failures)", systemImage: "xmark.circle")
        .font(.caption.bold())
        .foregroundStyle(.red)
    Spacer()
    Image(systemName: "arrow.up.arrow.down").foregroundStyle(.secondary)
    Image(systemName: "arrow.clockwise").foregroundStyle(.secondary)
    Image(systemName: "gearshape").foregroundStyle(.secondary)
}
.padding(.horizontal, 12)
.padding(.vertical, 10)

// Provider filter chips — mirrors MenuBarView.providerChip
let chipData: [(ProviderKind, Int)] = [
    (.cloudflare, 2), (.vercel, 1), (.railway, 1),
    (.hetzner, 1), (.netlify, 1), (.render, 1)
]
let chips = HStack(spacing: 6) {
    ForEach(chipData, id: \.0) { kind, count in
        HStack(spacing: 4) {
            ProviderIcon(kind: kind)
            Text("\(count)")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.06), in: Capsule())
    }
    Spacer()
}
.padding(.horizontal, 12)
.padding(.vertical, 6)

let search = HStack(spacing: 6) {
    Image(systemName: "magnifyingglass")
        .foregroundStyle(.secondary)
        .font(.caption)
    Text("Filter projects")
        .font(.callout)
        .foregroundStyle(Color.secondary.opacity(0.6))
    Spacer()
}
.padding(.horizontal, 12)
.padding(.vertical, 6)

let list = VStack(spacing: 6) {
    ForEach(projects) { project in
        ProjectRowView(project: project, compact: false)
    }
}
.padding(10)

let footer = HStack {
    Text("Updated 5 seconds ago")
        .font(.caption2)
        .foregroundStyle(.secondary)
    Spacer()
    Text("Quit")
        .font(.caption)
        .foregroundStyle(.secondary)
}
.padding(.horizontal, 12)
.padding(.vertical, 8)

let content = VStack(spacing: 0) {
    header
    Divider()
    chips
    Divider()
    search
    Divider()
    list
    Divider()
    footer
}
.frame(width: 360)
.background(Color(nsColor: .windowBackgroundColor))
.environment(\.colorScheme, .dark)

NSApplication.shared.appearance = NSAppearance(named: .darkAqua)
let renderer = ImageRenderer(content: content)
renderer.scale = 2

guard let nsImage = renderer.nsImage,
      let tiff = nsImage.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("render failed")
}
try! FileManager.default.createDirectory(atPath: "docs/screenshots", withIntermediateDirectories: true)
try! png.write(to: URL(fileURLWithPath: "docs/screenshots/projects.png"))
print("wrote docs/screenshots/projects.png")

}
}
