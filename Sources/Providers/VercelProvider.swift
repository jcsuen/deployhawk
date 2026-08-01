import Foundation

struct VercelProvider: ProviderClient {
    let account: ProviderAccount
    let token: String

    private static let base = URL(string: "https://api.vercel.com")!

    // MARK: - API types

    private struct UserResponse: Decodable {
        let user: User
        struct User: Decodable {
            let username: String?
            let name: String?
        }
    }

    private struct TeamsResponse: Decodable {
        let teams: [Team]
        struct Team: Decodable {
            let id: String
            let slug: String?
            let name: String?
        }
    }

    private struct DeploymentsResponse: Decodable {
        let deployments: [Deployment]

        struct Deployment: Decodable {
            let uid: String
            let name: String
            let url: String?
            let state: String?
            let readyState: String?
            let target: String?
            let created: Date?
            let ready: Date?
            let buildingAt: Date?
            let inspectorUrl: String?
            let meta: [String: String]?

            var deployState: DeployState {
                switch (state ?? readyState ?? "").uppercased() {
                case "READY": return .success
                case "ERROR": return .failure
                case "BUILDING", "INITIALIZING", "QUEUED": return .building
                case "CANCELED": return .canceled
                default: return .unknown
                }
            }

            var branch: String? {
                meta?["githubCommitRef"] ?? meta?["gitlabCommitRef"] ?? meta?["bitbucketCommitRef"]
            }

            var commitMessage: String? {
                meta?["githubCommitMessage"] ?? meta?["gitlabCommitMessage"] ?? meta?["bitbucketCommitMessage"]
            }

            var duration: TimeInterval? {
                guard let start = buildingAt ?? created else { return nil }
                if deployState == .building { return nil }
                guard let end = ready else { return nil }
                return end.timeIntervalSince(start)
            }
        }
    }

    // MARK: - Scopes (personal + each team)

    private struct Scope {
        let teamId: String?   // nil = personal
        let slug: String?
    }

    private func scopes() async throws -> [Scope] {
        var result: [Scope] = [Scope(teamId: nil, slug: nil)]
        // Team-scoped tokens can't list /v2/teams personal data; tolerate failure.
        if let teams = try? await HTTP.get(
            Self.base.appendingPathComponent("v2/teams"), bearer: token, as: TeamsResponse.self) {
            result += teams.teams.map { Scope(teamId: $0.id, slug: $0.slug) }
        }
        return result
    }

    private func deploymentsURL(scope: Scope, limit: Int, projectId: String? = nil) -> URL {
        var components = URLComponents(
            url: Self.base.appendingPathComponent("v6/deployments"), resolvingAgainstBaseURL: false)!
        var query = [URLQueryItem(name: "limit", value: "\(limit)")]
        if let teamId = scope.teamId { query.append(URLQueryItem(name: "teamId", value: teamId)) }
        if let projectId { query.append(URLQueryItem(name: "projectId", value: projectId)) }
        components.queryItems = query
        return components.url!
    }

    // MARK: - ProviderClient

    func validate() async throws -> String {
        let response = try await HTTP.get(
            Self.base.appendingPathComponent("v2/user"), bearer: token, as: UserResponse.self)
        return response.user.username ?? response.user.name ?? "Vercel"
    }

    func projects() async throws -> [ProjectItem] {
        var items: [ProjectItem] = []
        for scope in try await scopes() {
            guard let response = try? await HTTP.get(
                deploymentsURL(scope: scope, limit: 50), bearer: token, as: DeploymentsResponse.self)
            else { continue }

            // Latest deployment per project name within this scope.
            var latest: [String: DeploymentsResponse.Deployment] = [:]
            for d in response.deployments {
                if let existing = latest[d.name],
                   (existing.created ?? .distantPast) >= (d.created ?? .distantPast) { continue }
                latest[d.name] = d
            }
            items += latest.values.map { d in
                ProjectItem(
                    providerAccountId: account.id,
                    provider: .vercel,
                    name: d.name,
                    detail: scope.slug,
                    state: d.deployState,
                    lastActivity: d.created,
                    branch: d.branch,
                    commitMessage: d.commitMessage,
                    buildStart: d.buildingAt ?? d.created,
                    buildDuration: d.duration,
                    previewURL: d.url.map { "https://\($0)" },
                    dashboardURL: URL(string: d.inspectorUrl ?? "https://vercel.com"),
                    meta: scope.teamId.map { ["teamId": $0] } ?? [:]
                )
            }
        }
        return items
    }

    func deployments(for project: ProjectItem) async throws -> [DeploymentInfo] {
        var components = URLComponents(
            url: Self.base.appendingPathComponent("v6/deployments"), resolvingAgainstBaseURL: false)!
        var query = [
            URLQueryItem(name: "limit", value: "25"),
            URLQueryItem(name: "app", value: project.name)
        ]
        if let teamId = project.meta["teamId"] { query.append(URLQueryItem(name: "teamId", value: teamId)) }
        components.queryItems = query
        let response = try await HTTP.get(components.url!, bearer: token, as: DeploymentsResponse.self)
        return response.deployments.map { d in
            DeploymentInfo(
                id: d.uid,
                state: d.deployState,
                createdAt: d.created,
                duration: d.duration,
                branch: d.branch,
                commitMessage: d.commitMessage,
                url: d.url.map { "https://\($0)" },
                // Redeploy works from any prior deployment; surface it on failures.
                canRetry: d.deployState == .failure || d.deployState == .canceled,
                // Promote an older production deployment to current (instant rollback).
                canRollback: d.deployState == .success && d.target == "production"
            )
        }
    }

    private func withTeam(_ path: String, project: ProjectItem) -> URL {
        var components = URLComponents(
            url: Self.base.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if let teamId = project.meta["teamId"] {
            components.queryItems = [URLQueryItem(name: "teamId", value: teamId)]
        }
        return components.url!
    }

    /// Redeploy: create a new deployment from an existing one.
    func retry(deployment: DeploymentInfo, project: ProjectItem) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "name": project.name,
            "deploymentId": deployment.id,
            "target": "production"
        ])
        try await HTTP.sendRaw(
            withTeam("v13/deployments", project: project),
            method: "POST", body: body, bearer: token)
    }

    /// Rollback: promote a previous production deployment to current.
    func rollback(deployment: DeploymentInfo, project: ProjectItem) async throws {
        try await HTTP.sendRaw(
            withTeam("v10/projects/\(project.name)/promote/\(deployment.id)", project: project),
            method: "POST", body: nil, bearer: token)
    }
}
