import Foundation

/// DigitalOcean App Platform apps and their deployments.
struct DigitalOceanProvider: ProviderClient {
    let account: ProviderAccount
    let token: String

    private static let base = URL(string: "https://api.digitalocean.com/v2")!

    // MARK: - API types

    private struct AccountResponse: Decodable {
        let account: Account
        struct Account: Decodable {
            let email: String?
        }
    }

    private struct AppsResponse: Decodable {
        let apps: [App]?

        struct App: Decodable {
            let id: String
            let spec: Spec
            let live_url: String?
            let active_deployment: Deployment?
            let in_progress_deployment: Deployment?
            let last_deployment_created_at: Date?

            struct Spec: Decodable {
                let name: String
            }
        }
    }

    private struct DeploymentsResponse: Decodable {
        let deployments: [Deployment]?
    }

    struct Deployment: Decodable {
        let id: String
        let phase: String?
        let created_at: Date?
        let updated_at: Date?
        let cause: String?

        var deployState: DeployState {
            switch phase ?? "" {
            case "ACTIVE": return .success
            case "ERROR": return .failure
            case "PENDING_BUILD", "PENDING_DEPLOY", "BUILDING", "DEPLOYING": return .building
            case "CANCELED", "SUPERSEDED": return .canceled
            default: return .unknown
            }
        }

        var duration: TimeInterval? {
            guard let start = created_at, deployState != .building,
                  let end = updated_at else { return nil }
            return end.timeIntervalSince(start)
        }
    }

    private func url(_ path: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(
            url: Self.base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        return components.url!
    }

    // MARK: - ProviderClient

    func validate() async throws -> String {
        let response = try await HTTP.get(url("account"), bearer: token, as: AccountResponse.self)
        return response.account.email ?? "DigitalOcean"
    }

    func projects() async throws -> [ProjectItem] {
        let apps = try await HTTP.get(
            url("apps", query: [URLQueryItem(name: "per_page", value: "50")]),
            bearer: token, as: AppsResponse.self).apps ?? []
        return apps.map { app in
            // An in-progress deployment outranks the last active one.
            let deployment = app.in_progress_deployment ?? app.active_deployment
            return ProjectItem(
                providerAccountId: account.id,
                provider: .digitalocean,
                name: app.spec.name,
                detail: nil,
                state: deployment?.deployState ?? .unknown,
                lastActivity: deployment?.created_at ?? app.last_deployment_created_at,
                branch: nil,
                commitMessage: deployment?.cause,
                buildStart: deployment?.created_at,
                buildDuration: deployment?.duration,
                previewURL: app.live_url,
                dashboardURL: URL(string: "https://cloud.digitalocean.com/apps/\(app.id)"),
                meta: ["appId": app.id]
            )
        }
    }

    func deployments(for project: ProjectItem) async throws -> [DeploymentInfo] {
        guard let appId = project.meta["appId"] else { return [] }
        let deployments = try await HTTP.get(
            url("apps/\(appId)/deployments", query: [URLQueryItem(name: "per_page", value: "15")]),
            bearer: token, as: DeploymentsResponse.self).deployments ?? []
        return deployments.map { d in
            DeploymentInfo(
                id: d.id,
                state: d.deployState,
                createdAt: d.created_at,
                duration: d.duration,
                branch: nil,
                commitMessage: d.cause,
                url: nil,
                canRetry: d.deployState == .failure || d.deployState == .canceled,
                canRollback: false
            )
        }
    }

    /// "Retry" = trigger a fresh deployment (force build).
    func retry(deployment: DeploymentInfo, project: ProjectItem) async throws {
        guard let appId = project.meta["appId"] else { throw ProviderError.unsupported }
        let body = try JSONSerialization.data(withJSONObject: ["force_build": true])
        try await HTTP.sendRaw(
            url("apps/\(appId)/deployments"), method: "POST", body: body, bearer: token)
    }

    func projectActions(for project: ProjectItem) -> [ProjectAction] {
        [ProjectAction(id: "deploy", label: "Deploy", symbol: "paperplane")]
    }

    func perform(actionId: String, project: ProjectItem) async throws {
        guard actionId == "deploy", let appId = project.meta["appId"] else { throw ProviderError.unsupported }
        let body = try JSONSerialization.data(withJSONObject: ["force_build": false])
        try await HTTP.sendRaw(
            url("apps/\(appId)/deployments"), method: "POST", body: body, bearer: token)
    }
}
