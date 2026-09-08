import Foundation
import SwiftData

/// A single schema used by the app and storage regression checks.
enum AppPersistence {
    static var isPreview: Bool {
        #if DEBUG
        ProcessInfo.processInfo.environment["BLAB_PREVIEW"] == "1"
        #else
        false
        #endif
    }

    static var preferences: UserDefaults {
        isPreview ? UserDefaults(suiteName: "Blab.Preview")! : .standard
    }

    static var schema: Schema {
        Schema([
            Member.self, MemberFollow.self, LabItem.self, LabLocation.self,
            EventParticipant.self, LabEvent.self, LabAttachment.self,
            LabLog.self, LabMessage.self, AISettings.self,
            WardrobeGarment.self, OutfitRecord.self
        ])
    }
}
