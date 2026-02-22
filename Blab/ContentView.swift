import SwiftUI
import SwiftData

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\Member.name), SortDescriptor(\Member.username)]) private var members: [Member]

    @AppStorage("benlab.currentMemberID") private var currentMemberID: String = ""

    @State private var selectedSection: SidebarSection? = .dashboard

    private var currentMember: Member? {
        members.first(where: { $0.id.uuidString == currentMemberID }) ?? members.first
    }

    var body: some View {
        NavigationSplitView {
            List(SidebarSection.allCases, selection: $selectedSection) { section in
                Label(section.title, systemImage: section.systemImage)
                    .tag(section)
            }
            .navigationTitle("Blab")
            .safeAreaInset(edge: .bottom) {
                VStack(alignment: .leading, spacing: 4) {
                    Divider()
                    HStack(spacing: 8) {
                        Image("BrandLogo")
                            .resizable()
                            .interpolation(.high)
                            .frame(width: 22, height: 22)
                            .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        Text("Blab")
                            .font(.caption.weight(.semibold))
                    }
                    Text(currentMember?.displayName ?? "未选择成员")
                        .font(.subheadline.weight(.semibold))
                    Text(currentMember?.username.isEmpty == false ? "@\(currentMember!.username)" : "")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
            }
        } detail: {
            Group {
                switch selectedSection ?? .dashboard {
                case .dashboard:
                    DashboardSectionView(currentMember: currentMember)
                case .events:
                    EventsSectionView(currentMember: currentMember)
                case .items:
                    ItemsSectionView(currentMember: currentMember)
                case .locations:
                    LocationsSectionView(currentMember: currentMember)
                case .members:
                    MembersSectionView(currentMember: currentMember)
                case .logs:
                    LogsSectionView()
                case .settings:
                    SettingsSectionView(currentMemberID: $currentMemberID)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background)
        }
        .task {
            SeedDataService.bootstrapIfNeeded(context: modelContext)
            if members.first(where: { $0.id.uuidString == currentMemberID }) == nil,
               let firstMember = members.first {
                currentMemberID = firstMember.id.uuidString
            }
        }
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [
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
        ], inMemory: true)
}
