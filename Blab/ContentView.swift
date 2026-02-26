import SwiftUI
import SwiftData
import AppKit

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\Member.name), SortDescriptor(\Member.username)]) private var members: [Member]
    @Query(sort: [SortDescriptor(\LabItem.name)]) private var items: [LabItem]
    @Query(sort: [SortDescriptor(\LabLocation.name)]) private var locations: [LabLocation]

    @AppStorage("blab.currentMemberID") private var currentMemberID: String = ""
    @AppStorage("blab.deepLink.memberID") private var deepLinkMemberID: String = ""
    @AppStorage("blab.deepLink.entity") private var deepLinkEntity: String = ""
    @AppStorage("blab.deepLink.targetID") private var deepLinkTargetID: String = ""
    @AppStorage("blab.deepLink.token") private var deepLinkToken: String = ""

    @State private var selectedSection: SidebarSection? = .dashboard

    private var currentMember: Member? {
        members.first(where: { $0.id.uuidString == currentMemberID }) ?? members.first
    }

    private var memberIDsFingerprint: String {
        members.map { $0.id.uuidString }.joined(separator: "|")
    }

    private var alertFingerprint: String {
        let itemTokens = items.compactMap { item -> String? in
            guard let status = item.status, status.isAlert else { return nil }
            let ownerIDs = item.responsibleMembers.map { $0.id.uuidString }.sorted()
            guard !ownerIDs.isEmpty else { return nil }
            return "i|\(item.id.uuidString)|\(status.rawValue)|\(ownerIDs.joined(separator: ","))"
        }
        .sorted()

        let locationTokens = locations.compactMap { location -> String? in
            guard let status = location.status, status.isAlert else { return nil }
            let ownerIDs = location.responsibleMembers.map { $0.id.uuidString }.sorted()
            guard !ownerIDs.isEmpty else { return nil }
            return "l|\(location.id.uuidString)|\(status.rawValue)|\(ownerIDs.joined(separator: ","))"
        }
        .sorted()

        return (itemTokens + locationTokens).joined(separator: ";")
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
                    if members.isEmpty {
                        Text("暂无成员，请先在成员页创建。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        let selectedMemberID = currentMember?.id.uuidString ?? currentMemberID

                        Menu {
                            ForEach(members) { member in
                                let isCurrent = member.id.uuidString == selectedMemberID
                                Button {
                                    currentMemberID = member.id.uuidString
                                } label: {
                                    if isCurrent {
                                        Label(member.displayName, systemImage: "checkmark")
                                    } else {
                                        Text(member.displayName)
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 10) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(currentMember?.displayName ?? "未选择成员")
                                        .font(.subheadline.weight(.semibold))

                                    if let currentMember, !currentMember.username.isEmpty {
                                        Text("@\(currentMember.username)")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    } else {
                                        Text("点击切换用户")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }

                                Spacer(minLength: 8)

                                Image(systemName: "chevron.up.chevron.down")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(Color.secondary.opacity(0.1))
                            )
                        }
                        .buttonStyle(.plain)
                        .menuStyle(.borderlessButton)
                        .accessibilityLabel("切换活动成员")
                    }
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
                    SettingsSectionView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(.background)
        }
        .task {
            SeedDataService.bootstrapIfNeeded(context: modelContext)
            ensureCurrentMemberSelected()
            refreshAlertNotifications()
        }
        .onChange(of: memberIDsFingerprint) { _, _ in
            ensureCurrentMemberSelected()
        }
        .onChange(of: alertFingerprint) { _, _ in
            refreshAlertNotifications()
        }
        .onReceive(NotificationCenter.default.publisher(for: .blabAlertNotificationTapped)) { notification in
            handleAlertNotificationTap(notification.userInfo)
        }
    }

    private func refreshAlertNotifications() {
        AlertNotificationService.shared.refresh(
            items: items,
            locations: locations
        )
    }

    private func ensureCurrentMemberSelected() {
        guard let firstMember = members.first else {
            currentMemberID = ""
            return
        }

        if members.first(where: { $0.id.uuidString == currentMemberID }) == nil {
            currentMemberID = firstMember.id.uuidString
        }
    }

    private func handleAlertNotificationTap(_ userInfo: [AnyHashable: Any]?) {
        guard let userInfo,
              let route = AlertNotificationRoute(userInfo: userInfo) else {
            return
        }

        currentMemberID = route.memberID.uuidString
        selectedSection = route.entity == .item ? .items : .locations

        deepLinkMemberID = route.memberID.uuidString
        deepLinkEntity = route.entity.rawValue
        deepLinkTargetID = route.targetID.uuidString
        deepLinkToken = UUID().uuidString

        NSApp.activate(ignoringOtherApps: true)
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
