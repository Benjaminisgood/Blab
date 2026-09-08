import Foundation

@main
struct RecommendationTests {
    static func main() {
        let owner = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let other = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let date = Date(timeIntervalSince1970: 1_789_200_000)
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }
        func garment(_ number: Int, _ category: WardrobeCategory) -> WardrobeGarmentSnapshot {
            let id = UUID(uuidString: String(format: "10000000-0000-0000-0000-%012d", number))!
            return WardrobeGarmentSnapshot(id: id, name: "单品 \(number)", ownerID: owner, category: category, color: .white)
        }
        let top = garment(1, .top), bottom = garment(2, .bottom), shoe = garment(3, .shoes)
        let base = [top, bottom, shoe]
        var context = OutfitContext(ownerID: owner, temperature: 22, occasion: .everyday, date: date, season: .autumn)
        func result(_ garments: [WardrobeGarmentSnapshot], history: [OutfitWearSnapshot] = [], limit: Int = 3) -> OutfitRecommendationResult {
            OutfitRecommendationService.recommend(garments: garments, history: history, context: context, limit: limit)
        }

        check(result([]).outfits.isEmpty, "Empty wardrobe cannot generate an outfit")
        check(!result([]).messages.isEmpty, "Empty wardrobe explains how to start")
        check(result(base).outfits.count == 1, "One set yields one complete outfit")
        check(result(base).outfits.allSatisfy(\.isComplete), "Recommendations must be complete")
        check(result([top, bottom]).outfits.isEmpty, "Footwear is required")
        check(result([top, shoe]).outfits.isEmpty, "A top alone is incomplete")
        let onePiece = garment(4, .onePiece)
        check(result([onePiece, shoe]).outfits.first?.isComplete == true, "One-piece plus footwear is complete")
        check(result([onePiece, top, shoe]).outfits.first?.garments.count == 2, "One-piece does not require or duplicate a top")
        check(result(base + base).outfits.count == 1, "Duplicate snapshots do not produce duplicate outfits")
        check(result(base, limit: 0).outfits.isEmpty, "Zero requested outfits is respected")

        for state in [WardrobeLaundryState.laundry, .archived] {
            var excluded = top
            excluded.laundryState = state
            check(result([excluded, bottom, shoe]).outfits.isEmpty, "Non-ready clothes are excluded")
        }
        var unavailable = top
        unavailable.isAvailable = false
        check(result([unavailable, bottom, shoe]).outfits.isEmpty, "Unavailable inventory is excluded")
        var othersTop = top
        othersTop.ownerID = other
        check(result([othersTop, bottom, shoe]).outfits.isEmpty, "Other owners cannot complete this wardrobe")
        var seasonalTop = top
        seasonalTop.season = .summer
        check(result([seasonalTop, bottom, shoe]).outfits.isEmpty, "Wrong season is excluded")
        context.season = .allSeason
        check(!result([seasonalTop, bottom, shoe]).outfits.isEmpty, "Explicit all-season context overrides month")
        context.season = .autumn

        context.occasion = .formal
        check(result(base).outfits.isEmpty, "Everyday items cannot silently become formal wear")
        let formal = base.map { source in var item = source; item.occasion = .formal; return item }
        check(result(formal).outfits.first?.isComplete == true, "Explicit formal outfit is eligible")
        context.occasion = .sport
        check(result(formal).outfits.isEmpty, "Formal clothes cannot silently become sportswear")
        context.occasion = .work
        check(!result(base).outfits.isEmpty, "Everyday basics may be reused for work")
        context.occasion = .everyday

        var warmBase = base.map { source in var item = source; item.warmth = .warm; return item }
        context.temperature = 15
        check(!result(warmBase).outfits.isEmpty, "Warm footwear includes its upper bound")
        context.temperature = 15.1
        check(result(warmBase).outfits.isEmpty, "Warm footwear excludes temperatures above its bound")
        warmBase[2].warmth = .medium
        context.temperature = 18
        check(!result(warmBase).outfits.isEmpty, "Warm clothing includes its upper bound")
        context.temperature = 18.1
        check(result(warmBase).outfits.isEmpty, "Warm clothing excludes temperatures above its bound")
        context.temperature = 0
        check(!result(base).outfits.isEmpty, "Medium clothing includes its lower bound")
        context.temperature = -0.1
        check(result(base).outfits.isEmpty, "Medium clothing excludes temperatures below its bound")
        for temperature in [Double.nan, Double.infinity, -20.1, 45.1] {
            context.temperature = temperature
            check(result(base).outfits.isEmpty, "Invalid temperature has no recommendation")
            check(!result(base).messages.isEmpty, "Invalid temperature explains accepted range")
        }
        context.temperature = 12
        let coat = garment(5, .outerwear)
        check(result(base + [coat]).outfits.first?.garments.contains(where: { $0.category == .outerwear }) == true, "Cool weather adds an eligible coat")
        check(!result(base).messages.isEmpty, "Cool weather without a coat warns visibly")
        context.temperature = 22
        check(result(base + [coat]).outfits.first?.garments.contains(where: { $0.category == .outerwear }) == false, "Mild weather does not force an outer layer")

        let alternateTop = garment(6, .top)
        let options = base + [alternateTop]
        let wear = OutfitWearSnapshot(ownerID: owner, garmentIDs: base.map(\.id), date: date.addingTimeInterval(-3_600), isWorn: true)
        check(result(options, history: [wear]).outfits.first?.garments.contains(where: { $0.id == alternateTop.id }) == true, "Recent wear rotates primary clothing")
        var planned = wear
        planned.isWorn = false
        check(result(options, history: [planned]).outfits.map(\.id) == result(options).outfits.map(\.id), "Saved plans do not count as worn")
        var futureWear = wear
        futureWear.date = date.addingTimeInterval(86_400)
        check(result(options, history: [futureWear]).outfits.map(\.id) == result(options).outfits.map(\.id), "Future wear does not influence today's recommendation")
        var othersWear = wear
        othersWear.ownerID = other
        check(result(options, history: [othersWear]).outfits.map(\.id) == result(options).outfits.map(\.id), "Other owners' history has no influence")
        check(result(options).outfits.map(\.id) == result(options.reversed()).outfits.map(\.id), "Input order does not change recommendation order")
        check(result(options, limit: 1).outfits.count == 1, "Output limit is respected")
        check(result(options).outfits.allSatisfy { Set($0.garments.map(\.id)).count == $0.garments.count }, "Outfits never repeat a garment")

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3_600)!
        let pageOpened = calendar.startOfDay(for: date).addingTimeInterval(8 * 3_600)
        let laterToday = pageOpened.addingTimeInterval(2 * 3_600)
        let sameDayWear = OutfitWearSnapshot(ownerID: owner, garmentIDs: base.map(\.id), date: laterToday.addingTimeInterval(-60), isWorn: true)
        context.date = OutfitContext.referenceDate(for: pageOpened, now: laterToday, calendar: calendar)
        check(context.date == laterToday, "Today's reference refreshes the cached picker time")
        check(result(options, history: [sameDayWear]).outfits.first?.garments.contains(where: { $0.id == alternateTop.id }) == true, "Wear logged after the page opened immediately rotates today's outfit")
        let yesterday = calendar.date(byAdding: .day, value: -1, to: pageOpened)!
        let yesterdayReference = OutfitContext.referenceDate(for: yesterday, now: laterToday, calendar: calendar)
        check(yesterdayReference == calendar.startOfDay(for: laterToday).addingTimeInterval(-1), "A historical date includes its whole day in the selected timezone")
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: pageOpened)!
        let tomorrowReference = OutfitContext.referenceDate(for: tomorrow, now: laterToday, calendar: calendar)
        check(calendar.component(.hour, from: tomorrowReference) == 23 && calendar.component(.second, from: tomorrowReference) == 59, "A future selected day uses its local end of day")
        print("Wardrobe recommendation: \(checks) checks passed")
    }
}
