import SwiftUI

struct DetailInfoGrid<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            content
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct DetailInfoRow: View {
    var title: String
    var value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .multilineTextAlignment(.trailing)
                .textSelection(.enabled)
        }
        .font(.subheadline)
    }
}

struct AttachmentRow: View {
    let attachment: LabAttachment

    var body: some View {
        HStack {
            Text(DomainCodec.mediaKind(for: attachment.filename).displayName)
                .font(.caption)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.secondary.opacity(0.14))
                .clipShape(Capsule())
            Text(AttachmentStore.displayName(for: attachment.filename))
                .lineLimit(1)
            Spacer()
            if let url = AttachmentStore.resolveURL(for: attachment.filename) {
                Link("打开", destination: url)
            }
        }
    }
}
