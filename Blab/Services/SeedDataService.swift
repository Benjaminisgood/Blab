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
                // A fresh personal workspace starts with a local profile, never invented assets or plans.
                let member = Member(
                    name: "我",
                    username: "me",
                    notesRaw: DomainCodec.serializeProfileMetadata(
                        ProfileMetadata(
                            bio: "我的生活空间",
                            socialLinks: [],
                            locationRelations: [],
                            itemRelations: [],
                            eventRelations: []
                        )
                    )
                )
                context.insert(member)
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
