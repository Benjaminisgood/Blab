import Foundation

/// Deterministic, offline styling rules. The UI owns persistence and user confirmation.
enum OutfitRecommendationService {
    static func recommend(
        garments: [WardrobeGarmentSnapshot], history: [OutfitWearSnapshot] = [],
        context: OutfitContext, limit: Int = 3
    ) -> OutfitRecommendationResult {
        guard context.temperature.isFinite, (-20...45).contains(context.temperature) else {
            return OutfitRecommendationResult(outfits: [], messages: ["请输入 −20 至 45°C 的参考气温。"])
        }
        guard limit > 0 else { return OutfitRecommendationResult(outfits: [], messages: []) }

        let owned = garments.filter { $0.ownerID == context.ownerID }
        guard !owned.isEmpty else {
            return OutfitRecommendationResult(outfits: [], messages: ["先添加自己的上装、下装（或连体装）和鞋履，再生成搭配。"])
        }
        let wornHistory = history.filter {
            $0.ownerID == context.ownerID && $0.isWorn && $0.date <= context.date
        }
        var lastWorn: [UUID: Date] = [:]
        var recentWearCount: [UUID: Int] = [:]
        for wear in wornHistory {
            for id in Set(wear.garmentIDs) {
                lastWorn[id] = max(lastWorn[id] ?? .distantPast, wear.date)
                if context.date.timeIntervalSince(wear.date) < 30 * 86_400 {
                    recentWearCount[id, default: 0] += 1
                }
            }
        }

        var seen = Set<UUID>()
        let eligible = owned.filter { garment in
            guard garment.laundryState == .ready, garment.isAvailable,
                  context.occasion.accepts(garment.occasion),
                  garment.season == .allSeason || context.season == .allSeason || garment.season == context.season,
                  garment.warmth.temperatureRange(for: garment.category).contains(context.temperature)
            else { return false }
            return seen.insert(garment.id).inserted
        }

        func garmentScore(_ garment: WardrobeGarmentSnapshot) -> Int {
            var score = garment.occasion == context.occasion ? 12 : 6
            if garment.color.isNeutral { score += 3 }
            if let date = lastWorn[garment.id] {
                let days = context.date.timeIntervalSince(date) / 86_400
                score -= days < 1 ? 26 : days < 3 ? 16 : days < 7 ? 6 : 0
            } else {
                score += 4
            }
            score -= min(16, recentWearCount[garment.id, default: 0] * 2)
            switch garment.warmth {
            case .light: score += context.temperature >= 24 ? 8 : 0
            case .medium: score += (12...23).contains(context.temperature) ? 8 : 0
            case .warm: score += context.temperature < 12 ? 8 : 0
            }
            return score
        }

        func ranked(_ category: WardrobeCategory) -> [WardrobeGarmentSnapshot] {
            // Bound the cross product for large wardrobes while retaining the best individual candidates.
            Array(eligible.filter { $0.category == category }.sorted {
                let left = garmentScore($0)
                let right = garmentScore($1)
                return left == right ? $0.id.uuidString < $1.id.uuidString : left > right
            }.prefix(20))
        }

        let tops = ranked(.top), bottoms = ranked(.bottom), onePieces = ranked(.onePiece)
        let shoes = ranked(.shoes), coats = ranked(.outerwear), accessories = ranked(.accessory)
        var messages: [String] = []
        if shoes.isEmpty { messages.append("缺少符合气温、季节和场景的可穿鞋履。") }
        if onePieces.isEmpty && (tops.isEmpty || bottoms.isEmpty) {
            messages.append("还需要符合条件的上装和下装，或一件连体装。")
        }
        guard shoes.isEmpty == false, !onePieces.isEmpty || (!tops.isEmpty && !bottoms.isEmpty) else {
            messages.append("待洗、归档、借出或不属于你的单品不会参与推荐；也可调整气温或场景后重试。")
            return OutfitRecommendationResult(outfits: [], messages: messages)
        }

        let needsCoat = context.temperature < 18
        if needsCoat && coats.isEmpty {
            messages.append("当前气温偏低，衣橱中没有符合条件的外套；出门前请补充适合的保暖层。")
        }

        func colorScore(_ pieces: [WardrobeGarmentSnapshot]) -> Int {
            let accents = Set(pieces.filter { !$0.color.isNeutral }.map(\.color))
            return accents.count <= 1 ? 14 : accents.count == 2 ? 4 : -10
        }

        func makeSuggestion(_ core: [WardrobeGarmentSnapshot]) -> OutfitSuggestion {
            var pieces = core
            if needsCoat, let coat = coats.max(by: {
                let left = garmentScore($0) + colorScore(core + [$0])
                let right = garmentScore($1) + colorScore(core + [$1])
                return left == right ? $0.id.uuidString > $1.id.uuidString : left < right
            }) { pieces.append(coat) }
            // Accessories remain optional and only appear when they preserve a restrained palette.
            if let accessory = accessories.first(where: { colorScore(pieces + [$0]) >= 14 }) {
                pieces.append(accessory)
            }
            var score = pieces.reduce(0) { $0 + garmentScore($1) } / pieces.count + colorScore(pieces)
            let ids = Set(pieces.map(\.id))
            if wornHistory.contains(where: {
                Set($0.garmentIDs) == ids && context.date.timeIntervalSince($0.date) < 7 * 86_400
            }) { score -= 18 }

            var reasons = ["按约 \(Int(context.temperature.rounded()))°C、\(context.occasion.displayName)场景筛选。"]
            if colorScore(pieces) >= 14 { reasons.append("以中性色或同一主色组合，整体配色更容易协调。") }
            if needsCoat {
                reasons.append(coats.isEmpty ? "气温偏低，建议另外补充保暖外套。" : "气温偏低，已加入适合叠穿的外套。")
            }
            if !wornHistory.isEmpty { reasons.append("参考已穿记录，优先轮换近期较少穿着的单品。") }
            return OutfitSuggestion(garments: pieces, reasons: reasons, score: score)
        }

        var candidates: [OutfitSuggestion] = []
        for onePiece in onePieces {
            for shoe in shoes { candidates.append(makeSuggestion([onePiece, shoe])) }
        }
        for top in tops {
            for bottom in bottoms {
                for shoe in shoes { candidates.append(makeSuggestion([top, bottom, shoe])) }
            }
        }
        candidates.sort { $0.score == $1.score ? $0.id < $1.id : $0.score > $1.score }
        // Diversify primary clothing so the first results are not the same outfit with different shoes.
        var outfits: [OutfitSuggestion] = []
        var primarySets = Set<String>()
        for candidate in candidates {
            let primaryID = candidate.garments.filter { [.top, .bottom, .onePiece].contains($0.category) }
                .map(\.id.uuidString).sorted().joined(separator: ":")
            if primarySets.insert(primaryID).inserted { outfits.append(candidate) }
            if outfits.count >= limit { break }
        }
        if outfits.count < limit {
            let selected = Set(outfits.map(\.id))
            outfits += candidates.filter { !selected.contains($0.id) }.prefix(limit - outfits.count)
        }
        return OutfitRecommendationResult(outfits: outfits, messages: messages)
    }
}
