import SwiftUI

struct StatusBadge: View {
    let state: DeployState

    private var color: Color {
        switch state {
        case .building: return .orange
        case .success, .running: return .green
        case .failure: return .red
        case .stopped, .canceled: return .gray
        case .unknown: return .secondary.opacity(0.5)
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            if state == .building {
                ProgressView().controlSize(.mini)
            } else {
                Circle().fill(color).frame(width: 7, height: 7)
            }
            Text(state.label)
                .font(.caption2.weight(.medium))
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 3)
        .background(color.opacity(0.15), in: Capsule())
        .foregroundStyle(color)
    }
}

struct ProviderIcon: View {
    let kind: ProviderKind

    var body: some View {
        Image(systemName: kind.symbol)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(width: 16)
            .help(kind.displayName)
    }
}

struct ProjectRowView: View {
    let project: ProjectItem
    let compact: Bool
    // Re-render every second so the live build duration ticks.
    @State private var now = Date()
    private let ticker = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 8) {
            ProviderIcon(kind: project.provider)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(project.name)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    if let detail = project.detail {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if !compact {
                    subtitle
                }
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 2) {
                StatusBadge(state: project.state)
                if let text = durationText {
                    Text(text)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(project.state == .building ? .orange : .secondary)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, compact ? 5 : 8)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary, lineWidth: 1))
        .onReceive(ticker) { date in
            if project.state == .building { now = date }
        }
    }

    @ViewBuilder
    private var subtitle: some View {
        HStack(spacing: 4) {
            if let branch = project.branch {
                Image(systemName: "arrow.triangle.branch")
                    .font(.caption2)
                Text(branch)
                    .font(.caption2)
                    .lineLimit(1)
            }
            if let message = project.commitMessage {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            } else if let last = project.lastActivity {
                Text(last, style: .relative)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .foregroundStyle(.secondary)
    }

    private var durationText: String? {
        if project.state == .building, let start = project.buildStart {
            return formatDuration(now.timeIntervalSince(start))
        }
        return project.buildDuration.map(formatDuration)
    }
}
