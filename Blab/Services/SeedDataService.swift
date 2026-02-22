import Foundation
import SwiftData

enum SeedDataService {
    @MainActor
    static func bootstrapIfNeeded(context: ModelContext) {
        do {
            var memberFetch = FetchDescriptor<Member>()
            memberFetch.fetchLimit = 1
            let hasMember = try context.fetch(memberFetch).isEmpty == false

            if !hasMember {
                let admin = Member(
                    name: "Admin User",
                    username: "admin",
                    passwordHash: "admin",
                    contact: "admin@example.com",
                    notesRaw: DomainCodec.serializeProfileMetadata(
                        ProfileMetadata(
                            bio: "欢迎来到 Blab 原生版。",
                            socialLinks: [],
                            locationRelations: [],
                            itemRelations: [],
                            eventRelations: []
                        )
                    )
                )
                context.insert(admin)

                let starterLocation = LabLocation(
                    name: "社区共享空间",
                    statusRaw: LocationStatus.normal.rawValue,
                    notes: "可用于活动、聚会、设备存放。",
                    isPublic: true,
                    detailRefsRaw: DomainCodec.serializeDetailRefs([
                        DetailRef(label: DomainCodec.usageLabel, value: LocationUsageTag.event.displayName),
                        DetailRef(label: DomainCodec.usageLabel, value: LocationUsageTag.public.displayName)
                    ])
                )
                starterLocation.responsibleMembers = [admin]
                context.insert(starterLocation)

                let starterItem = LabItem(
                    name: "应急物资包",
                    category: "公共资源",
                    statusRaw: ItemStockStatus.normal.rawValue,
                    featureRaw: ItemFeature.public.rawValue,
                    quantityDesc: "1箱",
                    notes: "基础医药和工具",
                    purchaseLink: ""
                )
                starterItem.assignResponsibleMembers([admin])
                starterItem.locations = [starterLocation]
                context.insert(starterItem)

                let starterEvent = LabEvent(
                    title: "新成员欢迎会",
                    summaryText: "欢迎新伙伴熟悉社区资源与规则。",
                    visibilityRaw: EventVisibility.public.rawValue,
                    startTime: Calendar.current.date(byAdding: .day, value: 1, to: .now),
                    endTime: Calendar.current.date(byAdding: .hour, value: 2, to: Calendar.current.date(byAdding: .day, value: 1, to: .now) ?? .now),
                    owner: admin
                )
                starterEvent.items = [starterItem]
                starterEvent.locations = [starterLocation]
                starterEvent.ensureOwnerParticipation()
                context.insert(starterEvent)

                context.insert(
                    LabLog(
                        actionType: "初始化系统",
                        details: "已创建默认管理员与示例数据",
                        user: admin,
                        item: starterItem,
                        location: starterLocation,
                        event: starterEvent
                    )
                )
            }

            var aiFetch = FetchDescriptor<AISettings>(predicate: #Predicate { $0.key == "default" })
            aiFetch.fetchLimit = 1
            let hasAISettings = try context.fetch(aiFetch).isEmpty == false
            if !hasAISettings {
                context.insert(AISettings())
            }

            try context.save()
        } catch {
            assertionFailure("SeedData bootstrap failed: \(error)")
        }
    }
}
