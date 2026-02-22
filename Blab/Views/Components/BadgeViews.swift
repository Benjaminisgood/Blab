import SwiftUI

struct ItemStatusBadge: View {
    var status: ItemStockStatus?

    var body: some View {
        if let status {
            Text(status.rawValue)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(backgroundColor(for: status))
                .foregroundStyle(foregroundColor(for: status))
                .clipShape(Capsule())
        }
    }

    private func backgroundColor(for status: ItemStockStatus) -> Color {
        switch status {
        case .normal:
            return .green.opacity(0.18)
        case .low:
            return .yellow.opacity(0.22)
        case .empty:
            return .red.opacity(0.22)
        case .borrowed:
            return .blue.opacity(0.18)
        case .discarded:
            return .gray.opacity(0.22)
        }
    }

    private func foregroundColor(for status: ItemStockStatus) -> Color {
        switch status {
        case .low:
            return .orange
        case .discarded:
            return .secondary
        case .normal:
            return .green
        case .empty:
            return .red
        case .borrowed:
            return .blue
        }
    }
}

struct FeatureBadge: View {
    var feature: ItemFeature?

    var body: some View {
        if let feature {
            Text(feature.rawValue)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(feature == .public ? Color.mint.opacity(0.18) : Color.indigo.opacity(0.18))
                .foregroundStyle(feature == .public ? Color.mint : Color.indigo)
                .clipShape(Capsule())
        }
    }
}

struct LocationStatusBadge: View {
    var status: LocationStatus?

    var body: some View {
        if let status {
            Text(status.rawValue)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(backgroundColor(for: status))
                .foregroundStyle(foregroundColor(for: status))
                .clipShape(Capsule())
        }
    }

    private func backgroundColor(for status: LocationStatus) -> Color {
        switch status {
        case .normal:
            return .green.opacity(0.18)
        case .dirty, .repair:
            return .yellow.opacity(0.24)
        case .danger:
            return .red.opacity(0.24)
        case .forbidden:
            return .gray.opacity(0.2)
        }
    }

    private func foregroundColor(for status: LocationStatus) -> Color {
        switch status {
        case .normal:
            return .green
        case .dirty, .repair:
            return .orange
        case .danger:
            return .red
        case .forbidden:
            return .secondary
        }
    }
}

struct EventVisibilityBadge: View {
    var visibility: EventVisibility

    var body: some View {
        Text(visibility.displayName)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(backgroundColor)
            .foregroundStyle(foregroundColor)
            .clipShape(Capsule())
    }

    private var backgroundColor: Color {
        switch visibility {
        case .public:
            return .green.opacity(0.18)
        case .internal:
            return .orange.opacity(0.18)
        case .personal:
            return .purple.opacity(0.16)
        }
    }

    private var foregroundColor: Color {
        switch visibility {
        case .public:
            return .green
        case .internal:
            return .orange
        case .personal:
            return .purple
        }
    }
}
