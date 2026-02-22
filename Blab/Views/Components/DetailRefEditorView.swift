import SwiftUI

struct DetailRefEditorView: View {
    @Binding var refs: [DetailRef]
    var title: String = "参考信息"

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                Button {
                    refs.append(DetailRef())
                } label: {
                    Label("新增", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            }

            if refs.isEmpty {
                Text("暂无参考信息")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            } else {
                ForEach($refs) { $ref in
                    HStack(alignment: .top, spacing: 8) {
                        TextField("说明", text: $ref.label)
                            .textFieldStyle(.roundedBorder)
                        TextField("内容", text: $ref.value)
                            .textFieldStyle(.roundedBorder)
                        Button(role: .destructive) {
                            refs.removeAll(where: { $0.id == ref.id })
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }
        }
    }
}
