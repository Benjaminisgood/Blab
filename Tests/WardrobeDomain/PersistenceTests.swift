import Foundation
import SwiftData

@main
struct PersistenceTests {
    @MainActor
    static func main() throws {
        let arguments = CommandLine.arguments
        guard arguments.count == 3 else { fatalError("Usage: persistence-tests <legacy|migrate|verify|seed> <store-path>") }
        let phase = arguments[1]
        let url = URL(fileURLWithPath: arguments[2])
        let ownerID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let itemID = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        let legacyModels: [any PersistentModel.Type] = [
            Member.self, MemberFollow.self, LabItem.self, LabLocation.self,
            EventParticipant.self, LabEvent.self, LabAttachment.self,
            LabLog.self, LabMessage.self, AISettings.self
        ]
        let schema = phase == "legacy" ? Schema(legacyModels) : AppPersistence.schema
        let configuration = ModelConfiguration("WardrobeMigration", schema: schema, url: url)
        let container = try ModelContainer(for: schema, configurations: [configuration])
        let context = ModelContext(container)
        context.autosaveEnabled = false
        var checks = 0
        func check(_ condition: @autoclosure () -> Bool, _ message: String) {
            precondition(condition(), message)
            checks += 1
        }

        if phase == "seed" {
            SeedDataService.bootstrapIfNeeded(context: context)
            let members = try context.fetch(FetchDescriptor<Member>())
            let settings = try context.fetch(FetchDescriptor<AISettings>())
            check(members.count == 1 && members[0].name == "我" && members[0].username == "me", "A fresh workspace creates only the local profile")
            check(settings.count == 1 && settings[0].key == "default" && settings[0].apiKey.isEmpty, "A fresh workspace creates default AI settings without credentials")
            let initialCounts = try [
                context.fetchCount(FetchDescriptor<LabItem>()), context.fetchCount(FetchDescriptor<LabEvent>()),
                context.fetchCount(FetchDescriptor<LabLocation>()), context.fetchCount(FetchDescriptor<WardrobeGarment>()),
                context.fetchCount(FetchDescriptor<OutfitRecord>())
            ]
            check(initialCounts.allSatisfy { $0 == 0 }, "Fresh bootstrap does not invent inventory, plans, locations or outfits")

            SeedDataService.bootstrapIfNeeded(context: context)
            let reopened = ModelContext(container)
            let repeatedMembers = try reopened.fetch(FetchDescriptor<Member>())
            let repeatedSettings = try reopened.fetch(FetchDescriptor<AISettings>())
            check(repeatedMembers.count == 1 && repeatedMembers[0].id == members[0].id, "A second bootstrap preserves the same persisted profile")
            check(repeatedSettings.count == 1 && repeatedSettings[0].key == "default", "A second bootstrap preserves a single persisted settings record")
            print("Fresh workspace bootstrap: \(checks) checks passed")
            return
        }

        if phase == "legacy" {
            let owner = Member(id: ownerID, name: "迁移测试", username: "wardrobe-test")
            let item = LabItem(id: itemID, name: "原有衬衫", category: "衣服", notes: "保留原始信息", responsibleMembers: [owner])
            context.insert(owner)
            context.insert(item)
            try context.save()
            print("Legacy store created")
            return
        }

        let members = try context.fetch(FetchDescriptor<Member>())
        let items = try context.fetch(FetchDescriptor<LabItem>())
        check(members.count == 1 && members.first?.id == ownerID, "Legacy member survives additive schema migration")
        check(items.count == 1 && items.first?.id == itemID, "Legacy item survives additive schema migration")
        let owner = members[0], item = items[0]
        check(item.notes == "保留原始信息", "Legacy fields survive")
        check(item.responsibleMembers.map(\.id) == [ownerID], "Legacy ownership relationship survives")

        if phase == "migrate" {
            let garment = WardrobeGarment(name: item.name, ownerID: ownerID, category: .top, linkedItem: item)
            let bottom = WardrobeGarment(name: "长裤", ownerID: ownerID, category: .bottom)
            let shoe = WardrobeGarment(name: "运动鞋", ownerID: ownerID, category: .shoes)
            [garment, bottom, shoe].forEach(context.insert)
            check(garment.isAvailable, "An owned normal inventory garment is available")
            check(garment.canEdit(owner), "Owner may edit the garment")
            check(!garment.canEdit(nil), "Signed-out user cannot edit the garment")
            item.status = .borrowed
            check(!garment.snapshot().isAvailable, "Borrowed inventory is excluded")
            item.status = .discarded
            check(!garment.snapshot().isAvailable, "Discarded inventory is excluded")
            item.status = .normal
            item.responsibleMembers = []
            check(!garment.snapshot().isAvailable, "Inventory without ownership is excluded")
            item.responsibleMembers = [owner]
            garment.laundryState = .laundry
            check(!garment.isAvailable, "Laundry state is reflected in snapshots")
            garment.laundryState = .ready

            let outfitContext = OutfitContext(ownerID: ownerID, temperature: 22, occasion: .everyday)
            let suggestion = OutfitRecommendationService.recommend(garments: [garment, bottom, shoe].map { $0.snapshot() }, context: outfitContext).outfits[0]
            let record = OutfitRecord(suggestion: suggestion, ownerID: ownerID, date: .now, temperature: 22, occasion: .everyday)
            context.insert(record)
            check(record.garments.count == 3, "Record stores all three garment snapshots")
            check(!record.isWorn && !record.wearSnapshot.isWorn, "Saving a suggestion does not count as worn")
            garment.name = "改名后的衬衫"
            garment.color = .red
            check(record.garments.first(where: { $0.id == garment.id })?.name == "原有衬衫", "Saved history retains original garment name")
            check(record.garments.first(where: { $0.id == garment.id })?.color == .blue, "Saved history retains original garment color")
            let wearDate = Date(timeIntervalSince1970: 1_789_200_000)
            record.markWorn(at: wearDate)
            record.markWorn(at: wearDate.addingTimeInterval(100))
            check(record.wornAt == wearDate && record.wearSnapshot.date == wearDate, "Recording wear is idempotent")
            try context.save()
            print("Additive migration and persistence: \(checks) checks passed")
        } else if phase == "verify" {
            let garments = try context.fetch(FetchDescriptor<WardrobeGarment>())
            let records = try context.fetch(FetchDescriptor<OutfitRecord>())
            check(garments.count == 3, "New wardrobe persists across process restart")
            check(records.count == 1, "Saved outfit persists across process restart")
            let record = records[0]
            check(record.garments.count == 3 && record.isWorn, "Snapshot and worn state survive restart")
            let linked = garments.first(where: { $0.linkedItem != nil })!
            check(linked.linkedItem?.id == itemID && linked.isAvailable, "Optional inventory relationship survives restart")
            context.delete(linked)
            try context.save()
            check(record.garments.count == 3, "Deleting a garment preserves saved outfit snapshots")
            check(item.name == "原有衬衫", "Wardrobe profile deletion leaves the inventory item unchanged")
            print("Persistence reopen and deletion: \(checks) checks passed")
        } else {
            fatalError("Unknown phase \(phase)")
        }
    }
}
