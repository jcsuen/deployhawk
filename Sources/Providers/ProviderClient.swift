import Foundation

/// One instance per configured ProviderAccount, constructed with its token.
protocol ProviderClient: Sendable {
    var account: ProviderAccount { get }

    /// Validates the token and returns a human label for the connection
    /// (e.g. Cloudflare account name, Vercel username).
    func validate() async throws -> String

    /// All monitorable items (projects, services, servers) with latest status.
    func projects() async throws -> [ProjectItem]

    /// Deployment history for one item; empty if the provider has none.
    func deployments(for project: ProjectItem) async throws -> [DeploymentInfo]

    func retry(deployment: DeploymentInfo, project: ProjectItem) async throws
    func rollback(deployment: DeploymentInfo, project: ProjectItem) async throws

    /// Whole-project actions (restart, power on/off, trigger build, …).
    func projectActions(for project: ProjectItem) -> [ProjectAction]
    func perform(actionId: String, project: ProjectItem) async throws

    /// On-demand drill-down: build config, logs, per-deployment links.
    func deploymentDetail(_ deployment: DeploymentInfo, project: ProjectItem) async throws -> DeploymentDetail

    /// Provider-specific project facts for the detail view (specs, metrics).
    func projectDetail(for project: ProjectItem) async throws -> ProjectDetailInfo?
}

extension ProviderClient {
    func deployments(for project: ProjectItem) async throws -> [DeploymentInfo] { [] }
    func retry(deployment: DeploymentInfo, project: ProjectItem) async throws { throw ProviderError.unsupported }
    func rollback(deployment: DeploymentInfo, project: ProjectItem) async throws { throw ProviderError.unsupported }
    func projectActions(for project: ProjectItem) -> [ProjectAction] { [] }
    func perform(actionId: String, project: ProjectItem) async throws { throw ProviderError.unsupported }
    func deploymentDetail(_ deployment: DeploymentInfo, project: ProjectItem) async throws -> DeploymentDetail {
        DeploymentDetail()
    }
    func projectDetail(for project: ProjectItem) async throws -> ProjectDetailInfo? { nil }
}

enum ProviderFactory {
    static func client(for account: ProviderAccount, token: String) -> ProviderClient {
        switch account.kind {
        case .cloudflare: return CloudflareProvider(account: account, token: token)
        case .vercel: return VercelProvider(account: account, token: token)
        case .railway: return RailwayProvider(account: account, token: token)
        case .hetzner: return HetznerProvider(account: account, token: token)
        case .netlify: return NetlifyProvider(account: account, token: token)
        case .render: return RenderProvider(account: account, token: token)
        case .github: return GitHubProvider(account: account, token: token)
        case .fly: return FlyProvider(account: account, token: token)
        }
    }
}

// MARK: - Shared HTTP helpers

enum HTTP {
    static let iso8601Decoder: JSONDecoder = {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let plain = ISO8601DateFormatter()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { d in
            let container = try d.singleValueContainer()
            if let ms = try? container.decode(Double.self) {
                // Epoch milliseconds (Vercel) or seconds
                return Date(timeIntervalSince1970: ms > 1_000_000_000_000 ? ms / 1000 : ms)
            }
            let str = try container.decode(String.self)
            if let date = withFraction.date(from: str) ?? plain.date(from: str) { return date }
            throw DecodingError.dataCorrupted(.init(
                codingPath: d.codingPath, debugDescription: "Unparseable date: \(str)"))
        }
        return decoder
    }()

    static func get<T: Decodable>(_ url: URL, bearer token: String, as type: T.Type) async throws -> T {
        try await send(url, method: "GET", body: nil, bearer: token, as: type)
    }

    static func send<T: Decodable>(
        _ url: URL, method: String, body: Data?, bearer token: String, as type: T.Type
    ) async throws -> T {
        let data = try await sendRaw(url, method: method, body: body, bearer: token)
        return try iso8601Decoder.decode(T.self, from: data)
    }

    /// For endpoints whose response body we don't care about (may be empty).
    @discardableResult
    static func sendRaw(_ url: URL, method: String, body: Data?, bearer token: String) async throws -> Data {
        var req = URLRequest(url: url)
        req.httpMethod = method
        if !token.isEmpty {
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        if body != nil {
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body
        }
        let (data, response) = try await URLSession.shared.data(for: req)
        if let http = response as? HTTPURLResponse {
            if http.statusCode == 401 || http.statusCode == 403 { throw ProviderError.invalidToken }
            guard (200..<300).contains(http.statusCode) else { throw ProviderError.http(http.statusCode) }
        }
        return data
    }
}
