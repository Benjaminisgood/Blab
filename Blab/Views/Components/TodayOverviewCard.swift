import SwiftUI

struct TodayOverviewCard: View {
    let currentMemberName: String?
    let entries: [LifeScheduleEntry]
    var onNavigate: (SidebarSection) -> Void = { _ in }

    var body: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let overview = LifeOverview(entries: entries, now: context.date)
            VStack(alignment: .leading, spacing: 20) {
                header(now: context.date)

                if currentMemberName == nil {
                    onboarding
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
                        metric("今日安排", count: overview.today.count, icon: "sun.max", tint: .orange)
                        metric("后续安排", count: overview.upcoming.count, icon: "calendar", tint: .blue)
                        metric("尚未定时", count: overview.unscheduled.count, icon: "clock.badge.questionmark", tint: .secondary)
                    }

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 310), spacing: 16, alignment: .top)], alignment: .leading, spacing: 16) {
                        agenda(overview: overview, now: context.date)
                        VStack(alignment: .leading, spacing: 16) {
                            wardrobe
                            upcoming(overview: overview)
                        }
                    }
                }
            }
        }
    }

    private func header(now: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(now.formatted(.dateTime.year().month(.wide).day().weekday(.wide)))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            Text(currentMemberName.map { "\(greeting(at: now))，\($0)" } ?? "从今天，照顾好自己的生活")
                .font(.largeTitle.bold())
            Text("把今天的安排、身边的物品和每日穿搭放在一起。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    private var onboarding: some View {
        EditorCard(title: "建立你的生活视角", subtitle: "先创建或选择自己的成员资料，即可查看你创建和参与的日程。", systemImage: "person.crop.circle.badge.plus") {
            Button("管理成员资料") { onNavigate(.members) }
                .buttonStyle(.borderedProminent)
            Text("已有成员时，可从侧栏顶部切换当前成员。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("浏览事项") { onNavigate(.events) }
                Button("打开衣橱") { onNavigate(.wardrobe) }
            }
            .buttonStyle(.bordered)
        }
    }

    private func metric(_ title: String, count: Int, icon: String, tint: Color) -> some View {
        Button { onNavigate(.events) } label: {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(tint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(count)")
                        .font(.title2.bold().monospacedDigit())
                        .foregroundStyle(.primary)
                    Text(title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 14))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
        .help("打开事项日程")
    }

    private func agenda(overview: LifeOverview, now: Date) -> some View {
        EditorCard(title: "今天的安排", subtitle: "你创建或参与的事项", systemImage: "calendar.day.timeline.left") {
            if overview.today.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("今天还没有安排")
                        .font(.headline)
                    Text("留一点空白给自己，也可以安排运动、采购或一次见面。")
                        .foregroundStyle(.secondary)
                        .font(.subheadline)
                }
                .padding(.vertical, 12)
            } else {
                ForEach(Array(overview.today.prefix(5))) { entry in
                    agendaRow(entry, now: now)
                    if entry.id != overview.today.prefix(5).last?.id { Divider() }
                }
            }
            Button(overview.today.isEmpty ? "安排一件事" : "查看全部日程") { onNavigate(.events) }
                .buttonStyle(.bordered)
        }
    }

    private func agendaRow(_ entry: LifeScheduleEntry, now: Date) -> some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(entry.isOngoing(at: now) ? Color.accentColor : Color.secondary.opacity(0.3))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.title)
                    .font(.headline)
                    .lineLimit(2)
                Text(timeLabel(for: entry, now: now))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                if !entry.location.isEmpty {
                    Label(entry.location, systemImage: "mappin")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
            if entry.isOngoing(at: now) {
                Text("进行中")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.accentColor)
            } else if entry.isElapsed(at: now) {
                Text("时间已过")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 4)
    }

    private var wardrobe: some View {
        EditorCard(title: "今天，穿什么？", subtitle: "从自己的衣橱出发，按温度和场合搭配。", systemImage: "tshirt") {
            Text("记录衣服的颜色、季节和状态，预览组合，再决定今天的穿搭。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button { onNavigate(.wardrobe) } label: {
                Label("打开衣橱与穿搭", systemImage: "arrow.right")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private func upcoming(overview: LifeOverview) -> some View {
        EditorCard(title: "接下来", systemImage: "arrow.turn.down.right") {
            if let next = overview.upcoming.first, let date = next.scheduledDate {
                Text(next.title)
                    .font(.headline)
                    .lineLimit(2)
                Text(date.formatted(.dateTime.month().day().weekday(.abbreviated).hour().minute()))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("今天之后还没有定时安排。")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if !overview.unscheduled.isEmpty {
                Text("另有 \(overview.unscheduled.count) 件事项尚未设置时间，可以找个合适的日子。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button("整理日程") { onNavigate(.events) }
                .buttonStyle(.bordered)
        }
    }

    private func timeLabel(for entry: LifeScheduleEntry, now: Date) -> String {
        func format(_ date: Date) -> String {
            if Calendar.current.isDate(date, inSameDayAs: now) {
                return date.formatted(date: .omitted, time: .shortened)
            }
            return date.formatted(.dateTime.month().day().hour().minute())
        }
        if let start = entry.start {
            if let end = entry.end { return "\(format(start)) – \(format(end))" }
            return format(start)
        }
        if let end = entry.end { return "截至 \(format(end))" }
        return "尚未定时"
    }

    private func greeting(at date: Date) -> String {
        switch Calendar.current.component(.hour, from: date) {
        case 5..<12: return "早上好"
        case 12..<18: return "下午好"
        default: return "晚上好"
        }
    }
}
