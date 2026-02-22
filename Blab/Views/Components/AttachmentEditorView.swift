import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct AttachmentEditorView: View {
    var existingAttachments: [LabAttachment]
    @Binding var removedAttachmentIDs: Set<UUID>
    @Binding var importedFileURLs: [URL]
    @Binding var externalURLsText: String

    @State private var isImporterPresented = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("媒体附件")
                    .font(.headline)
                Spacer()
                Button {
                    isImporterPresented = true
                } label: {
                    Label("导入文件", systemImage: "square.and.arrow.down")
                }
            }

            if existingAttachments.isEmpty {
                Text("暂无已保存附件")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(existingAttachments) { attachment in
                    HStack {
                        let kind = DomainCodec.mediaKind(for: attachment.filename)
                        Text(kind.displayName)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.14))
                            .clipShape(Capsule())

                        Text(AttachmentStore.displayName(for: attachment.filename))
                            .lineLimit(1)

                        Spacer()

                        if let url = AttachmentStore.resolveURL(for: attachment.filename) {
                            Button("打开") {
                                NSWorkspace.shared.open(url)
                            }
                            .buttonStyle(.borderless)
                        }

                        Toggle(
                            isOn: Binding(
                                get: { removedAttachmentIDs.contains(attachment.id) },
                                set: { isOn in
                                    if isOn {
                                        removedAttachmentIDs.insert(attachment.id)
                                    } else {
                                        removedAttachmentIDs.remove(attachment.id)
                                    }
                                }
                            )
                        ) {
                            Text("删除")
                        }
                        .toggleStyle(.checkbox)
                        .labelsHidden()
                    }
                }
            }

            if !importedFileURLs.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("待导入文件")
                        .font(.subheadline.weight(.medium))
                    ForEach(importedFileURLs, id: \.self) { url in
                        HStack {
                            Image(systemName: "doc")
                            Text(url.lastPathComponent)
                                .lineLimit(1)
                            Spacer()
                            Button(role: .destructive) {
                                importedFileURLs.removeAll(where: { $0 == url })
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("外部媒体链接")
                    .font(.subheadline.weight(.medium))
                TextEditor(text: $externalURLsText)
                    .frame(minHeight: 70)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.22))
                    )
                Text("每行或逗号分隔输入一个 http(s):// 链接")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .fileImporter(
            isPresented: $isImporterPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case .success(let urls):
                let clean = urls.filter { $0.isFileURL }
                importedFileURLs.append(contentsOf: clean)
                importedFileURLs = Array(Set(importedFileURLs))
            case .failure:
                break
            }
        }
    }
}
