import Foundation
import Observation

@Observable
@MainActor
final class DeploymentStore {
    var providerAccounts: [ProviderAccount] = []
    var projects: [ProjectItem] = []
    var lastRefresh: Date?
    var isRefreshing = false
    /// Per-provider-account error messages from the last refresh.
    var errors: [UUID: String] = [:]

    var isConfigured: Bool { !providerAccounts.isEmpty }
    var buildingCount: Int { projects.filter { $0.state == .building }.count }
    var failureCount: Int { projects.filter { $0.state == .failure }.count }
    /// True briefly after an instant deploy (Workers) — drives a menu bar flash.
    var deployFlash = false
    private var flashGeneration = 0

    private var pollTask: Task<Void, Never>?
    /// Session cache so the Keychain isn't consulted on every poll.
    private var tokenCache: [UUID: String] = [:]
    /// Last seen activity timestamp per project — detects "instant" deploys
    /// (Workers uploads) that never pass through a building state.
    private var previousActivity: [String: Date] = [:]
    /// Consecutive failed polls per account — a banner only shows from the
    /// second consecutive failure, so transient network blips stay silent.
    private var failureStreaks: [UUID: Int] = [:]
    // Last known state per project id, to notify only on transitions.
    private var previousStates: [String: DeployState] = [:]
    /// Project ids excluded from notifications.
    var mutedProjects: Set<String> = []

    private static let accountsKey = "providerAccounts"
    private static let mutedKey = "mutedProjects"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.accountsKey),
           let accounts = try? JSONDecoder().decode([ProviderAccount].self, from: data) {
            providerAccounts = accounts
        }
        mutedProjects = Set(UserDefaults.standard.stringArray(forKey: Self.mutedKey) ?? [])
    }

    func toggleMute(_ item: ProjectItem) {
        if mutedProjects.contains(item.id) {
            mutedProjects.remove(item.id)
        } else {
            mutedProjects.insert(item.id)
        }
        UserDefaults.standard.set(Array(mutedProjects), forKey: Self.mutedKey)
    }

    func start() {
        // DEPLOYHAWK_DEMO=1 runs a scripted deployment lifecycle with fake
        // projects through the real notification/menu-bar pipeline.
        if ProcessInfo.processInfo.environment["DEPLOYHAWK_DEMO"] != nil {
            Task { await runDemoLoop() }
            return
        }
        scheduleNextPoll(after: 0.1)
    }

    // MARK: - Demo mode

    private func runDemoLoop() async {
        let demoAccount = UUID()

        func demoItem(
            _ provider: ProviderKind, _ name: String, _ state: DeployState,
            detail: String? = nil, branch: String? = nil, message: String? = nil,
            activity: Date, buildStart: Date? = nil, duration: TimeInterval? = nil
        ) -> ProjectItem {
            ProjectItem(
                providerAccountId: demoAccount, provider: provider, name: name,
                detail: detail, state: state, lastActivity: activity,
                branch: branch, commitMessage: message,
                buildStart: buildStart, buildDuration: duration,
                previewURL: nil, dashboardURL: nil, meta: [:])
        }

        func apply(_ items: [ProjectItem]) {
            notifyTransitions(items)
            projects = items
            lastRefresh = Date()
        }

        let base = Date()
        var workerDeployedAt = base

        while !Task.isCancelled {
            let steady = { (now: Date) -> [ProjectItem] in
                [
                    demoItem(.cloudflare, "api-gateway", .running, detail: "Worker",
                             activity: workerDeployedAt),
                    demoItem(.hetzner, "db1", .running, detail: "cx32 · fsn1",
                             activity: base.addingTimeInterval(-86_400))
                ]
            }

            // 1 — steady state
            apply(steady(Date()) + [
                demoItem(.vercel, "dashboard", .success, branch: "main",
                         message: "Fix auth redirect", activity: base, duration: 34)
            ])
            try? await Task.sleep(for: .seconds(5))

            // 2 — a build starts: menu bar pulses orange
            let buildStart = Date()
            apply(steady(Date()) + [
                demoItem(.vercel, "dashboard", .building, branch: "main",
                         message: "Add billing page", activity: buildStart, buildStart: buildStart)
            ])
            try? await Task.sleep(for: .seconds(20))

            // 3 — build succeeds: notification fires
            apply(steady(Date()) + [
                demoItem(.vercel, "dashboard", .success, branch: "main",
                         message: "Add billing page", activity: buildStart,
                         duration: Date().timeIntervalSince(buildStart))
            ])
            try? await Task.sleep(for: .seconds(6))

            // 4 — instant Worker deploy: notification + green menu bar flash
            workerDeployedAt = Date()
            apply(steady(Date()) + [
                demoItem(.vercel, "dashboard", .success, branch: "main",
                         message: "Add billing page", activity: buildStart, duration: 21)
            ])
            try? await Task.sleep(for: .seconds(10))

            // 5 — another build starts, then fails: red badge + notification
            let failStart = Date()
            apply(steady(Date()) + [
                demoItem(.railway, "postgres-sync", .building, branch: "main",
                         message: "Bump pg driver", activity: failStart, buildStart: failStart),
                demoItem(.vercel, "dashboard", .success, branch: "main",
                         message: "Add billing page", activity: buildStart, duration: 21)
            ])
            try? await Task.sleep(for: .seconds(12))
            apply(steady(Date()) + [
                demoItem(.railway, "postgres-sync", .failure, branch: "main",
                         message: "Bump pg driver", activity: failStart, duration: 12),
                demoItem(.vercel, "dashboard", .success, branch: "main",
                         message: "Add billing page", activity: buildStart, duration: 21)
            ])
            try? await Task.sleep(for: .seconds(15))
        }
    }

    // MARK: - Account management

    /// Validates the token, stores it in the Keychain and registers the account.
    func addAccount(kind: ProviderKind, token: String, tokenSourcePath: String? = nil) async throws {
        let account = ProviderAccount(
            id: UUID(), kind: kind, label: kind.displayName, tokenSourcePath: tokenSourcePath)
        let client = ProviderFactory.client(for: account, token: token)
        let label = try await client.validate()
        var named = account
        named.label = label
        Keychain.save(token, account: named.keychainKey)
        tokenCache[named.id] = token
        providerAccounts.append(named)
        persistAccounts()
        await refresh()
    }

    /// Connect straight from a detected CLI credential file.
    func importFromCLI(_ source: CLICredentialSource) async throws {
        guard let token = CLIImporter.readToken(from: source) else {
            throw ProviderError.message("Could not read a token from \(source.cliName)")
        }
        try await addAccount(
            kind: source.kind, token: token,
            tokenSourcePath: source.live ? source.path : nil)
    }

    /// Cheap token lookup: in-memory cache, then Keychain (at most once per
    /// account per run — the app is ad-hoc signed, so every rebuild is a "new
    /// app" to the Keychain ACL and each read can prompt). Live CLI files are
    /// NOT read here: this gets called from view bodies via client(for:), and
    /// file IO + regex there pegs the main thread (froze the app once).
    /// refreshLiveTokens() re-reads them once per poll instead.
    private func currentToken(for account: ProviderAccount) -> String? {
        if let cached = tokenCache[account.id] { return cached }
        if let path = account.tokenSourcePath,
           let token = CLIImporter.readToken(from: CLICredentialSource(
                kind: account.kind, cliName: "CLI", path: path, live: true)) {
            tokenCache[account.id] = token
            return token
        }
        guard let token = Keychain.load(account: account.keychainKey) else { return nil }
        tokenCache[account.id] = token
        return token
    }

    /// Re-read rotating CLI credential files (wrangler) — once per poll cycle.
    private func refreshLiveTokens() {
        for account in providerAccounts {
            guard let path = account.tokenSourcePath,
                  let token = CLIImporter.readToken(from: CLICredentialSource(
                    kind: account.kind, cliName: "CLI", path: path, live: true))
            else { continue }
            tokenCache[account.id] = token
        }
    }

    func removeAccount(_ account: ProviderAccount) {
        tokenCache[account.id] = nil
        Keychain.delete(account: account.keychainKey)
        providerAccounts.removeAll { $0.id == account.id }
        projects.removeAll { $0.providerAccountId == account.id }
        errors[account.id] = nil
        persistAccounts()
    }

    private func persistAccounts() {
        if let data = try? JSONEncoder().encode(providerAccounts) {
            UserDefaults.standard.set(data, forKey: Self.accountsKey)
        }
    }

    func client(for item: ProjectItem) -> ProviderClient? {
        guard let account = providerAccounts.first(where: { $0.id == item.providerAccountId }),
              let token = currentToken(for: account) else { return nil }
        return ProviderFactory.client(for: account, token: token)
    }

    // MARK: - Polling

    func refresh() async {
        guard !providerAccounts.isEmpty, !isRefreshing else {
            scheduleNextPoll()
            return
        }
        isRefreshing = true
        defer {
            isRefreshing = false
            scheduleNextPoll()
        }

        refreshLiveTokens()
        var clients: [(ProviderAccount, ProviderClient)] = []
        for account in providerAccounts {
            guard let token = currentToken(for: account) else {
                errors[account.id] = "Token missing from Keychain"
                continue
            }
            clients.append((account, ProviderFactory.client(for: account, token: token)))
        }

        // Collect inside the group, mutate actor state only afterwards
        // (Swift 5.9 rejects isolated-property mutation in the group closure).
        let results = await withTaskGroup(
            of: (UUID, Result<[ProjectItem], Error>).self,
            returning: [(UUID, Result<[ProjectItem], Error>)].self
        ) { group in
            for (account, client) in clients {
                group.addTask {
                    do { return (account.id, .success(try await client.projects())) }
                    catch { return (account.id, .failure(error)) }
                }
            }
            var collected: [(UUID, Result<[ProjectItem], Error>)] = []
            for await result in group { collected.append(result) }
            return collected
        }

        var allItems: [ProjectItem] = []
        var newErrors: [UUID: String] = [:]
        for (accountId, result) in results {
            switch result {
            case .success(let items):
                failureStreaks[accountId] = 0
                allItems += items
            case .failure(let error):
                let streak = (failureStreaks[accountId] ?? 0) + 1
                failureStreaks[accountId] = streak
                // First failure: keep last known items, stay silent.
                guard streak >= 2 else {
                    allItems += projects.filter { $0.providerAccountId == accountId }
                    continue
                }
                let account = clients.first { $0.0.id == accountId }?.0
                if account?.tokenSourcePath != nil, case ProviderError.invalidToken = error {
                    newErrors[accountId] = "CLI session expired — run the \(account?.kind.displayName ?? "") CLI once (e.g. `wrangler whoami`) to refresh it."
                } else {
                    newErrors[accountId] = error.localizedDescription
                }
            }
        }

        // Keep last known items for accounts that errored this round.
        for (accountId, _) in newErrors {
            allItems += projects.filter { $0.providerAccountId == accountId }
        }

        notifyTransitions(allItems)
        projects = allItems
        errors = newErrors
        lastRefresh = Date()
    }

    /// Adaptive polling: 5 s while anything is building, otherwise the user's interval.
    private func scheduleNextPoll(after override: TimeInterval? = nil) {
        pollTask?.cancel()
        let idle = UserDefaults.standard.double(forKey: "pollInterval")
        let interval = override ?? (buildingCount > 0 ? 5 : (idle > 0 ? idle : 60))
        pollTask = Task {
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }

    // MARK: - Notifications

    private func notifyTransitions(_ newItems: [ProjectItem]) {
        let defaults = UserDefaults.standard
        let notifySuccess = defaults.object(forKey: "notifySuccess") as? Bool ?? true
        let notifyFailure = defaults.object(forKey: "notifyFailure") as? Bool ?? true
        for item in newItems {
            let old = previousStates[item.id]
            previousStates[item.id] = item.state
            let oldActivity = previousActivity[item.id]
            previousActivity[item.id] = item.lastActivity

            // Instant deploys (Workers uploads): no building phase, just a
            // jump in the activity timestamp of an already-known project.
            if old != .building, item.state != .building, item.state != .failure,
               let oldA = oldActivity, let newA = item.lastActivity, newA > oldA.addingTimeInterval(1) {
                flashDeploy()
                if notifySuccess, !mutedProjects.contains(item.id) {
                    NotificationManager.shared.send(
                        title: "\(item.name) deployed",
                        body: "\(item.provider.displayName)\(item.detail.map { " \($0)" } ?? "") updated just now",
                        url: item.previewURL.flatMap(URL.init(string:)) ?? item.dashboardURL)
                }
                continue
            }

            guard old == .building, item.state != .building,
                  !mutedProjects.contains(item.id) else { continue }
            switch item.state {
            case .success, .running:
                guard notifySuccess else { break }
                NotificationManager.shared.send(
                    title: "\(item.name) deployed",
                    body: transitionBody(item, verb: "succeeded"),
                    url: item.previewURL.flatMap(URL.init(string:)) ?? item.dashboardURL)
            case .failure:
                guard notifyFailure else { break }
                NotificationManager.shared.send(
                    title: "\(item.name) failed",
                    body: transitionBody(item, verb: "failed"),
                    url: item.dashboardURL)
            default:
                break
            }
        }
    }

    /// Light the menu bar green for 90 s after an instant deploy.
    private func flashDeploy() {
        flashGeneration += 1
        let generation = flashGeneration
        deployFlash = true
        Task {
            try? await Task.sleep(for: .seconds(90))
            if flashGeneration == generation { deployFlash = false }
        }
    }

    private func transitionBody(_ item: ProjectItem, verb: String) -> String {
        var parts = ["\(item.provider.displayName) deployment \(verb)"]
        if let branch = item.branch { parts.append("on \(branch)") }
        if let duration = item.currentDuration { parts.append("in \(formatDuration(duration))") }
        return parts.joined(separator: " ")
    }

    // MARK: - Detail actions

    func deployments(for item: ProjectItem) async throws -> [DeploymentInfo] {
        guard let client = client(for: item) else { return [] }
        return try await client.deployments(for: item)
    }

    func retry(_ deployment: DeploymentInfo, project: ProjectItem) async throws {
        guard let client = client(for: project) else { return }
        try await client.retry(deployment: deployment, project: project)
        await refresh()
    }

    func rollback(to deployment: DeploymentInfo, project: ProjectItem) async throws {
        guard let client = client(for: project) else { return }
        try await client.rollback(deployment: deployment, project: project)
        await refresh()
    }

    func projectDetail(for item: ProjectItem) async throws -> ProjectDetailInfo? {
        guard let client = client(for: item) else { return nil }
        return try await client.projectDetail(for: item)
    }

    func deploymentDetail(_ deployment: DeploymentInfo, project: ProjectItem) async throws -> DeploymentDetail {
        guard let client = client(for: project) else { return DeploymentDetail() }
        return try await client.deploymentDetail(deployment, project: project)
    }

    func actions(for item: ProjectItem) -> [ProjectAction] {
        client(for: item)?.projectActions(for: item) ?? []
    }

    func perform(_ action: ProjectAction, on item: ProjectItem) async throws {
        guard let client = client(for: item) else { return }
        try await client.perform(actionId: action.id, project: item)
        await refresh()
    }
}
