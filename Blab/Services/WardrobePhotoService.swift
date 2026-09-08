import AppKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Vision

enum WardrobePhotoError: LocalizedError {
    case unreadable, noSubject, conversionFailed
    var errorDescription: String? {
        switch self {
        case .unreadable: "无法读取这张图片，请选择 JPEG、PNG 或 HEIC 图片。"
        case .noSubject: "没有识别到清晰的衣物主体，请换一张背景简单的照片，或使用原图。"
        case .conversionFailed: "图片处理失败，原图仍然保留。"
        }
    }
}

/// Bounded image decoding and Vision work run outside the UI actor. No upload is performed.
enum WardrobePhotoService {
    nonisolated static func load(_ url: URL) throws -> Data {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1600
              ] as CFDictionary) else { throw WardrobePhotoError.unreadable }
        return try png(thumbnail)
    }

    nonisolated static func removeBackground(from data: Data) throws -> Data {
        let handler = VNImageRequestHandler(data: data)
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        guard let result = request.results?.first, !result.allInstances.isEmpty else {
            throw WardrobePhotoError.noSubject
        }
        let buffer = try result.generateMaskedImage(
            ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: true
        )
        let image = CIImage(cvPixelBuffer: buffer)
        guard let cgImage = CIContext().createCGImage(image, from: image.extent) else {
            throw WardrobePhotoError.conversionFailed
        }
        return try png(cgImage)
    }

    nonisolated private static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw WardrobePhotoError.conversionFailed
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw WardrobePhotoError.conversionFailed }
        return data as Data
    }
}

enum WardrobePhotoStore {
    static func directory() throws -> URL {
        let folder = try AttachmentStore.appSupportDirectory().appendingPathComponent("wardrobe", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    static func url(for filename: String) -> URL? {
        guard !filename.isEmpty, filename == URL(fileURLWithPath: filename).lastPathComponent,
              !filename.contains(".."), !filename.contains("/") else { return nil }
        return try? directory().appendingPathComponent(filename)
    }

    static func save(_ data: Data) throws -> String {
        let filename = UUID().uuidString + ".png"
        try data.write(to: directory().appendingPathComponent(filename), options: .atomic)
        return filename
    }

    static func removeUncommitted(_ filename: String) {
        if let url = url(for: filename) { try? FileManager.default.removeItem(at: url) }
    }
}
