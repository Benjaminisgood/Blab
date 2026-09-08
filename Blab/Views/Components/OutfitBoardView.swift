import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// The same view drives the live board and PNG export.
struct OutfitBoardView: View {
    var garments: [WardrobeGarmentSnapshot]
    var title: String = "今日搭配"
    var subtitle: String

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("BLAB / DAILY WARDROBE")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .tracking(2).foregroundStyle(.secondary)
                    Text(title).font(.title2.weight(.semibold))
                }
                Spacer()
                Image(systemName: "tshirt").font(.title2).foregroundStyle(.teal)
            }
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 14) {
                ForEach(garments) { garment in
                    VStack(alignment: .leading, spacing: 7) {
                        GarmentImageView(filename: garment.photoFilename, category: garment.category, color: garment.color)
                            .frame(height: 160)
                        Text(garment.name).font(.subheadline.weight(.medium)).lineLimit(2)
                        Text("\(garment.color.displayName) · \(garment.category.displayName)")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Divider()
            Text(subtitle).font(.caption).foregroundStyle(.secondary)
            Text("衣物搭配参考 · 版型与实际穿着效果以实物为准")
                .font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .padding(24)
        .background(.background, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(.quaternary))
    }
}

@MainActor
enum OutfitBoardExporter {
    static func export(garments: [WardrobeGarmentSnapshot], title: String = "今日搭配", subtitle: String) throws {
        let board = OutfitBoardView(garments: garments, title: title, subtitle: subtitle)
            .frame(width: 620)
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: board)
        renderer.scale = 2
        guard let image = renderer.nsImage,
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]) else {
            throw WardrobePhotoError.conversionFailed
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "Blab-今日穿搭.png"
        panel.title = "导出穿搭图"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try data.write(to: url, options: .atomic)
    }
}
