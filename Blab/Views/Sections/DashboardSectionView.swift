import SwiftUI
import SwiftData

struct DashboardSectionView: View {
    @Query(sort: [SortDescriptor(\LabItem.name)]) private var items: [LabItem]
    @Query(sort: [SortDescriptor(\LabLocation.name)]) private var locations: [LabLocation]
    @Query(sort: [SortDescriptor(\LabEvent.startTime, order: .forward), SortDescriptor(\LabEvent.createdAt, order: .reverse)]) private var events: [LabEvent]
    @Query(sort: [SortDescriptor(\Member.name)]) private var members: [Member]

    let currentMember: Member?
    var onNavigate: (SidebarSection) -> Void = { _ in }

    private var personalSchedule: [LifeScheduleEntry] {
        guard let currentMember else { return [] }
        return accessibleEvents.filter { event in
            event.owner?.id == currentMember.id || event.isParticipant(currentMember)
        }.map { event in
            LifeScheduleEntry(
                id: event.id,
                title: event.title,
                start: event.startTime,
                end: event.endTime,
                location: event.locations.map(\.name).joined(separator: "、")
            )
        }
    }

    private var accessibleEvents: [LabEvent] {
        events.filter { $0.canView(currentMember) }
    }

    private var visibilityCounts: [EventVisibility: Int] {
        var counts: [EventVisibility: Int] = [.public: 0, .internal: 0, .personal: 0]
        for event in accessibleEvents {
            counts[event.visibility, default: 0] += 1
        }
        return counts
    }

    private var itemAlerts: [ItemStockStatus: [LabItem]] {
        var grouped: [ItemStockStatus: [LabItem]] = [:]
        for item in items {
            guard item.canReceiveStatusAlert(currentMember),
                  let status = item.status else {
                continue
            }
            grouped[status, default: []].append(item)
        }
        return grouped
    }

    private var locationAlerts: [LocationStatus: [LabLocation]] {
        var grouped: [LocationStatus: [LabLocation]] = [:]
        for location in locations {
            guard location.canReceiveStatusAlert(currentMember),
                  let status = location.status else {
                continue
            }
            grouped[status, default: []].append(location)
        }
        return grouped
    }

    private var itemAlertTotal: Int {
        itemAlerts.values.reduce(0, { $0 + $1.count })
    }

    private var locationAlertTotal: Int {
        locationAlerts.values.reduce(0, { $0 + $1.count })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                TodayOverviewCard(
                    currentMemberName: currentMember?.displayName,
                    entries: personalSchedule,
                    onNavigate: onNavigate
                )

                Text("资料与提醒")
                    .font(.title3.weight(.semibold))
                    .padding(.top, 8)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 12)], spacing: 12) {
                    SummaryCard(
                        title: "事项",
                        value: "\(accessibleEvents.count)",
                        hint: "公开 \(visibilityCounts[.public, default: 0]) · 内部 \(visibilityCounts[.internal, default: 0])",
                        color: .blue,
                        icon: "calendar"
                    )
                    SummaryCard(
                        title: "物品",
                        value: "\(items.count)",
                        hint: "库存预警 \(itemAlertTotal)",
                        color: .teal,
                        icon: "shippingbox.fill"
                    )
                    SummaryCard(
                        title: "空间",
                        value: "\(locations.count)",
                        hint: "状态预警 \(locationAlertTotal)",
                        color: .orange,
                        icon: "building.2.fill"
                    )
                    SummaryCard(
                        title: "成员",
                        value: "\(members.count)",
                        hint: currentMember == nil ? "请选择当前成员" : "当前视角已启用",
                        color: .indigo,
                        icon: "person.3.fill"
                    )
                }

                DisclosureGroup {
                    DashboardHousekeeperCard(
                        currentMember: currentMember,
                        items: items,
                        locations: locations,
                        events: events,
                        members: members
                    )
                    .padding(.top, 10)
                } label: {
                    Label("智能生活助手", systemImage: "sparkles")
                        .font(.headline)
                }
                .padding(16)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))

                if !itemAlerts.isEmpty {
                    EditorCard(
                        title: "物品预警",
                        subtitle: "需要补货、清理或回收的物品",
                        systemImage: "exclamationmark.triangle.fill"
                    ) {
                        ForEach(ItemStockStatus.allCases.filter { itemAlerts[$0] != nil }, id: \.id) { status in
                            if let entries = itemAlerts[status] {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(alignment: .firstTextBaseline) {
                                        ItemStatusBadge(status: status)
                                        Text(String(format: status.alertMessageTemplate, entries.count))
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }

                                    ForEach(entries.sorted { lhs, rhs in
                                        lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                                    }) { item in
                                        Button {
                                            routeToAlert(
                                                makeItemAlertRoute(for: item)
                                            )
                                        } label: {
                                            DashboardAlertJumpRow(
                                                name: item.name,
                                                actionLabel: status.alertActionLabel
                                            )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                }

                if !locationAlerts.isEmpty {
                    EditorCard(
                        title: "空间预警",
                        subtitle: "需要清理、报修或隔离处理的空间",
                        systemImage: "wrench.and.screwdriver.fill"
                    ) {
                        ForEach(LocationStatus.allCases.filter { locationAlerts[$0] != nil }, id: \.id) { status in
                            if let entries = locationAlerts[status] {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack(alignment: .firstTextBaseline) {
                                        LocationStatusBadge(status: status)
                                        Text(String(format: status.alertMessageTemplate, entries.count))
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                    }

                                    ForEach(entries.sorted { lhs, rhs in
                                        lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                                    }) { location in
                                        Button {
                                            routeToAlert(
                                                makeLocationAlertRoute(for: location)
                                            )
                                        } label: {
                                            DashboardAlertJumpRow(
                                                name: location.name,
                                                actionLabel: status.alertActionLabel
                                            )
                                        }
                                        .buttonStyle(.plain)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .background(
            LinearGradient(
                colors: [Color.accentColor.opacity(0.04), Color.clear],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private func makeItemAlertRoute(for item: LabItem) -> AlertNotificationRoute? {
        guard let member = currentMember,
              item.canReceiveStatusAlert(member),
              let status = item.status else {
            return nil
        }

        let message = "物品「\(item.name)」状态「\(status.rawValue)」，建议\(status.alertActionLabel)。"
        return AlertNotificationRoute(
            memberID: member.id,
            entity: .item,
            targetID: item.id,
            targetName: item.name,
            message: message
        )
    }

    private func makeLocationAlertRoute(for location: LabLocation) -> AlertNotificationRoute? {
        guard let member = currentMember,
              location.canReceiveStatusAlert(member),
              let status = location.status else {
            return nil
        }

        let message = "空间「\(location.name)」状态「\(status.rawValue)」，建议\(status.alertActionLabel)。"
        return AlertNotificationRoute(
            memberID: member.id,
            entity: .location,
            targetID: location.id,
            targetName: location.name,
            message: message
        )
    }

    private func routeToAlert(_ route: AlertNotificationRoute?) {
        guard let route else { return }
        NotificationCenter.default.post(
            name: .blabAlertNotificationTapped,
            object: nil,
            userInfo: route.userInfo
        )
    }
}

private struct SummaryCard: View {
    var title: String
    var value: String
    var hint: String
    var color: Color
    var icon: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(title, systemImage: icon)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            Text(value)
                .font(.title2.bold())
                .foregroundStyle(color)
            Text(hint)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(
            LinearGradient(
                colors: [color.opacity(0.14), Color.secondary.opacity(0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(color.opacity(0.22))
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct DashboardAlertJumpRow: View {
    var name: String
    var actionLabel: String

    var body: some View {
        HStack(spacing: 8) {
            Text(name)
                .font(.subheadline.weight(.medium))
                .lineLimit(1)
            Spacer()
            Text(actionLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
