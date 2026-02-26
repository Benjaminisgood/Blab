import Foundation
import SwiftData

struct AgentExecutionEntry: Identifiable {
    var id: UUID = UUID()
    var operationID: String
    var success: Bool
    var message: String
}

struct AgentExecutionResult {
    var entries: [AgentExecutionEntry]

    var successCount: Int {
        entries.filter { $0.success }.count
    }

    var failureCount: Int {
        entries.filter { !$0.success }.count
    }

    var summary: String {
        "执行完成：成功 \(successCount) 条，失败 \(failureCount) 条。"
    }
}

enum AgentExecutorService {
    @MainActor
    static func execute(
        plan: AgentPlan,
        modelContext: ModelContext,
        currentMember: Member?,
        items: [LabItem],
        locations: [LabLocation],
        events: [LabEvent],
        members: [Member],
        requestID: String? = nil
    ) -> AgentExecutionResult {
        var runtimeItems = items
        var runtimeLocations = locations
        var runtimeEvents = events
        var runtimeMembers = members
        var attachmentRefsToDelete: [String] = []

        var entries: [AgentExecutionEntry] = []

        for operation in plan.operations {
            do {
                let message = try apply(
                    operation: operation,
                    modelContext: modelContext,
                    currentMember: currentMember,
                    items: &runtimeItems,
                    locations: &runtimeLocations,
                    events: &runtimeEvents,
                    members: &runtimeMembers,
                    deletedAttachmentRefs: &attachmentRefsToDelete,
                    requestID: requestID
                )
                entries.append(
                    AgentExecutionEntry(
                        operationID: operation.id,
                        success: true,
                        message: message
                    )
                )
            } catch {
                entries.append(
                    AgentExecutionEntry(
                        operationID: operation.id,
                        success: false,
                        message: "操作失败：\(error.localizedDescription)"
                    )
                )
            }
        }

        if entries.contains(where: { $0.success }) {
            do {
                try modelContext.save()
                for ref in Set(attachmentRefsToDelete) where !ref.isEmpty {
                    AttachmentStore.deleteManagedFile(ref: ref)
                }
            } catch {
                entries.append(
                    AgentExecutionEntry(
                        operationID: "save",
                        success: false,
                        message: "保存失败：\(error.localizedDescription)"
                    )
                )
            }
        }

        return AgentExecutionResult(entries: entries)
    }

    private static func apply(
        operation: AgentOperation,
        modelContext: ModelContext,
        currentMember: Member?,
        items: inout [LabItem],
        locations: inout [LabLocation],
        events: inout [LabEvent],
        members: inout [Member],
        deletedAttachmentRefs: inout [String],
        requestID: String?
    ) throws -> String {
        switch operation.entity {
        case .item:
            return try applyItem(
                operation: operation,
                modelContext: modelContext,
                currentMember: currentMember,
                items: &items,
                locations: locations,
                members: members,
                deletedAttachmentRefs: &deletedAttachmentRefs,
                requestID: requestID
            )
        case .location:
            return try applyLocation(
                operation: operation,
                modelContext: modelContext,
                currentMember: currentMember,
                locations: &locations,
                members: members,
                deletedAttachmentRefs: &deletedAttachmentRefs,
                requestID: requestID
            )
        case .event:
            return try applyEvent(
                operation: operation,
                modelContext: modelContext,
                currentMember: currentMember,
                events: &events,
                items: items,
                locations: locations,
                members: members,
                deletedAttachmentRefs: &deletedAttachmentRefs,
                requestID: requestID
            )
        case .member:
            return try applyMember(
                operation: operation,
                modelContext: modelContext,
                currentMember: currentMember,
                members: &members,
                deletedAttachmentRefs: &deletedAttachmentRefs,
                requestID: requestID
            )
        }
    }

    private static func applyItem(
        operation: AgentOperation,
        modelContext: ModelContext,
        currentMember: Member?,
        items: inout [LabItem],
        locations: [LabLocation],
        members: [Member],
        deletedAttachmentRefs: inout [String],
        requestID: String?
    ) throws -> String {
        switch operation.action {
        case .create:
            guard let fields = operation.item else {
                throw executionError("物品操作缺少 item 字段。")
            }
            guard let name = fields.name?.trimmedNonEmpty else {
                throw executionError("新增物品必须提供 item.name。")
            }
            let target = LabItem(name: name)

            try patchItem(
                target: target,
                fields: fields,
                currentMember: currentMember,
                locations: locations,
                members: members
            )

            modelContext.insert(target)
            items.append(target)

            modelContext.insert(
                LabLog(
                    actionType: "AI新增物品",
                    details: logDetails("AI created item \(target.name)", requestID: requestID),
                    user: currentMember,
                    item: target
                )
            )
            return "已新增物品：\(target.name)"

        case .update:
            guard let fields = operation.item else {
                throw executionError("物品操作缺少 item 字段。")
            }
            let target = try resolveItem(target: operation.target, fallbackName: fields.name, in: items)
            try ensureCanEditItem(
                target,
                currentMember: currentMember,
                actionLabel: "修改"
            )
            try patchItem(
                target: target,
                fields: fields,
                currentMember: currentMember,
                locations: locations,
                members: members
            )

            modelContext.insert(
                LabLog(
                    actionType: "AI修改物品",
                    details: logDetails("AI updated item \(target.name)", requestID: requestID),
                    user: currentMember,
                    item: target
                )
            )
            return "已修改物品：\(target.name)"
        case .delete:
            let fallbackName = operation.item?.name
            if isBulkDelete(operation: operation, fallbackToken: fallbackName) {
                let deletable = items.filter { candidate in
                    candidate.canEdit(currentMember)
                }
                guard !deletable.isEmpty else {
                    throw executionError("当前范围内没有可删除的物品。")
                }

                let skippedCount = max(0, items.count - deletable.count)
                for target in deletable {
                    let refs = target.attachmentRefs
                    let targetID = target.id
                    let name = target.name
                    modelContext.delete(target)
                    items.removeAll { $0.id == targetID }
                    deletedAttachmentRefs.append(contentsOf: refs)
                    modelContext.insert(
                        LabLog(
                            actionType: "AI删除物品",
                            details: logDetails("AI deleted item \(name)", requestID: requestID),
                            user: currentMember
                        )
                    )
                }
                if skippedCount > 0 {
                    return "已批量删除物品：\(deletable.count) 条，跳过无权限目标 \(skippedCount) 条。"
                }
                return "已批量删除物品：\(deletable.count) 条。"
            }

            let target = try resolveItem(target: operation.target, fallbackName: fallbackName, in: items)
            try ensureCanEditItem(
                target,
                currentMember: currentMember,
                actionLabel: "删除"
            )

            let refs = target.attachmentRefs
            let targetID = target.id
            let name = target.name
            modelContext.delete(target)
            items.removeAll { $0.id == targetID }
            deletedAttachmentRefs.append(contentsOf: refs)

            modelContext.insert(
                LabLog(
                    actionType: "AI删除物品",
                    details: logDetails("AI deleted item \(name)", requestID: requestID),
                    user: currentMember
                )
            )
            return "已删除物品：\(name)"
        }
    }

    private static func patchItem(
        target: LabItem,
        fields: AgentItemFields,
        currentMember: Member?,
        locations: [LabLocation],
        members: [Member]
    ) throws {
        if let value = fields.name?.trimmedNonEmpty {
            target.name = value
        }

        if let category = fields.category {
            target.category = category.trimmed
        }

        if let statusToken = fields.status?.trimmedNonEmpty {
            guard let status = parseItemStatus(statusToken) else {
                throw executionError("无效的物品状态：\(statusToken)")
            }
            target.status = status
        }

        if let featureToken = fields.feature?.trimmedNonEmpty {
            guard let feature = parseItemFeature(featureToken) else {
                throw executionError("无效的物品归属：\(featureToken)")
            }
            target.feature = feature
        }

        if let value = fields.value {
            target.value = value
        }

        if let quantityDesc = fields.quantityDesc {
            target.quantityDesc = quantityDesc.trimmed
        }

        if let dateToken = fields.purchaseDateISO {
            if isExplicitNull(dateToken) {
                target.purchaseDate = nil
            } else {
                guard let date = parseDate(dateToken) else {
                    throw executionError("购入日期无法解析：\(dateToken)")
                }
                target.purchaseDate = date
            }
        }

        if let notes = fields.notes {
            target.notes = notes.trimmed
        }

        if let link = fields.purchaseLink {
            target.purchaseLink = link.trimmed
        }

        if let detailRefs = fields.detailRefs {
            target.detailRefs = DomainCodec.deduplicatedDetailRefs(
                detailRefs.map { DetailRef(label: $0.label?.trimmed ?? "", value: $0.value.trimmed) }
            )
        }

        if let memberTokens = fields.responsibleMemberNames {
            let selectedMembers = try resolveMembers(tokens: memberTokens, in: members)
            if (target.feature ?? .private) == .private {
                if selectedMembers.isEmpty, let currentMember {
                    target.assignResponsibleMembers([currentMember])
                } else {
                    target.assignResponsibleMembers(selectedMembers)
                }
            } else {
                target.assignResponsibleMembers(selectedMembers)
            }
        } else if (target.feature ?? .private) == .private,
                  target.responsibleMembers.isEmpty,
                  let currentMember {
            target.assignResponsibleMembers([currentMember])
        }

        if (target.feature ?? .private) == .private,
           target.responsibleMembers.isEmpty {
            throw executionError("私有物品至少需要一位负责人。")
        }

        if let locationTokens = fields.locationNames {
            target.locations = try resolveLocations(tokens: locationTokens, in: locations)
        }

        guard target.name.trimmedNonEmpty != nil else {
            throw executionError("物品名称不能为空。")
        }

        target.touch()
    }

    private static func applyLocation(
        operation: AgentOperation,
        modelContext: ModelContext,
        currentMember: Member?,
        locations: inout [LabLocation],
        members: [Member],
        deletedAttachmentRefs: inout [String],
        requestID: String?
    ) throws -> String {
        switch operation.action {
        case .create:
            guard let fields = operation.location else {
                throw executionError("空间操作缺少 location 字段。")
            }
            guard let name = fields.name?.trimmedNonEmpty else {
                throw executionError("新增空间必须提供 location.name。")
            }
            let target = LabLocation(name: name)

            try patchLocation(
                target: target,
                fields: fields,
                currentMember: currentMember,
                allLocations: locations,
                members: members
            )

            modelContext.insert(target)
            locations.append(target)

            modelContext.insert(
                LabLog(
                    actionType: "AI新增位置",
                    details: logDetails("AI created location \(target.name)", requestID: requestID),
                    user: currentMember,
                    location: target
                )
            )
            return "已新增空间：\(target.name)"

        case .update:
            guard let fields = operation.location else {
                throw executionError("空间操作缺少 location 字段。")
            }
            let target = try resolveLocation(target: operation.target, fallbackName: fields.name, in: locations)
            try ensureCanEditLocation(
                target,
                currentMember: currentMember,
                actionLabel: "修改"
            )
            try patchLocation(
                target: target,
                fields: fields,
                currentMember: currentMember,
                allLocations: locations,
                members: members
            )

            modelContext.insert(
                LabLog(
                    actionType: "AI修改位置",
                    details: logDetails("AI updated location \(target.name)", requestID: requestID),
                    user: currentMember,
                    location: target
                )
            )
            return "已修改空间：\(target.name)"
        case .delete:
            let fallbackName = operation.location?.name
            if isBulkDelete(operation: operation, fallbackToken: fallbackName) {
                let deletable = locations.filter { location in
                    location.canEdit(currentMember)
                }
                guard !deletable.isEmpty else {
                    throw executionError("当前范围内没有可删除的空间。")
                }

                let skippedCount = max(0, locations.count - deletable.count)
                for target in deletable {
                    let refs = target.attachmentRefs
                    let targetID = target.id
                    let name = target.name
                    modelContext.delete(target)
                    locations.removeAll { $0.id == targetID }
                    deletedAttachmentRefs.append(contentsOf: refs)
                    modelContext.insert(
                        LabLog(
                            actionType: "AI删除位置",
                            details: logDetails("AI deleted location \(name)", requestID: requestID),
                            user: currentMember
                        )
                    )
                }
                if skippedCount > 0 {
                    return "已批量删除空间：\(deletable.count) 条，跳过无权限目标 \(skippedCount) 条。"
                }
                return "已批量删除空间：\(deletable.count) 条。"
            }

            let target = try resolveLocation(target: operation.target, fallbackName: fallbackName, in: locations)
            try ensureCanEditLocation(
                target,
                currentMember: currentMember,
                actionLabel: "删除"
            )

            let refs = target.attachmentRefs
            let targetID = target.id
            let name = target.name
            modelContext.delete(target)
            locations.removeAll { $0.id == targetID }
            deletedAttachmentRefs.append(contentsOf: refs)

            modelContext.insert(
                LabLog(
                    actionType: "AI删除位置",
                    details: logDetails("AI deleted location \(name)", requestID: requestID),
                    user: currentMember
                )
            )
            return "已删除空间：\(name)"
        }
    }

    private static func patchLocation(
        target: LabLocation,
        fields: AgentLocationFields,
        currentMember: Member?,
        allLocations: [LabLocation],
        members: [Member]
    ) throws {
        if let name = fields.name?.trimmedNonEmpty {
            target.name = name
        }

        if let statusToken = fields.status?.trimmedNonEmpty {
            guard let status = parseLocationStatus(statusToken) else {
                throw executionError("无效的空间状态：\(statusToken)")
            }
            target.status = status
        }

        if let isPublic = fields.isPublic {
            target.isPublic = isPublic
        }

        if let detailLink = fields.detailLink {
            target.detailLink = detailLink.trimmed
        }

        if let notes = fields.notes {
            target.notes = notes.trimmed
        }

        if fields.latitude != nil || fields.longitude != nil {
            guard let latitude = fields.latitude,
                  let longitude = fields.longitude else {
                throw executionError("坐标更新需同时提供 latitude 和 longitude。")
            }
            target.latitude = latitude
            target.longitude = longitude
            target.coordinateSource = fields.coordinateSource?.trimmed ?? target.coordinateSource
        }

        if let parentToken = fields.parentName {
            if isExplicitNull(parentToken) {
                target.parent = nil
            } else {
                let parent = try resolveLocationName(parentToken, in: allLocations.filter { $0.id != target.id })
                target.parent = parent
            }
        }

        if let memberTokens = fields.responsibleMemberNames {
            let selected = try resolveMembers(tokens: memberTokens, in: members)
            if target.isPublic {
                target.responsibleMembers = selected
            } else if selected.isEmpty, let currentMember {
                target.responsibleMembers = [currentMember]
            } else {
                target.responsibleMembers = selected
            }
        } else if !target.isPublic,
                  target.responsibleMembers.isEmpty,
                  let currentMember {
            target.responsibleMembers = [currentMember]
        }

        if !target.isPublic,
           target.responsibleMembers.isEmpty {
            throw executionError("私人空间至少需要一位负责人。")
        }

        if fields.detailRefs != nil || fields.usageTags != nil {
            let baseRefs: [DetailRef]
            if let detailRefs = fields.detailRefs {
                baseRefs = DomainCodec.deduplicatedDetailRefs(
                    detailRefs.map { DetailRef(label: $0.label?.trimmed ?? "", value: $0.value.trimmed) }
                )
            } else {
                baseRefs = target.detailRefsWithoutUsageTags
            }

            let tags: [LocationUsageTag]
            if let usageTokens = fields.usageTags {
                tags = try parseUsageTags(usageTokens)
            } else {
                tags = target.usageTags
            }

            target.detailRefs = DomainCodec.mergeUsageTags(tags, into: baseRefs)
        }

        guard target.name.trimmedNonEmpty != nil else {
            throw executionError("空间名称不能为空。")
        }

        target.touch()
    }

    private static func applyEvent(
        operation: AgentOperation,
        modelContext: ModelContext,
        currentMember: Member?,
        events: inout [LabEvent],
        items: [LabItem],
        locations: [LabLocation],
        members: [Member],
        deletedAttachmentRefs: inout [String],
        requestID: String?
    ) throws -> String {
        switch operation.action {
        case .create:
            guard let fields = operation.event else {
                throw executionError("事项操作缺少 event 字段。")
            }
            guard let title = fields.title?.trimmedNonEmpty else {
                throw executionError("新增事项必须提供 event.title。")
            }

            let owner: Member
            if let ownerName = fields.ownerName?.trimmedNonEmpty {
                owner = try resolveMemberToken(ownerName, in: members)
            } else if let currentMember {
                owner = currentMember
            } else if let first = members.first {
                owner = first
            } else {
                throw executionError("请先创建成员后再创建事项。")
            }

            let target = LabEvent(title: title, owner: owner)

            try patchEvent(
                target: target,
                fields: fields,
                isCreate: true,
                modelContext: modelContext,
                items: items,
                locations: locations,
                members: members
            )

            modelContext.insert(target)
            events.append(target)

            modelContext.insert(
                LabLog(
                    actionType: "AI新增事项",
                    details: logDetails("AI created event \(target.title)", requestID: requestID),
                    user: currentMember,
                    event: target
                )
            )
            return "已新增事项：\(target.title)"

        case .update:
            guard let fields = operation.event else {
                throw executionError("事项操作缺少 event 字段。")
            }
            let target = try resolveEvent(target: operation.target, fallbackTitle: fields.title, in: events)
            try patchEvent(
                target: target,
                fields: fields,
                isCreate: false,
                modelContext: modelContext,
                items: items,
                locations: locations,
                members: members
            )

            modelContext.insert(
                LabLog(
                    actionType: "AI修改事项",
                    details: logDetails("AI updated event \(target.title)", requestID: requestID),
                    user: currentMember,
                    event: target
                )
            )
            return "已修改事项：\(target.title)"
        case .delete:
            let fallbackTitle = operation.event?.title
            if isBulkDelete(operation: operation, fallbackToken: fallbackTitle) {
                let deletable = events.filter { event in
                    if event.owner?.id != nil, event.owner?.id != currentMember?.id {
                        return false
                    }
                    return true
                }
                guard !deletable.isEmpty else {
                    throw executionError("当前范围内没有可删除的事项。")
                }

                let skippedCount = max(0, events.count - deletable.count)
                for target in deletable {
                    let refs = target.attachmentRefs
                    let targetID = target.id
                    let title = target.title
                    modelContext.delete(target)
                    events.removeAll { $0.id == targetID }
                    deletedAttachmentRefs.append(contentsOf: refs)
                    modelContext.insert(
                        LabLog(
                            actionType: "AI删除事项",
                            details: logDetails("AI deleted event \(title)", requestID: requestID),
                            user: currentMember
                        )
                    )
                }
                if skippedCount > 0 {
                    return "已批量删除事项：\(deletable.count) 条，跳过非本人负责目标 \(skippedCount) 条。"
                }
                return "已批量删除事项：\(deletable.count) 条。"
            }

            let target = try resolveEvent(target: operation.target, fallbackTitle: fallbackTitle, in: events)
            if target.owner?.id != nil, target.owner?.id != currentMember?.id {
                throw executionError("仅事项负责人可删除：\(target.title)")
            }

            let refs = target.attachmentRefs
            let targetID = target.id
            let title = target.title
            modelContext.delete(target)
            events.removeAll { $0.id == targetID }
            deletedAttachmentRefs.append(contentsOf: refs)

            modelContext.insert(
                LabLog(
                    actionType: "AI删除事项",
                    details: logDetails("AI deleted event \(title)", requestID: requestID),
                    user: currentMember
                )
            )
            return "已删除事项：\(title)"
        }
    }

    private static func patchEvent(
        target: LabEvent,
        fields: AgentEventFields,
        isCreate: Bool,
        modelContext: ModelContext,
        items: [LabItem],
        locations: [LabLocation],
        members: [Member]
    ) throws {
        if let title = fields.title?.trimmedNonEmpty {
            target.title = title
        }

        if let summary = fields.summaryText {
            target.summaryText = summary.trimmed
        }

        var visibility = target.visibility
        if let visibilityToken = fields.visibility?.trimmedNonEmpty {
            guard let parsed = parseVisibility(visibilityToken) else {
                throw executionError("无效的事项可见性：\(visibilityToken)")
            }
            visibility = parsed
            target.visibility = parsed
        }

        if let detailLink = fields.detailLink {
            target.detailLink = detailLink.trimmed
        }

        if let allowParticipantEdit = fields.allowParticipantEdit {
            target.allowParticipantEdit = visibility == .internal ? allowParticipantEdit : false
        } else if visibility != .internal {
            target.allowParticipantEdit = false
        }

        if let ownerName = fields.ownerName?.trimmedNonEmpty {
            target.owner = try resolveMemberToken(ownerName, in: members)
        }

        if let startToken = fields.startTimeISO {
            if isExplicitNull(startToken) {
                target.startTime = nil
            } else {
                guard let parsed = parseDate(startToken) else {
                    throw executionError("开始时间无法解析：\(startToken)")
                }
                target.startTime = parsed
            }
        }

        if let endToken = fields.endTimeISO {
            if isExplicitNull(endToken) {
                target.endTime = nil
            } else {
                guard let parsed = parseDate(endToken) else {
                    throw executionError("结束时间无法解析：\(endToken)")
                }
                target.endTime = parsed
            }
        }

        if let start = target.startTime,
           let end = target.endTime,
           end < start {
            throw executionError("结束时间不能早于开始时间。")
        }

        if let itemTokens = fields.itemNames {
            target.items = try resolveItems(tokens: itemTokens, in: items)
        }

        if let locationTokens = fields.locationNames {
            target.locations = try resolveLocations(tokens: locationTokens, in: locations)
        }

        if let participantTokens = fields.participantNames {
            let desired = try resolveMembers(tokens: participantTokens, in: members)
            try syncParticipants(
                event: target,
                desiredParticipants: desired,
                visibility: visibility,
                modelContext: modelContext
            )
        } else if visibility == .personal {
            try syncParticipants(
                event: target,
                desiredParticipants: [],
                visibility: .personal,
                modelContext: modelContext
            )
        } else if isCreate {
            if visibility == .internal {
                throw executionError("内部事项至少需要一名参与成员。")
            }
            target.ensureOwnerParticipation()
        } else {
            target.ensureOwnerParticipation()
            if visibility == .internal {
                let participantCountExcludingOwner = target.participantLinks
                    .compactMap(\.member)
                    .filter { $0.id != target.owner?.id }
                    .count
                if participantCountExcludingOwner == 0 {
                    throw executionError("内部事项至少需要一名参与成员。")
                }
            }
        }

        guard target.title.trimmedNonEmpty != nil else {
            throw executionError("事项标题不能为空。")
        }

        guard target.owner != nil else {
            throw executionError("事项必须设置负责人。")
        }

        if isCreate {
            target.createdAt = .now
        }
        target.touch()
    }

    private static func syncParticipants(
        event: LabEvent,
        desiredParticipants: [Member],
        visibility: EventVisibility,
        modelContext: ModelContext
    ) throws {
        guard let owner = event.owner else {
            throw executionError("事项缺少负责人，无法同步参与成员。")
        }

        var desiredIDs = Set(desiredParticipants.map(\.id))
        desiredIDs.remove(owner.id)

        if visibility == .personal {
            desiredIDs.removeAll()
        }

        if visibility == .internal && desiredIDs.isEmpty {
            throw executionError("内部事项至少需要一名参与成员。")
        }

        var existingByMemberID: [UUID: EventParticipant] = [:]
        for link in event.participantLinks {
            if let memberID = link.member?.id {
                existingByMemberID[memberID] = link
            }
        }

        for (memberID, link) in existingByMemberID {
            if memberID == owner.id {
                link.role = .owner
                link.status = .confirmed
                continue
            }
            if !desiredIDs.contains(memberID) {
                modelContext.delete(link)
            } else {
                link.role = .participant
                link.status = .confirmed
            }
        }

        if visibility != .personal {
            for member in desiredParticipants where member.id != owner.id {
                guard existingByMemberID[member.id] == nil else { continue }
                let link = EventParticipant(
                    roleRaw: EventParticipantRole.participant.rawValue,
                    statusRaw: EventParticipantStatus.confirmed.rawValue,
                    joinedAt: .now,
                    event: event,
                    member: member
                )
                event.participantLinks.append(link)
            }
        }

        event.ensureOwnerParticipation()
    }

    private static func applyMember(
        operation: AgentOperation,
        modelContext: ModelContext,
        currentMember: Member?,
        members: inout [Member],
        deletedAttachmentRefs: inout [String],
        requestID: String?
    ) throws -> String {
        switch operation.action {
        case .create:
            guard let fields = operation.member else {
                throw executionError("成员操作缺少 member 字段。")
            }
            guard let name = fields.name?.trimmedNonEmpty else {
                throw executionError("新增成员必须提供 member.name。")
            }

            let preferredUsername = fields.username?.trimmedNonEmpty ?? name
            let username = makeAvailableUsername(from: preferredUsername, in: members)

            let target = Member(name: name, username: username)

            var patchedFields = fields
            patchedFields.username = username
            try patchMember(target: target, fields: patchedFields, allMembers: members + [target])

            modelContext.insert(target)
            members.append(target)

            modelContext.insert(
                LabLog(
                    actionType: "AI新增成员",
                    details: logDetails("AI created member \(target.displayName)", requestID: requestID),
                    user: currentMember ?? target
                )
            )
            return "已新增成员：\(target.displayName)（@\(target.username)）"

        case .update:
            guard let fields = operation.member else {
                throw executionError("成员操作缺少 member 字段。")
            }
            let target = try resolveMember(
                target: operation.target,
                fallbackName: fields.name,
                fallbackUsername: fields.username,
                in: members
            )

            try patchMember(target: target, fields: fields, allMembers: members)

            modelContext.insert(
                LabLog(
                    actionType: "AI修改成员",
                    details: logDetails("AI updated member \(target.displayName)", requestID: requestID),
                    user: currentMember ?? target
                )
            )
            return "已修改成员：\(target.displayName)"
        case .delete:
            if isBulkDelete(operation: operation, fallbackToken: operation.member?.username ?? operation.member?.name) {
                let deletable = members.filter { $0.id != currentMember?.id }
                guard !deletable.isEmpty else {
                    throw executionError("当前范围内没有可删除的成员。")
                }

                let skippedCount = members.contains(where: { $0.id == currentMember?.id }) ? 1 : 0
                for target in deletable {
                    let oldPhotoRef = target.photoRef
                    let targetID = target.id
                    let displayName = target.displayName
                    modelContext.delete(target)
                    members.removeAll { $0.id == targetID }
                    if !oldPhotoRef.isEmpty {
                        deletedAttachmentRefs.append(oldPhotoRef)
                    }
                    modelContext.insert(
                        LabLog(
                            actionType: "AI删除成员",
                            details: logDetails("AI deleted member \(displayName)", requestID: requestID),
                            user: currentMember
                        )
                    )
                }
                if skippedCount > 0 {
                    return "已批量删除成员：\(deletable.count) 条，已自动保留当前登录成员。"
                }
                return "已批量删除成员：\(deletable.count) 条。"
            }

            let target = try resolveMember(
                target: operation.target,
                fallbackName: operation.member?.name,
                fallbackUsername: operation.member?.username,
                in: members
            )
            guard target.id != currentMember?.id else {
                throw executionError("不能删除当前登录成员。")
            }

            let oldPhotoRef = target.photoRef
            let targetID = target.id
            let displayName = target.displayName
            let username = target.username

            modelContext.delete(target)
            members.removeAll { $0.id == targetID }
            if !oldPhotoRef.isEmpty {
                deletedAttachmentRefs.append(oldPhotoRef)
            }

            modelContext.insert(
                LabLog(
                    actionType: "AI删除成员",
                    details: logDetails("AI deleted member \(displayName)", requestID: requestID),
                    user: currentMember
                )
            )
            return "已删除成员：\(displayName)（@\(username)）"
        }
    }

    private static func patchMember(
        target: Member,
        fields: AgentMemberFields,
        allMembers: [Member]
    ) throws {
        if let name = fields.name?.trimmedNonEmpty {
            target.name = name
        }

        if let username = fields.username?.trimmedNonEmpty {
            try ensureUsernameAvailable(username, excluding: target.id, in: allMembers)
            target.username = username
        }

        if let contact = fields.contact {
            target.contact = contact.trimmed
        }

        if let password = fields.password?.trimmedNonEmpty {
            target.passwordHash = password
        }

        if let bio = fields.bio {
            var metadata = target.profileMetadata
            metadata.bio = bio.trimmed
            target.setProfileMetadata(metadata)
        } else {
            target.lastModified = .now
        }

        guard target.name.trimmedNonEmpty != nil else {
            throw executionError("成员姓名不能为空。")
        }
        guard target.username.trimmedNonEmpty != nil else {
            throw executionError("成员用户名不能为空。")
        }
    }

    private static func ensureUsernameAvailable(
        _ username: String,
        excluding memberID: UUID?,
        in members: [Member]
    ) throws {
        let lowered = username.normalizedToken
        if members.contains(where: { $0.username.normalizedToken == lowered && $0.id != memberID }) {
            throw executionError("用户名已存在：\(username)")
        }
    }

    private static func makeAvailableUsername(from source: String, in members: [Member]) -> String {
        let seed = usernameSeed(from: source)
        var candidate = seed
        var suffix = 1

        while members.contains(where: { $0.username.normalizedToken == candidate.normalizedToken }) {
            suffix += 1
            candidate = "\(seed)\(suffix)"
        }

        return candidate
    }

    private static func usernameSeed(from source: String) -> String {
        let token = source.trimmed
        if token.isEmpty {
            return "user"
        }

        let latin = token.applyingTransform(.toLatin, reverse: false) ?? token
        let folded = latin
            .folding(options: [.diacriticInsensitive, .widthInsensitive, .caseInsensitive], locale: .current)
            .lowercased()

        let mapped = folded.unicodeScalars.map { scalar -> String in
            if CharacterSet.alphanumerics.contains(scalar) {
                return String(scalar)
            }
            return "_"
        }
        .joined()

        let compacted = mapped
            .replacingOccurrences(of: "_+", with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))

        if compacted.isEmpty {
            return "user"
        }
        return compacted
    }

    private static func resolveItem(
        target: AgentTarget?,
        fallbackName: String?,
        in items: [LabItem]
    ) throws -> LabItem {
        if let idToken = target?.id?.trimmedNonEmpty,
           let uuid = UUID(uuidString: idToken),
           let matched = items.first(where: { $0.id == uuid }) {
            return matched
        }

        if let nameToken = target?.name?.trimmedNonEmpty ?? fallbackName?.trimmedNonEmpty {
            return try resolveItemName(nameToken, in: items)
        }

        throw executionError("物品操作缺少 target。")
    }

    private static func resolveLocation(
        target: AgentTarget?,
        fallbackName: String?,
        in locations: [LabLocation]
    ) throws -> LabLocation {
        if let idToken = target?.id?.trimmedNonEmpty,
           let uuid = UUID(uuidString: idToken),
           let matched = locations.first(where: { $0.id == uuid }) {
            return matched
        }

        if let nameToken = target?.name?.trimmedNonEmpty ?? fallbackName?.trimmedNonEmpty {
            return try resolveLocationName(nameToken, in: locations)
        }

        throw executionError("空间操作缺少 target。")
    }

    private static func resolveEvent(
        target: AgentTarget?,
        fallbackTitle: String?,
        in events: [LabEvent]
    ) throws -> LabEvent {
        if let idToken = target?.id?.trimmedNonEmpty,
           let uuid = UUID(uuidString: idToken),
           let matched = events.first(where: { $0.id == uuid }) {
            return matched
        }

        if let titleToken = target?.name?.trimmedNonEmpty ?? fallbackTitle?.trimmedNonEmpty {
            let normalized = titleToken.normalizedToken
            let exact = events.filter { $0.title.normalizedToken == normalized }
            if exact.count == 1, let only = exact.first {
                return only
            }
            if exact.count > 1 {
                throw executionError("事项目标不唯一：\(titleToken)")
            }
            let fuzzy = events.filter { $0.title.normalizedToken.contains(normalized) }
            if fuzzy.count == 1, let only = fuzzy.first {
                return only
            }
            if fuzzy.count > 1 {
                throw executionError("事项目标匹配到多条记录：\(titleToken)")
            }
        }

        throw executionError("未找到事项。")
    }

    private static func resolveMember(
        target: AgentTarget?,
        fallbackName: String?,
        fallbackUsername: String?,
        in members: [Member]
    ) throws -> Member {
        if let idToken = target?.id?.trimmedNonEmpty,
           let uuid = UUID(uuidString: idToken),
           let matched = members.first(where: { $0.id == uuid }) {
            return matched
        }

        if let usernameToken = target?.username?.trimmedNonEmpty ?? fallbackUsername?.trimmedNonEmpty {
            let matches = members.filter { $0.username.normalizedToken == usernameToken.normalizedToken }
            if matches.count == 1, let only = matches.first {
                return only
            }
            if matches.count > 1 {
                throw executionError("成员用户名匹配不唯一：\(usernameToken)")
            }
        }

        if let nameToken = target?.name?.trimmedNonEmpty ?? fallbackName?.trimmedNonEmpty {
            return try resolveMemberToken(nameToken, in: members)
        }

        throw executionError("成员操作缺少 target。")
    }

    private static func isBulkDelete(operation: AgentOperation, fallbackToken: String?) -> Bool {
        isBulkDeleteToken(operation.target?.name)
            || isBulkDeleteToken(fallbackToken)
            || isBulkDeleteToken(operation.note)
    }

    private static func isBulkDeleteToken(_ token: String?) -> Bool {
        guard let token = token?.trimmedNonEmpty else { return false }
        let normalized = token.normalizedToken
        if normalized.isEmpty { return false }
        return bulkDeleteTokens.contains { marker in
            normalized == marker || normalized.contains(marker)
        }
    }

    private static let bulkDeleteTokens: [String] = [
        "__all__", "*", "all", "everything", "所有", "全部", "全体", "全都", "清空"
    ]

    private static func resolveItems(tokens: [String], in items: [LabItem]) throws -> [LabItem] {
        var results: [LabItem] = []
        var seen = Set<UUID>()
        for token in tokens {
            guard let normalized = token.trimmedNonEmpty else { continue }
            let matched = try resolveItemName(normalized, in: items)
            guard !seen.contains(matched.id) else { continue }
            seen.insert(matched.id)
            results.append(matched)
        }
        return results
    }

    private static func resolveLocations(tokens: [String], in locations: [LabLocation]) throws -> [LabLocation] {
        var results: [LabLocation] = []
        var seen = Set<UUID>()
        for token in tokens {
            guard let normalized = token.trimmedNonEmpty else { continue }
            let matched = try resolveLocationName(normalized, in: locations)
            guard !seen.contains(matched.id) else { continue }
            seen.insert(matched.id)
            results.append(matched)
        }
        return results
    }

    private static func resolveMembers(tokens: [String], in members: [Member]) throws -> [Member] {
        var results: [Member] = []
        var seen = Set<UUID>()
        for token in tokens {
            guard let normalized = token.trimmedNonEmpty else { continue }
            let matched = try resolveMemberToken(normalized, in: members)
            guard !seen.contains(matched.id) else { continue }
            seen.insert(matched.id)
            results.append(matched)
        }
        return results
    }

    private static func resolveItemName(_ name: String, in items: [LabItem]) throws -> LabItem {
        let normalized = name.normalizedToken
        let exact = items.filter { $0.name.normalizedToken == normalized }
        if exact.count == 1, let only = exact.first {
            return only
        }
        if exact.count > 1 {
            throw executionError("物品目标不唯一：\(name)")
        }

        let fuzzy = items.filter { $0.name.normalizedToken.contains(normalized) }
        if fuzzy.count == 1, let only = fuzzy.first {
            return only
        }
        if fuzzy.count > 1 {
            throw executionError("物品目标匹配到多条记录：\(name)")
        }

        throw executionError("未找到物品：\(name)")
    }

    private static func resolveLocationName(_ name: String, in locations: [LabLocation]) throws -> LabLocation {
        let normalized = name.normalizedToken
        let exact = locations.filter { $0.name.normalizedToken == normalized }
        if exact.count == 1, let only = exact.first {
            return only
        }
        if exact.count > 1 {
            throw executionError("空间目标不唯一：\(name)")
        }

        let fuzzy = locations.filter { $0.name.normalizedToken.contains(normalized) }
        if fuzzy.count == 1, let only = fuzzy.first {
            return only
        }
        if fuzzy.count > 1 {
            throw executionError("空间目标匹配到多条记录：\(name)")
        }

        throw executionError("未找到空间：\(name)")
    }

    private static func resolveMemberToken(_ token: String, in members: [Member]) throws -> Member {
        let normalized = token.normalizedToken

        let byUsername = members.filter { $0.username.normalizedToken == normalized }
        if byUsername.count == 1, let only = byUsername.first {
            return only
        }
        if byUsername.count > 1 {
            throw executionError("成员用户名匹配不唯一：\(token)")
        }

        let byDisplayName = members.filter {
            $0.displayName.normalizedToken == normalized || $0.name.normalizedToken == normalized
        }
        if byDisplayName.count == 1, let only = byDisplayName.first {
            return only
        }
        if byDisplayName.count > 1 {
            throw executionError("成员姓名匹配不唯一：\(token)")
        }

        let fuzzy = members.filter {
            $0.displayName.normalizedToken.contains(normalized)
                || $0.username.normalizedToken.contains(normalized)
        }
        if fuzzy.count == 1, let only = fuzzy.first {
            return only
        }
        if fuzzy.count > 1 {
            throw executionError("成员匹配到多条记录：\(token)")
        }

        throw executionError("未找到成员：\(token)")
    }

    private static func parseItemStatus(_ token: String) -> ItemStockStatus? {
        let normalized = token.normalizedToken

        if let direct = ItemStockStatus.allCases.first(where: { $0.rawValue.normalizedToken == normalized }) {
            return direct
        }

        switch normalized {
        case "normal", "ok":
            return .normal
        case "low", "few":
            return .low
        case "empty", "out", "none":
            return .empty
        case "borrowed", "loan":
            return .borrowed
        case "discarded", "drop", "trash":
            return .discarded
        default:
            return nil
        }
    }

    private static func parseItemFeature(_ token: String) -> ItemFeature? {
        let normalized = token.normalizedToken

        if let direct = ItemFeature.allCases.first(where: { $0.rawValue.normalizedToken == normalized }) {
            return direct
        }

        switch normalized {
        case "public", "common", "公开":
            return .public
        case "private", "personal", "私有":
            return .private
        default:
            return nil
        }
    }

    private static func parseLocationStatus(_ token: String) -> LocationStatus? {
        let normalized = token.normalizedToken

        if let direct = LocationStatus.allCases.first(where: { $0.rawValue.normalizedToken == normalized }) {
            return direct
        }

        switch normalized {
        case "normal", "ok":
            return .normal
        case "dirty":
            return .dirty
        case "repair", "fix":
            return .repair
        case "danger", "risky":
            return .danger
        case "forbidden", "ban", "closed":
            return .forbidden
        default:
            return nil
        }
    }

    private static func parseVisibility(_ token: String) -> EventVisibility? {
        let normalized = token.normalizedToken

        if let direct = EventVisibility.allCases.first(where: { $0.rawValue.normalizedToken == normalized }) {
            return direct
        }

        switch normalized {
        case "个人事项", "个人":
            return .personal
        case "内部事项", "内部":
            return .internal
        case "公开事项", "公开", "publicevent":
            return .public
        default:
            return nil
        }
    }

    private static func parseUsageTags(_ tokens: [String]) throws -> [LocationUsageTag] {
        var tags: [LocationUsageTag] = []
        var seen = Set<LocationUsageTag>()

        for token in tokens {
            guard let normalized = token.trimmedNonEmpty else { continue }

            let parsed = LocationUsageTag.from(label: normalized)
                ?? LocationUsageTag.allCases.first(where: { $0.rawValue.normalizedToken == normalized.normalizedToken })

            guard let tag = parsed else {
                throw executionError("无效的空间用途标签：\(normalized)")
            }

            guard !seen.contains(tag) else { continue }
            seen.insert(tag)
            tags.append(tag)
        }

        return tags
    }

    private static func isExplicitNull(_ token: String) -> Bool {
        let normalized = token.normalizedToken
        return ["", "null", "none", "nil", "无", "空", "清空"].contains(normalized)
    }

    private static func parseDate(_ token: String) -> Date? {
        let value = token.trimmed
        guard !value.isEmpty else { return nil }

        if let natural = parseNaturalLanguageDate(value) {
            return natural
        }

        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        if let date = withFractional.date(from: value) {
            return date
        }

        let iso = ISO8601DateFormatter()
        if let date = iso.date(from: value) {
            return date
        }

        let formats = [
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm",
            "yyyy-MM-dd",
            "yyyy/MM/dd HH:mm:ss",
            "yyyy/MM/dd HH:mm",
            "yyyy/MM/dd"
        ]

        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return date
            }
        }

        return nil
    }

    private static func parseNaturalLanguageDate(_ text: String) -> Date? {
        let calendar = Calendar.current
        let now = Date()
        let trimmedText = text.trimmed
        let normalized = trimmedText.normalizedToken

        if let weekday = parseWeekdayToken(from: trimmedText) {
            let forceNextWeek = trimmedText.contains("下周") || trimmedText.contains("下星期")
            let base = dateForWeekday(weekday, from: now, calendar: calendar, forceNextWeek: forceNextWeek)
            return applyTime(to: base, from: trimmedText, calendar: calendar)
        }

        if let dayOffset = parseRelativeDayOffset(trimmedText, normalized: normalized) {
            let base = calendar.date(byAdding: .day, value: dayOffset, to: calendar.startOfDay(for: now)) ?? now
            return applyTime(to: base, from: trimmedText, calendar: calendar)
        }

        return nil
    }

    private static func parseRelativeDayOffset(_ text: String, normalized: String) -> Int? {
        if text.contains("大后天") || normalized.contains("in 3 days") {
            return 3
        }
        if text.contains("后天") || normalized.contains("day after tomorrow") {
            return 2
        }
        if text.contains("明天") || normalized.contains("tomorrow") {
            return 1
        }
        if text.contains("今天") || normalized.contains("today") {
            return 0
        }

        if let cn = firstRegexGroup(#"(\d+)\s*天后"#, in: text),
           let value = Int(cn) {
            return value
        }

        if let en = firstRegexGroup(#"in\s*(\d+)\s*days?"#, in: normalized),
           let value = Int(en) {
            return value
        }

        return nil
    }

    private static func parseWeekdayToken(from text: String) -> Int? {
        let mapping: [(tokens: [String], weekday: Int)] = [
            (["周一", "星期一"], 2),
            (["周二", "星期二"], 3),
            (["周三", "星期三"], 4),
            (["周四", "星期四"], 5),
            (["周五", "星期五"], 6),
            (["周六", "星期六"], 7),
            (["周日", "周天", "星期日", "星期天"], 1)
        ]

        for entry in mapping {
            if entry.tokens.contains(where: { text.contains($0) }) {
                return entry.weekday
            }
        }
        return nil
    }

    private static func dateForWeekday(
        _ weekday: Int,
        from now: Date,
        calendar: Calendar,
        forceNextWeek: Bool
    ) -> Date {
        let start = calendar.startOfDay(for: now)
        let currentWeekday = calendar.component(.weekday, from: start)
        var delta = weekday - currentWeekday

        if delta < 0 {
            delta += 7
        }
        if forceNextWeek {
            delta += 7
        }

        return calendar.date(byAdding: .day, value: delta, to: start) ?? start
    }

    private static func applyTime(to base: Date, from text: String, calendar: Calendar) -> Date {
        if let parsed = extractTime(from: text) {
            return calendar.date(bySettingHour: parsed.hour, minute: parsed.minute, second: 0, of: base) ?? base
        }

        if text.contains("下午") {
            return calendar.date(bySettingHour: 15, minute: 0, second: 0, of: base) ?? base
        }
        if text.contains("晚上") {
            return calendar.date(bySettingHour: 20, minute: 0, second: 0, of: base) ?? base
        }
        if text.contains("中午") {
            return calendar.date(bySettingHour: 12, minute: 0, second: 0, of: base) ?? base
        }
        if text.contains("上午") || text.contains("早上") {
            return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: base) ?? base
        }

        return base
    }

    private static func extractTime(from text: String) -> (hour: Int, minute: Int)? {
        if let match = regexMatch(#"(?:(凌晨|早上|上午|中午|下午|晚上))?\s*(\d{1,2})\s*[:：]\s*(\d{1,2})"#, in: text) {
            let period = match[safe: 1]
            guard let hourToken = match[safe: 2], let hourValue = Int(hourToken),
                  let minuteToken = match[safe: 3], let minuteValue = Int(minuteToken) else {
                return nil
            }
            let hour = normalizeHour(hourValue, period: period)
            return (min(max(0, hour), 23), min(max(0, minuteValue), 59))
        }

        if let match = regexMatch(#"(?:(凌晨|早上|上午|中午|下午|晚上))?\s*(\d{1,2})\s*点\s*(半|\d{1,2})?"#, in: text) {
            let period = match[safe: 1]
            guard let hourToken = match[safe: 2], let hourValue = Int(hourToken) else {
                return nil
            }
            let minute: Int
            if let minuteToken = match[safe: 3] {
                if minuteToken == "半" {
                    minute = 30
                } else {
                    minute = Int(minuteToken) ?? 0
                }
            } else {
                minute = 0
            }
            let hour = normalizeHour(hourValue, period: period)
            return (min(max(0, hour), 23), min(max(0, minute), 59))
        }

        return nil
    }

    private static func normalizeHour(_ hour: Int, period: String?) -> Int {
        guard let period else { return hour }

        switch period {
        case "下午", "晚上":
            if hour < 12 { return hour + 12 }
            return hour
        case "中午":
            if hour < 11 { return hour + 12 }
            return hour
        case "凌晨":
            if hour == 12 { return 0 }
            return hour
        case "上午", "早上":
            if hour == 12 { return 0 }
            return hour
        default:
            return hour
        }
    }

    private static func regexMatch(_ pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: []) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else {
            return nil
        }

        var groups: [String] = []
        for index in 1..<match.numberOfRanges {
            let nsRange = match.range(at: index)
            if nsRange.location == NSNotFound {
                groups.append("")
                continue
            }
            guard let swiftRange = Range(nsRange, in: text) else {
                groups.append("")
                continue
            }
            groups.append(String(text[swiftRange]))
        }
        return groups
    }

    private static func firstRegexGroup(_ pattern: String, in text: String) -> String? {
        regexMatch(pattern, in: text)?[safe: 0]?.trimmedNonEmpty
    }

    private static func logDetails(_ base: String, requestID: String?) -> String {
        guard let requestID = requestID?.trimmedNonEmpty else {
            return base
        }
        return "\(base) [request_id=\(requestID)]"
    }

    private static func ensureCanEditItem(
        _ target: LabItem,
        currentMember: Member?,
        actionLabel: String
    ) throws {
        guard target.canEdit(currentMember) else {
            throw executionError("无权\(actionLabel)该私有物品：\(target.name)")
        }
    }

    private static func ensureCanEditLocation(
        _ target: LabLocation,
        currentMember: Member?,
        actionLabel: String
    ) throws {
        guard target.canEdit(currentMember) else {
            throw executionError("无权\(actionLabel)该空间：\(target.name)")
        }
    }

    private static func executionError(_ message: String) -> NSError {
        NSError(
            domain: "AgentExecutorService",
            code: 5001,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}

private extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var trimmedNonEmpty: String? {
        let token = trimmed
        return token.isEmpty ? nil : token
    }

    var normalizedToken: String {
        trimmed.lowercased()
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
