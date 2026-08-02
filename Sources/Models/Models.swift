import Foundation

// MARK: - Providers

enum ProviderKind: String, Codable, CaseIterable, Identifiable {
    case cloudflare
    case vercel
    case railway
    case hetzner
    case netlify
    case render

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cloudflare: return "Cloudflare"
        case .vercel: return "Vercel"
        case .railway: return "Railway"
        case .hetzner: return "Hetzner"
        case .netlify: return "Netlify"
        case .render: return "Render"
        }
    }

    var symbol: String {
        switch self {
        case .cloudflare: return "flame.fill"
        case .vercel: return "triangle.fill"
        case .railway: return "tram.fill"
        case .hetzner: return "server.rack"
        case .netlify: return "diamond.fill"
        case .render: return "cube.fill"
        }
    }

    var tokenHelp: String {
        switch self {
        case .cloudflare:
            return "dash.cloudflare.com → My Profile → API Tokens. Needs: Pages:Edit, Workers Scripts:Read, Account Settings:Read."
        case .vercel:
            return "vercel.com/account/tokens — create a token with access to your scope."
        case .railway:
            return "railway.app/account/tokens — create an Account token."
        case .hetzner:
            return "console.hetzner.cloud → project → Security → API Tokens (Read & Write for power actions)."
        case .netlify:
            return "app.netlify.com/user/applications → Personal access tokens."
        case .render:
            return "dashboard.render.com → Account Settings → API Keys."
        }
    }
}

/// A configured provider connection. The token itself lives in the Keychain
/// under "token-<id>"; only metadata is persisted in UserDefaults.
struct ProviderAccount: Codable, Identifiable, Hashable {
    let id: UUID
    let kind: ProviderKind
    var label: String
    /// Path of a CLI credential file to re-read on every poll (e.g. wrangler's
    /// config, whose OAuth session token rotates). nil = static Keychain token.
    var tokenSourcePath: String?

    var keychainKey: String { "token-\(id.uuidString)" }
}

// MARK: - Unified status

enum DeployState: Int, Comparable {
    case failure = 0
    case building = 1
    case success = 2
    case running = 3
    case stopped = 4
    case canceled = 5
    case unknown = 6

    static func < (lhs: DeployState, rhs: DeployState) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .building: return "Building"
        case .success: return "Success"
        case .failure: return "Failed"
        case .running: return "Running"
        case .stopped: return "Stopped"
        case .canceled: return "Canceled"
        case .unknown: return "—"
        }
    }
}

// MARK: - Unified project / deployment

struct ProjectItem: Identifiable {
    let providerAccountId: UUID
    let provider: ProviderKind
    let name: String
    let detail: String?          // e.g. "Pages", "Worker", server type, region
    let state: DeployState
    let lastActivity: Date?
    let branch: String?
    let commitMessage: String?
    /// Open-ended while building (UI recomputes against now); final otherwise.
    let buildStart: Date?
    let buildDuration: TimeInterval?
    let previewURL: String?
    let dashboardURL: URL?
    /// Provider-specific identifiers needed for follow-up API calls.
    let meta: [String: String]

    var id: String { "\(provider.rawValue):\(providerAccountId):\(name):\(detail ?? "")" }

    var currentDuration: TimeInterval? {
        if state == .building, let start = buildStart { return Date().timeIntervalSince(start) }
        return buildDuration
    }
}

struct DeploymentInfo: Identifiable {
    let id: String
    let state: DeployState
    let createdAt: Date?
    let duration: TimeInterval?
    let branch: String?
    let commitMessage: String?
    let url: String?
    let canRetry: Bool
    let canRollback: Bool
    var commitHash: String?
    /// Provider-specific identifiers for follow-up calls (e.g. worker version id).
    var meta: [String: String] = [:]
}

/// Provider-specific facts about a project/server, fetched on demand for the
/// detail view (e.g. Hetzner server specs + CPU metrics).
struct ProjectDetailInfo {
    var rows: [(label: String, value: String)] = []
    /// Recent CPU utilisation samples (percent, oldest first).
    var cpuSeries: [Double]?
}

/// Rich per-deployment info fetched on demand for the drill-down view.
struct DeploymentDetail {
    var buildCommand: String?
    var outputDir: String?
    var rootDir: String?
    var logs: String?
    var dashboardURL: URL?
}

/// A provider-specific action on a whole project/server (not a single
/// deployment) — e.g. Hetzner power off, Railway restart, Netlify build.
struct ProjectAction: Identifiable {
    let id: String
    let label: String
    let symbol: String
    var destructive: Bool = false
}

enum SortOrder: String, CaseIterable {
    case recent
    case status
    case name

    var label: String {
        switch self {
        case .recent: return "Recent"
        case .status: return "Status"
        case .name: return "Name"
        }
    }
}

enum ProviderError: LocalizedError {
    case http(Int)
    case invalidToken
    case message(String)
    case unsupported

    var errorDescription: String? {
        switch self {
        case .http(let code): return "HTTP \(code)"
        case .invalidToken: return "Invalid or expired API token"
        case .message(let msg): return msg
        case .unsupported: return "Not supported by this provider"
        }
    }
}

func formatDuration(_ interval: TimeInterval) -> String {
    let s = Int(interval)
    if s < 60 { return "\(s)s" }
    return "\(s / 60)m \(s % 60)s"
}
