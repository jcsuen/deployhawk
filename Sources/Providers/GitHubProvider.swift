import Foundation

/// GitHub Actions: recent workflow runs across your most recently pushed
/// repos, with re-run for failures.
struct GitHubProvider: ProviderClient {
    let account: ProviderAccount
    let token: String

    private static let base = URL(string: "https://api.github.com")!
    /// How many recently-pushed repos to scan for workflow runs.
    private static let repoLimit = 15

    // MARK: - API types

    private struct User: Decodable {
        let login: String
    }

    private struct Repo: Decodable {
        let name: String
        let full_name: String
        let pushed_at: Date?
    }

    private struct RunsResponse: Decodable {
        let total_count: Int
        let workflow_runs: [Run]

        struct Run: Decodable {
            let id: Int
            let name: String?
            let display_title: String?
            let head_branch: String?
            let status: String?
            let conclusion: String?
            let html_url: String?
            let run_started_at: Date?
            let created_at: Date?
            let updated_at: Date?

            var deployState: DeployState {
                switch status ?? "" {
                case "queued", "in_progress", "waiting", "pending", "requested": return .building
                case "completed":
                    switch conclusion ?? "" {
                    case "success": return .success
                    case "failure", "timed_out", "startup_failure": return .failure
                    case "cancelled", "skipped", "stale": return .canceled
                    default: return .unknown
                    }
                default: return .unknown
                }
            }

            var duration: TimeInterval? {
                guard let start = run_started_at ?? created_at else { return nil }
                if deployState == .building { return nil }
                guard let end = updated_at else { return nil }
                return end.timeIntervalSince(start)
            }
        }
    }

    private func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(
            url: Self.base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        return components.url!
    }

    private func runs(repo: String, count: Int) async throws -> [RunsResponse.Run] {
        try await HTTP.get(
            url("repos/\(repo)/actions/runs", query: [URLQueryItem(name: "per_page", value: "\(count)")]),
            bearer: token, as: RunsResponse.self).workflow_runs
    }

    // MARK: - ProviderClient

    func validate() async throws -> String {
        try await HTTP.get(url("user"), bearer: token, as: User.self).login
    }

    func projects() async throws -> [ProjectItem] {
        let repos = try await HTTP.get(
            url("user/repos", query: [
                URLQueryItem(name: "sort", value: "pushed"),
                URLQueryItem(name: "per_page", value: "\(Self.repoLimit)")
            ]),
            bearer: token, as: [Repo].self)

        return try await withThrowingTaskGroup(of: ProjectItem?.self) { group in
            for repo in repos {
                group.addTask {
                    guard let run = (try? await runs(repo: repo.full_name, count: 1))?.first else {
                        return nil  // repo without workflow runs — not monitorable
                    }
                    return ProjectItem(
                        providerAccountId: account.id,
                        provider: .github,
                        name: repo.name,
                        detail: run.name,
                        state: run.deployState,
                        lastActivity: run.run_started_at ?? run.created_at,
                        branch: run.head_branch,
                        commitMessage: run.display_title,
                        buildStart: run.run_started_at,
                        buildDuration: run.duration,
                        previewURL: nil,
                        dashboardURL: run.html_url.flatMap(URL.init(string:)),
                        meta: ["repo": repo.full_name]
                    )
                }
            }
            var items: [ProjectItem] = []
            for try await item in group {
                if let item { items.append(item) }
            }
            return items
        }
    }

    func deployments(for project: ProjectItem) async throws -> [DeploymentInfo] {
        guard let repo = project.meta["repo"] else { return [] }
        return try await runs(repo: repo, count: 15).map { run in
            DeploymentInfo(
                id: "\(run.id)",
                state: run.deployState,
                createdAt: run.run_started_at ?? run.created_at,
                duration: run.duration,
                branch: run.head_branch,
                commitMessage: run.display_title.map { title in
                    run.name.map { "\($0) · \(title)" } ?? title
                },
                url: run.html_url,
                canRetry: run.deployState == .failure || run.deployState == .canceled,
                canRollback: false
            )
        }
    }

    /// Re-run a workflow (failed jobs only would be .../rerun-failed-jobs;
    /// full rerun is the safer default).
    func retry(deployment: DeploymentInfo, project: ProjectItem) async throws {
        guard let repo = project.meta["repo"] else { throw ProviderError.unsupported }
        try await HTTP.sendRaw(
            url("repos/\(repo)/actions/runs/\(deployment.id)/rerun"),
            method: "POST", body: nil, bearer: token)
    }
}
