import SwiftUI
import SwiftData

struct EventsSectionView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\LabEvent.startTime, order: .forward), SortDescriptor(\LabEvent.createdAt, order: .reverse)]) private var events: [LabEvent]
    @Query(sort: [SortDescriptor(\Member.name), SortDescriptor(\Member.username)]) private var members: [Member]
    @Query(sort: [SortDescriptor(\LabItem.name)]) private var items: [LabItem]
    @Query(sort: [SortDescriptor(\LabLocation.name)]) private var locations: [LabLocation]

    let currentMember: Member?

    @State private var searchText = ""
    @State private var presentingCreate = false
    @State private var editingEvent: LabEvent?
    @State private var deletingEvent: LabEvent?

    private var visibilityCounts: [EventVisibility: Int] {
        var counts: [EventVisibility: Int] = [.public: 0, .internal: 0, .personal: 0]
        for event in accessibleEvents {
            counts[event.visibility, default: 0] += 1
        }
        return counts
    }

    private var joinableCount: Int {
        accessibleEvents.filter { $0.canJoin(currentMember) }.count
    }

    private var accessibleEvents: [LabEvent] {
        events.filter { $0.canView(currentMember) }
    }

    private var upcomingEvents: [LabEvent] {
        let now = Date.now
        return filteredEvents.filter { event in
            guard let start = event.startTime else { return true }
            return start >= now
        }
    }

    private var pastEvents: [LabEvent] {
        let now = Date.now
        return filteredEvents.filter { event in
            if let end = event.endTime {
                return end < now
            }
            if let start = event.startTime {
                return start < now
            }
            return false
        }
        .sorted(by: {
            let lhs = $0.endTime ?? $0.startTime ?? $0.updatedAt
            let rhs = $1.endTime ?? $1.startTime ?? $1.updatedAt
            return lhs > rhs
        })
    }

    private var filteredEvents: [LabEvent] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !keyword.isEmpty else { return accessibleEvents }
        return accessibleEvents.filter { event in
            let people = event.participants.map(\.displayName).joined(separator: " ")
            let place = event.locations.map(\.name).joined(separator: " ")
            let itemText = event.items.map(\.name).joined(separator: " ")
            let text = [event.title, event.summaryText, event.visibilityRaw, people, place, itemText, event.owner?.displayName ?? ""]
                .joined(separator: " ")
                .lowercased()
            return text.contains(keyword)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    CollectionHeaderCard(
                        title: "事项日程",
                        subtitle: "按可见性与时间组织事项，支持报名与参与管理。",
                        systemImage: "calendar.badge.clock",
                        stats: [
                            CollectionStat(label: "可见", value: "\(accessibleEvents.count)", tint: .blue),
                            CollectionStat(label: "公开", value: "\(visibilityCounts[.public, default: 0])", tint: .mint),
                            CollectionStat(label: "内部", value: "\(visibilityCounts[.internal, default: 0])", tint: .indigo),
                            CollectionStat(label: "个人", value: "\(visibilityCounts[.personal, default: 0])", tint: .secondary),
                            CollectionStat(label: "可报名", value: "\(joinableCount)", tint: .orange)
                        ]
                    )
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                if filteredEvents.isEmpty {
                    ContentUnavailableView(
                        "暂无可见事项",
                        systemImage: "calendar.badge.exclamationmark",
                        description: Text("创建一个新事项，或切换当前成员查看不同权限视角。")
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else {
                    if !upcomingEvents.isEmpty {
                        Section("进行中 / 即将开始") {
                            ForEach(upcomingEvents) { event in
                                NavigationLink {
                                    EventDetailView(
                                        event: event,
                                        currentMember: currentMember,
                                        members: members,
                                        items: items,
                                        locations: locations,
                                        onDelete: {
                                            deletingEvent = event
                                        }
                                    )
                                } label: {
                                    ListRowSurface {
                                        EventRowView(event: event, currentMember: currentMember)
                                    }
                                }
                                .contextMenu {
                                    if event.canEdit(currentMember) {
                                        Button("编辑") {
                                            editingEvent = event
                                        }
                                    }
                                    if event.owner?.id == currentMember?.id {
                                        Button("删除", role: .destructive) {
                                            deletingEvent = event
                                        }
                                    }
                                }
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
                                .listRowBackground(Color.clear)
                            }
                        }
                    }

                    if !pastEvents.isEmpty {
                        Section("历史事项") {
                            ForEach(pastEvents) { event in
                                NavigationLink {
                                    EventDetailView(
                                        event: event,
                                        currentMember: currentMember,
                                        members: members,
                                        items: items,
                                        locations: locations,
                                        onDelete: {
                                            deletingEvent = event
                                        }
                                    )
                                } label: {
                                    ListRowSurface {
                                        EventRowView(event: event, currentMember: currentMember)
                                    }
                                }
                                .listRowSeparator(.hidden)
                                .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
                                .listRowBackground(Color.clear)
                            }
                        }
                    }
                }
            }
            .navigationTitle("事项日程")
            .searchable(text: $searchText, prompt: "标题 / 地点 / 成员 / 物品")
            .scrollContentBackground(.hidden)
            .background(
                LinearGradient(
                    colors: [Color.accentColor.opacity(0.04), Color.clear],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .listStyle(.inset)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        presentingCreate = true
                    } label: {
                        Label("新建事项", systemImage: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $presentingCreate) {
            EventEditorSheet(event: nil, members: members, items: items, locations: locations, currentMember: currentMember)
        }
        .sheet(item: $editingEvent) { event in
            EventEditorSheet(event: event, members: members, items: items, locations: locations, currentMember: currentMember)
        }
        .alert("确认删除事项", isPresented: Binding(get: {
            deletingEvent != nil
        }, set: { newValue in
            if !newValue {
                deletingEvent = nil
            }
        })) {
            Button("取消", role: .cancel) {
                deletingEvent = nil
            }
            Button("删除", role: .destructive) {
                performDelete()
            }
        } message: {
            Text("删除后会移除事项及附件记录。")
        }
    }

    private func performDelete() {
        guard let event = deletingEvent else { return }
        guard event.owner?.id == currentMember?.id else {
            deletingEvent = nil
            return
        }

        let refs = event.attachmentRefs
        let title = event.title
        modelContext.delete(event)
        modelContext.insert(LabLog(actionType: "删除事项", details: "Deleted event \(title)", user: currentMember))

        do {
            try modelContext.save()
            refs.forEach { AttachmentStore.deleteManagedFile(ref: $0) }
        } catch {
            assertionFailure("Delete event failed: \(error)")
        }

        deletingEvent = nil
    }
}

private struct EventRowView: View {
    let event: LabEvent
    let currentMember: Member?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(event.title)
                    .font(.headline)
                Spacer()
                EventVisibilityBadge(visibility: event.visibility)
            }

            HStack(spacing: 8) {
                if let start = event.startTime {
                    Text(start.formatted(date: .abbreviated, time: .shortened))
                } else {
                    Text("时间待定")
                }
                Text("·")
                Text(event.owner?.displayName ?? "未知负责人")
                Text("·")
                Text("参与 \(event.participantCount()) 人")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if !event.locations.isEmpty {
                Text(event.locations.map(\.name).joined(separator: "、"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if event.canJoin(currentMember) {
                Text("可报名")
                    .font(.caption2)
                    .foregroundStyle(.green)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct EventDetailView: View {
    @Environment(\.modelContext) private var modelContext

    let event: LabEvent
    let currentMember: Member?
    let members: [Member]
    let items: [LabItem]
    let locations: [LabLocation]
    let onDelete: () -> Void

    @State private var showingJoinFailed = false
    @State private var showingEditor = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(event.title)
                        .font(.largeTitle.bold())
                    Spacer()
                    EventVisibilityBadge(visibility: event.visibility)
                }

                HStack(spacing: 10) {
                    if event.canEdit(currentMember) {
                        Button("编辑") {
                            showingEditor = true
                        }
                        .buttonStyle(.borderedProminent)
                    }

                    if event.owner?.id == currentMember?.id {
                        Button("删除", role: .destructive) {
                            onDelete()
                        }
                        .buttonStyle(.bordered)
                    }

                    if event.canJoin(currentMember) {
                        Button("报名参加") {
                            joinEvent()
                        }
                        .buttonStyle(.bordered)
                    } else if event.isParticipant(currentMember), event.owner?.id != currentMember?.id {
                        Button("退出事项", role: .destructive) {
                            withdrawEvent()
                        }
                        .buttonStyle(.bordered)
                    }
                }

                DetailInfoGrid {
                    DetailInfoRow(title: "负责人", value: event.owner?.displayName ?? "未知")
                    DetailInfoRow(title: "时间", value: formattedTimeRange())
                    DetailInfoRow(title: "地点", value: event.locations.isEmpty ? "未指定" : event.locations.map(\.name).joined(separator: "、"))
                    DetailInfoRow(title: "物品", value: event.items.isEmpty ? "未指定" : event.items.map(\.name).joined(separator: "、"))
                    DetailInfoRow(title: "参与成员", value: event.participants.isEmpty ? "无" : event.participants.map(\.displayName).joined(separator: "、"))
                    DetailInfoRow(title: "参与人数", value: "\(event.participantCount())")
                    if !event.detailLink.isEmpty {
                        DetailInfoRow(title: "详情链接", value: event.detailLink)
                    }
                    DetailInfoRow(title: "创建于", value: event.createdAt.formatted(date: .abbreviated, time: .shortened))
                    DetailInfoRow(title: "更新于", value: event.updatedAt.formatted(date: .abbreviated, time: .shortened))
                }

                if !event.summaryText.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("事项内容")
                            .font(.headline)
                        Text(event.summaryText)
                            .textSelection(.enabled)
                    }
                }

                if !event.attachments.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("活动媒体")
                            .font(.headline)
                        ForEach(event.attachments) { attachment in
                            AttachmentRow(attachment: attachment)
                        }
                    }
                }

                FeedbackThreadView(entries: event.feedbackEntries) { text in
                    postFeedback(text)
                }
            }
            .padding(20)
        }
        .alert("操作失败", isPresented: $showingJoinFailed) {
            Button("确定", role: .cancel) {}
        } message: {
            Text("当前成员没有该操作权限。")
        }
        .sheet(isPresented: $showingEditor) {
            EventEditorSheet(
                event: event,
                members: members,
                items: items,
                locations: locations,
                currentMember: currentMember
            )
        }
    }

    private func formattedTimeRange() -> String {
        if let start = event.startTime, let end = event.endTime {
            return "\(start.formatted(date: .abbreviated, time: .shortened)) - \(end.formatted(date: .omitted, time: .shortened))"
        }
        if let start = event.startTime {
            return start.formatted(date: .abbreviated, time: .shortened)
        }
        return "时间待定"
    }

    private func postFeedback(_ content: String) {
        event.appendFeedback(from: currentMember, content: content)
        event.touch()
        modelContext.insert(
            LabLog(
                actionType: "事项留言",
                details: "Posted feedback to \(event.title)",
                user: currentMember,
                event: event
            )
        )
        try? modelContext.save()
    }

    private func joinEvent() {
        guard event.canJoin(currentMember), let currentMember else {
            showingJoinFailed = true
            return
        }

        event.participantLinks.append(
            EventParticipant(roleRaw: EventParticipantRole.participant.rawValue, statusRaw: EventParticipantStatus.confirmed.rawValue, joinedAt: .now, event: event, member: currentMember)
        )
        event.touch()
        modelContext.insert(
            LabLog(
                actionType: "参加事项",
                details: "Joined event \(event.title)",
                user: currentMember,
                event: event
            )
        )
        try? modelContext.save()
    }

    private func withdrawEvent() {
        guard event.isParticipant(currentMember), let currentMember else {
            showingJoinFailed = true
            return
        }
        guard event.owner?.id != currentMember.id else {
            showingJoinFailed = true
            return
        }

        for link in event.participantLinks where link.member?.id == currentMember.id {
            modelContext.delete(link)
        }
        event.touch()
        modelContext.insert(
            LabLog(
                actionType: "退出事项",
                details: "Withdrew from event \(event.title)",
                user: currentMember,
                event: event
            )
        )
        try? modelContext.save()
    }
}

private struct EventEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let event: LabEvent?
    let members: [Member]
    let items: [LabItem]
    let locations: [LabLocation]
    let currentMember: Member?

    @State private var title = ""
    @State private var summaryText = ""
    @State private var visibility: EventVisibility = .personal
    @State private var startTime = Date.now
    @State private var endTime = Date.now
    @State private var hasStartTime = false
    @State private var hasEndTime = false
    @State private var detailLink = ""
    @State private var allowParticipantEdit = false

    @State private var selectedParticipantIDs: Set<UUID> = []
    @State private var selectedItemIDs: Set<UUID> = []
    @State private var selectedLocationIDs: Set<UUID> = []

    @State private var removedAttachmentIDs: Set<UUID> = []
    @State private var importedFileURLs: [URL] = []
    @State private var externalURLsText = ""

    @State private var alertMessage: String?

    var body: some View {
        NavigationStack {
            EditorCanvas(maxWidth: 1000) {
                EditorHeader(
                    title: event == nil ? "创建事项" : "编辑事项",
                    subtitle: "先确定可见性和时间，再绑定地点/物品/成员，最后补充媒体。",
                    systemImage: "calendar.badge.clock"
                )

                EditorCard(
                    title: "基础信息",
                    subtitle: "标题、可见性、时间范围",
                    systemImage: "calendar"
                ) {
                    TextField("事项标题（必填）", text: $title)
                    Picker("可见性", selection: $visibility) {
                        ForEach(EventVisibility.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }
                    Toggle("记录开始时间", isOn: $hasStartTime)
                    if hasStartTime {
                        DatePicker("开始时间", selection: $startTime)
                    }
                    Toggle("记录结束时间", isOn: $hasEndTime)
                    if hasEndTime {
                        DatePicker("结束时间", selection: $endTime)
                    }
                    TextField("详情链接", text: $detailLink)
                }

                EditorCard(
                    title: "事项内容",
                    subtitle: "描述目标、流程和注意事项",
                    systemImage: "text.alignleft"
                ) {
                    TextField("说明", text: $summaryText, axis: .vertical)
                        .lineLimit(4...8)
                }

                EditorCard(
                    title: "活动地点",
                    subtitle: "可多选",
                    systemImage: "mappin.and.ellipse"
                ) {
                    if locations.isEmpty {
                        Text("暂无空间可选。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(locations) { location in
                            Toggle(isOn: Binding(
                                get: { selectedLocationIDs.contains(location.id) },
                                set: { isOn in
                                    if isOn {
                                        selectedLocationIDs.insert(location.id)
                                    } else {
                                        selectedLocationIDs.remove(location.id)
                                    }
                                }
                            )) {
                                HStack {
                                    Text(location.name)
                                    Spacer()
                                    LocationStatusBadge(status: location.status)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }

                EditorCard(
                    title: "所需物品",
                    subtitle: "可多选，用于活动准备",
                    systemImage: "shippingbox.fill"
                ) {
                    if items.isEmpty {
                        Text("暂无物品可选。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(items) { item in
                            Toggle(isOn: Binding(
                                get: { selectedItemIDs.contains(item.id) },
                                set: { isOn in
                                    if isOn {
                                        selectedItemIDs.insert(item.id)
                                    } else {
                                        selectedItemIDs.remove(item.id)
                                    }
                                }
                            )) {
                                HStack {
                                    Text(item.name)
                                    Spacer()
                                    ItemStatusBadge(status: item.status)
                                }
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }

                EditorCard(
                    title: "参与成员",
                    subtitle: "可见性会影响参与配置",
                    systemImage: "person.3.fill"
                ) {
                    if visibility == .personal {
                        Text("个人事项不需要参与成员。")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(members.filter { $0.id != event?.owner?.id && $0.id != currentMember?.id }) { member in
                            Toggle(isOn: Binding(
                                get: { selectedParticipantIDs.contains(member.id) },
                                set: { isOn in
                                    if isOn {
                                        selectedParticipantIDs.insert(member.id)
                                    } else {
                                        selectedParticipantIDs.remove(member.id)
                                    }
                                }
                            )) {
                                Text(member.displayName)
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                    if visibility == .internal {
                        Toggle("允许参与成员共同编辑", isOn: $allowParticipantEdit)
                    }
                }

                EditorCard(
                    title: "媒体附件",
                    subtitle: "支持本地文件与外链",
                    systemImage: "paperclip.circle.fill"
                ) {
                    AttachmentEditorView(
                        existingAttachments: event?.attachments ?? [],
                        removedAttachmentIDs: $removedAttachmentIDs,
                        importedFileURLs: $importedFileURLs,
                        externalURLsText: $externalURLsText
                    )
                }
            }
            .navigationTitle(event == nil ? "新建事项" : "编辑事项")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(event == nil ? "创建" : "保存") {
                        save()
                    }
                }
            }
            .onAppear {
                loadInitialState()
            }
            .alert("无法保存", isPresented: Binding(get: {
                alertMessage != nil
            }, set: { newValue in
                if !newValue {
                    alertMessage = nil
                }
            })) {
                Button("确定", role: .cancel) {}
            } message: {
                Text(alertMessage ?? "")
            }
        }
        .frame(
            minWidth: 860,
            idealWidth: 940,
            maxWidth: 1020,
            minHeight: 480,
            idealHeight: EditorSheetLayout.cappedHeight(ideal: 700),
            maxHeight: EditorSheetLayout.maxHeight
        )
    }

    private func loadInitialState() {
        guard let event else {
            return
        }

        title = event.title
        summaryText = event.summaryText
        visibility = event.visibility
        if let start = event.startTime {
            startTime = start
            hasStartTime = true
        }
        if let end = event.endTime {
            endTime = end
            hasEndTime = true
        }
        detailLink = event.detailLink
        allowParticipantEdit = event.allowParticipantEdit
        selectedParticipantIDs = Set(
            event.participantLinks
                .compactMap { $0.member?.id }
                .filter { $0 != event.owner?.id }
        )
        selectedItemIDs = Set(event.items.map(\.id))
        selectedLocationIDs = Set(event.locations.map(\.id))
    }

    private func save() {
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else {
            alertMessage = "事项标题不能为空。"
            return
        }

        let actualStart = hasStartTime ? startTime : nil
        let actualEnd = hasEndTime ? endTime : nil
        if let actualStart, let actualEnd, actualEnd < actualStart {
            alertMessage = "结束时间不能早于开始时间。"
            return
        }

        let owner = event?.owner ?? currentMember ?? members.first
        guard owner != nil else {
            alertMessage = "请先创建成员后再创建事项。"
            return
        }

        if visibility == .internal && selectedParticipantIDs.isEmpty {
            alertMessage = "内部事项至少需要一名参与成员。"
            return
        }

        let target = event ?? LabEvent(title: normalizedTitle, owner: owner)
        target.title = normalizedTitle
        target.summaryText = summaryText.trimmingCharacters(in: .whitespacesAndNewlines)
        target.visibility = visibility
        target.startTime = actualStart
        target.endTime = actualEnd
        target.detailLink = detailLink.trimmingCharacters(in: .whitespacesAndNewlines)
        target.allowParticipantEdit = visibility == .internal ? allowParticipantEdit : false
        target.owner = owner
        target.items = items.filter { selectedItemIDs.contains($0.id) }
        target.locations = locations.filter { selectedLocationIDs.contains($0.id) }
        target.touch()

        if event == nil {
            target.createdAt = .now
            modelContext.insert(target)
        }

        syncParticipants(for: target)

        var refsToDelete: [String] = []
        if let existing = event {
            for attachment in existing.attachments {
                if removedAttachmentIDs.contains(attachment.id) {
                    refsToDelete.append(attachment.filename)
                    modelContext.delete(attachment)
                }
            }
        }

        do {
            let importedRefs = try AttachmentStore.importFiles(importedFileURLs)
            appendAttachmentRefs(importedRefs, to: target)
        } catch {
            alertMessage = "附件导入失败：\(error.localizedDescription)"
            return
        }

        let externalRefs = DomainCodec.extractExternalURLs(from: externalURLsText)
        appendAttachmentRefs(externalRefs, to: target)

        modelContext.insert(
            LabLog(
                actionType: event == nil ? "新增事项" : "修改事项",
                details: event == nil ? "Created event \(target.title)" : "Updated event \(target.title)",
                user: currentMember,
                event: target
            )
        )

        do {
            try modelContext.save()
            refsToDelete.forEach { AttachmentStore.deleteManagedFile(ref: $0) }
            dismiss()
        } catch {
            alertMessage = "保存失败：\(error.localizedDescription)"
        }
    }

    private func syncParticipants(for event: LabEvent) {
        guard let owner = event.owner else { return }

        var existingByMemberID: [UUID: EventParticipant] = [:]
        for link in event.participantLinks {
            if let memberID = link.member?.id {
                existingByMemberID[memberID] = link
            }
        }

        var desiredIDs = selectedParticipantIDs
        desiredIDs.remove(owner.id)

        if visibility == .personal {
            desiredIDs = []
        }

        for (memberID, link) in existingByMemberID {
            if memberID == owner.id {
                link.role = .owner
                link.status = .confirmed
                continue
            }
            if !desiredIDs.contains(memberID) {
                modelContext.delete(link)
            }
        }

        if visibility != .personal {
            for memberID in desiredIDs {
                guard existingByMemberID[memberID] == nil else { continue }
                guard let member = members.first(where: { $0.id == memberID }) else { continue }
                let link = EventParticipant(
                    roleRaw: EventParticipantRole.participant.rawValue,
                    statusRaw: EventParticipantStatus.confirmed.rawValue,
                    joinedAt: .now,
                    event: event,
                    member: member
                )
                event.participantLinks.append(link)
            }
        }

        event.ensureOwnerParticipation()
    }

    private func appendAttachmentRefs(_ refs: [String], to event: LabEvent) {
        var existing = Set(event.attachments.map(\.filename))
        for ref in refs {
            let value = ref.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            guard !existing.contains(value) else { continue }
            let attachment = LabAttachment(filename: value, event: event)
            event.attachments.append(attachment)
            existing.insert(value)
        }
    }
}
