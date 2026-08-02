import SwiftUI

@MainActor
struct DetailView: View {
    let store: DeploymentStore
    let project: ProjectItem
    let onBack: () -> Void

    @State private var deployments: [DeploymentInfo] = []
    @State private var loading = true
    @State private var actionError: String?
    @State private var busy = false
    @State private var pendingAction: ProjectAction?
    // Computed once in load() — resolving actions builds a provider client,
    // which must never happen per body evaluation (main-thread file IO).
    @State private var projectActions: [ProjectAction] = []
    @State private var selectedDeployment: DeploymentInfo?
    @State private var projectInfo: ProjectDetailInfo?

    var body: some View {
        if let selected = selectedDeployment {
            DeploymentDetailView(
                store: store, project: project, deployment: selected,
                onBack: { selectedDeployment = nil })
        } else {
            content
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    links
                    if let actionError {
                        Label(actionError, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    if let info = projectInfo {
                        infoSection(info)
                    }
                    if loading {
                        HStack {
                            Spacer()
                            ProgressView().controlSize(.small)
                            Spacer()
                        }
                        .padding(.vertical, 20)
                    } else if deployments.isEmpty {
                        if project.provider != .hetzner {
                            Text("No deployments found.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.vertical, 12)
                        }
                    } else {
                        Text("Recent deployments")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        ForEach(deployments) { deployment in
                            deploymentRow(deployment)
                                .contentShape(Rectangle())
                                .onTapGesture { selectedDeployment = deployment }
                        }
                    }
                }
                .padding(12)
            }
        }
        .task { await load() }
    }

    private func load() async {
        loading = true
        projectActions = store.actions(for: project)
        async let infoTask = try? store.projectDetail(for: project)
        deployments = (try? await store.deployments(for: project)) ?? []
        projectInfo = await infoTask
        loading = false
    }

    private var header: some View {
        HStack(spacing: 8) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.borderless)
            ProviderIcon(kind: project.provider)
            VStack(alignment: .leading, spacing: 1) {
                Text(project.name)
                    .font(.headline)
                    .lineLimit(1)
                if let detail = project.detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                store.toggleMute(project)
            } label: {
                Image(systemName: store.mutedProjects.contains(project.id) ? "bell.slash.fill" : "bell")
                    .foregroundStyle(store.mutedProjects.contains(project.id) ? .orange : .secondary)
            }
            .buttonStyle(.borderless)
            .help("Mute notifications for this project")
            StatusBadge(state: project.state)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    private var links: some View {
        HStack(spacing: 8) {
            if let preview = project.previewURL, let url = URL(string: preview) {
                LinkChip(title: "Open Site", systemImage: "safari") {
                    NSWorkspace.shared.open(url)
                }
            }
            if let dashboard = project.dashboardURL {
                LinkChip(title: "Dashboard", systemImage: "rectangle.grid.2x2") {
                    NSWorkspace.shared.open(dashboard)
                }
            }
            if let logs = project.meta["logsURL"].flatMap(URL.init(string:)) {
                LinkChip(title: "Logs", systemImage: "text.alignleft") {
                    NSWorkspace.shared.open(logs)
                }
            }
            Spacer()
            ForEach(projectActions) { action in
                if action.destructive {
                    actionButton(action.label, systemImage: action.symbol) {
                        pendingAction = action
                    }
                } else {
                    actionButton(action.label, systemImage: action.symbol) {
                        try await store.perform(action, on: project)
                    }
                }
            }
        }
        .confirmationDialog(
            "\(pendingAction?.label ?? "") \(project.name)?",
            isPresented: Binding(get: { pendingAction != nil }, set: { if !$0 { pendingAction = nil } })
        ) {
            Button(pendingAction?.label ?? "Confirm", role: .destructive) {
                guard let action = pendingAction else { return }
                pendingAction = nil
                Task {
                    do { try await store.perform(action, on: project) }
                    catch { actionError = error.localizedDescription }
                    await load()
                }
            }
            Button("Cancel", role: .cancel) { pendingAction = nil }
        }
    }

    private func deploymentRow(_ deployment: DeploymentInfo) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                StatusBadge(state: deployment.state)
                if let created = deployment.createdAt {
                    Text(created, style: .relative)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let duration = deployment.duration {
                    Text(formatDuration(duration))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if deployment.canRetry {
                    actionButton("Retry", systemImage: "arrow.clockwise") {
                        try await store.retry(deployment, project: project)
                    }
                }
                if deployment.canRollback {
                    actionButton("Rollback", systemImage: "arrow.uturn.backward") {
                        try await store.rollback(to: deployment, project: project)
                    }
                }
                if let urlString = deployment.url, let url = URL(string: urlString) {
                    Button {
                        NSWorkspace.shared.open(url)
                    } label: {
                        Image(systemName: "arrow.up.right.square")
                    }
                    .buttonStyle(.borderless)
                }
                Image(systemName: "chevron.right")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if deployment.branch != nil || deployment.commitMessage != nil {
                HStack(spacing: 4) {
                    if let branch = deployment.branch {
                        Image(systemName: "arrow.triangle.branch").font(.caption2)
                        Text(branch).font(.caption2)
                    }
                    if let message = deployment.commitMessage {
                        Text(message)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, lineWidth: 1))
    }

    private func infoSection(_ info: ProjectDetailInfo) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Server")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(info.rows, id: \.label) { row in
                HStack(spacing: 6) {
                    Text(row.label)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 80, alignment: .leading)
                    Text(row.value)
                        .font(.caption)
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                }
            }
            if !info.metrics.isEmpty {
                Text("Last hour")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible())], spacing: 8) {
                    ForEach(info.metrics) { metric in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(metric.name)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Text(metric.latestFormatted)
                                    .font(.caption2.monospacedDigit().weight(.medium))
                            }
                            SparklineView(values: metric.values)
                                .frame(height: 28)
                        }
                        .padding(6)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
            }
        }
        .padding(8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, lineWidth: 1))
    }

    private func actionButton(_ title: String, systemImage: String, action: @escaping () async throws -> Void) -> some View {
        Button {
            Task {
                busy = true
                actionError = nil
                do {
                    try await action()
                    await load()
                } catch {
                    actionError = error.localizedDescription
                }
                busy = false
            }
        } label: {
            Label(title, systemImage: systemImage)
                .font(.caption2)
        }
        .buttonStyle(.bordered)
        .controlSize(.mini)
        .disabled(busy)
    }
}

/// Minimal line chart for metric series — no axes, filled area under the line.
struct SparklineView: View {
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

struct LinkChip: View {
    let title: String
    let systemImage: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(hovering ? Color.accentColor.opacity(0.15) : Color.clear, in: Capsule())
                .overlay(Capsule().strokeBorder(.quaternary, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
