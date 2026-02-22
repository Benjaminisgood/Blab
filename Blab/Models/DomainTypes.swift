import Foundation

enum ItemFeature: String, CaseIterable, Identifiable, Codable {
    case `public` = "公共"
    case `private` = "私人"

    var id: String { rawValue }
    var intent: String {
        switch self {
        case .public:
            return "public"
        case .private:
            return "private"
        }
    }
}

enum ItemStockStatus: String, CaseIterable, Identifiable, Codable {
    case normal = "正常"
    case low = "少量"
    case empty = "用完"
    case borrowed = "借出"
    case discarded = "舍弃"

    var id: String { rawValue }

    var intent: String {
        switch self {
        case .normal:
            return "positive"
        case .low:
            return "warning"
        case .empty:
            return "critical"
        case .borrowed:
            return "info"
        case .discarded:
            return "muted"
        }
    }

    var isAlert: Bool {
        switch self {
        case .empty, .discarded, .low, .borrowed:
            return true
        case .normal:
            return false
        }
    }

    var alertActionLabel: String {
        switch self {
        case .empty, .low:
            return "补货处理"
        case .discarded:
            return "弃置处理"
        case .borrowed:
            return "借出跟进"
        case .normal:
            return "处理"
        }
    }

    var alertLevel: String {
        switch self {
        case .empty:
            return "danger"
        case .discarded, .low, .borrowed:
            return "warning"
        case .normal:
            return "neutral"
        }
    }

    var alertMessageTemplate: String {
        switch self {
        case .empty:
            return "你有 %d 个库存用完的物品，请立即补货！"
        case .discarded:
            return "你有 %d 个标记为舍弃的物品，请尽快完成弃置处理。"
        case .low:
            return "你有 %d 个库存少量的物品，建议尽快补货。"
        case .borrowed:
            return "你有 %d 个借出中的物品，请及时跟进归还。"
        case .normal:
            return ""
        }
    }
}

enum LocationStatus: String, CaseIterable, Identifiable, Codable {
    case normal = "正常"
    case dirty = "脏"
    case repair = "报修"
    case danger = "危险"
    case forbidden = "禁止"

    var id: String { rawValue }

    var intent: String {
        switch self {
        case .normal:
            return "positive"
        case .forbidden:
            return "neutral"
        case .dirty, .repair, .danger:
            return "critical"
        }
    }

    var isAlert: Bool {
        switch self {
        case .dirty, .repair, .danger:
            return true
        case .normal, .forbidden:
            return false
        }
    }

    var alertActionLabel: String {
        switch self {
        case .danger:
            return "立即隔离"
        case .repair:
            return "安排报修"
        case .dirty:
            return "清洁处理"
        case .normal, .forbidden:
            return "处理"
        }
    }

    var alertLevel: String {
        switch self {
        case .danger:
            return "danger"
        case .repair, .dirty:
            return "warning"
        case .normal, .forbidden:
            return "neutral"
        }
    }

    var alertMessageTemplate: String {
        switch self {
        case .danger:
            return "你有 %d 个危险状态的位置，请立即处理并限制使用。"
        case .repair:
            return "你有 %d 个报修状态的位置，请尽快安排维修。"
        case .dirty:
            return "你有 %d 个脏状态的位置，请及时清洁。"
        case .normal, .forbidden:
            return ""
        }
    }
}

enum LocationUsageTag: String, CaseIterable, Identifiable, Codable {
    case study
    case leisure
    case event
    case `public`
    case rental
    case storage
    case travel
    case residence
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .study:
            return "学习空间"
        case .leisure:
            return "休闲娱乐"
        case .event:
            return "活动场地"
        case .public:
            return "公共设施"
        case .rental:
            return "出租空间"
        case .storage:
            return "储物空间"
        case .travel:
            return "旅游推荐"
        case .residence:
            return "生活社区"
        case .other:
            return "其他"
        }
    }

    static func from(label: String) -> LocationUsageTag? {
        allCases.first(where: { $0.displayName == label })
    }
}

enum MemberLocationRelation: String, CaseIterable, Identifiable, Codable {
    case study
    case work
    case live
    case own
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .study:
            return "上学"
        case .work:
            return "工作"
        case .live:
            return "居住"
        case .own:
            return "拥有"
        case .other:
            return "其他"
        }
    }
}

enum MemberItemRelation: String, CaseIterable, Identifiable, Codable {
    case borrow
    case praise
    case favorite
    case wishlist
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .borrow:
            return "租借"
        case .praise:
            return "好评"
        case .favorite:
            return "收藏"
        case .wishlist:
            return "待购"
        case .other:
            return "其他"
        }
    }
}

enum MemberEventRelation: String, CaseIterable, Identifiable, Codable {
    case host
    case join
    case support
    case follow
    case interested
    case other

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .host:
            return "主办"
        case .join:
            return "参与"
        case .support:
            return "协助"
        case .follow:
            return "关注"
        case .interested:
            return "想参加"
        case .other:
            return "其他"
        }
    }
}

enum EventVisibility: String, CaseIterable, Identifiable, Codable {
    case personal
    case `internal`
    case `public`

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .personal:
            return "个人事项"
        case .internal:
            return "内部事项"
        case .public:
            return "公开事项"
        }
    }
}

enum EventParticipantRole: String, CaseIterable, Identifiable, Codable {
    case owner
    case participant

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .owner:
            return "负责人"
        case .participant:
            return "参与成员"
        }
    }
}

enum EventParticipantStatus: String, CaseIterable, Identifiable, Codable {
    case confirmed
    case pending

    var id: String { rawValue }
}

enum AIAutofillProvider: String, CaseIterable, Identifiable, Codable {
    case chatanywhere
    case deepseek
    case aliyun

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .chatanywhere:
            return "ChatAnywhere"
        case .deepseek:
            return "DeepSeek"
        case .aliyun:
            return "阿里云百炼"
        }
    }

    var defaultModel: String {
        switch self {
        case .chatanywhere:
            return "gpt-4o-mini"
        case .deepseek:
            return "deepseek-chat"
        case .aliyun:
            return "qwen-vl-max-latest"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .chatanywhere:
            return "https://api.chatanywhere.tech/v1"
        case .deepseek:
            return "https://api.deepseek.com/v1"
        case .aliyun:
            return "https://dashscope.aliyuncs.com/compatible-mode/v1"
        }
    }
}

struct DetailRef: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var label: String = ""
    var value: String = ""
}

struct SocialLink: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var label: String = ""
    var url: String = ""
}

struct ProfileLocationRelation: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var locationID: UUID
    var relation: MemberLocationRelation
    var note: String
}

struct ProfileItemRelation: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var itemID: UUID
    var relation: MemberItemRelation
    var note: String
}

struct ProfileEventRelation: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var eventID: UUID
    var relation: MemberEventRelation
    var note: String
}

struct ProfileMetadata: Codable, Hashable {
    var bio: String = ""
    var socialLinks: [SocialLink] = []
    var locationRelations: [ProfileLocationRelation] = []
    var itemRelations: [ProfileItemRelation] = []
    var eventRelations: [ProfileEventRelation] = []

    static let empty = ProfileMetadata()
}

struct FeedbackEntry: Identifiable, Hashable, Codable {
    var id: UUID = UUID()
    var timestamp: Date
    var senderID: UUID?
    var senderName: String?
    var content: String

    var sentiment: String? {
        if content.contains("!!") {
            return "positive"
        }
        if content.contains("??") {
            return "doubt"
        }
        return nil
    }
}

enum MediaKind: String, CaseIterable {
    case image
    case video
    case audio
    case file

    var displayName: String {
        switch self {
        case .image:
            return "图片"
        case .video:
            return "视频"
        case .audio:
            return "音频"
        case .file:
            return "文件"
        }
    }
}

enum DomainCodec {
    static let usageLabel = "用途"

    static func parseDetailRefs(from raw: String?) -> [DetailRef] {
        guard var token = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty else {
            return []
        }

        if let data = token.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([DetailRef].self, from: data) {
            return deduplicatedDetailRefs(decoded)
        }

        if let data = token.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String].self, from: data) {
            let refs = decoded.map { DetailRef(label: "", value: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            return deduplicatedDetailRefs(refs)
        }

        var refs: [DetailRef] = []
        for line in token.components(separatedBy: .newlines) {
            let part = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !part.isEmpty else { continue }
            if let range = part.range(of: "|||") {
                let label = String(part[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let value = String(part[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    refs.append(DetailRef(label: label, value: value))
                }
            } else if let range = part.range(of: "|") {
                let label = String(part[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                let value = String(part[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
                if !value.isEmpty {
                    refs.append(DetailRef(label: label, value: value))
                }
            } else {
                refs.append(DetailRef(label: "", value: part))
            }
        }

        if refs.isEmpty {
            token = token.replacingOccurrences(of: "\r", with: "\n")
            for part in token.split(whereSeparator: { $0 == "\n" || $0 == "," }) {
                let value = String(part).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { continue }
                refs.append(DetailRef(label: "", value: value))
            }
        }

        return deduplicatedDetailRefs(refs)
    }

    static func serializeDetailRefs(_ refs: [DetailRef], maxLength: Int? = nil) -> String {
        var compact: [DetailRef] = []
        var seen = Set<String>()
        for entry in refs {
            let value = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
            let label = entry.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            guard !seen.contains(value) else { continue }
            seen.insert(value)
            compact.append(DetailRef(label: label, value: value))
        }

        if compact.isEmpty {
            return ""
        }

        func serialized(_ values: [DetailRef]) -> String {
            values.map { entry in
                if entry.label.isEmpty {
                    return entry.value
                }
                return "\(entry.label)|||\(entry.value)"
            }
            .joined(separator: "\n")
        }

        guard let maxLength else {
            return serialized(compact)
        }

        var candidate = compact
        while !candidate.isEmpty {
            let text = serialized(candidate)
            if text.count <= maxLength {
                return text
            }
            candidate.removeLast()
        }

        return ""
    }

    static func usageTags(from refs: [DetailRef]) -> [LocationUsageTag] {
        var tags: [LocationUsageTag] = []
        var seen = Set<LocationUsageTag>()
        for ref in refs {
            guard ref.label.trimmingCharacters(in: .whitespacesAndNewlines) == usageLabel else { continue }
            guard let tag = LocationUsageTag.from(label: ref.value.trimmingCharacters(in: .whitespacesAndNewlines)) else { continue }
            guard !seen.contains(tag) else { continue }
            seen.insert(tag)
            tags.append(tag)
        }
        return tags
    }

    static func stripUsageTags(from refs: [DetailRef]) -> [DetailRef] {
        refs.filter { ref in
            let label = ref.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard label == usageLabel else { return true }
            return LocationUsageTag.from(label: ref.value.trimmingCharacters(in: .whitespacesAndNewlines)) == nil
        }
    }

    static func mergeUsageTags(_ tags: [LocationUsageTag], into refs: [DetailRef]) -> [DetailRef] {
        var merged = stripUsageTags(from: refs)
        var seenValues = Set(merged.map { $0.value })
        for tag in tags {
            let label = tag.displayName
            guard !seenValues.contains(label) else { continue }
            merged.append(DetailRef(label: usageLabel, value: label))
            seenValues.insert(label)
        }
        return merged
    }

    static func parseProfileMetadata(_ raw: String?) -> ProfileMetadata {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .empty
        }
        if let data = raw.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(ProfileMetadata.self, from: data) {
            return decoded
        }
        return ProfileMetadata(bio: raw)
    }

    static func serializeProfileMetadata(_ meta: ProfileMetadata) -> String {
        guard let data = try? JSONEncoder().encode(meta),
              let raw = String(data: data, encoding: .utf8) else {
            return meta.bio
        }
        return raw
    }

    static func parseFeedbackEntries(_ raw: String?) -> [FeedbackEntry] {
        guard let raw, !raw.isEmpty else { return [] }
        var entries: [FeedbackEntry] = []
        for line in raw.split(whereSeparator: \.isNewline) {
            let token = String(line).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { continue }
            if let data = token.data(using: .utf8),
               let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let content = (payload["content"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !content.isEmpty else { continue }
                let senderName = payload["sn"] as? String
                let senderID: UUID?
                if let sid = payload["sid"] as? String {
                    senderID = UUID(uuidString: sid)
                } else {
                    senderID = nil
                }
                let timestamp: Date
                if let ts = payload["ts"] as? String,
                   let parsed = ISO8601DateFormatter().date(from: ts) {
                    timestamp = parsed
                } else {
                    timestamp = Date()
                }
                entries.append(FeedbackEntry(timestamp: timestamp, senderID: senderID, senderName: senderName, content: content))
            } else {
                entries.append(FeedbackEntry(timestamp: Date(), senderID: nil, senderName: nil, content: token))
            }
        }
        return entries.sorted(by: { $0.timestamp > $1.timestamp })
    }

    static func serializeFeedbackEntries(_ entries: [FeedbackEntry], limit: Int = 200) -> String {
        let trimmed = Array(entries.suffix(limit))
        let formatter = ISO8601DateFormatter()
        return trimmed.map { entry in
            var payload: [String: Any] = [
                "ts": formatter.string(from: entry.timestamp),
                "content": entry.content
            ]
            if let senderID = entry.senderID {
                payload["sid"] = senderID.uuidString
            }
            if let senderName = entry.senderName {
                payload["sn"] = senderName
            }
            guard let data = try? JSONSerialization.data(withJSONObject: payload, options: []),
                  let raw = String(data: data, encoding: .utf8) else {
                return entry.content
            }
            return raw
        }
        .joined(separator: "\n")
    }

    static func deduplicatedDetailRefs(_ refs: [DetailRef]) -> [DetailRef] {
        var seen = Set<String>()
        var result: [DetailRef] = []
        for entry in refs {
            let value = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            guard !seen.contains(value) else { continue }
            seen.insert(value)
            result.append(DetailRef(label: entry.label.trimmingCharacters(in: .whitespacesAndNewlines), value: value))
        }
        return result
    }

    static func extractExternalURLs(from text: String) -> [String] {
        let cleaned = text.replacingOccurrences(of: "\r", with: "\n")
        let rawParts = cleaned
            .components(separatedBy: .newlines)
            .flatMap { $0.split(separator: ",") }
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        var urls: [String] = []
        var seen = Set<String>()
        for token in rawParts {
            let normalized: String
            if token.hasPrefix("http://") || token.hasPrefix("https://") {
                normalized = token
            } else if token.hasPrefix("//") {
                normalized = "https:\(token)"
            } else {
                continue
            }
            guard !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            urls.append(normalized)
        }
        return urls
    }

    static func mediaKind(for ref: String) -> MediaKind {
        let lower = ref.lowercased()
        let ext = (lower.split(separator: ".").last.map(String.init) ?? "")
        if ["png", "jpg", "jpeg", "gif", "bmp", "webp", "heic", "heif"].contains(ext) || isExternalMedia(ref) {
            return .image
        }
        if ["mp4", "mov", "avi", "mkv", "webm", "m4v"].contains(ext) {
            return .video
        }
        if ["mp3", "wav", "aac", "m4a", "ogg", "flac"].contains(ext) {
            return .audio
        }
        return .file
    }

    static func isExternalMedia(_ ref: String) -> Bool {
        ref.hasPrefix("http://") || ref.hasPrefix("https://") || ref.hasPrefix("//")
    }
}
