import SwiftUI
import AppKit

extension WardrobeColor {
    var swatch: Color {
        let value = UInt64(hex.replacingOccurrences(of: "#", with: ""), radix: 16) ?? 0x888888
        return Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
    }
}

struct GarmentImageView: View {
    var filename: String
    var category: WardrobeCategory
    var color: WardrobeColor
    var imageData: Data? = nil

    private var photo: NSImage? {
        if let imageData { return NSImage(data: imageData) }
        guard let url = WardrobePhotoStore.url(for: filename) else { return nil }
        return NSImage(contentsOf: url)
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 14).fill(color.swatch.opacity(0.09))
            if let photo {
                Image(nsImage: photo)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFit()
                    .padding(12)
            } else {
                VStack(spacing: 8) {
                    Image(systemName: category.symbolName)
                        .font(.system(size: 46, weight: .light))
                        .foregroundStyle(color.swatch)
                        .shadow(color: .primary.opacity(0.16), radius: 1)
                    Text("\(category.displayName)示意")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityLabel(photo == nil ? "\(category.displayName)，尚未添加照片" : "\(category.displayName)照片")
    }
}
