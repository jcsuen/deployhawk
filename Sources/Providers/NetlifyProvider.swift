import Foundation

struct NetlifyProvider: ProviderClient {
    let account: ProviderAccount
    let token: String

    private static let base = URL(string: "https://api.netlify.com/api/v1")!

    // MARK: - API types

    private struct User: Decodable {
        let full_name: String?
        let email: String?
    }

    private struct Site: Decodable {
        let id: String
        let name: String
        let url: String?
        let admin_url: String?
        let updated_at: Date?
        let published_deploy: Deploy?
    }

    private struct Deploy: Decodable {
        let id: String
        let state: String?
        let created_at: Date?
        let deploy_time: Double?
        let branch: String?
        let title: String?
        let commit_ref: String?
        let deploy_ssl_url: String?
        let context: String?

        var deployState: DeployState {
            switch state ?? "" {
            case "ready", "current": return .success
            case "error": return .failure
            case "new", "building", "enqueued", "processing", "uploading", "uploaded", "preparing", "prepared": return .building
            case "rejected", "deleted", "skipped": return .canceled
            default: return .unknown
            }
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
        let user = try await HTTP.get(url("user"), bearer: token, as: User.self)
        return user.full_name ?? user.email ?? "Netlify"
    }

    func projects() async throws -> [ProjectItem] {
        let sites = try await HTTP.get(
            url("sites", query: [URLQueryItem(name: "per_page", value: "100")]),
            bearer: token, as: [Site].self)
        return sites.map { site in
            let deploy = site.published_deploy
            return ProjectItem(
                providerAccountId: account.id,
                provider: .netlify,
                name: site.name,
                detail: nil,
                state: deploy?.deployState ?? .unknown,
                lastActivity: deploy?.created_at ?? site.updated_at,
                branch: deploy?.branch,
                commitMessage: deploy?.title,
                buildStart: deploy?.created_at,
                buildDuration: deploy?.deploy_time,
                previewURL: site.url,
                dashboardURL: site.admin_url.flatMap(URL.init(string:)),
                meta: ["siteId": site.id]
            )
        }
    }

    func deployments(for project: ProjectItem) async throws -> [DeploymentInfo] {
        guard let siteId = project.meta["siteId"] else { return [] }
        let deploys = try await HTTP.get(
            url("sites/\(siteId)/deploys", query: [URLQueryItem(name: "per_page", value: "20")]),
            bearer: token, as: [Deploy].self)
        return deploys.map { d in
            DeploymentInfo(
                id: d.id,
                state: d.deployState,
                createdAt: d.created_at,
                duration: d.deploy_time,
                branch: d.branch,
                commitMessage: d.title,
                url: d.deploy_ssl_url,
                canRetry: false,
                // "Publish deploy" — restore any previously successful production deploy.
                canRollback: d.deployState == .success && d.context == "production"
            )
        }
    }

    func rollback(deployment: DeploymentInfo, project: ProjectItem) async throws {
        guard let siteId = project.meta["siteId"] else { throw ProviderError.unsupported }
        try await HTTP.sendRaw(
            url("sites/\(siteId)/deploys/\(deployment.id)/restore"),
            method: "POST", body: nil, bearer: token)
    }

    func projectActions(for project: ProjectItem) -> [ProjectAction] {
        [ProjectAction(id: "build", label: "Trigger Build", symbol: "hammer")]
    }

    func perform(actionId: String, project: ProjectItem) async throws {
        guard actionId == "build", let siteId = project.meta["siteId"] else { throw ProviderError.unsupported }
        try await HTTP.sendRaw(
            url("sites/\(siteId)/builds"), method: "POST",
            body: Data("{}".utf8), bearer: token)
    }
}
