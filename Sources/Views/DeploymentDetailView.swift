import SwiftUI

/// Third navigation level: everything about one deployment — commit details,
/// build configuration, links, and inline build logs.
@MainActor
struct DeploymentDetailView: View {
    let store: DeploymentStore
    let project: ProjectItem
    let deployment: DeploymentInfo
    let onBack: () -> Void

    @State private var detail = DeploymentDetail()
    @State private var loadingLogs = true

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    statusBlock
                    section("Commit Details") { commitRows }
                    if detail.buildCommand != nil || detail.outputDir != nil || detail.rootDir != nil {
                        section("Build Configuration") { buildRows }
                    }
                    section("Links") { linkRows }
                    logsSection
                }
                .padding(12)
            }
        }
        .frame(width: 360)
        .frame(minHeight: 200, maxHeight: 560)
        .task {
            loadingLogs = true
            detail = (try? await store.deploymentDetail(deployment, project: project)) ?? DeploymentDetail()
            loadingLogs = false
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            VStack(alignment: .leading, spacing: 1) {
                Text(project.name)
                    .font(.headline)
                    .lineLimit(1)
                Text("Deployment #\(String(deployment.id.prefix(8)))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            StatusBadge(state: deployment.state)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var statusBlock: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(deployment.state.label)
                .font(.title3.weight(.semibold))
            Spacer()
            if let duration = deployment.duration {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(formatDuration(duration))
                        .font(.callout.monospacedDigit().weight(.medium))
                    Text("Build Time")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder
    private var commitRows: some View {
        if let branch = deployment.branch {
            infoRow("Branch", branch, symbol: "arrow.triangle.branch")
        }
        if let hash = deployment.commitHash {
            infoRow("Commit", String(hash.prefix(8)), symbol: "number", copyValue: hash)
        }
        if let message = deployment.commitMessage {
            VStack(alignment: .leading, spacing: 4) {
                Label("Message", systemImage: "text.quote")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(message)
                    .font(.caption)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
        }
        if let created = deployment.createdAt {
            infoRow("Deployed", created.formatted(date: .abbreviated, time: .shortened), symbol: "clock")
        }
    }

    @ViewBuilder
    private var buildRows: some View {
        if let command = detail.buildCommand {
            infoRow("Build Command", command, symbol: "terminal", copyValue: command, mono: true)
        }
        if let dir = detail.outputDir {
            infoRow("Output Dir", dir, symbol: "folder", mono: true)
        }
        if let root = detail.rootDir {
            infoRow("Root Dir", root, symbol: "folder.badge.gearshape", mono: true)
        }
    }

    @ViewBuilder
    private var linkRows: some View {
        if let dashboard = detail.dashboardURL ?? project.dashboardURL {
            linkRow("View in Dashboard", url: dashboard, symbol: "rectangle.grid.2x2")
        }
        if let urlString = deployment.url, let url = URL(string: urlString) {
            linkRow(urlString.replacingOccurrences(of: "https://", with: ""), url: url, symbol: "globe")
        }
    }

    @ViewBuilder
    private var logsSection: some View {
        if loadingLogs {
            HStack {
                Spacer()
                ProgressView().controlSize(.small)
                Spacer()
            }
            .padding(.vertical, 8)
        } else if let logs = detail.logs {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Build Logs")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Spacer()
                    CopyButton(value: logs)
                }
                ScrollView([.vertical, .horizontal]) {
                    Text(logs)
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .frame(maxHeight: 180)
                .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
            }
        }
    }

    // MARK: - Row helpers

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 4)
    }

    private func infoRow(_ label: String, _ value: String, symbol: String, copyValue: String? = nil, mono: Bool = false) -> some View {
        HStack(spacing: 6) {
            Label(label, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .leading)
            Text(value)
                .font(mono ? .caption.monospaced() : .caption)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if let copyValue {
                CopyButton(value: copyValue)
            }
        }
    }

    private func linkRow(_ title: String, url: URL, symbol: String) -> some View {
        Button {
            NSWorkspace.shared.open(url)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(Color.accentColor)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
    }
}

struct CopyButton: View {
    let value: String
    @State private var copied = false

    var body: some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            copied = true
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                copied = false
            }
        } label: {
            Label(copied ? "Copied" : "Copy", systemImage: copied ? "checkmark" : "doc.on.doc")
                .font(.caption2)
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
    }
}
