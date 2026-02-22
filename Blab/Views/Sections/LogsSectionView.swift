import SwiftUI
import SwiftData

struct LogsSectionView: View {
    @Query(sort: [SortDescriptor(\LabLog.timestamp, order: .reverse)]) private var logs: [LabLog]

    @State private var searchText = ""

    private struct LogGroup: Identifiable {
        var day: Date
        var entries: [LabLog]
        var id: Date { day }
    }

    private var filteredLogs: [LabLog] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !keyword.isEmpty else { return logs }
        return logs.filter { log in
            let text = [log.actionType, log.details, log.user?.displayName ?? "", log.item?.name ?? "", log.location?.name ?? "", log.event?.title ?? ""]
                .joined(separator: " ")
                .lowercased()
            return text.contains(keyword)
        }
    }

    private var groupedLogs: [LogGroup] {
        let grouped = Dictionary(grouping: filteredLogs) { log in
            Calendar.current.startOfDay(for: log.timestamp)
        }

        return grouped
            .keys
            .sorted(by: >)
            .map { day in
                LogGroup(
                    day: day,
                    entries: (grouped[day] ?? []).sorted(by: { $0.timestamp > $1.timestamp })
                )
            }
    }

    private var todayCount: Int {
        filteredLogs.filter { Calendar.current.isDateInToday($0.timestamp) }.count
    }

    private var actorCount: Int {
        Set(filteredLogs.compactMap { $0.user?.id }).count
    }

    private var topActionStats: [CollectionStat] {
        let grouped = Dictionary(grouping: filteredLogs, by: \.actionType)
        return grouped
            .map { key, value in CollectionStat(label: key, value: "\(value.count)", tint: .blue) }
            .sorted(by: { Int($0.value) ?? 0 > Int($1.value) ?? 0 })
            .prefix(3)
            .map { $0 }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    CollectionHeaderCard(
                        title: "操作日志",
                        subtitle: "按时间追踪系统中的创建、编辑和协作行为。",
                        systemImage: "list.bullet.rectangle.portrait.fill",
                        stats: [
                            CollectionStat(label: "总记录", value: "\(filteredLogs.count)", tint: .blue),
                            CollectionStat(label: "今日", value: "\(todayCount)", tint: .mint),
                            CollectionStat(label: "活跃成员", value: "\(actorCount)", tint: .indigo)
                        ] + topActionStats
                    )
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                if groupedLogs.isEmpty {
                    ContentUnavailableView(
                        "暂无日志",
                        systemImage: "list.bullet.rectangle",
                        description: Text("执行创建、编辑、删除操作后会自动记录到这里。")
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(groupedLogs) { group in
                        Section(group.day.formatted(date: .abbreviated, time: .omitted)) {
                            ForEach(group.entries) { log in
                                LogRowCard(log: log)
                                    .listRowSeparator(.hidden)
                                    .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
                                    .listRowBackground(Color.clear)
                            }
                        }
                    }
                }
            }
            .navigationTitle("操作日志")
            .searchable(text: $searchText, prompt: "操作类型 / 成员 / 资源")
            .scrollContentBackground(.hidden)
            .background(
                LinearGradient(
                    colors: [Color.accentColor.opacity(0.04), Color.clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .listStyle(.inset)
        }
    }
}

private struct LogRowCard: View {
    let log: LabLog

    private var style: (icon: String, tint: Color) {
        let action = log.actionType.lowercased()
        if action.contains("删除") {
            return ("trash.fill", .red)
        }
        if action.contains("新增") || action.contains("创建") {
            return ("plus.circle.fill", .green)
        }
        if action.contains("修改") || action.contains("编辑") {
            return ("pencil.circle.fill", .orange)
        }
        if action.contains("留言") {
            return ("bubble.left.and.bubble.right.fill", .blue)
        }
        return ("clock.badge.checkmark.fill", .indigo)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: style.icon)
                .foregroundStyle(style.tint)
                .font(.headline)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(log.actionType)
                        .font(.headline)
                    Spacer()
                    Text(log.timestamp, format: Date.FormatStyle(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !log.details.isEmpty {
                    Text(log.details)
                        .font(.subheadline)
                }

                HStack(spacing: 8) {
                    if let user = log.user {
                        Text(user.displayName)
                    }
                    if let item = log.item {
                        Text("物品：\(item.name)")
                    }
                    if let location = log.location {
                        Text("空间：\(location.name)")
                    }
                    if let event = log.event {
                        Text("事项：\(event.title)")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color.secondary.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.16))
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.vertical, 2)
    }
}
