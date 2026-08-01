import Foundation

struct CloudflareProvider: ProviderClient {
    let account: ProviderAccount
    let token: String

    private static let base = URL(string: "https://api.cloudflare.com/client/v4")!

    // MARK: - API types

    private struct Envelope<T: Decodable>: Decodable {
        let success: Bool
        let result: T?
        let errors: [APIError]

        struct APIError: Decodable {
            let code: Int
            let message: String
        }
    }

    private struct CFAccount: Decodable {
        let id: String
        let name: String
    }

    private struct TokenStatus: Decodable {
        let status: String
    }

    private struct PagesProject: Decodable {
        let name: String
        let subdomain: String?
        let created_on: Date?
        let latest_deployment: PagesDeployment?
    }

    struct PagesDeployment: Decodable {
        let id: String
        let environment: String?
        let url: String?
        let created_on: Date?
        let modified_on: Date?
        let latest_stage: Stage?
        let deployment_trigger: Trigger?
        let build_config: BuildConfig?

        struct BuildConfig: Decodable {
            let build_command: String?
            let destination_dir: String?
            let root_dir: String?
        }

        struct Stage: Decodable {
            let name: String?
            let status: String?
            let ended_on: Date?
        }

        struct Trigger: Decodable {
            let metadata: Metadata?
            struct Metadata: Decodable {
                let branch: String?
                let commit_hash: String?
                let commit_message: String?
            }
        }

        var state: DeployState {
            guard let stage = latest_stage, let status = stage.status else { return .unknown }
            switch status {
            case "success":
                // Only the final "deploy" stage succeeding means live; earlier
                // stages report success while later ones are still running.
                return stage.name == "deploy" ? .success : .building
            case "failure": return .failure
            case "canceled": return .canceled
            case "active", "idle", "queued": return .building
            case "skipped": return stage.name == "deploy" ? .canceled : .building
            default: return .unknown
            }
        }

        var duration: TimeInterval? {
            guard let start = created_on, state != .building,
                  let end = latest_stage?.ended_on ?? modified_on else { return nil }
            return end.timeIntervalSince(start)
        }
    }

    private struct WorkerScript: Decodable {
        let id: String
        let created_on: Date?
        let modified_on: Date?
    }

    private struct WorkersSubdomain: Decodable {
        let subdomain: String?
    }

    // Workers deployments (gradual/versioned) — the result is an object
    // wrapping a "deployments" array, unlike the Pages endpoint.
    private struct WorkerDeploymentsResult: Decodable {
        let deployments: [WorkerDeployment]
    }

    struct WorkerDeployment: Decodable {
        let id: String
        let source: String?
        let strategy: String?
        let author_email: String?
        let created_on: Date?
        let annotations: [String: String]?
        let versions: [VersionRef]?

        struct VersionRef: Decodable {
            let version_id: String
            let percentage: Double?
        }
    }

    // MARK: - Requests

    private func request<T: Decodable>(_ path: String, method: String = "GET", as type: T.Type) async throws -> T {
        let envelope = try await HTTP.send(
            Self.base.appendingPathComponent(path), method: method, body: nil,
            bearer: token, as: Envelope<T>.self)
        guard envelope.success, let result = envelope.result else {
            throw ProviderError.message(envelope.errors.map(\.message).joined(separator: "; "))
        }
        return result
    }

    // MARK: - ProviderClient

    func validate() async throws -> String {
        // /user/tokens/verify only accepts API tokens — wrangler OAuth session
        // tokens fail it despite being valid. Only trust a *negative* verify
        // result for API tokens; the accounts call is the real gate (401/403
        // there throws invalidToken for any token type).
        if let status = try? await request("user/tokens/verify", as: TokenStatus.self),
           status.status != "active" {
            throw ProviderError.invalidToken
        }
        let accounts = try await request("accounts", as: [CFAccount].self)
        return accounts.map(\.name).joined(separator: ", ")
    }

    func projects() async throws -> [ProjectItem] {
        let cfAccounts = try await request("accounts", as: [CFAccount].self)
        var items: [ProjectItem] = []
        for cf in cfAccounts {
            async let pagesTask = request("accounts/\(cf.id)/pages/projects", as: [PagesProject].self)
            async let workersTask = request("accounts/\(cf.id)/workers/scripts", as: [WorkerScript].self)
            // workers.dev subdomain for preview URLs; tolerate absence.
            async let subdomainTask = try? request("accounts/\(cf.id)/workers/subdomain", as: WorkersSubdomain.self)
            let (pages, workers) = try await (pagesTask, workersTask)
            let subdomain = await subdomainTask?.subdomain

            items += pages.map { project in
                let dep = project.latest_deployment
                return ProjectItem(
                    providerAccountId: account.id,
                    provider: .cloudflare,
                    name: project.name,
                    detail: "Pages",
                    state: dep?.state ?? .unknown,
                    lastActivity: dep?.created_on ?? project.created_on,
                    branch: dep?.deployment_trigger?.metadata?.branch,
                    commitMessage: dep?.deployment_trigger?.metadata?.commit_message,
                    buildStart: dep?.created_on,
                    buildDuration: dep?.duration,
                    previewURL: dep?.url ?? project.subdomain.map { "https://\($0)" },
                    dashboardURL: URL(string: "https://dash.cloudflare.com/\(cf.id)/pages/view/\(project.name)"),
                    meta: ["accountId": cf.id]
                )
            }
            items += workers.map { script in
                let dashboard = "https://dash.cloudflare.com/\(cf.id)/workers/services/view/\(script.id)/production"
                return ProjectItem(
                    providerAccountId: account.id,
                    provider: .cloudflare,
                    name: script.id,
                    detail: "Worker",
                    state: .running,
                    lastActivity: script.modified_on ?? script.created_on,
                    branch: nil, commitMessage: nil,
                    buildStart: nil, buildDuration: nil,
                    previewURL: subdomain.map { "https://\(script.id).\($0).workers.dev" },
                    dashboardURL: URL(string: dashboard),
                    meta: ["accountId": cf.id, "logsURL": "\(dashboard)/logs"]
                )
            }
        }
        return items
    }

    func deployments(for project: ProjectItem) async throws -> [DeploymentInfo] {
        guard let accountId = project.meta["accountId"] else { return [] }
        if project.detail == "Worker" {
            return try await workerDeployments(accountId: accountId, script: project.name)
        }
        guard project.detail == "Pages" else { return [] }
        let deployments = try await request(
            "accounts/\(accountId)/pages/projects/\(project.name)/deployments",
            as: [PagesDeployment].self)
        return deployments.map { d in
            DeploymentInfo(
                id: d.id,
                state: d.state,
                createdAt: d.created_on,
                duration: d.duration,
                branch: d.deployment_trigger?.metadata?.branch,
                commitMessage: d.deployment_trigger?.metadata?.commit_message,
                url: d.url,
                canRetry: d.state == .failure || d.state == .canceled,
                canRollback: d.state == .success && d.environment == "production",
                commitHash: d.deployment_trigger?.metadata?.commit_hash,
                meta: [
                    "buildCommand": d.build_config?.build_command ?? "",
                    "outputDir": d.build_config?.destination_dir ?? "",
                    "rootDir": d.build_config?.root_dir ?? ""
                ]
            )
        }
    }

    private struct BuildLogsResult: Decodable {
        let data: [Entry]
        struct Entry: Decodable {
            let ts: String?
            let line: String?
        }
    }

    func deploymentDetail(_ deployment: DeploymentInfo, project: ProjectItem) async throws -> DeploymentDetail {
        guard project.detail == "Pages", let accountId = project.meta["accountId"] else {
            return DeploymentDetail(dashboardURL: project.dashboardURL)
        }
        let logs = try? await request(
            "accounts/\(accountId)/pages/projects/\(project.name)/deployments/\(deployment.id)/history/logs",
            as: BuildLogsResult.self)
        return DeploymentDetail(
            buildCommand: deployment.meta["buildCommand"].flatMap { $0.isEmpty ? nil : $0 },
            outputDir: deployment.meta["outputDir"].flatMap { $0.isEmpty ? nil : $0 },
            rootDir: deployment.meta["rootDir"].flatMap { $0.isEmpty ? nil : $0 },
            logs: logs.flatMap { result in
                let lines = result.data.compactMap(\.line)
                return lines.isEmpty ? nil : lines.joined(separator: "\n")
            },
            dashboardURL: URL(string: "https://dash.cloudflare.com/\(accountId)/pages/view/\(project.name)/\(deployment.id)")
        )
    }

    private func workerDeployments(accountId: String, script: String) async throws -> [DeploymentInfo] {
        let result = try await request(
            "accounts/\(accountId)/workers/scripts/\(script)/deployments",
            as: WorkerDeploymentsResult.self)
        return result.deployments.enumerated().map { index, d in
            let message = d.annotations?["workers/message"]
            let trigger = d.annotations?["workers/triggered_by"] ?? d.source
            let version = d.versions?.max { ($0.percentage ?? 0) < ($1.percentage ?? 0) }
            var parts: [String] = []
            if let trigger { parts.append(trigger) }
            if let author = d.author_email { parts.append(author) }
            return DeploymentInfo(
                id: d.id,
                // The newest deployment is the one serving traffic.
                state: index == 0 ? .running : .success,
                createdAt: d.created_on,
                duration: nil,
                branch: version.map { "v \(String($0.version_id.prefix(8)))" },
                commitMessage: message ?? (parts.isEmpty ? nil : parts.joined(separator: " · ")),
                url: nil,
                canRetry: false,
                // Rolling back = redeploying an older version at 100%.
                canRollback: index > 0 && version != nil,
                meta: version.map { ["versionId": $0.version_id] } ?? [:]
            )
        }
    }

    /// Worker rollback: point a new deployment at the old version (what
    /// `wrangler rollback` does under the hood).
    private func rollbackWorker(versionId: String, accountId: String, script: String) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "strategy": "percentage",
            "versions": [["version_id": versionId, "percentage": 100]],
            "annotations": ["workers/message": "Rollback via DeployHawk"]
        ])
        try await HTTP.sendRaw(
            Self.base.appendingPathComponent("accounts/\(accountId)/workers/scripts/\(script)/deployments"),
            method: "POST", body: body, bearer: token)
    }

    func retry(deployment: DeploymentInfo, project: ProjectItem) async throws {
        guard let accountId = project.meta["accountId"] else { throw ProviderError.unsupported }
        _ = try await request(
            "accounts/\(accountId)/pages/projects/\(project.name)/deployments/\(deployment.id)/retry",
            method: "POST", as: PagesDeployment.self)
    }

    func rollback(deployment: DeploymentInfo, project: ProjectItem) async throws {
        guard let accountId = project.meta["accountId"] else { throw ProviderError.unsupported }
        if project.detail == "Worker" {
            guard let versionId = deployment.meta["versionId"] else { throw ProviderError.unsupported }
            try await rollbackWorker(versionId: versionId, accountId: accountId, script: project.name)
            return
        }
        _ = try await request(
            "accounts/\(accountId)/pages/projects/\(project.name)/deployments/\(deployment.id)/rollback",
            method: "POST", as: PagesDeployment.self)
    }
}
