# DeployHawk

macOS menu bar app monitoring deployments across **Cloudflare (Workers + Pages), Vercel, Railway, Hetzner Cloud, Netlify, and Render**. Swift Package Manager executable, SwiftUI `MenuBarExtra(.window)`, zero external dependencies, macOS 14+.

Inspired by MenuFlare (menuflare.net, Cloudflare-only); architecture boilerplate from `../SessionHawk`.

## Build & run

```bash
swift build                     # debug build
swift run                       # dev run (notifications fall back to osascript — no bundle)
./scripts/make-app-bundle.sh    # release .app → /Applications/DeployHawk.app (ad-hoc signed)
```

Icon regen: `swift scripts/gen-icon.swift` fails under this machine's CommandLineTools JIT (AppKit symbols) — compile it instead: `swiftc -o /tmp/gen-icon scripts/gen-icon.swift && /tmp/gen-icon`, then rebuild `assets/AppIcon.icns` with `sips` + `iconutil`.

No tests yet; verify by running the app with real provider tokens.

## Architecture

- `Sources/App/` — `DeployHawkApp.swift` (`@main`, MenuBarExtra, label shows orange building-count / red failure-count badges), `AppDelegate.swift` (`.accessory`, notification auth).
- `Sources/Models/Models.swift` — provider-agnostic types: `ProviderKind`, `ProviderAccount` (token metadata; secret in Keychain under `token-<uuid>`), `DeployState`, `ProjectItem` (unified project/server row, `meta: [String: String]` carries provider-specific IDs), `DeploymentInfo`, `ProviderError`.
- `Sources/Providers/` — `ProviderClient` protocol (`validate`, `projects`, `deployments(for:)`, optional `retry`/`rollback`) + `ProviderFactory` + shared `HTTP` helpers (bearer requests, ISO8601-or-epoch-ms date decoder). One file per provider:
  - `CloudflareProvider` — REST v4; iterates all CF accounts; Pages projects with `latest_deployment` + Workers scripts; retry/rollback for Pages. Status: only stage `deploy` + `success` means live.
  - `VercelProvider` — `/v6/deployments` grouped to latest-per-project, across personal scope and every team (`teamId` param); branch/commit from `meta.githubCommit*`.
  - `RailwayProvider` — GraphQL at backboard.railway.app/graphql/v2 (Account token); projects query then per-project latest deployment in a task group.
  - `HetznerProvider` — servers as items (running/stopped/initializing); no deployment history; power on/off/reboot as project actions.
  - `NetlifyProvider` — sites with `published_deploy`; rollback = publish-deploy restore; Trigger Build action.
  - `RenderProvider` — services (list endpoints wrap items as `{service:…}`/`{deploy:…}` with cursors); per-service latest deploy in a task group; rollback + Deploy Latest action.
- `Sources/Services/CLIImporter.swift` — detects logged-in provider CLIs (wrangler, Vercel/Netlify/Railway CLIs, hcloud) and extracts tokens via regex from their TOML/JSON configs. Wrangler is a **live** source: its OAuth session token rotates ~hourly, so accounts with `tokenSourcePath` re-read the file on every poll (`DeploymentStore.currentToken`) instead of trusting the Keychain copy. OAuth proper is not viable for most providers (only Netlify/Vercel offer third-party OAuth) — CLI import is the low-friction path.
- `Sources/Services/` — `DeploymentStore` (`@Observable @MainActor`; parallel per-account refresh via task group, per-account `errors` dict, keeps stale items when an account errors; state-transition detection → notifications; adaptive poll: 5 s while building, else `pollInterval` default 60 s, via cancellable `Task.sleep` loop — NOT Timer, whose `@Sendable` closure can't capture weak self under Swift 5.9), `Keychain.swift`, `NotificationManager.swift` (osascript fallback when bundle-less; click opens deployment URL).
- `Sources/Views/` — `MenuBarView` (in-popover navigation: list ⇄ detail ⇄ settings; onboarding when no accounts), `ProjectRowView` (+`StatusBadge`, `ProviderIcon`; 1 s ticker for live build duration), `DetailView` (history, retry/rollback buttons gated by `canRetry`/`canRollback`), `SettingsView` (segmented provider picker + SecureField token connect flow, poll interval, notification toggles, SMAppService launch-at-login).

## Conventions & gotchas

- Non-`body` computed view properties are NOT implicitly main-actor — mark view structs `@MainActor` when they touch the store.
- **No IO in view bodies.** `store.client(for:)`/`store.actions(for:)` resolve tokens (file IO, regex) — calling them from a body froze the app once, because SwiftUI re-evaluates bodies every second (relative-time labels). Resolve into `@State` inside `.task`/`load()` instead. Live CLI tokens are re-read once per poll via `refreshLiveTokens()`, never per body.
- Services constructed in `App.init()` via `MainActor.assumeIsolated { }`, stored with `State(initialValue:)`.
- `UNUserNotificationCenter` **aborts** outside a .app bundle — always guard on `Bundle.main.bundleIdentifier != nil`.
- UserDefaults keys: `providerAccounts` (JSON metadata), `sortOrder`, `pollInterval`, `compactMode`, `notifySuccess`, `notifyFailure`. Tokens: Keychain service `com.deployhawk.app`.
- Adding a provider: new file in `Sources/Providers/` conforming to `ProviderClient`, add case to `ProviderKind` (displayName/symbol/tokenHelp) and `ProviderFactory`. Nothing else changes.
- Token scopes — Cloudflare: Pages:Edit (Edit enables retry/rollback), Workers Scripts:Read, Account Settings:Read. Vercel: account token. Railway: Account token (not project token). Hetzner: read-only project token.
- Ad-hoc codesign in make-app-bundle.sh keeps notification permission stable across rebuilds; installs to /Applications for LaunchServices icon registration.
- **Keychain prompts**: with ad-hoc signing every rebuild is a "new app" to Keychain ACLs, so each read can prompt the user. `DeploymentStore` reads the Keychain at most once per account per run (in-memory `tokenCache`), and live CLI-file accounts (wrangler) never touch the Keychain during polls. Never add per-poll Keychain reads. No codesigning identities exist on this machine (`security find-identity -v -p codesigning` → 0), so a stable signing identity isn't available.
