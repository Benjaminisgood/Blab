import Foundation

struct AttachmentStore {
    static let containerFolder = "Benlab"
    static let attachmentsFolder = "attachments"

    static func appSupportDirectory() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent(containerFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func attachmentsDirectory() throws -> URL {
        let dir = try appSupportDirectory().appendingPathComponent(attachmentsFolder, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func importFiles(_ urls: [URL]) throws -> [String] {
        let targetDir = try attachmentsDirectory()
        var importedRefs: [String] = []
        var seen = Set<String>()

        for src in urls {
            guard src.isFileURL else { continue }
            let ext = src.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
            let generated = UUID().uuidString + (ext.isEmpty ? "" : ".\(ext.lowercased())")
            let dst = targetDir.appendingPathComponent(generated)

            if FileManager.default.fileExists(atPath: dst.path) {
                continue
            }

            try FileManager.default.copyItem(at: src, to: dst)
            if !seen.contains(generated) {
                seen.insert(generated)
                importedRefs.append(generated)
            }
        }

        return importedRefs
    }

    static func resolveURL(for ref: String) -> URL? {
        let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if DomainCodec.isExternalMedia(trimmed) {
            if trimmed.hasPrefix("//") {
                return URL(string: "https:\(trimmed)")
            }
            return URL(string: trimmed)
        }

        guard let dir = try? attachmentsDirectory() else {
            return nil
        }
        return dir.appendingPathComponent(trimmed)
    }

    static func deleteManagedFile(ref: String) {
        let trimmed = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard !DomainCodec.isExternalMedia(trimmed) else { return }
        guard let dir = try? attachmentsDirectory() else { return }

        let path = dir.appendingPathComponent(trimmed)
        if FileManager.default.fileExists(atPath: path.path) {
            try? FileManager.default.removeItem(at: path)
        }
    }

    static func displayName(for ref: String) -> String {
        let cleaned = ref
            .components(separatedBy: "?").first ?? ref
        let cleanedHash = cleaned.components(separatedBy: "#").first ?? cleaned
        return URL(fileURLWithPath: cleanedHash).lastPathComponent
    }
}
