import Foundation

/// Hetzner Cloud has no deployments — we surface servers and their status
/// (running / stopped), which is what you want at a glance anyway.
struct HetznerProvider: ProviderClient {
    let account: ProviderAccount
    let token: String

    private static let base = URL(string: "https://api.hetzner.cloud/v1")!

    // MARK: - API types

    private struct ServersResponse: Decodable {
        let servers: [Server]

        struct Server: Decodable {
            let id: Int
            let name: String
            let status: String
            let created: Date?
            let publicNet: PublicNet?
            let serverType: ServerType?
            let datacenter: Datacenter?

            enum CodingKeys: String, CodingKey {
                case id, name, status, created, datacenter
                case publicNet = "public_net"
                case serverType = "server_type"
            }

            struct PublicNet: Decodable {
                let ipv4: IPv4?
                struct IPv4: Decodable {
                    let ip: String?
                }
            }
            struct ServerType: Decodable {
                let name: String?
            }
            struct Datacenter: Decodable {
                let location: Location?
                struct Location: Decodable {
                    let name: String?
                }
            }

            var deployState: DeployState {
                switch status {
                case "running": return .running
                case "off": return .stopped
                case "initializing", "starting", "stopping", "rebuilding", "migrating": return .building
                case "deleting": return .canceled
                default: return .unknown
                }
            }
        }
    }

    // MARK: - ProviderClient

    func validate() async throws -> String {
        let response = try await HTTP.get(
            Self.base.appendingPathComponent("servers"), bearer: token, as: ServersResponse.self)
        return "\(response.servers.count) server\(response.servers.count == 1 ? "" : "s")"
    }

    func projects() async throws -> [ProjectItem] {
        let response = try await HTTP.get(
            Self.base.appendingPathComponent("servers"), bearer: token, as: ServersResponse.self)
        return response.servers.map { server in
            let type = server.serverType?.name ?? "server"
            let location = server.datacenter?.location?.name
            return ProjectItem(
                providerAccountId: account.id,
                provider: .hetzner,
                name: server.name,
                detail: location.map { "\(type) · \($0)" } ?? type,
                state: server.deployState,
                lastActivity: server.created,
                branch: nil,
                commitMessage: nil,
                buildStart: nil,
                buildDuration: nil,
                previewURL: server.publicNet?.ipv4?.ip.map { "http://\($0)" },
                dashboardURL: URL(string: "https://console.hetzner.cloud/projects"),
                meta: ["serverId": "\(server.id)"]
            )
        }
    }

    func projectActions(for project: ProjectItem) -> [ProjectAction] {
        switch project.state {
        case .running:
            return [
                ProjectAction(id: "reboot", label: "Reboot", symbol: "arrow.clockwise.circle", destructive: true),
                ProjectAction(id: "poweroff", label: "Power Off", symbol: "power", destructive: true)
            ]
        case .stopped:
            return [ProjectAction(id: "poweron", label: "Power On", symbol: "power")]
        default:
            return []
        }
    }

    func perform(actionId: String, project: ProjectItem) async throws {
        guard let serverId = project.meta["serverId"],
              ["poweron", "poweroff", "reboot"].contains(actionId) else { throw ProviderError.unsupported }
        try await HTTP.sendRaw(
            Self.base.appendingPathComponent("servers/\(serverId)/actions/\(actionId)"),
            method: "POST", body: nil, bearer: token)
    }
}
