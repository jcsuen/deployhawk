import Foundation

/// Railway's public API is GraphQL-only (backboard.railway.app/graphql/v2),
/// authenticated with an Account token.
struct RailwayProvider: ProviderClient {
    let account: ProviderAccount
    let token: String

    private static let endpoint = URL(string: "https://backboard.railway.app/graphql/v2")!

    // MARK: - GraphQL plumbing

    private struct GQLResponse<T: Decodable>: Decodable {
        let data: T?
        let errors: [GQLError]?
        struct GQLError: Decodable {
            let message: String
        }
    }

    private func query<T: Decodable>(_ query: String, as type: T.Type) async throws -> T {
        let body = try JSONSerialization.data(withJSONObject: ["query": query])
        let response = try await HTTP.send(
            Self.endpoint, method: "POST", body: body, bearer: token, as: GQLResponse<T>.self)
        if let errors = response.errors, !errors.isEmpty {
            let message = errors.map(\.message).joined(separator: "; ")
            if message.localizedCaseInsensitiveContains("not authorized") { throw ProviderError.invalidToken }
            throw ProviderError.message(message)
        }
        guard let data = response.data else { throw ProviderError.message("Empty Railway response") }
        return data
    }

    // MARK: - API types

    private struct MeData: Decodable {
        let me: Me
        struct Me: Decodable {
            let name: String?
            let email: String?
        }
    }

    private struct ProjectsData: Decodable {
        let projects: Connection<Project>

        struct Connection<T: Decodable>: Decodable {
            let edges: [Edge<T>]
        }
        struct Edge<T: Decodable>: Decodable {
            let node: T
        }
        struct Project: Decodable {
            let id: String
            let name: String
            let updatedAt: Date?
        }
    }

    private struct DeploymentsData: Decodable {
        let deployments: ProjectsData.Connection<Deployment>

        struct Deployment: Decodable {
            let id: String
            let status: String?
            let createdAt: Date?
            let staticUrl: String?
            let url: String?
            let meta: Meta?

            struct Meta: Decodable {
                let branch: String?
                let commitMessage: String?
            }

            var deployState: DeployState {
                switch (status ?? "").uppercased() {
                case "SUCCESS": return .success
                case "FAILED", "CRASHED": return .failure
                case "BUILDING", "DEPLOYING", "QUEUED", "WAITING", "INITIALIZING": return .building
                case "REMOVED", "REMOVING", "SKIPPED": return .canceled
                case "SLEEPING": return .stopped
                default: return .unknown
                }
            }
        }
    }

    private func latestDeployment(projectId: String, count: Int = 1) async throws -> [DeploymentsData.Deployment] {
        let gql = """
        query { deployments(first: \(count), input: { projectId: "\(projectId)" }) {
            edges { node { id status createdAt staticUrl url meta } } } }
        """
        return try await query(gql, as: DeploymentsData.self).deployments.edges.map(\.node)
    }

    // MARK: - ProviderClient

    func validate() async throws -> String {
        let me = try await query("query { me { name email } }", as: MeData.self).me
        return me.name ?? me.email ?? "Railway"
    }

    func projects() async throws -> [ProjectItem] {
        let gql = "query { projects { edges { node { id name updatedAt } } } }"
        let projects = try await query(gql, as: ProjectsData.self).projects.edges.map(\.node)

        return try await withThrowingTaskGroup(of: ProjectItem.self) { group in
            for project in projects {
                group.addTask {
                    let deployment = (try? await latestDeployment(projectId: project.id))?.first
                    return ProjectItem(
                        providerAccountId: account.id,
                        provider: .railway,
                        name: project.name,
                        detail: nil,
                        state: deployment?.deployState ?? .unknown,
                        lastActivity: deployment?.createdAt ?? project.updatedAt,
                        branch: deployment?.meta?.branch,
                        commitMessage: deployment?.meta?.commitMessage,
                        buildStart: deployment?.createdAt,
                        buildDuration: nil,
                        previewURL: (deployment?.staticUrl).map { "https://\($0)" } ?? deployment?.url,
                        dashboardURL: URL(string: "https://railway.app/project/\(project.id)"),
                        meta: ["projectId": project.id]
                    )
                }
            }
            var items: [ProjectItem] = []
            for try await item in group { items.append(item) }
            return items
        }
    }

    func deployments(for project: ProjectItem) async throws -> [DeploymentInfo] {
        guard let projectId = project.meta["projectId"] else { return [] }
        return try await latestDeployment(projectId: projectId, count: 20).map { d in
            DeploymentInfo(
                id: d.id,
                state: d.deployState,
                createdAt: d.createdAt,
                duration: nil,
                branch: d.meta?.branch,
                commitMessage: d.meta?.commitMessage,
                url: d.staticUrl.map { "https://\($0)" } ?? d.url,
                canRetry: d.deployState == .failure || d.deployState == .canceled,
                canRollback: false
            )
        }
    }

    private struct BoolData: Decodable {}

    /// Redeploy: build & deploy the same commit again.
    func retry(deployment: DeploymentInfo, project: ProjectItem) async throws {
        _ = try await query(
            "mutation { deploymentRedeploy(id: \"\(deployment.id)\") { id } }", as: BoolData.self)
    }

    func projectActions(for project: ProjectItem) -> [ProjectAction] {
        guard project.state == .success || project.state == .running else { return [] }
        return [ProjectAction(id: "restart", label: "Restart", symbol: "arrow.clockwise.circle", destructive: true)]
    }

    /// Restart the latest deployment's containers without rebuilding.
    func perform(actionId: String, project: ProjectItem) async throws {
        guard actionId == "restart", let projectId = project.meta["projectId"] else { throw ProviderError.unsupported }
        guard let latest = try await latestDeployment(projectId: projectId).first else {
            throw ProviderError.message("No deployment to restart")
        }
        _ = try await query(
            "mutation { deploymentRestart(id: \"\(latest.id)\") }", as: BoolData.self)
    }
}
