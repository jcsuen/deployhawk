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

    // MARK: - Server detail (specs + CPU metrics)

    private struct ServerResponse: Decodable {
        let server: Server

        struct Server: Decodable {
            let name: String
            let created: Date?
            let publicNet: PublicNet?
            let serverType: ServerType?
            let datacenter: ServersResponse.Server.Datacenter?
            let image: Image?
            let primaryDiskSize: Int?

            enum CodingKeys: String, CodingKey {
                case name, created, datacenter, image
                case publicNet = "public_net"
                case serverType = "server_type"
                case primaryDiskSize = "primary_disk_size"
            }

            struct PublicNet: Decodable {
                let ipv4: IP?
                let ipv6: IP?
                struct IP: Decodable {
                    let ip: String?
                }
            }
            struct ServerType: Decodable {
                let name: String?
                let cores: Int?
                let memory: Double?
                let disk: Int?
            }
            struct Image: Decodable {
                let description: String?
                let name: String?
            }
        }
    }

    func projectDetail(for project: ProjectItem) async throws -> ProjectDetailInfo? {
        guard let serverId = project.meta["serverId"] else { return nil }
        let server = try await HTTP.get(
            Self.base.appendingPathComponent("servers/\(serverId)"),
            bearer: token, as: ServerResponse.self).server

        var rows: [(label: String, value: String)] = []
        if let ip = server.publicNet?.ipv4?.ip { rows.append(("IPv4", ip)) }
        if let ip = server.publicNet?.ipv6?.ip { rows.append(("IPv6", ip)) }
        if let type = server.serverType {
            let cores = type.cores.map { "\($0) vCPU" }
            let memory = type.memory.map { "\(Int($0)) GB RAM" }
            let disk = (server.primaryDiskSize ?? type.disk).map { "\($0) GB disk" }
            let spec = [cores, memory, disk].compactMap { $0 }.joined(separator: " · ")
            rows.append(("Type", "\(type.name ?? "?") — \(spec)"))
        }
        if let os = server.image?.description ?? server.image?.name { rows.append(("Image", os)) }
        if let location = server.datacenter?.location?.name { rows.append(("Datacenter", location)) }
        if let created = server.created {
            rows.append(("Created", created.formatted(date: .abbreviated, time: .omitted)))
        }

        return ProjectDetailInfo(rows: rows, metrics: (try? await metrics(serverId: serverId)) ?? [])
    }

    /// Last hour of CPU / network / disk metrics. The payload nests values as
    /// [[unix_ts, "12.34"], …] so decode via JSONSerialization. RAM is not
    /// available — Hetzner has no agentless memory metric.
    private func metrics(serverId: String) async throws -> [MetricSeries] {
        let iso = ISO8601DateFormatter()
        let end = Date()
        let start = end.addingTimeInterval(-3600)
        var components = URLComponents(
            url: Self.base.appendingPathComponent("servers/\(serverId)/metrics"),
            resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "type", value: "cpu,network,disk"),
            URLQueryItem(name: "start", value: iso.string(from: start)),
            URLQueryItem(name: "end", value: iso.string(from: end)),
            URLQueryItem(name: "step", value: "60")
        ]
        let data = try await HTTP.sendRaw(components.url!, method: "GET", body: nil, bearer: token)
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let metrics = root["metrics"] as? [String: Any],
              let series = metrics["time_series"] as? [String: Any] else { return [] }

        func samples(_ key: String) -> [Double]? {
            guard let entry = series[key] as? [String: Any],
                  let values = entry["values"] as? [[Any]] else { return nil }
            let result = values.compactMap { pair -> Double? in
                guard pair.count == 2 else { return nil }
                if let s = pair[1] as? String { return Double(s) }
                return pair[1] as? Double
            }
            return result.isEmpty ? nil : result
        }

        let wanted: [(key: String, name: String, unit: MetricSeries.Unit)] = [
            ("cpu", "CPU", .percent),
            ("network.0.bandwidth.in", "Net in", .bytesPerSecond),
            ("network.0.bandwidth.out", "Net out", .bytesPerSecond),
            ("disk.0.bandwidth.read", "Disk read", .bytesPerSecond),
            ("disk.0.bandwidth.write", "Disk write", .bytesPerSecond)
        ]
        return wanted.compactMap { spec in
            samples(spec.key).map { MetricSeries(name: spec.name, unit: spec.unit, values: $0) }
        }
    }
}
