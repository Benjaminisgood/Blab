import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct GarmentEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Query(sort: \LabItem.name) private var items: [LabItem]
    let owner: Member
    var garment: WardrobeGarment?

    @State private var name = ""
    @State private var category: WardrobeCategory = .top
    @State private var color: WardrobeColor = .blue
    @State private var warmth: WardrobeWarmth = .light
    @State private var season: WardrobeSeason = .allSeason
    @State private var occasion: WardrobeOccasion = .everyday
    @State private var laundry: WardrobeLaundryState = .ready
    @State private var notes = ""
    @State private var linkedItemID: UUID?
    @State private var photoData: Data?
    @State private var originalData: Data?
    @State private var isImporterPresented = false
    @State private var isProcessing = false
    @State private var errorMessage: String?
    @State private var loaded = false

    private var availableItems: [LabItem] { items.filter { $0.isResponsible(owner) || $0.id == garment?.linkedItem?.id } }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(garment == nil ? "添加衣物" : "编辑衣物").font(.title2.weight(.semibold))
                    Text("记录你已经拥有的衣服，让搭配更轻松。")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Button("取消") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("保存", action: save)
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isProcessing)
            }.padding(20)
            Divider()
            ScrollView {
                HStack(alignment: .top, spacing: 24) {
                    VStack(spacing: 12) {
                        GarmentImageView(filename: garment?.photoFilename ?? "", category: category, color: color, imageData: photoData)
                            .frame(width: 210, height: 260)
                        Button("选择衣物照片", systemImage: "photo.badge.plus") { isImporterPresented = true }
                            .disabled(isProcessing)
                        if photoData != nil || !(garment?.photoFilename ?? "").isEmpty {
                            Button("本地去除背景", systemImage: "person.crop.rectangle") { removeBackground() }
                                .disabled(isProcessing)
                        }
                        if originalData != nil {
                            Button("恢复导入原图") { photoData = originalData }.disabled(isProcessing)
                        }
                        if isProcessing { ProgressView("正在处理照片…").controlSize(.small) }
                        Text("照片保存在本机。背景简单、单件平铺的照片效果更好。")
                            .font(.caption).foregroundStyle(.secondary).frame(width: 210)
                    }
                    Form {
                        TextField("名称", text: $name, prompt: Text("例如：蓝色牛仔衬衫"))
                        Picker("类别", selection: $category) {
                            ForEach(WardrobeCategory.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        Picker("颜色", selection: $color) {
                            ForEach(WardrobeColor.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        Picker("厚薄", selection: $warmth) {
                            ForEach(WardrobeWarmth.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        Picker("季节", selection: $season) {
                            ForEach(WardrobeSeason.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        Picker("主要场合", selection: $occasion) {
                            ForEach(WardrobeOccasion.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        Picker("衣物状态", selection: $laundry) {
                            ForEach(WardrobeLaundryState.allCases, id: \.self) { Text($0.displayName).tag($0) }
                        }
                        Picker("关联已有物品", selection: $linkedItemID) {
                            Text("独立衣物档案").tag(nil as UUID?)
                            ForEach(availableItems) { Text($0.name).tag(Optional($0.id)) }
                        }
                        TextField("备注", text: $notes, axis: .vertical).lineLimit(3...6)
                    }
                    .formStyle(.grouped)
                    .frame(width: 370)
                }.padding(20)
            }
        }
        .frame(width: 670, height: EditorSheetLayout.cappedHeight(ideal: 650))
        .interactiveDismissDisabled(isProcessing)
        .onAppear(perform: load)
        .fileImporter(isPresented: $isImporterPresented, allowedContentTypes: [.image]) { result in
            switch result {
            case .success(let url):
                isProcessing = true
                Task {
                    defer { isProcessing = false }
                    do {
                        let data = try await Task.detached { try WardrobePhotoService.load(url) }.value
                        photoData = data
                        originalData = data
                    } catch { errorMessage = error.localizedDescription }
                }
            case .failure(let error): errorMessage = error.localizedDescription
            }
        }
        .alert("无法完成操作", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("知道了", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        guard let garment else { return }
        name = garment.name; category = garment.category; color = garment.color
        warmth = garment.warmth; season = garment.season; occasion = garment.occasion
        laundry = garment.laundryState; notes = garment.notes; linkedItemID = garment.linkedItem?.id
    }

    private func removeBackground() {
        isProcessing = true
        let filename = garment?.photoFilename ?? ""
        let currentData = photoData
        let existingURL = WardrobePhotoStore.url(for: filename)
        Task {
            defer { isProcessing = false }
            do {
                let input: Data
                if let currentData { input = currentData }
                else if let existingURL { input = try await Task.detached { try WardrobePhotoService.load(existingURL) }.value }
                else { throw WardrobePhotoError.unreadable }
                if originalData == nil { originalData = input }
                photoData = try await Task.detached { try WardrobePhotoService.removeBackground(from: input) }.value
            } catch { errorMessage = error.localizedDescription }
        }
    }

    private func save() {
        var newPhoto: String?
        // A separate transaction avoids rolling back edits owned by another open window.
        let transaction = ModelContext(context.container)
        transaction.autosaveEnabled = false
        do {
            let record: WardrobeGarment
            if let garment {
                let id = garment.id
                guard let existing = try transaction.fetch(FetchDescriptor<WardrobeGarment>(predicate: #Predicate { $0.id == id })).first,
                      existing.ownerID == owner.id else { throw WardrobePhotoError.conversionFailed }
                record = existing
            } else {
                record = WardrobeGarment(name: name, ownerID: owner.id, category: category)
                transaction.insert(record)
            }
            if let photoData { newPhoto = try WardrobePhotoStore.save(photoData) }
            record.name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            record.category = category; record.color = color; record.warmth = warmth
            record.season = season; record.occasion = occasion; record.laundryState = laundry
            record.notes = notes; record.updatedAt = .now
            if let newPhoto { record.photoFilename = newPhoto }
            if let linkedItemID {
                let linked = try transaction.fetch(FetchDescriptor<LabItem>(predicate: #Predicate { $0.id == linkedItemID })).first
                guard let linked, linked.isResponsible(owner) || linked.id == garment?.linkedItem?.id else { throw WardrobePhotoError.conversionFailed }
                record.linkedItem = linked
                record.linkedItemID = linked.id
            } else { record.linkedItem = nil; record.linkedItemID = nil }
            try transaction.save()
            dismiss()
        } catch {
            transaction.rollback()
            if let newPhoto { WardrobePhotoStore.removeUncommitted(newPhoto) }
            errorMessage = error.localizedDescription
        }
    }
}
