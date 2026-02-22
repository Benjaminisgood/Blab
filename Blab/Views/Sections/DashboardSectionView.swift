import SwiftUI
import SwiftData

struct DashboardSectionView: View {
    @Query(sort: [SortDescriptor(\LabItem.name)]) private var items: [LabItem]
    @Query(sort: [SortDescriptor(\LabLocation.name)]) private var locations: [LabLocation]
    @Query(sort: [SortDescriptor(\LabEvent.startTime, order: .forward), SortDescriptor(\LabEvent.createdAt, order: .reverse)]) private var events: [LabEvent]
    @Query(sort: [SortDescriptor(\Member.name)]) private var members: [Member]

    let currentMember: Member?

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
            guard let status = item.status, status.isAlert else { continue }
            grouped[status, default: []].append(item)
        }
        return grouped
    }

    private var locationAlerts: [LocationStatus: [LabLocation]] {
        var grouped: [LocationStatus: [LabLocation]] = [:]
        for location in locations {
            guard let status = location.status, status.isAlert else { continue }
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
                DashboardHeroCard(currentMemberName: currentMember?.displayName ?? "未选择成员")

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

                DashboardAgentAssistantCard(
                    currentMember: currentMember,
                    items: items,
                    locations: locations,
                    events: events,
                    members: members
                )

                if !itemAlerts.isEmpty {
                    EditorCard(
                        title: "物品预警",
                        subtitle: "需要补货、清理或回收的物品",
                        systemImage: "exclamationmark.triangle.fill"
                    ) {
                        ForEach(ItemStockStatus.allCases.filter { itemAlerts[$0] != nil }, id: \.id) { status in
                            if let entries = itemAlerts[status] {
                                HStack(alignment: .firstTextBaseline) {
                                    ItemStatusBadge(status: status)
                                    Text(String(format: status.alertMessageTemplate, entries.count))
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
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
                                HStack(alignment: .firstTextBaseline) {
                                    LocationStatusBadge(status: status)
                                    Text(String(format: status.alertMessageTemplate, entries.count))
                                        .font(.subheadline)
                                        .foregroundStyle(.secondary)
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
}

private struct DashboardHeroCard: View {
    var currentMemberName: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "waveform.path.ecg.rectangle.fill")
                .font(.title2.weight(.semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 40, height: 40)
                .background(Color.accentColor.opacity(0.14))
                .clipShape(RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 4) {
                Text("Benlab 控制台")
                    .font(.title2.weight(.bold))
                Text("当前成员：\(currentMemberName)")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }

            Spacer()
        }
        .padding(16)
        .background(
            LinearGradient(
                colors: [Color.accentColor.opacity(0.16), Color.secondary.opacity(0.08)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.18))
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
