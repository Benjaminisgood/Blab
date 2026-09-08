import Foundation
import SwiftData

/// Disposable fixtures are only reachable in the explicitly launched Debug preview app.
enum PreviewDataService {
    static func populate(context: ModelContext) {
        guard AppPersistence.isPreview,
              (try? context.fetchCount(FetchDescriptor<Member>())) == 0 else { return }
        let member = Member(name: "体验者", username: "preview", notesRaw: "演示资料")
        context.insert(member)
        context.insert(Member(name: "空衣橱体验", username: "preview-empty", notesRaw: "用于查看空状态的独立演示资料"))
        let pieces: [(String, WardrobeCategory, WardrobeColor, WardrobeWarmth)] = [
            ("白色棉质 T 恤", .top, .white, .light),
            ("牛仔蓝衬衫", .top, .blue, .medium),
            ("米色直筒裤", .bottom, .beige, .light),
            ("深灰休闲长裤", .bottom, .gray, .medium),
            ("白色运动鞋", .shoes, .white, .light),
            ("棕色乐福鞋", .shoes, .brown, .medium),
            ("橄榄绿轻外套", .outerwear, .green, .light),
            ("帆布托特包", .accessory, .beige, .light)
        ]
        for (name, category, color, warmth) in pieces {
            context.insert(WardrobeGarment(name: name, ownerID: member.id, category: category, color: color, warmth: warmth, notes: "演示衣物；图形为类别示意，可添加自己的衣物照片。"))
        }
        let start = Calendar.current.date(bySettingHour: 15, minute: 0, second: 0, of: .now) ?? .now
        context.insert(LabEvent(title: "散步与补充日用品（示例）", summaryText: "一段留给自己的时间", startTime: start, endTime: start.addingTimeInterval(3600), owner: member))
        context.insert(AISettings())
        try? context.save()
    }
}
