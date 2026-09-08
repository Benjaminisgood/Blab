import SwiftUI

struct OutfitRecordCard: View {
    var record: OutfitRecord
    var onWorn: () -> Void
    var onDelete: () -> Void
    @State private var expanded = false
    @State private var confirmDelete = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 16) {
                Image(systemName: record.isWorn ? "checkmark.seal.fill" : "bookmark")
                    .font(.title2).foregroundStyle(.teal)
                VStack(alignment: .leading, spacing: 5) {
                    Text(record.title).font(.headline)
                    Text("计划 \(record.date.formatted(date: .abbreviated, time: .omitted)) · \(record.occasion.displayName) · \(Int(record.temperature))°C")
                        .font(.caption).foregroundStyle(.secondary)
                    if let wornAt = record.wornAt {
                        Text("实际穿着：\(wornAt.formatted(date: .abbreviated, time: .omitted))")
                            .font(.caption).foregroundStyle(.teal)
                    }
                }
                Spacer()
                if !record.isWorn {
                    Button("今天穿了", action: onWorn).buttonStyle(.bordered)
                } else { Text("已穿过").font(.caption).foregroundStyle(.teal) }
                Button(expanded ? "收起" : "查看搭配") { expanded.toggle() }
                Button(role: .destructive) { confirmDelete = true } label: { Image(systemName: "trash") }
                    .help("删除这条穿搭记录")
            }
            if expanded {
                OutfitBoardView(garments: record.garments, title: record.title, subtitle: record.date.formatted(date: .abbreviated, time: .omitted))
                    .frame(maxWidth: 540)
                Button("导出这套搭配", systemImage: "square.and.arrow.up") {
                    do { try OutfitBoardExporter.export(garments: record.garments, title: record.title, subtitle: record.date.formatted(date: .abbreviated, time: .omitted)) }
                    catch { errorMessage = error.localizedDescription }
                }
            }
        }
        .padding(18)
        .background(Color.secondary.opacity(0.045), in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(.quaternary))
        .confirmationDialog("删除这条穿搭记录？衣橱中的衣物会保留。", isPresented: $confirmDelete) {
            Button("删除记录", role: .destructive, action: onDelete)
        }
        .alert("导出失败", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("知道了", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }
}
