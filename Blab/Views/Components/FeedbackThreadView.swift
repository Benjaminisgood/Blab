import SwiftUI

struct FeedbackThreadView: View {
    var entries: [FeedbackEntry]
    var onPost: (String) -> Void

    @State private var draftText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("留言讨论")
                    .font(.headline)
                Spacer()
                Text("\(entries.count)")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.18))
                    .clipShape(Capsule())
            }

            if entries.isEmpty {
                Text("暂无留言")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(entries.sorted(by: { $0.timestamp > $1.timestamp })) { entry in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Text(entry.senderName?.isEmpty == false ? entry.senderName! : "匿名")
                                        .font(.subheadline.weight(.medium))
                                    if entry.sentiment == "positive" {
                                        Text("好评")
                                            .font(.caption)
                                            .foregroundStyle(.green)
                                    } else if entry.sentiment == "doubt" {
                                        Text("需关注")
                                            .font(.caption)
                                            .foregroundStyle(.orange)
                                    }
                                    Spacer()
                                    Text(entry.timestamp, style: .date)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text(entry.content)
                                    .font(.body)
                                    .textSelection(.enabled)
                            }
                            .padding(10)
                            .background(Color.secondary.opacity(0.08))
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
                .frame(minHeight: 120, maxHeight: 220)
            }

            TextEditor(text: $draftText)
                .frame(minHeight: 70)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.secondary.opacity(0.22))
                )

            HStack {
                Text("支持 #标签 / @成员 / !!好评 / ??质疑")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("发布留言") {
                    let text = draftText.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { return }
                    onPost(text)
                    draftText = ""
                }
                .buttonStyle(.borderedProminent)
            }
        }
    }
}
