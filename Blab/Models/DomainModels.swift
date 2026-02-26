import Foundation
import SwiftData

@Model
final class Member {
    @Attribute(.unique) var id: UUID
    var name: String
    @Attribute(.unique) var username: String
    var passwordHash: String
    var contact: String
    var photoRef: String
    var notesRaw: String
    var feedbackLogRaw: String
    var lastModified: Date

    var items: [LabItem]
    var responsibleLocations: [LabLocation]
    var sentMessages: [LabMessage]
    var receivedMessages: [LabMessage]
    var logs: [LabLog]
    var eventParticipations: [EventParticipant]
    var followingLinks: [MemberFollow]
    var followerLinks: [MemberFollow]
    var eventsOwned: [LabEvent]

    init(
        id: UUID = UUID(),
        name: String,
        username: String,
        passwordHash: String = "",
        contact: String = "",
        photoRef: String = "",
        notesRaw: String = "",
        feedbackLogRaw: String = "",
        lastModified: Date = .now,
        items: [LabItem] = [],
        responsibleLocations: [LabLocation] = [],
        sentMessages: [LabMessage] = [],
        receivedMessages: [LabMessage] = [],
        logs: [LabLog] = [],
        eventParticipations: [EventParticipant] = [],
        followingLinks: [MemberFollow] = [],
        followerLinks: [MemberFollow] = [],
        eventsOwned: [LabEvent] = []
    ) {
        self.id = id
        self.name = name
        self.username = username
        self.passwordHash = passwordHash
        self.contact = contact
        self.photoRef = photoRef
        self.notesRaw = notesRaw
        self.feedbackLogRaw = feedbackLogRaw
        self.lastModified = lastModified
        self.items = items
        self.responsibleLocations = responsibleLocations
        self.sentMessages = sentMessages
        self.receivedMessages = receivedMessages
        self.logs = logs
        self.eventParticipations = eventParticipations
        self.followingLinks = followingLinks
        self.followerLinks = followerLinks
        self.eventsOwned = eventsOwned
    }

    var displayName: String {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmedName.isEmpty ? username : trimmedName
    }

    var profileMetadata: ProfileMetadata {
        DomainCodec.parseProfileMetadata(notesRaw)
    }

    func setProfileMetadata(_ metadata: ProfileMetadata) {
        notesRaw = DomainCodec.serializeProfileMetadata(metadata)
        lastModified = .now
    }

    var feedbackEntries: [FeedbackEntry] {
        DomainCodec.parseFeedbackEntries(feedbackLogRaw)
    }

    func appendFeedback(from sender: Member?, content: String) {
        let normalized = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        var entries = DomainCodec.parseFeedbackEntries(feedbackLogRaw)
        entries.append(
            FeedbackEntry(
                timestamp: .now,
                senderID: sender?.id,
                senderName: sender?.displayName,
                content: normalized
            )
        )
        feedbackLogRaw = DomainCodec.serializeFeedbackEntries(entries)
        lastModified = .now
    }

    var followingMembers: [Member] {
        followingLinks
            .compactMap { $0.followed }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    var followerMembers: [Member] {
        followerLinks
            .compactMap { $0.follower }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }
}

@Model
final class MemberFollow {
    @Attribute(.unique) var id: UUID
    var createdAt: Date
    var follower: Member?
    var followed: Member?

    init(
        id: UUID = UUID(),
        createdAt: Date = .now,
        follower: Member? = nil,
        followed: Member? = nil
    ) {
        self.id = id
        self.createdAt = createdAt
        self.follower = follower
        self.followed = followed
    }
}

@Model
final class LabItem {
    @Attribute(.unique) var id: UUID
    var name: String
    var detailRefsRaw: String
    var category: String
    var statusRaw: String
    var featureRaw: String
    var value: Double?
    var quantityDesc: String
    var purchaseDate: Date?
    var notes: String
    var lastModified: Date
    var purchaseLink: String

    var locations: [LabLocation]
    var responsibleMembers: [Member]
    var attachments: [LabAttachment]
    var events: [LabEvent]
    var logs: [LabLog]

    init(
        id: UUID = UUID(),
        name: String,
        detailRefsRaw: String = "",
        category: String = "",
        statusRaw: String = ItemStockStatus.normal.rawValue,
        featureRaw: String = ItemFeature.private.rawValue,
        value: Double? = nil,
        quantityDesc: String = "",
        purchaseDate: Date? = nil,
        notes: String = "",
        lastModified: Date = .now,
        purchaseLink: String = "",
        locations: [LabLocation] = [],
        responsibleMembers: [Member] = [],
        attachments: [LabAttachment] = [],
        events: [LabEvent] = [],
        logs: [LabLog] = []
    ) {
        self.id = id
        self.name = name
        self.detailRefsRaw = detailRefsRaw
        self.category = category
        self.statusRaw = statusRaw
        self.featureRaw = featureRaw
        self.value = value
        self.quantityDesc = quantityDesc
        self.purchaseDate = purchaseDate
        self.notes = notes
        self.lastModified = lastModified
        self.purchaseLink = purchaseLink
        self.locations = locations
        self.responsibleMembers = responsibleMembers
        self.attachments = attachments
        self.events = events
        self.logs = logs
    }

    var status: ItemStockStatus? {
        get { ItemStockStatus(rawValue: statusRaw) }
        set { statusRaw = newValue?.rawValue ?? "" }
    }

    var feature: ItemFeature? {
        get { ItemFeature(rawValue: featureRaw) }
        set { featureRaw = newValue?.rawValue ?? "" }
    }

    var detailRefs: [DetailRef] {
        get { DomainCodec.parseDetailRefs(from: detailRefsRaw) }
        set { detailRefsRaw = DomainCodec.serializeDetailRefs(newValue) }
    }

    var attachmentRefs: [String] {
        attachments.map(\.filename).filter { !$0.isEmpty }
    }

    var primaryResponsible: Member? {
        responsibleMembers.sorted(by: { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }).first
    }

    func isResponsible(_ member: Member?) -> Bool {
        guard let member else { return false }
        return responsibleMembers.contains(where: { $0.id == member.id })
    }

    func canEdit(_ member: Member?) -> Bool {
        if feature == .private {
            return isResponsible(member)
        }
        return true
    }

    func canReceiveStatusAlert(_ member: Member?) -> Bool {
        guard status?.isAlert == true else { return false }
        guard !responsibleMembers.isEmpty else { return false }
        return isResponsible(member)
    }

    func assignResponsibleMembers(_ members: [Member]) {
        var seen = Set<UUID>()
        let unique = members.filter { member in
            guard !seen.contains(member.id) else { return false }
            seen.insert(member.id)
            return true
        }
        responsibleMembers = unique.sorted {
            $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
    }

    func touch() {
        lastModified = .now
    }
}

@Model
final class LabLocation {
    @Attribute(.unique) var id: UUID
    var name: String
    var statusRaw: String
    var latitude: Double?
    var longitude: Double?
    var coordinateSource: String
    var notes: String
    var isPublic: Bool
    var detailRefsRaw: String
    var lastModified: Date
    var detailLink: String

    var parent: LabLocation?
    var children: [LabLocation]

    var responsibleMembers: [Member]
    var items: [LabItem]
    var events: [LabEvent]
    var attachments: [LabAttachment]
    var logs: [LabLog]

    init(
        id: UUID = UUID(),
        name: String,
        statusRaw: String = LocationStatus.normal.rawValue,
        latitude: Double? = nil,
        longitude: Double? = nil,
        coordinateSource: String = "",
        notes: String = "",
        isPublic: Bool = false,
        detailRefsRaw: String = "",
        lastModified: Date = .now,
        detailLink: String = "",
        parent: LabLocation? = nil,
        children: [LabLocation] = [],
        responsibleMembers: [Member] = [],
        items: [LabItem] = [],
        events: [LabEvent] = [],
        attachments: [LabAttachment] = [],
        logs: [LabLog] = []
    ) {
        self.id = id
        self.name = name
        self.statusRaw = statusRaw
        self.latitude = latitude
        self.longitude = longitude
        self.coordinateSource = coordinateSource
        self.notes = notes
        self.isPublic = isPublic
        self.detailRefsRaw = detailRefsRaw
        self.lastModified = lastModified
        self.detailLink = detailLink
        self.parent = parent
        self.children = children
        self.responsibleMembers = responsibleMembers
        self.items = items
        self.events = events
        self.attachments = attachments
        self.logs = logs
    }

    var status: LocationStatus? {
        get { LocationStatus(rawValue: statusRaw) }
        set { statusRaw = newValue?.rawValue ?? "" }
    }

    var detailRefs: [DetailRef] {
        get { DomainCodec.parseDetailRefs(from: detailRefsRaw) }
        set { detailRefsRaw = DomainCodec.serializeDetailRefs(newValue) }
    }

    var usageTags: [LocationUsageTag] {
        DomainCodec.usageTags(from: detailRefs)
    }

    var detailRefsWithoutUsageTags: [DetailRef] {
        DomainCodec.stripUsageTags(from: detailRefs)
    }

    var attachmentRefs: [String] {
        attachments.map(\.filename).filter { !$0.isEmpty }
    }

    func isResponsible(_ member: Member?) -> Bool {
        guard let member else { return false }
        return responsibleMembers.contains(where: { $0.id == member.id })
    }

    func canEdit(_ member: Member?) -> Bool {
        guard !responsibleMembers.isEmpty else { return true }
        return isResponsible(member)
    }

    func canReceiveStatusAlert(_ member: Member?) -> Bool {
        guard status?.isAlert == true else { return false }
        guard !responsibleMembers.isEmpty else { return false }
        return isResponsible(member)
    }

    func setUsageTags(_ tags: [LocationUsageTag]) {
        detailRefs = DomainCodec.mergeUsageTags(tags, into: detailRefs)
    }

    func touch() {
        lastModified = .now
    }
}

@Model
final class EventParticipant {
    @Attribute(.unique) var id: UUID
    var roleRaw: String
    var statusRaw: String
    var joinedAt: Date

    var event: LabEvent?
    var member: Member?

    init(
        id: UUID = UUID(),
        roleRaw: String = EventParticipantRole.participant.rawValue,
        statusRaw: String = EventParticipantStatus.confirmed.rawValue,
        joinedAt: Date = .now,
        event: LabEvent? = nil,
        member: Member? = nil
    ) {
        self.id = id
        self.roleRaw = roleRaw
        self.statusRaw = statusRaw
        self.joinedAt = joinedAt
        self.event = event
        self.member = member
    }

    var role: EventParticipantRole {
        get { EventParticipantRole(rawValue: roleRaw) ?? .participant }
        set { roleRaw = newValue.rawValue }
    }

    var status: EventParticipantStatus {
        get { EventParticipantStatus(rawValue: statusRaw) ?? .confirmed }
        set { statusRaw = newValue.rawValue }
    }
}

@Model
final class LabEvent {
    @Attribute(.unique) var id: UUID
    var title: String
    var summaryText: String
    var visibilityRaw: String
    var startTime: Date?
    var endTime: Date?
    var detailLink: String
    var feedbackLogRaw: String
    var allowParticipantEdit: Bool
    var createdAt: Date
    var updatedAt: Date

    var owner: Member?
    var participantLinks: [EventParticipant]
    var items: [LabItem]
    var locations: [LabLocation]
    var attachments: [LabAttachment]
    var logs: [LabLog]

    init(
        id: UUID = UUID(),
        title: String,
        summaryText: String = "",
        visibilityRaw: String = EventVisibility.personal.rawValue,
        startTime: Date? = nil,
        endTime: Date? = nil,
        detailLink: String = "",
        feedbackLogRaw: String = "",
        allowParticipantEdit: Bool = false,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        owner: Member? = nil,
        participantLinks: [EventParticipant] = [],
        items: [LabItem] = [],
        locations: [LabLocation] = [],
        attachments: [LabAttachment] = [],
        logs: [LabLog] = []
    ) {
        self.id = id
        self.title = title
        self.summaryText = summaryText
        self.visibilityRaw = visibilityRaw
        self.startTime = startTime
        self.endTime = endTime
        self.detailLink = detailLink
        self.feedbackLogRaw = feedbackLogRaw
        self.allowParticipantEdit = allowParticipantEdit
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.owner = owner
        self.participantLinks = participantLinks
        self.items = items
        self.locations = locations
        self.attachments = attachments
        self.logs = logs
    }

    var visibility: EventVisibility {
        get { EventVisibility(rawValue: visibilityRaw) ?? .personal }
        set { visibilityRaw = newValue.rawValue }
    }

    var feedbackEntries: [FeedbackEntry] {
        DomainCodec.parseFeedbackEntries(feedbackLogRaw)
    }

    var attachmentRefs: [String] {
        attachments.map(\.filename).filter { !$0.isEmpty }
    }

    var participants: [Member] {
        participantLinks
            .compactMap(\.member)
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    func canView(_ member: Member?) -> Bool {
        if visibility == .public {
            return true
        }
        guard let member else { return false }
        if member.id == owner?.id {
            return true
        }
        return participantLinks.contains(where: { $0.member?.id == member.id })
    }

    func canEdit(_ member: Member?) -> Bool {
        guard let member else { return false }
        if member.id == owner?.id {
            return true
        }
        if visibility == .internal && allowParticipantEdit {
            return participantLinks.contains(where: { $0.member?.id == member.id })
        }
        return false
    }

    func canJoin(_ member: Member?) -> Bool {
        guard let member else { return false }
        guard visibility == .public else { return false }
        if member.id == owner?.id {
            return false
        }
        return !participantLinks.contains(where: { $0.member?.id == member.id })
    }

    func isParticipant(_ member: Member?) -> Bool {
        guard let member else { return false }
        return participantLinks.contains(where: { $0.member?.id == member.id })
    }

    func participantCount() -> Int {
        participantLinks.count
    }

    func ensureOwnerParticipation() {
        guard let owner else { return }
        if let ownerLink = participantLinks.first(where: { $0.member?.id == owner.id }) {
            ownerLink.role = .owner
            ownerLink.status = .confirmed
            return
        }

        let link = EventParticipant(
            roleRaw: EventParticipantRole.owner.rawValue,
            statusRaw: EventParticipantStatus.confirmed.rawValue,
            joinedAt: .now,
            event: self,
            member: owner
        )
        participantLinks.append(link)
    }

    func appendFeedback(from sender: Member?, content: String) {
        let normalized = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }

        var entries = DomainCodec.parseFeedbackEntries(feedbackLogRaw)
        entries.append(
            FeedbackEntry(
                timestamp: .now,
                senderID: sender?.id,
                senderName: sender?.displayName,
                content: normalized
            )
        )
        feedbackLogRaw = DomainCodec.serializeFeedbackEntries(entries)
        touch()
    }

    func touch() {
        updatedAt = .now
    }
}

@Model
final class LabAttachment {
    @Attribute(.unique) var id: UUID
    var filename: String
    var createdAt: Date

    var item: LabItem?
    var location: LabLocation?
    var event: LabEvent?

    init(
        id: UUID = UUID(),
        filename: String,
        createdAt: Date = .now,
        item: LabItem? = nil,
        location: LabLocation? = nil,
        event: LabEvent? = nil
    ) {
        self.id = id
        self.filename = filename
        self.createdAt = createdAt
        self.item = item
        self.location = location
        self.event = event
    }

    var ownerKind: String {
        if item != nil { return "item" }
        if location != nil { return "location" }
        if event != nil { return "event" }
        return "unknown"
    }
}

@Model
final class LabLog {
    @Attribute(.unique) var id: UUID
    var timestamp: Date
    var actionType: String
    var details: String

    var user: Member?
    var item: LabItem?
    var location: LabLocation?
    var event: LabEvent?

    init(
        id: UUID = UUID(),
        timestamp: Date = .now,
        actionType: String,
        details: String = "",
        user: Member? = nil,
        item: LabItem? = nil,
        location: LabLocation? = nil,
        event: LabEvent? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.actionType = actionType
        self.details = details
        self.user = user
        self.item = item
        self.location = location
        self.event = event
    }
}

@Model
final class LabMessage {
    @Attribute(.unique) var id: UUID
    var content: String
    var timestamp: Date

    var sender: Member?
    var receiver: Member?

    init(
        id: UUID = UUID(),
        content: String,
        timestamp: Date = .now,
        sender: Member? = nil,
        receiver: Member? = nil
    ) {
        self.id = id
        self.content = content
        self.timestamp = timestamp
        self.sender = sender
        self.receiver = receiver
    }
}

@Model
final class AISettings {
    @Attribute(.unique) var key: String
    var providerRaw: String
    var model: String
    var baseURL: String
    var apiKey: String
    var timeoutSeconds: Int
    var autoFillEnabled: Bool
    var preferredImageLimit: Int
    var updatedAt: Date

    init(
        key: String = "default",
        providerRaw: String = AIAutofillProvider.chatanywhere.rawValue,
        model: String = AIAutofillProvider.chatanywhere.defaultModel,
        baseURL: String = AIAutofillProvider.chatanywhere.defaultBaseURL,
        apiKey: String = "",
        timeoutSeconds: Int = 45,
        autoFillEnabled: Bool = true,
        preferredImageLimit: Int = 6,
        updatedAt: Date = .now
    ) {
        self.key = key
        self.providerRaw = providerRaw
        self.model = model
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.timeoutSeconds = timeoutSeconds
        self.autoFillEnabled = autoFillEnabled
        self.preferredImageLimit = preferredImageLimit
        self.updatedAt = updatedAt
    }

    var provider: AIAutofillProvider {
        get { AIAutofillProvider(rawValue: providerRaw) ?? .chatanywhere }
        set {
            providerRaw = newValue.rawValue
            if model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                model = newValue.defaultModel
            }
            if baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                baseURL = newValue.defaultBaseURL
            }
        }
    }

    func touch() {
        updatedAt = .now
    }
}

struct EventSummaryBundle {
    var ongoing: [LabEvent]
    var upcoming: [LabEvent]
    var unscheduled: [LabEvent]
    var recentPast: [LabEvent]
    var pastTotal: Int

    var total: Int {
        ongoing.count + upcoming.count + unscheduled.count + pastTotal
    }

    var participantCount: Int {
        ongoing.reduce(0, { $0 + $1.participantCount() })
        + upcoming.reduce(0, { $0 + $1.participantCount() })
        + unscheduled.reduce(0, { $0 + $1.participantCount() })
        + recentPast.reduce(0, { $0 + $1.participantCount() })
    }

    static func build(from events: [LabEvent], now: Date = .now, recentPastLimit: Int = 5) -> EventSummaryBundle {
        var ongoing: [LabEvent] = []
        var upcoming: [LabEvent] = []
        var unscheduled: [LabEvent] = []
        var past: [LabEvent] = []

        for event in events {
            let start = event.startTime
            let end = event.endTime
            if let start, let end {
                if end < now {
                    past.append(event)
                } else if start > now {
                    upcoming.append(event)
                } else {
                    ongoing.append(event)
                }
            } else if let start {
                if start >= now {
                    upcoming.append(event)
                } else {
                    past.append(event)
                }
            } else {
                unscheduled.append(event)
            }
        }

        func sortKey(_ event: LabEvent) -> Date {
            if let start = event.startTime {
                return start
            }
            if let end = event.endTime {
                return end
            }
            return event.createdAt
        }

        ongoing.sort { sortKey($0) < sortKey($1) }
        upcoming.sort { sortKey($0) < sortKey($1) }
        unscheduled.sort { $0.updatedAt > $1.updatedAt }
        past.sort {
            let lhs = $0.endTime ?? $0.startTime ?? $0.updatedAt
            let rhs = $1.endTime ?? $1.startTime ?? $1.updatedAt
            return lhs > rhs
        }

        return EventSummaryBundle(
            ongoing: ongoing,
            upcoming: upcoming,
            unscheduled: unscheduled,
            recentPast: Array(past.prefix(recentPastLimit)),
            pastTotal: past.count
        )
    }
}
