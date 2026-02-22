import SwiftUI
import SwiftData

@main
struct BlabApp: App {
    private var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Member.self,
            MemberFollow.self,
            LabItem.self,
            LabLocation.self,
            EventParticipant.self,
            LabEvent.self,
            LabAttachment.self,
            LabLog.self,
            LabMessage.self,
            AISettings.self
        ])

        let configuration = ModelConfiguration(
            schema: schema,
            isStoredInMemoryOnly: false,
            allowsSave: true
        )

        do {
            return try ModelContainer(for: schema, configurations: [configuration])
        } catch {
            fatalError("Failed to create SwiftData container: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
        .commands {
            SidebarCommands()
        }
    }
}
