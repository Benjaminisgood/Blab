import Foundation

struct HousekeeperVerificationEntry {
    var operationID: String
    var success: Bool
    var message: String
}

struct HousekeeperVerificationResult {
    var entries: [HousekeeperVerificationEntry]

    var successCount: Int {
        entries.filter(\.success).count
    }

    var failureCount: Int {
        entries.filter { !$0.success }.count
    }

    var summary: String {
        "目标校验完成：通过 \(successCount) 条，未通过 \(failureCount) 条。"
    }
}

struct HousekeeperVerificationSnapshot {
    var items: [LabItem]
    var locations: [LabLocation]
    var events: [LabEvent]
    var members: [Member]
}

enum HousekeeperPostConditionVerifier {
    static func verify(
        plan: AgentPlan,
        before: HousekeeperVerificationSnapshot,
        after: HousekeeperVerificationSnapshot
    ) -> HousekeeperVerificationResult {
        let entries = plan.operations.map { operation in
            verifyOperation(
                operation,
                before: before,
                after: after
            )
        }
        return HousekeeperVerificationResult(entries: entries)
    }

    private static func verifyOperation(
        _ operation: AgentOperation,
        before: HousekeeperVerificationSnapshot,
        after: HousekeeperVerificationSnapshot
    ) -> HousekeeperVerificationEntry {
        switch (operation.entity, operation.action) {
        case (.item, .create):
            return verifyCreateItem(operation, before: before, after: after)
        case (.item, .update):
            return verifyUpdateItem(operation, before: before, after: after)
        case (.item, .delete):
            return verifyDeleteItem(operation, before: before, after: after)

        case (.location, .create):
            return verifyCreateLocation(operation, before: before, after: after)
        case (.location, .update):
            return verifyUpdateLocation(operation, before: before, after: after)
        case (.location, .delete):
            return verifyDeleteLocation(operation, before: before, after: after)

        case (.event, .create):
            return verifyCreateEvent(operation, before: before, after: after)
        case (.event, .update):
            return verifyUpdateEvent(operation, before: before, after: after)
        case (.event, .delete):
            return verifyDeleteEvent(operation, before: before, after: after)

        case (.member, .create):
            return verifyCreateMember(operation, before: before, after: after)
        case (.member, .update):
            return verifyUpdateMember(operation, before: before, after: after)
        case (.member, .delete):
            return verifyDeleteMember(operation, before: before, after: after)
        }
    }

    private static func verifyCreateItem(
        _ operation: AgentOperation,
        before: HousekeeperVerificationSnapshot,
        after: HousekeeperVerificationSnapshot
    ) -> HousekeeperVerificationEntry {
        let nameToken = trimmedNonEmpty(operation.item?.name) ?? trimmedNonEmpty(operation.target?.name)
        let beforeMatches = matchItems(byName: nameToken, in: before.items)
        let afterMatches = matchItems(byName: nameToken, in: after.items)

        guard afterMatches.count > beforeMatches.count else {
            let label = nameToken ?? "目标物品"
            return failedEntry(operation.id, "新增校验失败：\(label) 在执行后数量未增加。")
        }

        guard let candidate = newestItem(in: afterMatches) else {
            return failedEntry(operation.id, "新增校验失败：未找到新增后的物品记录。")
        }

        let issues = validateItemFields(
            operation.item,
            actual: candidate,
            allMembers: after.members,
            allLocations: after.locations
        )
        guard issues.isEmpty else {
            return failedEntry(operation.id, "新增校验失败：\(issues.joined(separator: "；"))")
        }

        return successEntry(operation.id, "新增物品目标已达成。")
    }

    private static func verifyUpdateItem(
        _ operation: AgentOperation,
        before: HousekeeperVerificationSnapshot,
        after: HousekeeperVerificationSnapshot
    ) -> HousekeeperVerificationEntry {
        let candidate: LabItem
        do {
            if let beforeTarget = try resolveItem(
                target: operation.target,
                fallbackName: operation.item?.name,
                in: before.items
            ),
               let afterByID = after.items.first(where: { $0.id == beforeTarget.id }) {
                candidate = afterByID
            } else {
                guard let resolved = try resolveItem(
                    target: operation.target,
                    fallbackName: operation.item?.name,
                    in: after.items
                ) else {
                    return failedEntry(operation.id, "修改校验失败：执行后未定位到物品。")
                }
                candidate = resolved
            }
        } catch {
            return failedEntry(operation.id, "修改校验失败：\(error.localizedDescription)")
        }

        let issues = validateItemFields(
            operation.item,
            actual: candidate,
            allMembers: after.members,
            allLocations: after.locations
        )
        guard issues.isEmpty else {
            return failedEntry(operation.id, "修改校验失败：\(issues.joined(separator: "；"))")
        }

        return successEntry(operation.id, "修改物品目标已达成。")
    }

    private static func verifyDeleteItem(
        _ operation: AgentOperation,
        before: HousekeeperVerificationSnapshot,
        after: HousekeeperVerificationSnapshot
    ) -> HousekeeperVerificationEntry {
        do {
            guard let beforeTarget = try resolveItem(
                target: operation.target,
                fallbackName: operation.item?.name,
                in: before.items
            ) else {
                return failedEntry(operation.id, "删除校验失败：执行前无法定位物品目标。")
            }

            if after.items.contains(where: { $0.id == beforeTarget.id }) {
                return failedEntry(operation.id, "删除校验失败：目标物品仍存在。")
            }
            return successEntry(operation.id, "删除物品目标已达成。")
        } catch {
            return failedEntry(operation.id, "删除校验失败：\(error.localizedDescription)")
        }
    }

    private static func verifyCreateLocation(
        _ operation: AgentOperation,
        before: HousekeeperVerificationSnapshot,
        after: HousekeeperVerificationSnapshot
    ) -> HousekeeperVerificationEntry {
        let nameToken = trimmedNonEmpty(operation.location?.name) ?? trimmedNonEmpty(operation.target?.name)
        let beforeMatches = matchLocations(byName: nameToken, in: before.locations)
        let afterMatches = matchLocations(byName: nameToken, in: after.locations)

        guard afterMatches.count > beforeMatches.count else {
            let label = nameToken ?? "目标空间"
            return failedEntry(operation.id, "新增校验失败：\(label) 在执行后数量未增加。")
        }

        guard let candidate = newestLocation(in: afterMatches) else {
            return failedEntry(operation.id, "新增校验失败：未找到新增后的空间记录。")
        }

        let issues = validateLocationFields(
            operation.location,
            actual: candidate,
            allMembers: after.members,
            allLocations: after.locations
        )
        guard issues.isEmpty else {
            return failedEntry(operation.id, "新增校验失败：\(issues.joined(separator: "；"))")
        }

        return successEntry(operation.id, "新增空间目标已达成。")
    }

    private static func verifyUpdateLocation(
        _ operation: AgentOperation,
        before: HousekeeperVerificationSnapshot,
        after: HousekeeperVerificationSnapshot
    ) -> HousekeeperVerificationEntry {
        let candidate: LabLocation
        do {
            if let beforeTarget = try resolveLocation(
                target: operation.target,
                fallbackName: operation.location?.name,
                in: before.locations
            ),
               let afterByID = after.locations.first(where: { $0.id == beforeTarget.id }) {
                candidate = afterByID
            } else {
                guard let resolved = try resolveLocation(
                    target: operation.target,
                    fallbackName: operation.location?.name,
                    in: after.locations
                ) else {
                    return failedEntry(operation.id, "修改校验失败：执行后未定位到空间。")
                }
                candidate = resolved
            }
        } catch {
            return failedEntry(operation.id, "修改校验失败：\(error.localizedDescription)")
        }

        let issues = validateLocationFields(
            operation.location,
            actual: candidate,
            allMembers: after.members,
            allLocations: after.locations
        )
        guard issues.isEmpty else {
            return failedEntry(operation.id, "修改校验失败：\(issues.joined(separator: "；"))")
        }

        return successEntry(operation.id, "修改空间目标已达成。")
    }

    private static func verifyDeleteLocation(
        _ operation: AgentOperation,
        before: HousekeeperVerificationSnapshot,
        after: HousekeeperVerificationSnapshot
    ) -> HousekeeperVerificationEntry {
        do {
            guard let beforeTarget = try resolveLocation(
                target: operation.target,
                fallbackName: operation.location?.name,
                in: before.locations
            ) else {
                return failedEntry(operation.id, "删除校验失败：执行前无法定位空间目标。")
            }

            if after.locations.contains(where: { $0.id == beforeTarget.id }) {
                return failedEntry(operation.id, "删除校验失败：目标空间仍存在。")
            }
            return successEntry(operation.id, "删除空间目标已达成。")
        } catch {
            return failedEntry(operation.id, "删除校验失败：\(error.localizedDescription)")
        }
    }

    private static func verifyCreateEvent(
        _ operation: AgentOperation,
        before: HousekeeperVerificationSnapshot,
        after: HousekeeperVerificationSnapshot
    ) -> HousekeeperVerificationEntry {
        let titleToken = trimmedNonEmpty(operation.event?.title) ?? trimmedNonEmpty(operation.target?.name)
        let beforeMatches = matchEvents(byTitle: titleToken, in: before.events)
        let afterMatches = matchEvents(byTitle: titleToken, in: after.events)

        guard afterMatches.count > beforeMatches.count else {
            let label = titleToken ?? "目标事项"
            return failedEntry(operation.id, "新增校验失败：\(label) 在执行后数量未增加。")
        }

        guard let candidate = newestEvent(in: afterMatches) else {
            return failedEntry(operation.id, "新增校验失败：未找到新增后的事项记录。")
        }

        let issues = validateEventFields(
            operation.event,
            actual: candidate,
            allMembers: after.members,
            allItems: after.items,
            allLocations: after.locations
        )
        guard issues.isEmpty else {
            return failedEntry(operation.id, "新增校验失败：\(issues.joined(separator: "；"))")
        }

        return successEntry(operation.id, "新增事项目标已达成。")
    }

    private static func verifyUpdateEvent(
        _ operation: AgentOperation,
        before: HousekeeperVerificationSnapshot,
        after: HousekeeperVerificationSnapshot
    ) -> HousekeeperVerificationEntry {
        let candidate: LabEvent
        do {
            if let beforeTarget = try resolveEvent(
                target: operation.target,
                fallbackTitle: operation.event?.title,
                in: before.events
            ),
               let afterByID = after.events.first(where: { $0.id == beforeTarget.id }) {
                candidate = afterByID
            } else {
                guard let resolved = try resolveEvent(
                    target: operation.target,
                    fallbackTitle: operation.event?.title,
                    in: after.events
                ) else {
                    return failedEntry(operation.id, "修改校验失败：执行后未定位到事项。")
                }
                candidate = resolved
            }
        } catch {
            return failedEntry(operation.id, "修改校验失败：\(error.localizedDescription)")
        }

        let issues = validateEventFields(
            operation.event,
            actual: candidate,
            allMembers: after.members,
            allItems: after.items,
            allLocations: after.locations
        )
        guard issues.isEmpty else {
            return failedEntry(operation.id, "修改校验失败：\(issues.joined(separator: "；"))")
        }

        return successEntry(operation.id, "修改事项目标已达成。")
    }

    private static func verifyDeleteEvent(
        _ operation: AgentOperation,
        before: HousekeeperVerificationSnapshot,
        after: HousekeeperVerificationSnapshot
    ) -> HousekeeperVerificationEntry {
        do {
            guard let beforeTarget = try resolveEvent(
                target: operation.target,
                fallbackTitle: operation.event?.title,
                in: before.events
            ) else {
                return failedEntry(operation.id, "删除校验失败：执行前无法定位事项目标。")
            }

            if after.events.contains(where: { $0.id == beforeTarget.id }) {
                return failedEntry(operation.id, "删除校验失败：目标事项仍存在。")
            }
            return successEntry(operation.id, "删除事项目标已达成。")
        } catch {
            return failedEntry(operation.id, "删除校验失败：\(error.localizedDescription)")
        }
    }

    private static func verifyCreateMember(
        _ operation: AgentOperation,
        before: HousekeeperVerificationSnapshot,
        after: HousekeeperVerificationSnapshot
    ) -> HousekeeperVerificationEntry {
        let usernameToken = trimmedNonEmpty(operation.member?.username) ?? trimmedNonEmpty(operation.target?.username)
        let nameToken = trimmedNonEmpty(operation.member?.name) ?? trimmedNonEmpty(operation.target?.name)

        let beforeMatches = matchMembers(username: usernameToken, name: nameToken, in: before.members)
        let afterMatches = matchMembers(username: usernameToken, name: nameToken, in: after.members)

        guard afterMatches.count > beforeMatches.count else {
            let label = usernameToken ?? nameToken ?? "目标成员"
            return failedEntry(operation.id, "新增校验失败：\(label) 在执行后数量未增加。")
        }

        guard let candidate = newestMember(in: afterMatches) else {
            return failedEntry(operation.id, "新增校验失败：未找到新增后的成员记录。")
        }

        let issues = validateMemberFields(operation.member, actual: candidate)
        guard issues.isEmpty else {
            return failedEntry(operation.id, "新增校验失败：\(issues.joined(separator: "；"))")
        }

        return successEntry(operation.id, "新增成员目标已达成。")
    }

    private static func verifyUpdateMember(
        _ operation: AgentOperation,
        before: HousekeeperVerificationSnapshot,
        after: HousekeeperVerificationSnapshot
    ) -> HousekeeperVerificationEntry {
        let candidate: Member
        do {
            if let beforeTarget = try resolveMember(
                target: operation.target,
                fallbackName: operation.member?.name,
                fallbackUsername: operation.member?.username,
                in: before.members
            ),
               let afterByID = after.members.first(where: { $0.id == beforeTarget.id }) {
                candidate = afterByID
            } else {
                guard let resolved = try resolveMember(
                    target: operation.target,
                    fallbackName: operation.member?.name,
                    fallbackUsername: operation.member?.username,
                    in: after.members
                ) else {
                    return failedEntry(operation.id, "修改校验失败：执行后未定位到成员。")
                }
                candidate = resolved
            }
        } catch {
            return failedEntry(operation.id, "修改校验失败：\(error.localizedDescription)")
        }

        let issues = validateMemberFields(operation.member, actual: candidate)
        guard issues.isEmpty else {
            return failedEntry(operation.id, "修改校验失败：\(issues.joined(separator: "；"))")
        }

        return successEntry(operation.id, "修改成员目标已达成。")
    }

    private static func verifyDeleteMember(
        _ operation: AgentOperation,
        before: HousekeeperVerificationSnapshot,
        after: HousekeeperVerificationSnapshot
    ) -> HousekeeperVerificationEntry {
        do {
            guard let beforeTarget = try resolveMember(
                target: operation.target,
                fallbackName: operation.member?.name,
                fallbackUsername: operation.member?.username,
                in: before.members
            ) else {
                return failedEntry(operation.id, "删除校验失败：执行前无法定位成员目标。")
            }

            if after.members.contains(where: { $0.id == beforeTarget.id }) {
                return failedEntry(operation.id, "删除校验失败：目标成员仍存在。")
            }
            return successEntry(operation.id, "删除成员目标已达成。")
        } catch {
            return failedEntry(operation.id, "删除校验失败：\(error.localizedDescription)")
        }
    }

    private static func validateItemFields(
        _ fields: AgentItemFields?,
        actual: LabItem,
        allMembers: [Member],
        allLocations: [LabLocation]
    ) -> [String] {
        guard let fields else { return [] }
        var issues: [String] = []

        if let expected = trimmedNonEmpty(fields.name),
           normalizedToken(actual.name) != normalizedToken(expected) {
            issues.append("name 不匹配")
        }

        if let expected = trimmedNonEmpty(fields.status) {
            guard let parsed = parseItemStatus(expected) else {
                issues.append("status 无法解析")
                return issues
            }
            if actual.status != parsed {
                issues.append("status 未更新为 \(parsed.rawValue)")
            }
        }

        if let expected = trimmedNonEmpty(fields.feature) {
            guard let parsed = parseItemFeature(expected) else {
                issues.append("feature 无法解析")
                return issues
            }
            if actual.feature != parsed {
                issues.append("feature 未更新为 \(parsed.rawValue)")
            }
        }

        if let expectedTokens = fields.responsibleMemberNames {
            do {
                let expectedMembers = try resolveMembers(tokens: expectedTokens, in: allMembers)
                let expectedIDs = Set(expectedMembers.map(\.id))
                let actualIDs = Set(actual.responsibleMembers.map(\.id))
                if expectedIDs != actualIDs {
                    issues.append("responsibleMemberNames 不匹配")
                }
            } catch {
                issues.append("responsibleMemberNames 无法解析")
            }
        }

        if let expectedTokens = fields.locationNames {
            do {
                let expectedLocations = try resolveLocations(tokens: expectedTokens, in: allLocations)
                let expectedIDs = Set(expectedLocations.map(\.id))
                let actualIDs = Set(actual.locations.map(\.id))
                if expectedIDs != actualIDs {
                    issues.append("locationNames 不匹配")
                }
            } catch {
                issues.append("locationNames 无法解析")
            }
        }

        return issues
    }

    private static func validateLocationFields(
        _ fields: AgentLocationFields?,
        actual: LabLocation,
        allMembers: [Member],
        allLocations: [LabLocation]
    ) -> [String] {
        guard let fields else { return [] }
        var issues: [String] = []

        if let expected = trimmedNonEmpty(fields.name),
           normalizedToken(actual.name) != normalizedToken(expected) {
            issues.append("name 不匹配")
        }

        if let expected = trimmedNonEmpty(fields.status) {
            guard let parsed = parseLocationStatus(expected) else {
                issues.append("status 无法解析")
                return issues
            }
            if actual.status != parsed {
                issues.append("status 未更新为 \(parsed.rawValue)")
            }
        }

        if let expectedIsPublic = fields.isPublic,
           actual.isPublic != expectedIsPublic {
            issues.append("isPublic 不匹配")
        }

        if let parentToken = fields.parentName {
            if isExplicitNull(parentToken) {
                if actual.parent != nil {
                    issues.append("parentName 应为空")
                }
            } else {
                do {
                    let parent = try resolveLocationName(
                        parentToken,
                        in: allLocations.filter { $0.id != actual.id }
                    )
                    if actual.parent?.id != parent.id {
                        issues.append("parentName 不匹配")
                    }
                } catch {
                    issues.append("parentName 无法解析")
                }
            }
        }

        if let expectedTokens = fields.responsibleMemberNames {
            do {
                let expectedMembers = try resolveMembers(tokens: expectedTokens, in: allMembers)
                let expectedIDs = Set(expectedMembers.map(\.id))
                let actualIDs = Set(actual.responsibleMembers.map(\.id))
                if expectedIDs != actualIDs {
                    issues.append("responsibleMemberNames 不匹配")
                }
            } catch {
                issues.append("responsibleMemberNames 无法解析")
            }
        }

        return issues
    }

    private static func validateEventFields(
        _ fields: AgentEventFields?,
        actual: LabEvent,
        allMembers: [Member],
        allItems: [LabItem],
        allLocations: [LabLocation]
    ) -> [String] {
        guard let fields else { return [] }
        var issues: [String] = []

        if let expected = trimmedNonEmpty(fields.title),
           normalizedToken(actual.title) != normalizedToken(expected) {
            issues.append("title 不匹配")
        }

        if let expected = trimmedNonEmpty(fields.visibility) {
            guard let parsed = parseVisibility(expected) else {
                issues.append("visibility 无法解析")
                return issues
            }
            if actual.visibility != parsed {
                issues.append("visibility 未更新为 \(parsed.rawValue)")
            }
        }

        if let ownerToken = trimmedNonEmpty(fields.ownerName) {
            do {
                let expectedOwner = try resolveMemberToken(ownerToken, in: allMembers)
                if actual.owner?.id != expectedOwner.id {
                    issues.append("ownerName 不匹配")
                }
            } catch {
                issues.append("ownerName 无法解析")
            }
        }

        if let itemTokens = fields.itemNames {
            do {
                let expectedItems = try resolveItems(tokens: itemTokens, in: allItems)
                let expectedIDs = Set(expectedItems.map(\.id))
                let actualIDs = Set(actual.items.map(\.id))
                if expectedIDs != actualIDs {
                    issues.append("itemNames 不匹配")
                }
            } catch {
                issues.append("itemNames 无法解析")
            }
        }

        if let locationTokens = fields.locationNames {
            do {
                let expectedLocations = try resolveLocations(tokens: locationTokens, in: allLocations)
                let expectedIDs = Set(expectedLocations.map(\.id))
                let actualIDs = Set(actual.locations.map(\.id))
                if expectedIDs != actualIDs {
                    issues.append("locationNames 不匹配")
                }
            } catch {
                issues.append("locationNames 无法解析")
            }
        }

        if let participantTokens = fields.participantNames {
            do {
                let expectedParticipants = try resolveMembers(tokens: participantTokens, in: allMembers)
                let expectedIDs = Set(expectedParticipants.map(\.id))
                let ownerID = actual.owner?.id
                let actualIDs = Set(
                    actual.participantLinks
                        .compactMap(\.member)
                        .filter { $0.id != ownerID }
                        .map(\.id)
                )
                if expectedIDs != actualIDs {
                    issues.append("participantNames 不匹配")
                }
            } catch {
                issues.append("participantNames 无法解析")
            }
        }

        return issues
    }

    private static func validateMemberFields(
        _ fields: AgentMemberFields?,
        actual: Member
    ) -> [String] {
        guard let fields else { return [] }
        var issues: [String] = []

        if let expected = trimmedNonEmpty(fields.name),
           normalizedToken(actual.displayName) != normalizedToken(expected) {
            issues.append("name 不匹配")
        }

        if let expected = trimmedNonEmpty(fields.username),
           normalizedToken(actual.username) != normalizedToken(expected) {
            issues.append("username 不匹配")
        }

        if let expected = fields.contact?.trimmingCharacters(in: .whitespacesAndNewlines),
           actual.contact.trimmingCharacters(in: .whitespacesAndNewlines) != expected {
            issues.append("contact 不匹配")
        }

        return issues
    }

    private static func newestItem(in matches: [LabItem]) -> LabItem? {
        matches.max(by: { $0.lastModified < $1.lastModified })
    }

    private static func newestLocation(in matches: [LabLocation]) -> LabLocation? {
        matches.max(by: { $0.lastModified < $1.lastModified })
    }

    private static func newestEvent(in matches: [LabEvent]) -> LabEvent? {
        matches.max(by: { $0.updatedAt < $1.updatedAt })
    }

    private static func newestMember(in matches: [Member]) -> Member? {
        matches.max(by: { $0.lastModified < $1.lastModified })
    }

    private static func matchItems(byName name: String?, in items: [LabItem]) -> [LabItem] {
        guard let name else { return items }
        let normalized = normalizedToken(name)
        return items.filter { normalizedToken($0.name) == normalized }
    }

    private static func matchLocations(byName name: String?, in locations: [LabLocation]) -> [LabLocation] {
        guard let name else { return locations }
        let normalized = normalizedToken(name)
        return locations.filter { normalizedToken($0.name) == normalized }
    }

    private static func matchEvents(byTitle title: String?, in events: [LabEvent]) -> [LabEvent] {
        guard let title else { return events }
        let normalized = normalizedToken(title)
        return events.filter { normalizedToken($0.title) == normalized }
    }

    private static func matchMembers(username: String?, name: String?, in members: [Member]) -> [Member] {
        if let username {
            let normalized = normalizedToken(username)
            return members.filter { normalizedToken($0.username) == normalized }
        }
        if let name {
            let normalized = normalizedToken(name)
            return members.filter {
                normalizedToken($0.displayName) == normalized || normalizedToken($0.name) == normalized
            }
        }
        return members
    }

    private static func resolveItem(
        target: AgentTarget?,
        fallbackName: String?,
        in items: [LabItem]
    ) throws -> LabItem? {
        if let idToken = trimmedNonEmpty(target?.id),
           let uuid = UUID(uuidString: idToken),
           let matched = items.first(where: { $0.id == uuid }) {
            return matched
        }

        if let nameToken = trimmedNonEmpty(target?.name) ?? trimmedNonEmpty(fallbackName) {
            return try resolveItemName(nameToken, in: items)
        }

        return nil
    }

    private static func resolveLocation(
        target: AgentTarget?,
        fallbackName: String?,
        in locations: [LabLocation]
    ) throws -> LabLocation? {
        if let idToken = trimmedNonEmpty(target?.id),
           let uuid = UUID(uuidString: idToken),
           let matched = locations.first(where: { $0.id == uuid }) {
            return matched
        }

        if let nameToken = trimmedNonEmpty(target?.name) ?? trimmedNonEmpty(fallbackName) {
            return try resolveLocationName(nameToken, in: locations)
        }

        return nil
    }

    private static func resolveEvent(
        target: AgentTarget?,
        fallbackTitle: String?,
        in events: [LabEvent]
    ) throws -> LabEvent? {
        if let idToken = trimmedNonEmpty(target?.id),
           let uuid = UUID(uuidString: idToken),
           let matched = events.first(where: { $0.id == uuid }) {
            return matched
        }

        if let titleToken = trimmedNonEmpty(target?.name) ?? trimmedNonEmpty(fallbackTitle) {
            let normalized = normalizedToken(titleToken)
            let exact = events.filter { normalizedToken($0.title) == normalized }
            if exact.count == 1, let only = exact.first {
                return only
            }
            if exact.count > 1 {
                throw verificationError("事项目标不唯一：\(titleToken)")
            }

            let fuzzy = events.filter { normalizedToken($0.title).contains(normalized) }
            if fuzzy.count == 1, let only = fuzzy.first {
                return only
            }
            if fuzzy.count > 1 {
                throw verificationError("事项目标匹配到多条记录：\(titleToken)")
            }
            throw verificationError("未找到事项：\(titleToken)")
        }

        return nil
    }

    private static func resolveMember(
        target: AgentTarget?,
        fallbackName: String?,
        fallbackUsername: String?,
        in members: [Member]
    ) throws -> Member? {
        if let idToken = trimmedNonEmpty(target?.id),
           let uuid = UUID(uuidString: idToken),
           let matched = members.first(where: { $0.id == uuid }) {
            return matched
        }

        if let usernameToken = trimmedNonEmpty(target?.username) ?? trimmedNonEmpty(fallbackUsername) {
            let matches = members.filter { normalizedToken($0.username) == normalizedToken(usernameToken) }
            if matches.count == 1, let only = matches.first {
                return only
            }
            if matches.count > 1 {
                throw verificationError("成员用户名匹配不唯一：\(usernameToken)")
            }
        }

        if let nameToken = trimmedNonEmpty(target?.name) ?? trimmedNonEmpty(fallbackName) {
            return try resolveMemberToken(nameToken, in: members)
        }

        return nil
    }

    private static func resolveItems(tokens: [String], in items: [LabItem]) throws -> [LabItem] {
        var results: [LabItem] = []
        var seen = Set<UUID>()
        for token in tokens {
            guard let normalized = trimmedNonEmpty(token) else { continue }
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
            guard let normalized = trimmedNonEmpty(token) else { continue }
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
            guard let normalized = trimmedNonEmpty(token) else { continue }
            let matched = try resolveMemberToken(normalized, in: members)
            guard !seen.contains(matched.id) else { continue }
            seen.insert(matched.id)
            results.append(matched)
        }
        return results
    }

    private static func resolveItemName(_ name: String, in items: [LabItem]) throws -> LabItem {
        let normalized = normalizedToken(name)
        let exact = items.filter { normalizedToken($0.name) == normalized }
        if exact.count == 1, let only = exact.first {
            return only
        }
        if exact.count > 1 {
            throw verificationError("物品目标不唯一：\(name)")
        }

        let fuzzy = items.filter { normalizedToken($0.name).contains(normalized) }
        if fuzzy.count == 1, let only = fuzzy.first {
            return only
        }
        if fuzzy.count > 1 {
            throw verificationError("物品目标匹配到多条记录：\(name)")
        }
        throw verificationError("未找到物品：\(name)")
    }

    private static func resolveLocationName(_ name: String, in locations: [LabLocation]) throws -> LabLocation {
        let normalized = normalizedToken(name)
        let exact = locations.filter { normalizedToken($0.name) == normalized }
        if exact.count == 1, let only = exact.first {
            return only
        }
        if exact.count > 1 {
            throw verificationError("空间目标不唯一：\(name)")
        }

        let fuzzy = locations.filter { normalizedToken($0.name).contains(normalized) }
        if fuzzy.count == 1, let only = fuzzy.first {
            return only
        }
        if fuzzy.count > 1 {
            throw verificationError("空间目标匹配到多条记录：\(name)")
        }
        throw verificationError("未找到空间：\(name)")
    }

    private static func resolveMemberToken(_ token: String, in members: [Member]) throws -> Member {
        let normalized = normalizedToken(token)

        let byUsername = members.filter { normalizedToken($0.username) == normalized }
        if byUsername.count == 1, let only = byUsername.first {
            return only
        }
        if byUsername.count > 1 {
            throw verificationError("成员用户名匹配不唯一：\(token)")
        }

        let byDisplayName = members.filter {
            normalizedToken($0.displayName) == normalized || normalizedToken($0.name) == normalized
        }
        if byDisplayName.count == 1, let only = byDisplayName.first {
            return only
        }
        if byDisplayName.count > 1 {
            throw verificationError("成员姓名匹配不唯一：\(token)")
        }

        let fuzzy = members.filter {
            normalizedToken($0.displayName).contains(normalized)
                || normalizedToken($0.username).contains(normalized)
        }
        if fuzzy.count == 1, let only = fuzzy.first {
            return only
        }
        if fuzzy.count > 1 {
            throw verificationError("成员匹配到多条记录：\(token)")
        }

        throw verificationError("未找到成员：\(token)")
    }

    private static func parseItemStatus(_ token: String) -> ItemStockStatus? {
        let normalized = normalizedToken(token)

        if let direct = ItemStockStatus.allCases.first(where: { normalizedToken($0.rawValue) == normalized }) {
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
        let normalized = normalizedToken(token)

        if let direct = ItemFeature.allCases.first(where: { normalizedToken($0.rawValue) == normalized }) {
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
        let normalized = normalizedToken(token)

        if let direct = LocationStatus.allCases.first(where: { normalizedToken($0.rawValue) == normalized }) {
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
        let normalized = normalizedToken(token)

        if let direct = EventVisibility.allCases.first(where: { normalizedToken($0.rawValue) == normalized }) {
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

    private static func isExplicitNull(_ token: String) -> Bool {
        let normalized = normalizedToken(token)
        return ["", "null", "none", "nil", "无", "空", "清空"].contains(normalized)
    }

    private static func trimmedNonEmpty(_ token: String?) -> String? {
        guard let token else { return nil }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedToken(_ token: String) -> String {
        token
            .folding(options: [.diacriticInsensitive, .widthInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .replacingOccurrences(of: #"\s+"#, with: "", options: .regularExpression)
    }

    private static func successEntry(_ operationID: String, _ message: String) -> HousekeeperVerificationEntry {
        HousekeeperVerificationEntry(operationID: operationID, success: true, message: message)
    }

    private static func failedEntry(_ operationID: String, _ message: String) -> HousekeeperVerificationEntry {
        HousekeeperVerificationEntry(operationID: operationID, success: false, message: message)
    }

    private static func verificationError(_ message: String) -> NSError {
        NSError(
            domain: "HousekeeperPostConditionVerifier",
            code: 4301,
            userInfo: [NSLocalizedDescriptionKey: message]
        )
    }
}
