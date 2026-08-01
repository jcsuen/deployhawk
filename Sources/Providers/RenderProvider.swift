import Foundation

struct RenderProvider: ProviderClient {
    let account: ProviderAccount
    let token: String

    private static let base = URL(string: "https://api.render.com/v1")!

    // MARK: - API types (Render list endpoints wrap each item with a cursor)

    private struct OwnerWrapper: Decodable {
        let owner: Owner
        struct Owner: Decodable {
            let name: String?
            let email: String?
        }
    }

    private struct ServiceWrapper: Decodable {
        let service: Service

        struct Service: Decodable {
            let id: String
            let name: String
            let type: String?
            let suspended: String?
            let updatedAt: Date?
            let serviceDetails: Details?

            struct Details: Decodable {
                let url: String?
            }
        }
    }

    private struct DeployWrapper: Decodable {
        let deploy: Deploy

        struct Deploy: Decodable {
            let id: String
            let status: String?
            let createdAt: Date?
            let finishedAt: Date?
            let commit: Commit?

            struct Commit: Decodable {
                let id: String?
                let message: String?
            }

            var deployState: DeployState {
                switch status ?? "" {
                case "live": return .success
                case "build_failed", "update_failed", "pre_deploy_failed": return .failure
                case "created", "queued", "build_in_progress", "update_in_progress", "pre_deploy_in_progress": return .building
                case "canceled": return .canceled
                case "deactivated": return .stopped
                default: return .unknown
                }
            }

            var duration: TimeInterval? {
                guard let start = createdAt, let end = finishedAt else { return nil }
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

    private func latestDeploys(serviceId: String, limit: Int) async throws -> [DeployWrapper.Deploy] {
        try await HTTP.get(
            url("services/\(serviceId)/deploys", query: [URLQueryItem(name: "limit", value: "\(limit)")]),
            bearer: token, as: [DeployWrapper].self).map(\.deploy)
    }

    // MARK: - ProviderClient

    func validate() async throws -> String {
        let owners = try await HTTP.get(
            url("owners", query: [URLQueryItem(name: "limit", value: "10")]),
            bearer: token, as: [OwnerWrapper].self)
        let names = owners.compactMap { $0.owner.name ?? $0.owner.email }
        return names.isEmpty ? "Render" : names.joined(separator: ", ")
    }

    func projects() async throws -> [ProjectItem] {
        let services = try await HTTP.get(
            url("services", query: [URLQueryItem(name: "limit", value: "100")]),
            bearer: token, as: [ServiceWrapper].self).map(\.service)

        return try await withThrowingTaskGroup(of: ProjectItem.self) { group in
            for service in services {
                group.addTask {
                    let deploy = (try? await latestDeploys(serviceId: service.id, limit: 1))?.first
                    let suspended = service.suspended == "suspended"
                    return ProjectItem(
                        providerAccountId: account.id,
                        provider: .render,
                        name: service.name,
                        detail: service.type,
                        state: suspended ? .stopped : (deploy?.deployState ?? .unknown),
                        lastActivity: deploy?.createdAt ?? service.updatedAt,
                        branch: nil,
                        commitMessage: deploy?.commit?.message,
                        buildStart: deploy?.createdAt,
                        buildDuration: deploy?.duration,
                        previewURL: service.serviceDetails?.url,
                        dashboardURL: URL(string: "https://dashboard.render.com/web/\(service.id)"),
                        meta: ["serviceId": service.id]
                    )
                }
            }
            var items: [ProjectItem] = []
            for try await item in group { items.append(item) }
            return items
        }
    }

    func deployments(for project: ProjectItem) async throws -> [DeploymentInfo] {
        guard let serviceId = project.meta["serviceId"] else { return [] }
        return try await latestDeploys(serviceId: serviceId, limit: 20).map { d in
            DeploymentInfo(
                id: d.id,
                state: d.deployState,
                createdAt: d.createdAt,
                duration: d.duration,
                branch: nil,
                commitMessage: d.commit?.message,
                url: nil,
                canRetry: false,
                canRollback: d.deployState == .success
            )
        }
    }

    func rollback(deployment: DeploymentInfo, project: ProjectItem) async throws {
        guard let serviceId = project.meta["serviceId"] else { throw ProviderError.unsupported }
        let body = try JSONSerialization.data(withJSONObject: ["deployId": deployment.id])
        try await HTTP.sendRaw(url("services/\(serviceId)/rollback"), method: "POST", body: body, bearer: token)
    }

    func projectActions(for project: ProjectItem) -> [ProjectAction] {
        [ProjectAction(id: "deploy", label: "Deploy Latest", symbol: "paperplane")]
    }

    func perform(actionId: String, project: ProjectItem) async throws {
        guard actionId == "deploy", let serviceId = project.meta["serviceId"] else { throw ProviderError.unsupported }
        try await HTTP.sendRaw(
            url("services/\(serviceId)/deploys"), method: "POST",
            body: Data("{}".utf8), bearer: token)
    }
}
