import SwiftUI
import SwiftData

struct ItemsSectionView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\LabItem.name)]) private var items: [LabItem]
    @Query(sort: [SortDescriptor(\Member.name), SortDescriptor(\Member.username)]) private var members: [Member]
    @Query(sort: [SortDescriptor(\LabLocation.name)]) private var locations: [LabLocation]

    let currentMember: Member?

    @State private var searchText = ""
    @State private var presentingCreate = false
    @State private var editingItem: LabItem?
    @State private var deletingItem: LabItem?

    private var publicCount: Int {
        items.filter { $0.feature == .public }.count
    }

    private var privateCount: Int {
        max(0, items.count - publicCount)
    }

    private var alertCount: Int {
        items.filter { $0.status?.isAlert == true }.count
    }

    private var filteredItems: [LabItem] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !keyword.isEmpty else { return items }
        return items.filter { item in
            let refs = item.detailRefs.map(\.value).joined(separator: " ")
            let owners = item.responsibleMembers.map(\.displayName).joined(separator: " ")
            let places = item.locations.map(\.name).joined(separator: " ")
            let text = [item.name, item.category, item.statusRaw, item.featureRaw, item.notes, refs, owners, places]
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
                        title: "物品资产",
                        subtitle: "统一管理库存状态、归属与空间关联。",
                        systemImage: "shippingbox.fill",
                        stats: [
                            CollectionStat(label: "总数", value: "\(items.count)", tint: .blue),
                            CollectionStat(label: "公共", value: "\(publicCount)", tint: .mint),
                            CollectionStat(label: "私人", value: "\(privateCount)", tint: .indigo),
                            CollectionStat(label: "告警", value: "\(alertCount)", tint: .orange)
                        ]
                    )
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                if filteredItems.isEmpty {
                    ContentUnavailableView(
                        "没有匹配物品",
                        systemImage: "shippingbox",
                        description: Text(searchText.isEmpty ? "点击右上角新增物品。" : "尝试更换关键词。")
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else {
                    Section(searchText.isEmpty ? "全部物品" : "搜索结果（\(filteredItems.count)）") {
                        ForEach(filteredItems) { item in
                            NavigationLink {
                                ItemDetailView(
                                    item: item,
                                    currentMember: currentMember,
                                    members: members,
                                    locations: locations
                                )
                            } label: {
                                ListRowSurface {
                                    ItemRowView(item: item)
                                }
                            }
                            .contextMenu {
                                Button("编辑") {
                                    editingItem = item
                                }
                                Button("删除", role: .destructive) {
                                    deletingItem = item
                                }
                            }
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
                            .listRowBackground(Color.clear)
                        }
                    }
                }
            }
            .navigationTitle("社区物品")
            .searchable(text: $searchText, prompt: "名称 / 备注 / 负责人 / 位置")
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
                        Label("新增物品", systemImage: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $presentingCreate) {
            ItemEditorSheet(item: nil, members: members, locations: locations, currentMember: currentMember)
        }
        .sheet(item: $editingItem) { item in
            ItemEditorSheet(item: item, members: members, locations: locations, currentMember: currentMember)
        }
        .alert("确认删除物品", isPresented: Binding(get: {
            deletingItem != nil
        }, set: { newValue in
            if !newValue {
                deletingItem = nil
            }
        })) {
            Button("取消", role: .cancel) {
                deletingItem = nil
            }
            Button("删除", role: .destructive) {
                performDelete()
            }
        } message: {
            Text("删除后将移除该物品及其附件记录。")
        }
    }

    private func performDelete() {
        guard let item = deletingItem else { return }

        if item.feature == .private,
           let currentMember,
           !item.responsibleMembers.contains(where: { $0.id == currentMember.id }) {
            deletingItem = nil
            return
        }

        let refs = item.attachmentRefs
        let itemName = item.name
        let itemID = item.id
        modelContext.delete(item)

        let log = LabLog(
            actionType: "删除物品",
            details: "Deleted item \(itemName)",
            user: currentMember,
            item: nil,
            location: nil,
            event: nil
        )
        modelContext.insert(log)

        do {
            try modelContext.save()
            for ref in refs {
                AttachmentStore.deleteManagedFile(ref: ref)
            }
        } catch {
            assertionFailure("Delete item failed: \(error) for \(itemID)")
        }

        deletingItem = nil
    }
}

private struct ItemRowView: View {
    let item: LabItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(item.name)
                    .font(.headline)
                ItemStatusBadge(status: item.status)
                FeatureBadge(feature: item.feature)
            }

            HStack(spacing: 8) {
                if !item.locations.isEmpty {
                    Text(item.locations.map(\.name).joined(separator: "、"))
                        .lineLimit(1)
                } else {
                    Text("未指定位置")
                }
                if !item.responsibleMembers.isEmpty {
                    Text("·")
                    Text(item.responsibleMembers.map(\.displayName).joined(separator: "、"))
                        .lineLimit(1)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct ItemDetailView: View {
    let item: LabItem
    let currentMember: Member?
    let members: [Member]
    let locations: [LabLocation]

    @State private var showingEditor = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text(item.name)
                        .font(.largeTitle.bold())
                    Spacer()
                    Button("编辑") {
                        showingEditor = true
                    }
                    .buttonStyle(.borderedProminent)
                }

                HStack(spacing: 8) {
                    ItemStatusBadge(status: item.status)
                    FeatureBadge(feature: item.feature)
                    if !item.category.isEmpty {
                        Text(item.category)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.14))
                            .clipShape(Capsule())
                    }
                }

                DetailInfoGrid {
                    DetailInfoRow(title: "价值", value: item.value.map { String(format: "%.2f", $0) } ?? "未指定")
                    DetailInfoRow(title: "数量描述", value: item.quantityDesc.isEmpty ? "未指定" : item.quantityDesc)
                    DetailInfoRow(title: "购入时间", value: item.purchaseDate?.formatted(date: .abbreviated, time: .omitted) ?? "未指定")
                    DetailInfoRow(title: "购买链接", value: item.purchaseLink.isEmpty ? "未指定" : item.purchaseLink)
                    DetailInfoRow(title: "负责人", value: item.responsibleMembers.isEmpty ? "未指定" : item.responsibleMembers.map(\.displayName).joined(separator: "、"))
                    DetailInfoRow(title: "位置", value: item.locations.isEmpty ? "未指定" : item.locations.map(\.name).joined(separator: "、"))
                    DetailInfoRow(title: "更新时间", value: item.lastModified.formatted(date: .abbreviated, time: .shortened))
                }

                if !item.notes.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("备注")
                            .font(.headline)
                        Text(item.notes)
                            .textSelection(.enabled)
                    }
                }

                if !item.detailRefs.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("参考信息")
                            .font(.headline)
                        ForEach(item.detailRefs) { ref in
                            VStack(alignment: .leading, spacing: 2) {
                                if !ref.label.isEmpty {
                                    Text(ref.label)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Text(ref.value)
                                    .textSelection(.enabled)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }

                if !item.attachments.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("附件")
                            .font(.headline)
                        ForEach(item.attachments) { attachment in
                            AttachmentRow(attachment: attachment)
                        }
                    }
                }

                if !item.events.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("关联事项")
                            .font(.headline)
                        ForEach(item.events.sorted(by: { $0.updatedAt > $1.updatedAt })) { event in
                            HStack {
                                Text(event.title)
                                Spacer()
                                EventVisibilityBadge(visibility: event.visibility)
                            }
                        }
                    }
                }
            }
            .padding(20)
        }
        .sheet(isPresented: $showingEditor) {
            ItemEditorSheet(item: item, members: members, locations: locations, currentMember: currentMember)
        }
    }
}

private struct ItemEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let item: LabItem?
    let members: [Member]
    let locations: [LabLocation]
    let currentMember: Member?

    @State private var name: String = ""
    @State private var category: String = ""
    @State private var status: ItemStockStatus = .normal
    @State private var feature: ItemFeature = .private
    @State private var valueText: String = ""
    @State private var quantityDesc: String = ""
    @State private var purchaseDate: Date = .now
    @State private var hasPurchaseDate = false
    @State private var notes: String = ""
    @State private var purchaseLink: String = ""
    @State private var detailRefs: [DetailRef] = []

    @State private var selectedMemberIDs: Set<UUID> = []
    @State private var selectedLocationIDs: Set<UUID> = []

    @State private var removedAttachmentIDs: Set<UUID> = []
    @State private var importedFileURLs: [URL] = []
    @State private var externalURLsText: String = ""

    @State private var alertMessage: String?

    var body: some View {
        NavigationStack {
            EditorCanvas(maxWidth: 980) {
                EditorHeader(
                    title: item == nil ? "创建物品" : "编辑物品",
                    subtitle: "先填写核心属性，再绑定负责人与位置，最后补充附件和参考信息。",
                    systemImage: "cube.box.fill"
                )

                EditorCard(
                    title: "基础信息",
                    subtitle: "识别信息与库存状态",
                    systemImage: "tag.fill"
                ) {
                    TextField("物品名称（必填）", text: $name)

                    HStack(spacing: 12) {
                        Picker("状态", selection: $status) {
                            ForEach(ItemStockStatus.allCases) { option in
                                Text(option.rawValue).tag(option)
                            }
                        }
                        Picker("归属", selection: $feature) {
                            ForEach(ItemFeature.allCases) { option in
                                Text(option.rawValue).tag(option)
                            }
                        }
                    }

                    TextField("类别", text: $category)
                }

                EditorCard(
                    title: "扩展属性",
                    subtitle: "采购信息、数量与备注",
                    systemImage: "text.badge.plus"
                ) {
                    TextField("价值（￥）", text: $valueText)
                    TextField("数量描述", text: $quantityDesc)
                    Toggle("记录购入时间", isOn: $hasPurchaseDate)
                    if hasPurchaseDate {
                        DatePicker("购入日期", selection: $purchaseDate, displayedComponents: .date)
                    }
                    TextField("购买链接", text: $purchaseLink)
                    TextField("备注", text: $notes, axis: .vertical)
                        .lineLimit(3...6)
                }

                EditorCard(
                    title: "负责人",
                    subtitle: "私人物品建议至少保留一位负责人",
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
                    title: "位置",
                    subtitle: "关联当前物品所在空间",
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
                    title: "参考信息",
                    subtitle: "可添加结构化引用信息",
                    systemImage: "list.bullet.rectangle"
                ) {
                    DetailRefEditorView(refs: $detailRefs)
                }

                EditorCard(
                    title: "媒体附件",
                    subtitle: "支持本地文件与外链",
                    systemImage: "paperclip.circle.fill"
                ) {
                    AttachmentEditorView(
                        existingAttachments: item?.attachments ?? [],
                        removedAttachmentIDs: $removedAttachmentIDs,
                        importedFileURLs: $importedFileURLs,
                        externalURLsText: $externalURLsText
                    )
                }
            }
            .navigationTitle(item == nil ? "新增物品" : "编辑物品")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(item == nil ? "创建" : "保存") {
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
                Button("确定", role: .cancel) {
                    alertMessage = nil
                }
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
        guard let item else {
            detailRefs = [DetailRef()]
            if let currentMember {
                selectedMemberIDs = [currentMember.id]
            }
            return
        }

        name = item.name
        category = item.category
        status = item.status ?? .normal
        feature = item.feature ?? .private
        valueText = item.value.map { String($0) } ?? ""
        quantityDesc = item.quantityDesc
        if let date = item.purchaseDate {
            purchaseDate = date
            hasPurchaseDate = true
        }
        notes = item.notes
        purchaseLink = item.purchaseLink
        detailRefs = item.detailRefs
        selectedMemberIDs = Set(item.responsibleMembers.map(\.id))
        selectedLocationIDs = Set(item.locations.map(\.id))
        removedAttachmentIDs = []
    }

    private func save() {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            alertMessage = "物品名称不能为空。"
            return
        }

        let parsedValue = Double(valueText.trimmingCharacters(in: .whitespacesAndNewlines))
        let refinedRefs = DomainCodec.deduplicatedDetailRefs(detailRefs)

        let target = item ?? LabItem(name: normalizedName)
        target.name = normalizedName
        target.category = category.trimmingCharacters(in: .whitespacesAndNewlines)
        target.status = status
        target.feature = feature
        target.value = parsedValue
        target.quantityDesc = quantityDesc.trimmingCharacters(in: .whitespacesAndNewlines)
        target.purchaseDate = hasPurchaseDate ? purchaseDate : nil
        target.notes = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        target.purchaseLink = purchaseLink.trimmingCharacters(in: .whitespacesAndNewlines)
        target.detailRefs = refinedRefs

        let selectedMembers = members.filter { selectedMemberIDs.contains($0.id) }
        if feature == .private {
            if selectedMembers.isEmpty, let currentMember {
                target.assignResponsibleMembers([currentMember])
            } else {
                target.assignResponsibleMembers(selectedMembers)
            }
        } else {
            target.assignResponsibleMembers(selectedMembers)
        }

        target.locations = locations.filter { selectedLocationIDs.contains($0.id) }
        target.touch()

        if item == nil {
            modelContext.insert(target)
        }

        var refsToDelete: [String] = []
        if let existing = item {
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

        let log = LabLog(
            actionType: item == nil ? "新增物品" : "修改物品",
            details: item == nil ? "Added item \(target.name)" : "Edited item \(target.name)",
            user: currentMember,
            item: target
        )
        modelContext.insert(log)

        do {
            try modelContext.save()
            refsToDelete.forEach { AttachmentStore.deleteManagedFile(ref: $0) }
            dismiss()
        } catch {
            alertMessage = "保存失败：\(error.localizedDescription)"
        }
    }

    private func appendAttachmentRefs(_ refs: [String], to item: LabItem) {
        var existing = Set(item.attachments.map(\.filename))
        for ref in refs {
            let value = ref.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty else { continue }
            guard !existing.contains(value) else { continue }
            let attachment = LabAttachment(filename: value, item: item)
            item.attachments.append(attachment)
            existing.insert(value)
        }
    }
}
