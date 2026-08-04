import Foundation

/// Fly.io via its GraphQL API (api.fly.io/graphql), authenticated with a
/// deploy/auth token (`fly tokens create` or the CLI's stored session).
struct FlyProvider: ProviderClient {
    let account: ProviderAccount
    let token: String

    private static let endpoint = URL(string: "https://api.fly.io/graphql")!

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
            if message.localizedCaseInsensitiveContains("unauthorized")
                || message.localizedCaseInsensitiveContains("unauthenticated") {
                throw ProviderError.invalidToken
            }
            throw ProviderError.message(message)
        }
        guard let data = response.data else { throw ProviderError.message("Empty Fly.io response") }
        return data
    }

    // MARK: - API types

    private struct ViewerData: Decodable {
        let viewer: Viewer
        struct Viewer: Decodable {
            let email: String?
        }
    }

    private struct AppsData: Decodable {
        let apps: Nodes<App>

        struct Nodes<T: Decodable>: Decodable {
            let nodes: [T]
        }

        struct App: Decodable {
            let name: String
            let status: String?
            let hostname: String?
            let organization: Org?
            let currentRelease: Release?

            struct Org: Decodable {
                let slug: String?
            }
        }

        struct Release: Decodable {
            let version: Int?
            let status: String?
            let description: String?
            let createdAt: Date?
        }
    }

    private struct AppReleasesData: Decodable {
        let app: AppNode
        struct AppNode: Decodable {
            let releases: AppsData.Nodes<AppsData.Release>
        }
    }

    private static func appState(_ status: String?, release: AppsData.Release?) -> DeployState {
        switch status ?? "" {
        case "deployed": return .running
        case "suspended": return .stopped
        case "pending": return .building
        case "dead": return .failure
        default:
            switch release?.status ?? "" {
            case "succeeded", "complete": return .running
            case "failed": return .failure
            case "running", "in_progress": return .building
            default: return .unknown
            }
        }
    }

    private static func releaseState(_ status: String?) -> DeployState {
        switch status ?? "" {
        case "succeeded", "complete", "active": return .success
        case "failed": return .failure
        case "running", "in_progress", "pending": return .building
        case "cancelled": return .canceled
        default: return .unknown
        }
    }

    // MARK: - ProviderClient

    func validate() async throws -> String {
        let viewer = try await query("query { viewer { email } }", as: ViewerData.self).viewer
        return viewer.email ?? "Fly.io"
    }

    func projects() async throws -> [ProjectItem] {
        let gql = """
        query { apps { nodes { name status hostname
            organization { slug }
            currentRelease { version status description createdAt } } } }
        """
        let apps = try await query(gql, as: AppsData.self).apps.nodes
        return apps.map { app in
            ProjectItem(
                providerAccountId: account.id,
                provider: .fly,
                name: app.name,
                detail: app.organization?.slug,
                state: Self.appState(app.status, release: app.currentRelease),
                lastActivity: app.currentRelease?.createdAt,
                branch: app.currentRelease?.version.map { "v\($0)" },
                commitMessage: app.currentRelease?.description,
                buildStart: app.currentRelease?.createdAt,
                buildDuration: nil,
                previewURL: app.hostname.map { "https://\($0)" },
                dashboardURL: URL(string: "https://fly.io/apps/\(app.name)"),
                meta: [:]
            )
        }
    }

    func deployments(for project: ProjectItem) async throws -> [DeploymentInfo] {
        let gql = """
        query { app(name: "\(project.name)") {
            releases(first: 15) { nodes { version status description createdAt } } } }
        """
        let releases = try await query(gql, as: AppReleasesData.self).app.releases.nodes
        return releases.map { release in
            DeploymentInfo(
                id: release.version.map { "v\($0)" } ?? UUID().uuidString,
                state: Self.releaseState(release.status),
                createdAt: release.createdAt,
                duration: nil,
                branch: release.version.map { "v\($0)" },
                commitMessage: release.description,
                url: nil,
                canRetry: false,
                canRollback: false
            )
        }
    }
}
