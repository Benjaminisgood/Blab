import Foundation

enum WardrobeCategory: String, CaseIterable, Identifiable, Codable, Sendable {
    case top, bottom, onePiece, outerwear, shoes, accessory

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .top: "上装"
        case .bottom: "下装"
        case .onePiece: "连体装"
        case .outerwear: "外套"
        case .shoes: "鞋履"
        case .accessory: "配饰"
        }
    }
    var symbolName: String {
        switch self {
        case .top: "tshirt"
        case .bottom: "figure.stand"
        case .onePiece: "figure.dress.line.vertical.figure"
        case .outerwear: "jacket"
        case .shoes: "shoe"
        case .accessory: "bag"
        }
    }
}

enum WardrobeColor: String, CaseIterable, Identifiable, Codable, Sendable {
    case white, black, gray, beige, brown, blue, green, red, pink, purple, yellow

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .white: "白色"
        case .black: "黑色"
        case .gray: "灰色"
        case .beige: "米色"
        case .brown: "棕色"
        case .blue: "蓝色"
        case .green: "绿色"
        case .red: "红色"
        case .pink: "粉色"
        case .purple: "紫色"
        case .yellow: "黄色"
        }
    }
    var hex: String {
        switch self {
        case .white: "F2EFE8"
        case .black: "292D32"
        case .gray: "969B9E"
        case .beige: "D9C7A4"
        case .brown: "8E654C"
        case .blue: "477698"
        case .green: "617D62"
        case .red: "BA5149"
        case .pink: "D698A7"
        case .purple: "9173A5"
        case .yellow: "D8B45A"
        }
    }
    var isNeutral: Bool { [.white, .black, .gray, .beige, .brown].contains(self) }
}

enum WardrobeWarmth: String, CaseIterable, Identifiable, Codable, Sendable {
    case light, medium, warm

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .light: "轻薄"
        case .medium: "适中"
        case .warm: "保暖"
        }
    }

    /// Broad styling ranges, not a thermal comfort or weather forecast model.
    /// Inner layers tolerate cooler temperatures because an outer layer can be added.
    func temperatureRange(for category: WardrobeCategory) -> ClosedRange<Double> {
        switch (category, self) {
        case (.outerwear, .light): 14...23
        case (.outerwear, .medium): 4...18
        case (.outerwear, .warm): -20...12
        case (.shoes, .light): 8...45
        case (.shoes, .medium): -10...35
        case (.shoes, .warm): -20...15
        case (.accessory, .light): 12...45
        case (.accessory, .medium): -10...30
        case (.accessory, .warm): -20...15
        case (_, .light): 12...45
        case (_, .medium): 0...28
        case (_, .warm): -20...18
        }
    }
}

enum WardrobeSeason: String, CaseIterable, Identifiable, Codable, Sendable {
    case allSeason, spring, summer, autumn, winter

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .allSeason: "四季"
        case .spring: "春季"
        case .summer: "夏季"
        case .autumn: "秋季"
        case .winter: "冬季"
        }
    }

    /// Northern hemisphere default; callers may provide an explicit season in OutfitContext.
    static func current(at date: Date, calendar: Calendar = .current) -> Self {
        switch calendar.component(.month, from: date) {
        case 3...5: .spring
        case 6...8: .summer
        case 9...11: .autumn
        default: .winter
        }
    }
}

enum WardrobeOccasion: String, CaseIterable, Identifiable, Codable, Sendable {
    case everyday, work, sport, formal

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .everyday: "日常"
        case .work: "通勤"
        case .sport: "运动"
        case .formal: "正式"
        }
    }

    func accepts(_ garmentOccasion: Self) -> Bool {
        switch self {
        case .everyday, .work: garmentOccasion == .everyday || garmentOccasion == .work
        case .sport, .formal: garmentOccasion == self
        }
    }
}

enum WardrobeLaundryState: String, CaseIterable, Identifiable, Codable, Sendable {
    case ready, laundry, archived

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .ready: "可穿"
        case .laundry: "待洗"
        case .archived: "收纳归档"
        }
    }
}

/// Value-only boundary between persistence, rendering and recommendation logic.
struct WardrobeGarmentSnapshot: Identifiable, Hashable, Codable, Sendable {
    var id: UUID
    var name: String
    var ownerID: UUID
    var category: WardrobeCategory
    var color: WardrobeColor
    var warmth: WardrobeWarmth
    var season: WardrobeSeason
    var occasion: WardrobeOccasion
    var laundryState: WardrobeLaundryState
    var photoFilename: String
    var isAvailable: Bool

    init(
        id: UUID = UUID(), name: String, ownerID: UUID, category: WardrobeCategory,
        color: WardrobeColor = .blue, warmth: WardrobeWarmth = .medium,
        season: WardrobeSeason = .allSeason, occasion: WardrobeOccasion = .everyday,
        laundryState: WardrobeLaundryState = .ready, photoFilename: String = "",
        isAvailable: Bool = true
    ) {
        self.id = id
        self.name = name
        self.ownerID = ownerID
        self.category = category
        self.color = color
        self.warmth = warmth
        self.season = season
        self.occasion = occasion
        self.laundryState = laundryState
        self.photoFilename = photoFilename
        self.isAvailable = isAvailable
    }
}

struct OutfitContext: Sendable {
    var ownerID: UUID
    var temperature: Double
    var occasion: WardrobeOccasion
    var date: Date
    var season: WardrobeSeason

    init(ownerID: UUID, temperature: Double, occasion: WardrobeOccasion, date: Date = .now, season: WardrobeSeason? = nil) {
        self.ownerID = ownerID
        self.temperature = temperature
        self.occasion = occasion
        self.date = date
        self.season = season ?? .current(at: date)
    }

    /// A date-only picker retains its original time. Use the actual current instant for
    /// today so clothes marked worn after the page opened participate immediately.
    static func referenceDate(for selectedDay: Date, now: Date = .now, calendar: Calendar = .current) -> Date {
        if calendar.isDate(selectedDay, inSameDayAs: now) { return now }
        let start = calendar.startOfDay(for: selectedDay)
        guard let nextDay = calendar.date(byAdding: .day, value: 1, to: start) else { return selectedDay }
        return nextDay.addingTimeInterval(-1)
    }
}

struct OutfitWearSnapshot: Hashable, Codable, Sendable {
    var ownerID: UUID
    var garmentIDs: [UUID]
    var date: Date
    var isWorn: Bool
}

struct OutfitSuggestion: Identifiable, Hashable, Sendable {
    var garments: [WardrobeGarmentSnapshot]
    var reasons: [String]
    var score: Int

    var id: String { garments.map(\.id.uuidString).sorted().joined(separator: ":") }
    var title: String {
        let main = garments.first(where: { $0.category == .onePiece || $0.category == .top })
        return main.map { "\($0.color.displayName)\($0.category == .onePiece ? "连体" : "分体")搭配" } ?? "我的搭配"
    }
    var isComplete: Bool {
        let categories = Set(garments.map(\.category))
        return categories.contains(.shoes)
            && (categories.contains(.onePiece) || (categories.contains(.top) && categories.contains(.bottom)))
    }
}

struct OutfitRecommendationResult: Sendable {
    var outfits: [OutfitSuggestion]
    var messages: [String]
}
