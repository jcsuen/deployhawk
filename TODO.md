# DeployHawk — TODO

A macOS menu bar app that monitors deployments across **Cloudflare, Vercel, Railway and Hetzner**.
Inspired by MenuFlare (menuflare.net), boilerplate from ../SessionHawk.

## Done
- [x] TODO.md + CLAUDE.md
- [x] Package.swift (SPM executable, macOS 14+, zero deps)
- [x] App skeleton: MenuBarExtra(.window), AppDelegate (.accessory), template menu bar icon
- [x] Multi-provider architecture: `ProviderClient` protocol + `ProviderFactory`
- [x] CloudflareProvider — Pages (deployments, retry, rollback) + Workers, all CF accounts
- [x] VercelProvider — deployments across personal scope + teams, branch/commit metadata
- [x] RailwayProvider — GraphQL (backboard), projects + latest deployment status
- [x] HetznerProvider — servers with running/stopped/initializing status
- [x] Keychain token storage (one entry per connected account)
- [x] DeploymentStore: parallel refresh across accounts, adaptive polling (5 s building / user interval idle)
- [x] Notifications on build → success/failure transitions, osascript fallback for `swift run`
- [x] MenuBarView (onboarding, sort recent/status/name, compact mode, per-account error banners)
- [x] ProjectRowView (status badge, branch/commit, live build-duration ticker)
- [x] DetailView (deployment history, open site/dashboard, retry & rollback for CF Pages)
- [x] SettingsView (connect/remove providers, poll interval, notification toggles, launch at login via SMAppService)
- [x] Menu bar icon badges: orange count while building, red count on failures
- [x] gen-icon.swift + assets (flame icon, template menubar PNG, .icns)
- [x] make-app-bundle.sh → signed .app in /Applications — builds, launches ✅

## Done (round 2)
- [x] NetlifyProvider — sites + deploys, publish-deploy rollback, Trigger Build action
- [x] RenderProvider — services + deploys, rollback, Deploy Latest action
- [x] Vercel actions: redeploy failed deployments (v13), rollback via promote (v10)
- [x] Railway actions: deploymentRedeploy on failures, Restart (with confirm)
- [x] Hetzner actions: Power On / Power Off / Reboot (destructive ones confirm first)
- [x] Per-project notification mute (bell in detail view + row context menu)
- [x] Filter/search box (appears when >8 projects), row context menu (mute/dashboard/site)
- [x] Confirmation dialog for destructive project actions

## Done (round 3)
- [x] CLI credential import ("Found on this Mac" in Settings): wrangler, Vercel CLI, Netlify CLI, Railway CLI, hcloud
- [x] Live token sources: wrangler's rotating OAuth session is re-read from disk on every poll; Keychain kept in sync
- [x] Friendly "CLI session expired — run wrangler once" error instead of a raw 401

## Done (round 4 — deeper Cloudflare)
- [x] Workers deployment/version history (source, author, gradual-rollout %, version id)
- [x] Worker rollback — repoint deployment at an older version at 100% (wrangler-rollback style)
- [x] workers.dev preview URLs (account subdomain lookup)
- [x] "Logs" quick-link chip on Worker detail (dashboard live logs)
- [x] retry/rollback now pass full DeploymentInfo (meta carries version ids)
- [x] Cloudflare validate() accepts wrangler OAuth tokens (tokens/verify is API-token-only)

## Done (round 5 — deployment drill-down, MenuFlare parity)
- [x] Third navigation level: project → deployment → full detail (DeploymentDetailView)
- [x] Commit details: branch, hash (copy), full message, deployed date
- [x] Build configuration: build command, output dir, root dir (copy)
- [x] Links: per-deployment dashboard URL + preview URL
- [x] Inline build logs (Pages history/logs endpoint), monospaced, copyable
- [x] Keychain prompt fix (in-memory token cache) + view-body IO freeze fix

## Next
- [ ] Verify each provider end-to-end with real tokens (Cloudflare, Vercel, Railway, Hetzner, Netlify, Render) — NEEDS TOKENS
- [ ] Railway: service-level granularity (project → services → deployments per environment)
- [ ] Hetzner: CPU/traffic metrics in detail view
- [ ] More providers: Fly.io, GitHub Actions, DigitalOcean App Platform
- [x] Renamed FlareHawk → DeployHawk (provider-neutral), rocket icon
- [x] Public repo https://github.com/jcsuen/deployhawk + README + PolyForm license + install.sh
- [x] v0.1.0 release with DeployHawk.zip — https://github.com/jcsuen/deployhawk/releases/tag/v0.1.0
- [x] UpdateChecker: GitHub releases API, 24h interval, in-app update banner (DEPLOYHAWK_FAKE_UPDATE to test)

## Improvements over MenuFlare (the inspiration)
1. **Multi-provider** — MenuFlare is Cloudflare-only; DeployHawk unifies CF, Vercel, Railway, Hetzner in one list.
2. **Notifications** on deployment success/failure — MenuFlare makes you look; we tell you.
3. **Retry & rollback** from the menu bar — MenuFlare is read-only.
4. **Keychain** token storage.
5. **Adaptive polling** — 5 s while a build runs, relaxed when idle (kinder to rate limits, faster feedback).
6. **Launch at login via SMAppService** — one toggle, no launchd plists.
7. **Live menu bar state** — building count / failure count visible without opening the popover.
8. **System-native materials** instead of custom themes (auto light/dark for free).
