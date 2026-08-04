import Foundation

/// Detects credentials from provider CLIs already logged in on this machine,
/// so users can connect without pasting a token. Tokens are read locally and
/// never leave the machine except toward the provider's own API.
struct CLICredentialSource: Identifiable {
    let kind: ProviderKind
    let cliName: String
    let path: String
    /// Live sources (wrangler OAuth sessions) are re-read on every poll so the
    /// app picks up tokens the CLI refreshes; static ones are copied once.
    let live: Bool

    var id: String { path }
}

enum CLIImporter {
    private static func home(_ rel: String) -> String {
        (NSHomeDirectory() as NSString).appendingPathComponent(rel)
    }

    /// All known CLI credential locations. First match per provider wins.
    private static var candidates: [CLICredentialSource] {
        [
            CLICredentialSource(
                kind: .cloudflare, cliName: "wrangler",
                path: home("Library/Preferences/.wrangler/config/default.toml"), live: true),
            CLICredentialSource(
                kind: .cloudflare, cliName: "wrangler",
                path: home(".wrangler/config/default.toml"), live: true),
            CLICredentialSource(
                kind: .vercel, cliName: "Vercel CLI",
                path: home("Library/Application Support/com.vercel.cli/auth.json"), live: false),
            CLICredentialSource(
                kind: .vercel, cliName: "Vercel CLI",
                path: home(".vercel/auth.json"), live: false),
            CLICredentialSource(
                kind: .netlify, cliName: "Netlify CLI",
                path: home("Library/Preferences/netlify/config.json"), live: false),
            CLICredentialSource(
                kind: .railway, cliName: "Railway CLI",
                path: home(".railway/config.json"), live: false),
            CLICredentialSource(
                kind: .hetzner, cliName: "hcloud CLI",
                path: home(".config/hcloud/cli.toml"), live: false),
            CLICredentialSource(
                kind: .github, cliName: "gh CLI",
                path: home(".config/gh/hosts.yml"), live: false),
            CLICredentialSource(
                kind: .fly, cliName: "flyctl",
                path: home(".fly/config.yml"), live: false),
            CLICredentialSource(
                kind: .digitalocean, cliName: "doctl",
                path: home("Library/Application Support/doctl/config.yaml"), live: false),
            CLICredentialSource(
                kind: .digitalocean, cliName: "doctl",
                path: home(".config/doctl/config.yaml"), live: false),
        ]
    }

    /// Sources that exist on disk and yield a parseable token, one per provider.
    static func detect() -> [CLICredentialSource] {
        var seen = Set<ProviderKind>()
        return candidates.filter { source in
            guard !seen.contains(source.kind),
                  FileManager.default.fileExists(atPath: source.path),
                  readToken(from: source) != nil else { return false }
            seen.insert(source.kind)
            return true
        }
    }

    static func readToken(from source: CLICredentialSource) -> String? {
        guard let content = try? String(contentsOfFile: source.path, encoding: .utf8) else { return nil }
        switch source.kind {
        case .cloudflare:
            // Long-lived api_token wins over the ~1h OAuth session token.
            return tomlValue("api_token", in: content) ?? tomlValue("oauth_token", in: content)
        case .vercel, .railway, .netlify:
            return jsonValue("token", in: content)
        case .hetzner:
            return tomlValue("token", in: content)
        case .github:
            // gh CLI hosts.yml: `oauth_token: gho_…` (unquoted YAML)
            return firstMatch("(?m)^\\s*oauth_token:\\s*(\\S+)", in: content)
        case .fly:
            // flyctl config.yml: `access_token: FlyV1 …` (may contain spaces)
            return firstMatch("(?m)^\\s*access_token:\\s*\"?([^\"\\n]+)\"?", in: content)?
                .trimmingCharacters(in: .whitespaces)
        case .digitalocean:
            // doctl config.yaml: `access-token: dop_v1_…`
            return firstMatch("(?m)^\\s*access-token:\\s*(\\S+)", in: content)
        case .render:
            return nil
        }
    }

    /// `key = "value"` (TOML) — first occurrence.
    private static func tomlValue(_ key: String, in content: String) -> String? {
        firstMatch("(?m)^\\s*\(key)\\s*=\\s*\"([^\"]+)\"", in: content)
    }

    /// `"key": "value"` (JSON) — first occurrence, regardless of nesting.
    private static func jsonValue(_ key: String, in content: String) -> String? {
        firstMatch("\"\(key)\"\\s*:\\s*\"([^\"]+)\"", in: content)
    }

    private static func firstMatch(_ pattern: String, in content: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: content, range: NSRange(content.startIndex..., in: content)),
              let range = Range(match.range(at: 1), in: content) else { return nil }
        let value = String(content[range])
        return value.isEmpty ? nil : value
    }
}
