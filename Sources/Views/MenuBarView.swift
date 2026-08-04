import SwiftUI

@MainActor
struct MenuBarView: View {
    @Bindable var store: DeploymentStore
    var updateChecker: UpdateChecker? = nil
    @State private var selectedProject: ProjectItem?
    @State private var showSettings = false
    @AppStorage("sortOrder") private var sortOrder: SortOrder = .recent
    @AppStorage("compactMode") private var compactMode = false
    @State private var searchText = ""
    /// Empty = show all providers. Persisted as comma-joined raw values.
    @AppStorage("providerFilter") private var providerFilterRaw = ""

    private var providerFilter: Set<ProviderKind> {
        Set(providerFilterRaw.split(separator: ",").compactMap { ProviderKind(rawValue: String($0)) })
    }

    private func setProviderFilter(_ filter: Set<ProviderKind>) {
        providerFilterRaw = filter.map(\.rawValue).sorted().joined(separator: ",")
    }

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
                if let checker = updateChecker, checker.updateAvailable, let latest = checker.latestVersion {
                    Button {
                        NSWorkspace.shared.open(UpdateChecker.releasesURL)
                    } label: {
                        Label("DeployHawk \(latest) available — click to update", systemImage: "arrow.down.circle.fill")
                            .font(.caption.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                            .background(.blue.opacity(0.15))
                    }
                    .buttonStyle(.plain)
                    Divider()
                }
                projectList
                Divider()
                footer
            }
        }
        // One fixed window size for every screen — MenuBarExtra re-measures on
        // each open, and min/max ranges collapse to the minimum until a
        // navigation forces a relayout (the "tiny window on reopen" bug).
        .frame(width: 360, height: 520)
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

    /// Providers that actually have projects right now, in enum order.
    private var activeProviders: [ProviderKind] {
        let present = Set(store.projects.map(\.provider))
        return ProviderKind.allCases.filter { present.contains($0) }
    }

    private var filteredProjects: [ProjectItem] {
        var result = sortedProjects
        if !providerFilter.isEmpty {
            result = result.filter { providerFilter.contains($0.provider) }
        }
        if !searchText.isEmpty {
            result = result.filter { $0.name.localizedCaseInsensitiveContains(searchText) }
        }
        return result
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
            if activeProviders.count > 1 {
                HStack(spacing: 6) {
                    ForEach(activeProviders) { kind in
                        providerChip(kind)
                    }
                    Spacer()
                    if !providerFilter.isEmpty {
                        Button("All") { setProviderFilter([]) }
                            .buttonStyle(.borderless)
                            .font(.caption2)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                Divider()
            }
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

    private func providerChip(_ kind: ProviderKind) -> some View {
        let isSelected = providerFilter.contains(kind)
        let count = store.projects.filter { $0.provider == kind }.count
        return Button {
            // Tap toggles; selecting the only remaining filter clears back to All.
            var filter = providerFilter
            if isSelected {
                filter.remove(kind)
            } else {
                filter.insert(kind)
            }
            setProviderFilter(filter)
        } label: {
            HStack(spacing: 4) {
                ProviderIcon(kind: kind)
                Text("\(count)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(isSelected ? .primary : .secondary)
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(
                isSelected ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.06),
                in: Capsule())
            .overlay(Capsule().strokeBorder(
                isSelected ? Color.accentColor.opacity(0.6) : .clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(kind.displayName)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
