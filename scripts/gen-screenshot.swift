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
    item(.github, "deployhawk", .success, detail: "Release",
         branch: "main", message: "v0.3.0", ago: 600, duration: 312),
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
    (.cloudflare, 2), (.vercel, 1), (.railway, 1), (.hetzner, 1),
    (.netlify, 1), (.render, 1), (.github, 1), (.fly, 1)
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

// MARK: - Server detail render (Hetzner metrics)

// Deterministic plausible series — no randomness so re-renders are stable.
func series(_ base: Double, amp: Double, spike: Int? = nil, spikeValue: Double = 0) -> [Double] {
    (0..<60).map { index in
        var value = base + amp * (sin(Double(index) / 6.5) + 0.4 * sin(Double(index) / 2.3))
        if let spike, abs(index - spike) < 3 { value += spikeValue * (3 - Double(abs(index - spike))) / 3 }
        return max(value, 0)
    }
}

let metrics: [MetricSeries] = [
    MetricSeries(name: "CPU", unit: .percent, values: series(23, amp: 8, spike: 48, spikeValue: 41)),
    MetricSeries(name: "Net in", unit: .bytesPerSecond, values: series(180_000, amp: 90_000)),
    MetricSeries(name: "Net out", unit: .bytesPerSecond, values: series(2_400_000, amp: 900_000, spike: 48, spikeValue: 4_000_000)),
    MetricSeries(name: "Disk read", unit: .bytesPerSecond, values: series(60_000, amp: 40_000)),
    MetricSeries(name: "Disk write", unit: .bytesPerSecond, values: series(340_000, amp: 150_000, spike: 20, spikeValue: 800_000))
]

let serverRows: [(String, String)] = [
    ("IPv4", "95.216.38.112"),
    ("IPv6", "2a01:4f9:2b:1a4::1"),
    ("Type", "cx32 — 4 vCPU · 8 GB RAM · 80 GB disk"),
    ("Image", "Ubuntu 24.04"),
    ("Datacenter", "fsn1"),
    ("Created", "Mar 2, 2025")
]

let detailHeader = HStack(spacing: 8) {
    Image(systemName: "chevron.left").foregroundStyle(.secondary)
    ProviderIcon(kind: .hetzner)
    VStack(alignment: .leading, spacing: 1) {
        Text("db1").font(.headline)
        Text("cx32 · fsn1").font(.caption2).foregroundStyle(.secondary)
    }
    Spacer()
    Image(systemName: "bell").foregroundStyle(.secondary)
    StatusBadge(state: .running)
}
.padding(.horizontal, 12)
.padding(.vertical, 10)

let actionChips = HStack(spacing: 8) {
    Label("Open Site", systemImage: "safari")
        .font(.caption)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
    Spacer()
    Label("Reboot", systemImage: "arrow.clockwise.circle")
        .font(.caption2)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
    Label("Power Off", systemImage: "power")
        .font(.caption2)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
}

let serverSection = VStack(alignment: .leading, spacing: 6) {
    Text("Server").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
    ForEach(serverRows, id: \.0) { row in
        HStack(spacing: 6) {
            Text(row.0).font(.caption).foregroundStyle(.secondary)
                .frame(width: 80, alignment: .leading)
            Text(row.1).font(.caption)
            Spacer()
        }
    }
    Text("Last hour").font(.caption2).foregroundStyle(.tertiary).padding(.top, 2)
    LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())], spacing: 8) {
        ForEach(metrics) { metric in
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(metric.name).font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Text(metric.latestFormatted)
                        .font(.caption2.monospacedDigit().weight(.medium))
                }
                DemoSparkline(values: metric.values).frame(height: 28)
            }
            .padding(6)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}
.padding(8)
.background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
.overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, lineWidth: 1))

let detailContent = VStack(spacing: 0) {
    detailHeader
    Divider()
    VStack(alignment: .leading, spacing: 8) {
        actionChips
        serverSection
    }
    .padding(12)
}
.frame(width: 360)
.background(Color(nsColor: .windowBackgroundColor))
.environment(\.colorScheme, .dark)

let detailRenderer = ImageRenderer(content: detailContent)
detailRenderer.scale = 2
guard let detailImage = detailRenderer.nsImage,
      let detailTiff = detailImage.tiffRepresentation,
      let detailRep = NSBitmapImageRep(data: detailTiff),
      let detailPng = detailRep.representation(using: .png, properties: [:]) else {
    fatalError("detail render failed")
}
try! detailPng.write(to: URL(fileURLWithPath: "docs/screenshots/server-detail.png"))
print("wrote docs/screenshots/server-detail.png")

// MARK: - LinkedIn social card (1200x627)

// Shorter list variant so the panel fits a landscape card without cropping.
let promoList = VStack(spacing: 0) {
    header
    Divider()
    chips
    Divider()
    VStack(spacing: 6) {
        ForEach(Array(projects.prefix(5))) { project in
            ProjectRowView(project: project, compact: false)
        }
    }
    .padding(10)
}
.frame(width: 360)
.background(Color(nsColor: .windowBackgroundColor))
.environment(\.colorScheme, .dark)

let promoListRenderer = ImageRenderer(content: promoList)
promoListRenderer.scale = 2
guard let promoListImage = promoListRenderer.nsImage else { fatalError("promo list render failed") }

let appIcon = NSImage(contentsOfFile: "assets/icon_1024.png")

let providerLogos = HStack(spacing: 14) {
    ForEach(ProviderKind.allCases) { kind in
        if let logo = ProviderIcon.logo(for: kind) {
            Image(nsImage: logo)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 22, height: 22)
                .foregroundStyle(.white)
        }
    }
}

let promo = ZStack {
    LinearGradient(
        colors: [
            Color(red: 0.13, green: 0.12, blue: 0.30),
            Color(red: 0.05, green: 0.05, blue: 0.10)
        ],
        startPoint: .topLeading, endPoint: .bottomTrailing)

    HStack(spacing: 44) {
        VStack(alignment: .leading, spacing: 18) {
            if let appIcon {
                Image(nsImage: appIcon)
                    .resizable()
                    .frame(width: 88, height: 88)
            }
            Text("DeployHawk")
                .font(.system(size: 46, weight: .bold))
                .foregroundStyle(.white)
            Text("Every deploy. Every provider.\nOne menu bar.")
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(.white.opacity(0.75))
                .lineSpacing(4)
            providerLogos
                .padding(.top, 6)
            Text("github.com/jcsuen/deployhawk")
                .font(.system(size: 15, design: .monospaced))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.top, 10)
        }
        Spacer(minLength: 0)
        HStack(alignment: .top, spacing: 18) {
            Image(nsImage: promoListImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 540)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
            Image(nsImage: detailImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(height: 470)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.5), radius: 18, y: 8)
                .offset(y: 36)
        }
    }
    .padding(.horizontal, 52)
    .padding(.vertical, 40)
}
.frame(width: 1200, height: 627)
.environment(\.colorScheme, .dark)

let promoRenderer = ImageRenderer(content: promo)
promoRenderer.scale = 2
guard let promoImage = promoRenderer.nsImage,
      let promoTiff = promoImage.tiffRepresentation,
      let promoRep = NSBitmapImageRep(data: promoTiff),
      let promoPng = promoRep.representation(using: .png, properties: [:]) else {
    fatalError("promo render failed")
}
try! FileManager.default.createDirectory(atPath: "docs/social", withIntermediateDirectories: true)
try! promoPng.write(to: URL(fileURLWithPath: "docs/social/deployhawk-linkedin.png"))
print("wrote docs/social/deployhawk-linkedin.png")

}
}

/// Local sparkline copy — DetailView.swift can't be compiled standalone.
struct DemoSparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { geo in
            let maxValue = max(values.max() ?? 1, 1)
            let stepX = geo.size.width / CGFloat(max(values.count - 1, 1))
            let points = values.enumerated().map { index, value in
                CGPoint(
                    x: CGFloat(index) * stepX,
                    y: geo.size.height * (1 - CGFloat(value / maxValue) * 0.9))
            }
            let line = Path { path in
                guard let first = points.first else { return }
                path.move(to: first)
                for point in points.dropFirst() { path.addLine(to: point) }
            }
            let area = Path { path in
                guard let first = points.first, let last = points.last else { return }
                path.move(to: CGPoint(x: first.x, y: geo.size.height))
                path.addLine(to: first)
                for point in points.dropFirst() { path.addLine(to: point) }
                path.addLine(to: CGPoint(x: last.x, y: geo.size.height))
                path.closeSubpath()
            }
            area.fill(Color.accentColor.opacity(0.15))
            line.stroke(Color.accentColor, lineWidth: 1.5)
        }
    }
}
