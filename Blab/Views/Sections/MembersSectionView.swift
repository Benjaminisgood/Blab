import SwiftUI
import SwiftData
import AppKit
import UniformTypeIdentifiers

struct MembersSectionView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\Member.name), SortDescriptor(\Member.username)]) private var members: [Member]
    @Query(sort: [SortDescriptor(\LabItem.name)]) private var items: [LabItem]
    @Query(sort: [SortDescriptor(\LabLocation.name)]) private var locations: [LabLocation]
    @Query(sort: [SortDescriptor(\LabEvent.startTime, order: .forward), SortDescriptor(\LabEvent.createdAt, order: .reverse)]) private var events: [LabEvent]

    let currentMember: Member?

    @State private var searchText = ""
    @State private var presentingCreate = false
    @State private var editingMember: Member?
    @State private var deletingMember: Member?

    private var withContactCount: Int {
        members.filter { !$0.contact.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
    }

    private var withBioCount: Int {
        members.filter {
            !$0.profileMetadata.bio.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.count
    }

    private var followingCount: Int {
        currentMember?.followingMembers.count ?? 0
    }

    private var followerCount: Int {
        currentMember?.followerMembers.count ?? 0
    }

    private var sortedMembers: [Member] {
        let followedIDs = Set(currentMember?.followingMembers.map(\.id) ?? [])

        return members.sorted { lhs, rhs in
            func group(_ member: Member) -> Int {
                if member.id == currentMember?.id {
                    return 0
                }
                if followedIDs.contains(member.id) {
                    return 1
                }
                return 2
            }

            let groupL = group(lhs)
            let groupR = group(rhs)
            if groupL != groupR {
                return groupL < groupR
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    private var filteredMembers: [Member] {
        let keyword = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !keyword.isEmpty else {
            return sortedMembers
        }
        return sortedMembers.filter { member in
            let text = [member.name, member.username, member.contact]
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
                        title: "社区成员",
                        subtitle: "维护成员档案、关注关系和协作身份。",
                        systemImage: "person.3.fill",
                        stats: [
                            CollectionStat(label: "成员总数", value: "\(members.count)", tint: .blue),
                            CollectionStat(label: "有联系方式", value: "\(withContactCount)", tint: .teal),
                            CollectionStat(label: "有简介", value: "\(withBioCount)", tint: .indigo),
                            CollectionStat(label: "我关注", value: "\(followingCount)", tint: .mint),
                            CollectionStat(label: "关注我", value: "\(followerCount)", tint: .orange)
                        ]
                    )
                }
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                if filteredMembers.isEmpty {
                    ContentUnavailableView(
                        "没有匹配成员",
                        systemImage: "person.3",
                        description: Text(searchText.isEmpty ? "点击右上角新增成员。" : "尝试更换关键词。")
                    )
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else {
                    Section(searchText.isEmpty ? "全部成员" : "搜索结果（\(filteredMembers.count)）") {
                        ForEach(filteredMembers) { member in
                            NavigationLink {
                                MemberDetailView(
                                    member: member,
                                    currentMember: currentMember,
                                    allItems: items,
                                    allLocations: locations,
                                    allEvents: events,
                                    onDelete: {
                                        deletingMember = member
                                    },
                                    onToggleFollow: {
                                        toggleFollow(member)
                                    }
                                )
                            } label: {
                                ListRowSurface {
                                    MemberRowView(member: member, currentMember: currentMember)
                                }
                            }
                            .contextMenu {
                                Button("编辑") {
                                    editingMember = member
                                }
                                if member.id != currentMember?.id {
                                    Button(isFollowing(member) ? "取消关注" : "关注") {
                                        toggleFollow(member)
                                    }
                                }
                                Button("删除", role: .destructive) {
                                    deletingMember = member
                                }
                            }
                            .listRowSeparator(.hidden)
                            .listRowInsets(EdgeInsets(top: 2, leading: 10, bottom: 2, trailing: 10))
                            .listRowBackground(Color.clear)
                        }
                    }
                }
            }
            .navigationTitle("社区成员")
            .searchable(text: $searchText, prompt: "姓名 / 用户名 / 联系方式")
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
                        Label("新增成员", systemImage: "plus")
                    }
                }
            }
        }
        .sheet(isPresented: $presentingCreate) {
            MemberEditorSheet(member: nil, allItems: items, allLocations: locations, allEvents: events)
        }
        .sheet(item: $editingMember) { member in
            MemberEditorSheet(member: member, allItems: items, allLocations: locations, allEvents: events)
        }
        .alert("确认删除成员", isPresented: Binding(get: {
            deletingMember != nil
        }, set: { newValue in
            if !newValue {
                deletingMember = nil
            }
        })) {
            Button("取消", role: .cancel) {
                deletingMember = nil
            }
            Button("删除", role: .destructive) {
                performDelete()
            }
        } message: {
            Text("删除成员将同时移除其关注关系和参与记录。")
        }
    }

    private func isFollowing(_ member: Member) -> Bool {
        guard let currentMember, member.id != currentMember.id else { return false }
        return currentMember.followingLinks.contains(where: { $0.followed?.id == member.id })
    }

    private func toggleFollow(_ member: Member) {
        guard let currentMember, member.id != currentMember.id else { return }

        if let existing = currentMember.followingLinks.first(where: { $0.followed?.id == member.id }) {
            modelContext.delete(existing)
        } else {
            let link = MemberFollow(follower: currentMember, followed: member)
            modelContext.insert(link)
        }

        try? modelContext.save()
    }

    private func performDelete() {
        guard let member = deletingMember else { return }
        if member.id == currentMember?.id {
            deletingMember = nil
            return
        }

        let oldPhoto = member.photoRef
        modelContext.delete(member)
        do {
            try modelContext.save()
            if !oldPhoto.isEmpty {
                AttachmentStore.deleteManagedFile(ref: oldPhoto)
            }
        } catch {
            assertionFailure("Delete member failed: \(error)")
        }

        deletingMember = nil
    }
}

private struct MemberRowView: View {
    let member: Member
    let currentMember: Member?

    var body: some View {
        let isSelf = member.id == currentMember?.id
        let followed = currentMember?.followingLinks.contains(where: { $0.followed?.id == member.id }) == true

        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(member.displayName)
                    .font(.headline)
                if isSelf {
                    Text("我")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.blue.opacity(0.18))
                        .foregroundStyle(.blue)
                        .clipShape(Capsule())
                } else if followed {
                    Text("已关注")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.mint.opacity(0.18))
                        .foregroundStyle(.mint)
                        .clipShape(Capsule())
                }
            }
            Text("@\(member.username)")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(member.contact.isEmpty ? "无联系方式" : member.contact)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

private struct MemberDetailView: View {
    @Environment(\.modelContext) private var modelContext

    let member: Member
    let currentMember: Member?
    let allItems: [LabItem]
    let allLocations: [LabLocation]
    let allEvents: [LabEvent]
    let onDelete: () -> Void
    let onToggleFollow: () -> Void

    @State private var showingEditor = false

    private var isSelf: Bool {
        member.id == currentMember?.id
    }

    private var profileMeta: ProfileMetadata {
        member.profileMetadata
    }

    private var relatedEvents: [LabEvent] {
        allEvents.filter { event in
            event.owner?.id == member.id || event.participantLinks.contains(where: { $0.member?.id == member.id })
        }
    }

    private var itemAlerts: [LabItem] {
        member.items.filter { $0.status?.isAlert == true }
    }

    private var locationAlerts: [LabLocation] {
        member.responsibleLocations.filter { $0.status?.isAlert == true }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    if let avatarURL = AttachmentStore.resolveURL(for: member.photoRef) {
                        AsyncImage(url: avatarURL) { image in
                            image
                                .resizable()
                                .scaledToFill()
                        } placeholder: {
                            Color.secondary.opacity(0.14)
                        }
                        .frame(width: 92, height: 92)
                        .clipShape(Circle())
                    } else {
                        Circle()
                            .fill(Color.secondary.opacity(0.16))
                            .frame(width: 92, height: 92)
                            .overlay(Image(systemName: "person.fill").font(.largeTitle).foregroundStyle(.secondary))
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Text(member.displayName)
                                .font(.largeTitle.bold())
                            if isSelf {
                                Text("我")
                                    .font(.caption)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 2)
                                    .background(Color.blue.opacity(0.16))
                                    .foregroundStyle(.blue)
                                    .clipShape(Capsule())
                            }
                        }

                        Text("@\(member.username)")
                            .foregroundStyle(.secondary)

                        if !member.contact.isEmpty {
                            Text(member.contact)
                        }

                        HStack(spacing: 8) {
                            Button("编辑") {
                                showingEditor = true
                            }
                            .buttonStyle(.borderedProminent)

                            if !isSelf {
                                Button(
                                    currentMember?.followingLinks.contains(where: { $0.followed?.id == member.id }) == true ? "取消关注" : "关注"
                                ) {
                                    onToggleFollow()
                                }
                                .buttonStyle(.bordered)
                            }

                            if !isSelf {
                                Button("删除", role: .destructive) {
                                    onDelete()
                                }
                                .buttonStyle(.bordered)
                            }
                        }
                    }
                    Spacer()
                }

                DetailInfoGrid {
                    DetailInfoRow(title: "负责物品", value: "\(member.items.count)")
                    DetailInfoRow(title: "负责空间", value: "\(member.responsibleLocations.count)")
                    DetailInfoRow(title: "举办事项", value: "\(member.eventsOwned.count)")
                    DetailInfoRow(title: "相关事项", value: "\(relatedEvents.count)")
                    DetailInfoRow(title: "关注成员", value: "\(member.followingMembers.count)")
                    DetailInfoRow(title: "被关注", value: "\(member.followerMembers.count)")
                    DetailInfoRow(title: "更新时间", value: member.lastModified.formatted(date: .abbreviated, time: .shortened))
                }

                if !profileMeta.bio.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("个人展示")
                            .font(.headline)
                        Text(profileMeta.bio)
                            .textSelection(.enabled)
                    }
                }

                if !profileMeta.socialLinks.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("社交链接")
                            .font(.headline)
                        ForEach(profileMeta.socialLinks) { link in
                            if let url = URL(string: link.url), !link.url.isEmpty {
                                Link(link.label.isEmpty ? link.url : link.label, destination: url)
                            }
                        }
                    }
                }

                if !itemAlerts.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("物品预警")
                            .font(.headline)
                        ForEach(itemAlerts) { item in
                            HStack {
                                Text(item.name)
                                Spacer()
                                ItemStatusBadge(status: item.status)
                            }
                        }
                    }
                }

                if !locationAlerts.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("空间预警")
                            .font(.headline)
                        ForEach(locationAlerts) { location in
                            HStack {
                                Text(location.name)
                                Spacer()
                                LocationStatusBadge(status: location.status)
                            }
                        }
                    }
                }

                if !relatedEvents.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("相关事项")
                            .font(.headline)
                        ForEach(relatedEvents.sorted(by: { $0.updatedAt > $1.updatedAt })) { event in
                            HStack {
                                Text(event.title)
                                Spacer()
                                EventVisibilityBadge(visibility: event.visibility)
                            }
                        }
                    }
                }

                FeedbackThreadView(entries: member.feedbackEntries) { text in
                    member.appendFeedback(from: currentMember, content: text)
                    modelContext.insert(
                        LabLog(
                            actionType: "成员留言",
                            details: "Posted feedback to \(member.displayName)",
                            user: currentMember
                        )
                    )
                    try? modelContext.save()
                }
            }
            .padding(20)
        }
        .sheet(isPresented: $showingEditor) {
            MemberEditorSheet(
                member: member,
                allItems: allItems,
                allLocations: allLocations,
                allEvents: allEvents
            )
        }
    }
}

private struct MemberEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext

    let member: Member?
    let allItems: [LabItem]
    let allLocations: [LabLocation]
    let allEvents: [LabEvent]

    @State private var name = ""
    @State private var username = ""
    @State private var contact = ""
    @State private var password = ""

    @State private var bio = ""
    @State private var socialLinks: [SocialLink] = []
    @State private var locationRelations: [ProfileLocationRelation] = []
    @State private var itemRelations: [ProfileItemRelation] = []
    @State private var eventRelations: [ProfileEventRelation] = []

    @State private var selectedPhotoURL: URL?
    @State private var isPhotoImporterPresented = false

    @State private var alertMessage: String?

    var body: some View {
        NavigationStack {
            EditorCanvas(maxWidth: 1040) {
                EditorHeader(
                    title: member == nil ? "创建成员" : "编辑成员",
                    subtitle: "先维护账号基础信息，再补充头像、简介和个人关联。",
                    systemImage: "person.crop.circle.badge.plus"
                )

                EditorCard(
                    title: "基础信息",
                    subtitle: "姓名、用户名和登录密码",
                    systemImage: "person.text.rectangle"
                ) {
                    TextField("姓名（必填）", text: $name)
                    TextField("用户名（必填）", text: $username)
                    TextField("联系方式", text: $contact)
                    SecureField("密码（留空表示不改）", text: $password)
                }

                EditorCard(
                    title: "头像与简介",
                    subtitle: "用于成员识别和个人介绍",
                    systemImage: "person.crop.square"
                ) {
                    HStack {
                        if let selectedPhotoURL {
                            Text(selectedPhotoURL.lastPathComponent)
                                .lineLimit(1)
                        } else if let member, !member.photoRef.isEmpty {
                            Text(AttachmentStore.displayName(for: member.photoRef))
                                .lineLimit(1)
                        } else {
                            Text("未选择头像")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("选择图片") {
                            isPhotoImporterPresented = true
                        }
                    }

                    TextField("介绍", text: $bio, axis: .vertical)
                        .lineLimit(3...8)
                }

                EditorCard(
                    title: "社交链接",
                    subtitle: "支持多条链接",
                    systemImage: "link.circle.fill"
                ) {
                    ForEach($socialLinks) { $link in
                        VStack(alignment: .leading, spacing: 6) {
                            TextField("平台", text: $link.label)
                            TextField("链接", text: $link.url)
                            Button(role: .destructive) {
                                socialLinks.removeAll(where: { $0.id == link.id })
                            } label: {
                                Text("删除链接")
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 4)
                    }
                    Button("新增社交链接") {
                        socialLinks.append(SocialLink())
                    }
                }

                EditorCard(
                    title: "地点关联（仅自己可见）",
                    subtitle: "记录你和空间的关系",
                    systemImage: "mappin.and.ellipse"
                ) {
                    ForEach($locationRelations) { $relation in
                        VStack(alignment: .leading, spacing: 6) {
                            Picker("地点", selection: $relation.locationID) {
                                ForEach(allLocations) { location in
                                    Text(location.name).tag(location.id)
                                }
                            }
                            Picker("关系", selection: $relation.relation) {
                                ForEach(MemberLocationRelation.allCases) { option in
                                    Text(option.displayName).tag(option)
                                }
                            }
                            TextField("备注", text: $relation.note)
                            Button(role: .destructive) {
                                locationRelations.removeAll(where: { $0.id == relation.id })
                            } label: {
                                Text("删除地点关联")
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 4)
                    }
                    Button("新增地点关联") {
                        if let first = allLocations.first {
                            locationRelations.append(
                                ProfileLocationRelation(locationID: first.id, relation: .other, note: "")
                            )
                        }
                    }
                    .disabled(allLocations.isEmpty)
                }

                EditorCard(
                    title: "兴趣物品（仅自己可见）",
                    subtitle: "记录你对物品的偏好",
                    systemImage: "shippingbox.fill"
                ) {
                    ForEach($itemRelations) { $relation in
                        VStack(alignment: .leading, spacing: 6) {
                            Picker("物品", selection: $relation.itemID) {
                                ForEach(allItems) { item in
                                    Text(item.name).tag(item.id)
                                }
                            }
                            Picker("关系", selection: $relation.relation) {
                                ForEach(MemberItemRelation.allCases) { option in
                                    Text(option.displayName).tag(option)
                                }
                            }
                            TextField("备注", text: $relation.note)
                            Button(role: .destructive) {
                                itemRelations.removeAll(where: { $0.id == relation.id })
                            } label: {
                                Text("删除物品关联")
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 4)
                    }
                    Button("新增物品关联") {
                        if let first = allItems.first {
                            itemRelations.append(
                                ProfileItemRelation(itemID: first.id, relation: .other, note: "")
                            )
                        }
                    }
                    .disabled(allItems.isEmpty)
                }

                EditorCard(
                    title: "活动关联（仅自己可见）",
                    subtitle: "记录你和活动的关系",
                    systemImage: "calendar.badge.clock"
                ) {
                    ForEach($eventRelations) { $relation in
                        VStack(alignment: .leading, spacing: 6) {
                            Picker("活动", selection: $relation.eventID) {
                                ForEach(allEvents) { event in
                                    Text(event.title).tag(event.id)
                                }
                            }
                            Picker("关系", selection: $relation.relation) {
                                ForEach(MemberEventRelation.allCases) { option in
                                    Text(option.displayName).tag(option)
                                }
                            }
                            TextField("备注", text: $relation.note)
                            Button(role: .destructive) {
                                eventRelations.removeAll(where: { $0.id == relation.id })
                            } label: {
                                Text("删除活动关联")
                            }
                            .buttonStyle(.borderless)
                        }
                        .padding(.vertical, 4)
                    }
                    Button("新增活动关联") {
                        if let first = allEvents.first {
                            eventRelations.append(
                                ProfileEventRelation(eventID: first.id, relation: .other, note: "")
                            )
                        }
                    }
                    .disabled(allEvents.isEmpty)
                }
            }
            .navigationTitle(member == nil ? "新增成员" : "编辑成员")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(member == nil ? "创建" : "保存") {
                        save()
                    }
                }
            }
            .onAppear {
                loadInitialState()
            }
            .fileImporter(
                isPresented: $isPhotoImporterPresented,
                allowedContentTypes: [.image],
                allowsMultipleSelection: false
            ) { result in
                if case .success(let urls) = result {
                    selectedPhotoURL = urls.first
                }
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
            minWidth: 900,
            idealWidth: 980,
            maxWidth: 1080,
            minHeight: 500,
            idealHeight: EditorSheetLayout.cappedHeight(ideal: 720),
            maxHeight: EditorSheetLayout.maxHeight
        )
    }

    private func loadInitialState() {
        guard let member else {
            return
        }

        name = member.name
        username = member.username
        contact = member.contact

        let meta = member.profileMetadata
        bio = meta.bio
        socialLinks = meta.socialLinks
        locationRelations = meta.locationRelations
        itemRelations = meta.itemRelations
        eventRelations = meta.eventRelations
    }

    private func save() {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedName.isEmpty else {
            alertMessage = "姓名不能为空。"
            return
        }
        guard !normalizedUsername.isEmpty else {
            alertMessage = "用户名不能为空。"
            return
        }

        if membersConflict(with: normalizedUsername) {
            alertMessage = "用户名已存在，请更换。"
            return
        }

        let target = member ?? Member(name: normalizedName, username: normalizedUsername)
        let oldPhotoRef = target.photoRef

        target.name = normalizedName
        target.username = normalizedUsername
        target.contact = contact.trimmingCharacters(in: .whitespacesAndNewlines)
        if !password.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            target.passwordHash = password
        }

        let meta = ProfileMetadata(
            bio: bio.trimmingCharacters(in: .whitespacesAndNewlines),
            socialLinks: socialLinks.filter { !$0.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty },
            locationRelations: locationRelations,
            itemRelations: itemRelations,
            eventRelations: eventRelations
        )
        target.setProfileMetadata(meta)

        if member == nil {
            modelContext.insert(target)
        }

        if let selectedPhotoURL {
            do {
                let imported = try AttachmentStore.importFiles([selectedPhotoURL])
                if let ref = imported.first {
                    target.photoRef = ref
                    if !oldPhotoRef.isEmpty && oldPhotoRef != ref {
                        AttachmentStore.deleteManagedFile(ref: oldPhotoRef)
                    }
                }
            } catch {
                alertMessage = "头像导入失败：\(error.localizedDescription)"
                return
            }
        }

        modelContext.insert(
            LabLog(
                actionType: member == nil ? "新增成员" : "修改成员",
                details: member == nil ? "Added member \(target.displayName)" : "Edited member \(target.displayName)",
                user: target
            )
        )

        do {
            try modelContext.save()
            dismiss()
        } catch {
            alertMessage = "保存失败：\(error.localizedDescription)"
        }
    }

    private func membersConflict(with username: String) -> Bool {
        let lowered = username.lowercased()
        return allMembers.contains { other in
            other.username.lowercased() == lowered && other.id != member?.id
        }
    }

    private var allMembers: [Member] {
        (try? modelContext.fetch(FetchDescriptor<Member>())) ?? []
    }
}
