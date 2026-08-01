import SwiftUI

@MainActor
struct MenuBarView: View {
    @Bindable var store: DeploymentStore
    @State private var selectedProject: ProjectItem?
    @State private var showSettings = false
    @AppStorage("sortOrder") private var sortOrder: SortOrder = .recent
    @AppStorage("compactMode") private var compactMode = false
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            if showSettings {
                SettingsView(store: store, onClose: { showSettings = false })
            } else if let project = selectedProject {
                DetailView(store: store, project: project, onBack: { selectedProject = nil })
            } else if !store.isConfigured {
                onboarding
            } else {
                header
                Divider()
                projectList
                Divider()
                footer
            }
        }
        .frame(width: 360)
        .frame(minHeight: 120, maxHeight: 560)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            Text("DeployHawk")
                .font(.headline)
            if store.buildingCount > 0 {
                Label("\(store.buildingCount)", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption.bold())
                    .foregroundStyle(.orange)
            }
            if store.failureCount > 0 {
                Label("\(store.failureCount)", systemImage: "xmark.circle")
                    .font(.caption.bold())
                    .foregroundStyle(.red)
            }
            Spacer()
            Menu {
                Picker("Sort", selection: $sortOrder) {
                    ForEach(SortOrder.allCases, id: \.self) { order in
                        Text(order.label).tag(order)
                    }
                }
                Toggle("Compact", isOn: $compactMode)
            } label: {
                Image(systemName: "arrow.up.arrow.down")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button {
                Task { await store.refresh() }
            } label: {
                if store.isRefreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)

            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape")
            }
            .buttonStyle(.borderless)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - List

    private var filteredProjects: [ProjectItem] {
        guard !searchText.isEmpty else { return sortedProjects }
        return sortedProjects.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
    }

    private var sortedProjects: [ProjectItem] {
        switch sortOrder {
        case .recent:
            return store.projects.sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
        case .status:
            return store.projects.sorted {
                $0.state == $1.state
                    ? ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast)
                    : $0.state < $1.state
            }
        case .name:
            return store.projects.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }
    }

    private var projectList: some View {
        VStack(spacing: 0) {
            if store.projects.count > 8 {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    TextField("Filter projects", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.callout)
                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                Divider()
            }
            ScrollView {
                LazyVStack(spacing: compactMode ? 2 : 6) {
                    ForEach(errorBanners, id: \.0) { _, message in
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(6)
                            .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
                    }
                    if store.projects.isEmpty {
                        emptyState
                    } else {
                        ForEach(filteredProjects) { project in
                            ProjectRowView(project: project, compact: compactMode)
                                .contentShape(Rectangle())
                                .onTapGesture { selectedProject = project }
                                .contextMenu {
                                    Button(store.mutedProjects.contains(project.id) ? "Unmute Notifications" : "Mute Notifications") {
                                        store.toggleMute(project)
                                    }
                                    if let dashboard = project.dashboardURL {
                                        Button("Open Dashboard") { NSWorkspace.shared.open(dashboard) }
                                    }
                                    if let preview = project.previewURL, let url = URL(string: preview) {
                                        Button("Open Site") { NSWorkspace.shared.open(url) }
                                    }
                                }
                        }
                    }
                }
                .padding(10)
            }
        }
    }

    private var errorBanners: [(UUID, String)] {
        store.errors.map { (accountId, message) in
            let name = store.providerAccounts.first { $0.id == accountId }
                .map { "\($0.kind.displayName) (\($0.label))" } ?? "Account"
            return (accountId, "\(name): \(message)")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: store.isRefreshing ? "hourglass" : "tray")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text(store.isRefreshing ? "Loading projects…" : "No projects found")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 30)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack {
            if let last = store.lastRefresh {
                Text("Updated \(last, style: .relative) ago")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    // MARK: - Onboarding

    private var onboarding: some View {
        VStack(spacing: 12) {
            Image(systemName: "paperplane.fill")
                .font(.largeTitle)
                .foregroundStyle(.indigo)
            Text("Welcome to DeployHawk")
                .font(.headline)
            Text("Monitor Cloudflare, Vercel, Railway and Hetzner deployments from your menu bar.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Connect a provider…") { showSettings = true }
                .buttonStyle(.borderedProminent)
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.borderless)
                .font(.caption)
        }
        .padding(24)
    }
}
