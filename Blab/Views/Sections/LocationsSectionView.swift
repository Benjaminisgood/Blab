import SwiftUI
import SwiftData

struct LocationsSectionView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\LabLocation.name)]) private var locations: [LabLocation]
    @Query(sort: [SortDescriptor(\Member.name), SortDescriptor(\Member.username)]) private var members: [Member]

    let currentMember: Member?

    @State private var searchText = ""
    @State private var presentingCreate = false
    @State private var editingLocation: LabLocation?
    @State private var deletingLocation: LabLocation?

    private var publicCount: Int {
        locations.filter(\.isPublic).count
    }

    private var privateCount: Int {
        max(0, locations.count - publicCount)
    }

    private var alertCount: Int {
        locations.filter { $0.status?.isAlert == true }.count
    }

    private var withCoordinatesCount: Int {
        locations.filter { $0.latitude != nil && $0.longitude != nil }.count
    }

    private var filteredLocations: [LabLocation] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !keyword.isEmpty else { return locations }
        return locations.filter { location in
            let usage = location.usageTags.map(\.displayName).joined(separator: " ")
            let people = location.responsibleMembers.map(\.displayName).joined(separator: " ")
            let refs = location.detailRefs.map(\.value).joined(separator: " ")
            let text = [location.name, location.statusRaw, usage, people, location.notes, refs]
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
                        title: "空间管理",
                        subtitle: "统一维护空间状态、层级关系和用途标签。",
                        systemImage: "building.2.fill",
                        stats: [
                            CollectionStat(label: "总数", value: "\(locations.count)", tint: .blue),
                            CollectionStat(label: "公共", value: "\(publicCount)", tint: .mint),
                            CollectionStat(label: "私人", value: "\(privateCount)", tint: .indigo),
                            CollectionStat(label: "异常", value: "\(alertCount)", tint: .orange),
                            CollectionStat(label: "含坐标", value: "\(withCoordinatesCount)", tint: .teal)
                        ]
                    )
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                if filteredLocations.isEmpty {
                    ContentUnavailableView(
                        "没有匹配空间",
                        systemImage: "building",
                        description: Text(searchText.isEmpty ? "点击右上角新增空间。" : "尝试更换关键词。")
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else {
                    Section(searchText.isEmpty ? "全部空间" : "搜索结果（\(filteredLocations.count)）") {
                        ForEach(filteredLocations) { location in
                            NavigationLink {
                                LocationDetailView(
                                    location: location,
                                    currentMember: currentMember,
                                    allLocations: locations,
                                    members: members
                                )
                            } label: {
                                ListRowSurface {
                                    LocationRowView(location: location)
                                }
                            }
                            .contextMenu {
                                Button("编辑") {
                                    editingLocation = location
                                }
                                Button("删除", role: .destructive) {
                                    deletingLocation = location
                                }
                            }
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
                            .listRowBackground(Color.clear)
                        }
                    }
                }
            }
            .navigationTitle("社区空间")
            .searchable(text: $searchText, prompt: "名称 / 用途 / 负责人 / 状态")
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
                        Label("新增空间", systemImage: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $presentingCreate) {
            LocationEditorSheet(location: nil, allLocations: locations, members: members, currentMember: currentMember)
        }
        .sheet(item: $editingLocation) { location in
            LocationEditorSheet(location: location, allLocations: locations, members: members, currentMember: currentMember)
        }
        .alert("确认删除空间", isPresented: Binding(get: {
            deletingLocation != nil
        }, set: { newValue in
            if !newValue {
                deletingLocation = nil
            }
        })) {
            Button("取消", role: .cancel) {
                deletingLocation = nil
            }
            Button("删除", role: .destructive) {
                performDelete()
            }
        } message: {
            Text("删除后会断开关联并移除空间附件记录。")
        }
    }

    private func performDelete() {
        guard let location = deletingLocation else { return }

        if !location.responsibleMembers.isEmpty,
           let currentMember,
           !location.responsibleMembers.contains(where: { $0.id == currentMember.id }) {
            deletingLocation = nil
            return
        }

        let refs = location.attachmentRefs
        let name = location.name
        modelContext.delete(location)
        modelContext.insert(
            LabLog(
                actionType: "删除位置",
                details: "Deleted location \(name)",
                user: currentMember
            )
        )

        do {
            try modelContext.save()
            refs.forEach { AttachmentStore.deleteManagedFile(ref: $0) }
        } catch {
            assertionFailure("Delete location failed: \(error)")
        }

        deletingLocation = nil
    }
}

private struct LocationRowView: View {
    let location: LabLocation

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(location.name)
                    .font(.headline)
                LocationStatusBadge(status: location.status)
                Text(location.isPublic ? "公共" : "私人")
                    .font(.caption)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background((location.isPublic ? Color.mint : Color.indigo).opacity(0.16))
                    .foregroundStyle(location.isPublic ? Color.mint : Color.indigo)
                    .clipShape(Capsule())
            }
            HStack(spacing: 8) {
                if let parent = location.parent {
                    Text("上级：\(parent.name)")
                    Text("·")
                }
                Text(location.responsibleMembers.isEmpty ? "无负责人" : location.responsibleMembers.map(\.displayName).joined(separator: "、"))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct LocationDetailView: View {
    let location: LabLocation
    let currentMember: Member?
    let allLocations: [LabLocation]
    let members: [Member]

    @State private var showingEditor = false

    private var bundle: EventSummaryBundle {
        EventSummaryBundle.build(from: location.events)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(location.name)
                        .font(.largeTitle.bold())
                    Spacer()
                    Button("编辑") {
                        showingEditor = true
                    }
                    .buttonStyle(.borderedProminent)
                }

                HStack(spacing: 8) {
                    LocationStatusBadge(status: location.status)
                    Text(location.isPublic ? "公共空间" : "私人空间")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background((location.isPublic ? Color.mint : Color.indigo).opacity(0.16))
                        .foregroundStyle(location.isPublic ? Color.mint : Color.indigo)
                        .clipShape(Capsule())
                }

                DetailInfoGrid {
                    DetailInfoRow(title: "负责人", value: location.responsibleMembers.isEmpty ? "无" : location.responsibleMembers.map(\.displayName).joined(separator: "、"))
                    DetailInfoRow(title: "上级空间", value: location.parent?.name ?? "顶层")
                    DetailInfoRow(title: "用途", value: location.usageTags.isEmpty ? "未指定" : location.usageTags.map(\.displayName).joined(separator: "、"))
                    DetailInfoRow(title: "关联物品", value: "\(location.items.count)")
                    DetailInfoRow(title: "关联事项", value: "\(bundle.total)（进行中 \(bundle.ongoing.count) / 即将 \(bundle.upcoming.count)）")
                    if let lat = location.latitude, let lng = location.longitude {
                        DetailInfoRow(title: "坐标", value: String(format: "%.6f, %.6f", lat, lng))
                    }
                    if !location.detailLink.isEmpty {
                        DetailInfoRow(title: "详情链接", value: location.detailLink)
                    }
                    DetailInfoRow(title: "更新时间", value: location.lastModified.formatted(date: .abbreviated, time: .shortened))
                }

                if !location.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("备注")
                            .font(.headline)
                        Text(location.notes)
                            .textSelection(.enabled)
                    }
                }

                if !location.detailRefsWithoutUsageTags.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("参考信息")
                            .font(.headline)
                        ForEach(location.detailRefsWithoutUsageTags) { ref in
                            VStack(alignment: .leading, spacing: 2) {
                                if !ref.label.isEmpty {
                                    Text(ref.label)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text(ref.value)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }

                if !location.items.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("空间内物品")
                            .font(.headline)
                        ForEach(location.items.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending })) { item in
                            HStack {
                                Text(item.name)
                                Spacer()
                                ItemStatusBadge(status: item.status)
                            }
                        }
                    }
                }

                if !location.attachments.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("附件")
                            .font(.headline)
                        ForEach(location.attachments) { attachment in
                            AttachmentRow(attachment: attachment)
                        }
                    }
                }
            }
            .padding(20)
        }
        .sheet(isPresented: $showingEditor) {
            LocationEditorSheet(
                location: location,
                allLocations: allLocations,
                members: members,
                currentMember: currentMember
            )
        }
    }
}

private struct LocationEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let location: LabLocation?
    let allLocations: [LabLocation]
    let members: [Member]
    let currentMember: Member?

    @State private var name = ""
    @State private var status: LocationStatus = .normal
    @State private var isPublic = false
    @State private var selectedUsageTags: Set<LocationUsageTag> = []
    @State private var selectedMemberIDs: Set<UUID> = []
    @State private var parentID: UUID?
    @State private var detailLink = ""
    @State private var notes = ""
    @State private var detailRefs: [DetailRef] = []
    @State private var latitudeText = ""
    @State private var longitudeText = ""
    @State private var coordinateSource = ""

    @State private var removedAttachmentIDs: Set<UUID> = []
    @State private var importedFileURLs: [URL] = []
    @State private var externalURLsText = ""

    @State private var alertMessage: String?

    var body: some View {
        NavigationStack {
            EditorCanvas(maxWidth: 980) {
                EditorHeader(
                    title: location == nil ? "创建空间" : "编辑空间",
                    subtitle: "先定义空间属性，再配置用途标签与负责人，最后补充附件与参考信息。",
                    systemImage: "building.2.fill"
                )

                EditorCard(
                    title: "基础信息",
                    subtitle: "名称、状态、层级和公开范围",
                    systemImage: "square.grid.2x2.fill"
                ) {
                    TextField("空间名称（必填）", text: $name)
                    Picker("状态", selection: $status) {
                        ForEach(LocationStatus.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }
                    Toggle("公共空间", isOn: $isPublic)

                    Picker("上级空间", selection: $parentID) {
                        Text("顶层空间").tag(Optional<UUID>.none)
                        ForEach(allLocations.filter { $0.id != location?.id }) { candidate in
                            Text(candidate.name).tag(Optional(candidate.id))
                        }
                    }
                }

                EditorCard(
                    title: "用途标签",
                    subtitle: "可多选，用于快速检索空间类型",
                    systemImage: "tag.fill"
                ) {
                    ForEach(LocationUsageTag.allCases) { tag in
                        Toggle(tag.displayName, isOn: Binding(
                            get: { selectedUsageTags.contains(tag) },
                            set: { isOn in
                                if isOn {
                                    selectedUsageTags.insert(tag)
                                } else {
                                    selectedUsageTags.remove(tag)
                                }
                            }
                        ))
                        .toggleStyle(.checkbox)
                    }
                }

                EditorCard(
                    title: "负责人",
                    subtitle: "私人空间建议至少有一位负责人",
                    systemImage: "person.2.fill"
                ) {
                    if members.isEmpty {
                        Text("暂无成员可选。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(members) { member in
                            Toggle(isOn: Binding(
                                get: { selectedMemberIDs.contains(member.id) },
                                set: { isOn in
                                    if isOn {
                                        selectedMemberIDs.insert(member.id)
                                    } else {
                                        selectedMemberIDs.remove(member.id)
                                    }
                                }
                            )) {
                                Text(member.displayName)
                            }
                            .toggleStyle(.checkbox)
                        }
                    }
                }

                EditorCard(
                    title: "坐标与链接",
                    subtitle: "支持经纬度与来源说明",
                    systemImage: "location.fill"
                ) {
                    TextField("详情链接", text: $detailLink)
                    TextField("纬度", text: $latitudeText)
                    TextField("经度", text: $longitudeText)
                    TextField("坐标来源（device/map/manual）", text: $coordinateSource)
                }

                EditorCard(
                    title: "备注与参考",
                    subtitle: "补充描述和结构化引用",
                    systemImage: "note.text"
                ) {
                    TextField("备注", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                    DetailRefEditorView(refs: $detailRefs)
                }

                EditorCard(
                    title: "媒体附件",
                    subtitle: "支持本地文件与外链",
                    systemImage: "paperclip.circle.fill"
                ) {
                    AttachmentEditorView(
                        existingAttachments: location?.attachments ?? [],
                        removedAttachmentIDs: $removedAttachmentIDs,
                        importedFileURLs: $importedFileURLs,
                        externalURLsText: $externalURLsText
                    )
                }
            }
            .navigationTitle(location == nil ? "新增空间" : "编辑空间")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(location == nil ? "创建" : "保存") {
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
            minWidth: 820,
            idealWidth: 900,
            maxWidth: 980,
            minHeight: 460,
            idealHeight: EditorSheetLayout.cappedHeight(ideal: 680),
            maxHeight: EditorSheetLayout.maxHeight
        )
    }

    private func loadInitialState() {
        guard let location else {
            detailRefs = [DetailRef()]
            if let currentMember {
                selectedMemberIDs = [currentMember.id]
            }
            return
        }

        name = location.name
        status = location.status ?? .normal
        isPublic = location.isPublic
        selectedUsageTags = Set(location.usageTags)
        selectedMemberIDs = Set(location.responsibleMembers.map(\.id))
        parentID = location.parent?.id
        detailLink = location.detailLink
        notes = location.notes
        detailRefs = location.detailRefsWithoutUsageTags
        if let latitude = location.latitude {
            latitudeText = String(latitude)
        }
        if let longitude = location.longitude {
            longitudeText = String(longitude)
        }
        coordinateSource = location.coordinateSource
    }

    private func save() {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            alertMessage = "空间名称不能为空。"
            return
        }

        let target = location ?? LabLocation(name: normalizedName)
        target.name = normalizedName
        target.status = status
        target.isPublic = isPublic
        target.detailLink = detailLink.trimmingCharacters(in: .whitespacesAndNewlines)
        target.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)

        let baseRefs = DomainCodec.deduplicatedDetailRefs(detailRefs)
        target.detailRefs = DomainCodec.mergeUsageTags(Array(selectedUsageTags), into: baseRefs)

        let selectedMembers = members.filter { selectedMemberIDs.contains($0.id) }
        if isPublic {
            target.responsibleMembers = selectedMembers
        } else if selectedMembers.isEmpty, let currentMember {
            target.responsibleMembers = [currentMember]
        } else {
            target.responsibleMembers = selectedMembers
        }

        if let parentID,
           let parent = allLocations.first(where: { $0.id == parentID && $0.id != target.id }) {
            target.parent = parent
        } else {
            target.parent = nil
        }

        let latitude = Double(latitudeText.trimmingCharacters(in: .whitespacesAndNewlines))
        let longitude = Double(longitudeText.trimmingCharacters(in: .whitespacesAndNewlines))
        if latitude != nil && longitude != nil {
            target.latitude = latitude
            target.longitude = longitude
            target.coordinateSource = coordinateSource.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            target.latitude = nil
            target.longitude = nil
            target.coordinateSource = ""
        }

        target.touch()

        if location == nil {
            modelContext.insert(target)
        }

        var refsToDelete: [String] = []
        if let existing = location {
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
                actionType: location == nil ? "新增位置" : "修改位置",
                details: location == nil ? "Added location \(target.name)" : "Edited location \(target.name)",
                user: currentMember,
                location: target
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

    private func appendAttachmentRefs(_ refs: [String], to location: LabLocation) {
        var existing = Set(location.attachments.map(\.filename))
        for ref in refs {
            let value = ref.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            guard !existing.contains(value) else { continue }
            let attachment = LabAttachment(filename: value, location: location)
            location.attachments.append(attachment)
            existing.insert(value)
        }
    }
}
