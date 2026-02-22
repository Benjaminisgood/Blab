import SwiftUI
import AppKit

struct EditorCanvas<Content: View>: View {
    var maxWidth: CGFloat
    @ViewBuilder var content: Content

    init(maxWidth: CGFloat = 920, @ViewBuilder content: () -> Content) {
        self.maxWidth = maxWidth
        self.content = content()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                content
            }
            .frame(maxWidth: maxWidth, alignment: .leading)
            .padding(.horizontal, 22)
            .padding(.vertical, 18)
        }
        .background(
            LinearGradient(
                colors: [
                    Color.accentColor.opacity(0.05),
                    Color.secondary.opacity(0.02),
                    Color.clear
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }
}

struct EditorHeader: View {
    var title: String
    var subtitle: String
    var systemImage: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 34, height: 34)
                .background(Color.accentColor.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.title3.weight(.semibold))
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.18))
        )
    }
}

struct EditorCard<Content: View>: View {
    var title: String
    var subtitle: String?
    var systemImage: String
    @ViewBuilder var content: Content

    init(
        title: String,
        subtitle: String? = nil,
        systemImage: String,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: systemImage)
                    .foregroundStyle(Color.accentColor)
                    .font(.headline)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            VStack(alignment: .leading, spacing: 10) {
                content
            }
        }
        .padding(14)
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.16))
        )
    }
}

enum EditorSheetLayout {
    static var maxHeight: CGFloat {
        let fallback: CGFloat = 720
        guard let window = NSApp.keyWindow else { return fallback }
        return max(460, window.contentLayoutRect.height - 70)
    }

    static func cappedHeight(ideal: CGFloat) -> CGFloat {
        min(ideal, maxHeight)
    }
}
