import SwiftUI
import ServiceManagement

@MainActor
struct SettingsView: View {
    @Bindable var store: DeploymentStore
    let onClose: () -> Void

    @State private var newKind: ProviderKind = .cloudflare
    @State private var newToken = ""
    @State private var connecting = false
    @State private var connectError: String?

    @AppStorage("pollInterval") private var pollInterval: Double = 60
    @AppStorage("notifySuccess") private var notifySuccess = true
    @AppStorage("notifyFailure") private var notifyFailure = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onClose) {
                    Image(systemName: "chevron.left")
                }
                .buttonStyle(.borderless)
                Text("Settings")
                    .font(.headline)
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    connectedAccounts
                    Divider()
                    importFromCLI
                    addAccount
                    Divider()
                    preferences
                }
                .padding(12)
            }
        }
    }

    // MARK: - Accounts

    private var connectedAccounts: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Connected providers")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            if store.providerAccounts.isEmpty {
                Text("None yet — connect one below.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            ForEach(store.providerAccounts) { account in
                HStack(spacing: 8) {
                    ProviderIcon(kind: account.kind)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(account.kind.displayName)
                            .font(.callout.weight(.medium))
                        Text(account.label)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Button {
                        store.removeAccount(account)
                    } label: {
                        Image(systemName: "trash")
                            .foregroundStyle(.red)
                    }
                    .buttonStyle(.borderless)
                    .help("Disconnect and delete the token from the Keychain")
                }
                .padding(8)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var cliImports: [CLICredentialSource] {
        let connected = Set(store.providerAccounts.map(\.kind))
        return CLIImporter.detect().filter { !connected.contains($0.kind) }
    }

    @ViewBuilder
    private var importFromCLI: some View {
        let sources = cliImports
        if !sources.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Found on this Mac")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(sources) { source in
                    HStack(spacing: 8) {
                        ProviderIcon(kind: source.kind)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(source.kind.displayName)
                                .font(.callout.weight(.medium))
                            Text("Logged in via \(source.cliName)")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Connect") {
                            connectCLI(source)
                        }
                        .controlSize(.small)
                        .disabled(connecting)
                    }
                    .padding(8)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
                }
                if sources.contains(where: { $0.live }) {
                    Text("CLI sessions are re-read automatically when the CLI refreshes them.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            Divider()
        }
    }

    private func connectCLI(_ source: CLICredentialSource) {
        connecting = true
        connectError = nil
        Task {
            do {
                try await store.importFromCLI(source)
            } catch {
                connectError = "\(source.cliName): \(error.localizedDescription)"
            }
            connecting = false
        }
    }

    private var addAccount: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add provider")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Picker("Provider", selection: $newKind) {
                ForEach(ProviderKind.allCases) { kind in
                    Label(kind.displayName, systemImage: kind.symbol).tag(kind)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)

            SecureField("API token", text: $newToken)
                .textFieldStyle(.roundedBorder)

            Text(newKind.tokenHelp)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            if let connectError {
                Label(connectError, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            Button {
                connect()
            } label: {
                if connecting {
                    ProgressView().controlSize(.small)
                } else {
                    Text("Connect")
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(newToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || connecting)
        }
    }

    private func connect() {
        let token = newToken.trimmingCharacters(in: .whitespacesAndNewlines)
        connecting = true
        connectError = nil
        Task {
            do {
                try await store.addAccount(kind: newKind, token: token)
                newToken = ""
            } catch {
                connectError = error.localizedDescription
            }
            connecting = false
        }
    }

    // MARK: - Preferences

    private var preferences: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Preferences")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Picker("Refresh every", selection: $pollInterval) {
                Text("30 s").tag(30.0)
                Text("1 min").tag(60.0)
                Text("2 min").tag(120.0)
                Text("5 min").tag(300.0)
            }
            Text("Polling speeds up to 5 s automatically while a build is running.")
                .font(.caption2)
                .foregroundStyle(.tertiary)

            Toggle("Notify on deploy success", isOn: $notifySuccess)
            Toggle("Notify on deploy failure", isOn: $notifyFailure)
            HStack(spacing: 4) {
                Text("DeployHawk \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text("·").font(.caption2).foregroundStyle(.tertiary)
                Button("GitHub") {
                    NSWorkspace.shared.open(URL(string: "https://github.com/jcsuen/deployhawk")!)
                }
                .buttonStyle(.plain)
                .font(.caption2)
                .foregroundStyle(Color.accentColor)
            }
            .padding(.top, 4)

            Toggle("Launch at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, enabled in
                    do {
                        if enabled {
                            try SMAppService.mainApp.register()
                        } else {
                            try SMAppService.mainApp.unregister()
                        }
                    } catch {
                        // Fails outside a .app bundle (swift run); revert the toggle.
                        launchAtLogin = SMAppService.mainApp.status == .enabled
                    }
                }
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }
}
