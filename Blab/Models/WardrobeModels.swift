import Foundation
import SwiftData

/// An optional wardrobe profile supplements an inventory item without changing LabItem.
/// Standalone garments have their own owner and do not require an inventory entry.
@Model
final class WardrobeGarment {
    @Attribute(.unique) var id: UUID
    var name: String
    var ownerID: UUID
    var categoryRaw: String
    var colorRaw: String
    var warmthRaw: String
    var seasonRaw: String
    var occasionRaw: String
    var laundryStateRaw: String
    var photoFilename: String
    var notes: String
    var createdAt: Date
    var updatedAt: Date
    var linkedItemID: UUID?
    var linkedItem: LabItem?

    init(
        id: UUID = UUID(), name: String, ownerID: UUID, category: WardrobeCategory,
        color: WardrobeColor = .blue, warmth: WardrobeWarmth = .medium,
        season: WardrobeSeason = .allSeason, occasion: WardrobeOccasion = .everyday,
        laundryState: WardrobeLaundryState = .ready, photoFilename: String = "",
        notes: String = "", linkedItem: LabItem? = nil
    ) {
        self.id = id
        self.name = name
        self.ownerID = ownerID
        self.categoryRaw = category.rawValue
        self.colorRaw = color.rawValue
        self.warmthRaw = warmth.rawValue
        self.seasonRaw = season.rawValue
        self.occasionRaw = occasion.rawValue
        self.laundryStateRaw = laundryState.rawValue
        self.photoFilename = photoFilename
        self.notes = notes
        self.createdAt = .now
        self.updatedAt = .now
        self.linkedItemID = linkedItem?.id
        self.linkedItem = linkedItem
    }

    var category: WardrobeCategory {
        get { WardrobeCategory(rawValue: categoryRaw) ?? .top }
        set { categoryRaw = newValue.rawValue }
    }
    var color: WardrobeColor {
        get { WardrobeColor(rawValue: colorRaw) ?? .blue }
        set { colorRaw = newValue.rawValue }
    }
    var warmth: WardrobeWarmth {
        get { WardrobeWarmth(rawValue: warmthRaw) ?? .medium }
        set { warmthRaw = newValue.rawValue }
    }
    var season: WardrobeSeason {
        get { WardrobeSeason(rawValue: seasonRaw) ?? .allSeason }
        set { seasonRaw = newValue.rawValue }
    }
    var occasion: WardrobeOccasion {
        get { WardrobeOccasion(rawValue: occasionRaw) ?? .everyday }
        set { occasionRaw = newValue.rawValue }
    }
    var laundryState: WardrobeLaundryState {
        get { WardrobeLaundryState(rawValue: laundryStateRaw) ?? .archived }
        set { laundryStateRaw = newValue.rawValue }
    }
    var temperatureRange: ClosedRange<Double> { warmth.temperatureRange(for: category) }

    var isAvailable: Bool {
        guard laundryState == .ready else { return false }
        guard let linkedItem else { return linkedItemID == nil }
        // Shared/public inventory edit permission is not evidence of personal ownership.
        guard linkedItem.responsibleMembers.contains(where: { $0.id == ownerID }) else { return false }
        return linkedItem.status == .normal || linkedItem.status == .low
    }

    func canEdit(_ member: Member?) -> Bool { member?.id == ownerID }
    func touch() { updatedAt = .now }

    func snapshot() -> WardrobeGarmentSnapshot {
        WardrobeGarmentSnapshot(
            id: id, name: name, ownerID: ownerID, category: category, color: color,
            warmth: warmth, season: season, occasion: occasion, laundryState: laundryState,
            photoFilename: photoFilename, isAvailable: isAvailable
        )
    }
}

/// A saved choice preserves labels, colors and stable garment IDs even after wardrobe edits.
/// Saving a suggestion does not count as wearing it; the user explicitly records that action.
@Model
final class OutfitRecord {
    @Attribute(.unique) var id: UUID
    var ownerID: UUID
    var title: String
    var date: Date
    var temperature: Double
    var occasionRaw: String
    var garmentSnapshotsRaw: String
    var reasonsRaw: String
    var isWorn: Bool
    var wornAt: Date?
    var createdAt: Date

    init(suggestion: OutfitSuggestion, ownerID: UUID, date: Date, temperature: Double, occasion: WardrobeOccasion) {
        self.id = UUID()
        self.ownerID = ownerID
        self.title = suggestion.title
        self.date = date
        self.temperature = temperature
        self.occasionRaw = occasion.rawValue
        let ownedGarments = suggestion.garments.filter { $0.ownerID == ownerID }
        self.garmentSnapshotsRaw = Self.encode(ownedGarments)
        self.reasonsRaw = Self.encode(suggestion.reasons)
        self.isWorn = false
        self.wornAt = nil
        self.createdAt = .now
    }

    var occasion: WardrobeOccasion {
        get { WardrobeOccasion(rawValue: occasionRaw) ?? .everyday }
        set { occasionRaw = newValue.rawValue }
    }
    var garments: [WardrobeGarmentSnapshot] {
        guard let data = garmentSnapshotsRaw.data(using: .utf8),
              let values = try? JSONDecoder().decode([WardrobeGarmentSnapshot].self, from: data) else { return [] }
        return values.filter { $0.ownerID == ownerID }
    }
    var reasons: [String] {
        guard let data = reasonsRaw.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }
    var wearSnapshot: OutfitWearSnapshot {
        OutfitWearSnapshot(ownerID: ownerID, garmentIDs: garments.map(\.id), date: wornAt ?? date, isWorn: isWorn)
    }
    func canEdit(_ member: Member?) -> Bool { member?.id == ownerID }
    func markWorn(at date: Date = .now) {
        guard !isWorn else { return }
        isWorn = true
        wornAt = date
    }

    private static func encode<Value: Encodable>(_ value: Value) -> String {
        guard let data = try? JSONEncoder().encode(value), let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }
}
