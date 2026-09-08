import SwiftUI

struct ManualOutfitPicker: View {
    @Environment(\.dismiss) private var dismiss
    var garments: [WardrobeGarmentSnapshot]
    var onChoose: (OutfitSuggestion) -> Void
    @State private var selection: Set<UUID> = []
    private var chosen: [WardrobeGarmentSnapshot] {
        garments.filter { selection.contains($0.id) }.sorted {
            (WardrobeCategory.allCases.firstIndex(of: $0.category) ?? 0)
                < (WardrobeCategory.allCases.firstIndex(of: $1.category) ?? 0)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text("自由搭配").font(.title2.weight(.semibold))
                    Text("从可穿衣物中挑选单品，每类一件；可先保存搭配草稿。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("使用这套搭配") {
                    onChoose(OutfitSuggestion(garments: chosen, reasons: ["由你亲自选择的单品组合。", "自由搭配未按气温或场合筛选，请结合当天实际情况调整。"], score: 0))
                    dismiss()
                }.buttonStyle(.borderedProminent).disabled(selection.isEmpty).keyboardShortcut(.defaultAction)
            }
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 140))], spacing: 14) {
                    ForEach(garments) { garment in
                        Button {
                            if selection.contains(garment.id) { selection.remove(garment.id) }
                            else {
                                let conflicts = garments.filter { other in
                                    other.category == garment.category
                                        || (garment.category == .onePiece && [.top, .bottom].contains(other.category))
                                        || ([.top, .bottom].contains(garment.category) && other.category == .onePiece)
                                }.map(\.id)
                                selection.subtract(conflicts)
                                selection.insert(garment.id)
                            }
                        } label: {
                            VStack(alignment: .leading) {
                                GarmentImageView(filename: garment.photoFilename, category: garment.category, color: garment.color).frame(height: 125)
                                Label(garment.name, systemImage: selection.contains(garment.id) ? "checkmark.circle.fill" : "circle")
                                    .font(.subheadline).lineLimit(1)
                            }.padding(8).background(selection.contains(garment.id) ? Color.teal.opacity(0.12) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
                        }.buttonStyle(.plain)
                    }
                }
            }
        }.padding(22).frame(width: 720, height: EditorSheetLayout.cappedHeight(ideal: 600))
    }
}
