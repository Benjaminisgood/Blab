import SwiftUI
import SwiftData

struct WardrobeSectionView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \WardrobeGarment.updatedAt, order: .reverse) private var allGarments: [WardrobeGarment]
    @Query(sort: \OutfitRecord.date, order: .reverse) private var allRecords: [OutfitRecord]
    let currentMember: Member?

    @State private var tab = "衣橱"
    @State private var search = ""
    @State private var category: WardrobeCategory?
    @State private var showArchived = false
    @State private var editorRequest: GarmentEditorRequest?
    @State private var temperature = 22.0
    @State private var occasion: WardrobeOccasion = .everyday
    @State private var season: WardrobeSeason = .current(at: .now)
    @State private var date = Date.now
    @State private var result: OutfitRecommendationResult?
    @State private var selectedSuggestion: OutfitSuggestion?
    @State private var showManualPicker = false
    @State private var errorMessage: String?
    @State private var notice: String?

    private var garments: [WardrobeGarment] { allGarments.filter { $0.ownerID == currentMember?.id } }
    private var records: [OutfitRecord] { allRecords.filter { $0.ownerID == currentMember?.id } }
    private var filtered: [WardrobeGarment] {
        garments.filter {
            (showArchived || $0.laundryState != .archived)
                && (category == nil || $0.category == category)
                && (search.isEmpty || $0.name.localizedStandardContains(search) || $0.notes.localizedStandardContains(search))
        }
    }
    private var wardrobeFingerprint: String {
        garments.map { "\($0.id):\($0.updatedAt.timeIntervalSince1970):\($0.isAvailable)" }.joined()
    }
    private var boardSubtitle: String {
        "\(date.formatted(date: .abbreviated, time: .omitted)) · \(occasion.displayName) · 参考气温 \(Int(temperature))°C"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                if AppPersistence.isPreview {
                    Label("演示模式 · 示例衣物仅供体验，关闭后不保存", systemImage: "eye")
                        .font(.caption).foregroundStyle(.orange)
                }
                if currentMember == nil {
                    ContentUnavailableView("先建立你的个人资料", systemImage: "person.crop.circle.badge.plus", description: Text("在成员页创建资料后，就可以拥有独立衣橱与穿搭记录。"))
                } else {
                    Picker("衣橱页面", selection: $tab) {
                        Text("衣橱").tag("衣橱")
                        Text("搭配工作台").tag("搭配")
                        Text("穿搭记录").tag("记录")
                    }.pickerStyle(.segmented).frame(maxWidth: 420)
                    if let notice {
                        Label(notice, systemImage: "checkmark.circle.fill").font(.subheadline).foregroundStyle(.teal)
                    }
                    switch tab {
                    case "搭配": styling
                    case "记录": history
                    default: collection
                    }
                }
            }
            .padding(26)
            .frame(maxWidth: 1160, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .sheet(item: $editorRequest) { request in
            if let currentMember { GarmentEditorSheet(owner: currentMember, garment: request.garment) }
        }
        .sheet(isPresented: $showManualPicker) {
            ManualOutfitPicker(garments: garments.filter(\.isAvailable).map { $0.snapshot() }) { suggestion in
                selectedSuggestion = suggestion
                result = nil
                notice = nil
            }
        }
        .onChange(of: temperature) { _, _ in invalidate() }
        .onChange(of: occasion) { _, _ in invalidate() }
        .onChange(of: season) { _, _ in invalidate() }
        .onChange(of: date) { _, _ in invalidate() }
        .onChange(of: wardrobeFingerprint) { _, _ in invalidate() }
        .alert("无法完成操作", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("知道了", role: .cancel) { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 8) {
                Text("穿好今天，轻松出门。")
                    .font(.system(size: 29, weight: .semibold, design: .rounded))
                Text("\(garments.filter { $0.laundryState != .archived }.count) 件衣物 · \(garments.filter(\.isAvailable).count) 件可穿 · \(garments.filter { $0.laundryState == .laundry }.count) 件待洗")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Button { editorRequest = GarmentEditorRequest(garment: nil) } label: {
                Label("添加衣物", systemImage: "plus")
            }.buttonStyle(.borderedProminent).disabled(currentMember == nil)
        }
    }

    private var collection: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                TextField("搜索名称或备注", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 260)
                Picker("类别", selection: $category) {
                    Text("全部类别").tag(nil as WardrobeCategory?)
                    ForEach(WardrobeCategory.allCases) { Text($0.displayName).tag(Optional($0)) }
                }.frame(width: 170)
                Spacer()
                Toggle("显示归档", isOn: $showArchived).toggleStyle(.checkbox)
            }
            if filtered.isEmpty {
                ContentUnavailableView {
                    Label(garments.isEmpty ? "从第一件衣服开始" : "没有符合条件的衣物", systemImage: "tshirt")
                } description: {
                    Text(garments.isEmpty ? "添加上装、下装（或连体装）与鞋履，上传照片后就能组合自己的穿搭图。" : "试试其他分类、关键词，或显示归档衣物。")
                } actions: {
                    if garments.isEmpty { Button("添加第一件衣物") { editorRequest = GarmentEditorRequest(garment: nil) } }
                }.frame(minHeight: 330)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 270), spacing: 18)], spacing: 18) {
                    ForEach(filtered) { garment in
                        Button { editorRequest = GarmentEditorRequest(garment: garment) } label: {
                            VStack(alignment: .leading, spacing: 10) {
                                GarmentImageView(filename: garment.photoFilename, category: garment.category, color: garment.color)
                                    .frame(height: 190)
                                HStack {
                                    Text(garment.name).font(.headline).lineLimit(1)
                                    Spacer(minLength: 0)
                                    Circle().fill(garment.color.swatch).frame(width: 10, height: 10).overlay(Circle().stroke(.quaternary))
                                }
                                Text("\(garment.category.displayName) · \(garment.warmth.displayName) · \(garment.occasion.displayName)")
                                    .font(.caption).foregroundStyle(.secondary)
                                Label(garment.laundryState.displayName, systemImage: garment.isAvailable ? "checkmark.circle" : "archivebox")
                                    .font(.caption).foregroundStyle(garment.isAvailable ? Color.teal : Color.secondary)
                                if garment.laundryState == .ready && !garment.isAvailable {
                                    Text("关联物品当前不可用于穿搭").font(.caption2).foregroundStyle(.orange)
                                }
                            }.padding(12)
                                .background(.background, in: RoundedRectangle(cornerRadius: 18))
                                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(.quaternary))
                        }.buttonStyle(.plain).accessibilityLabel("编辑衣物：\(garment.name)")
                    }
                }
            }
        }
    }

    private var styling: some View {
        VStack(alignment: .leading, spacing: 20) {
            EditorCard(title: "为这一天搭配", subtitle: "手动填写参考气温；推荐结合季节、场合、可穿状态与已穿记录。", systemImage: "sun.max") {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 18) { stylingFields }
                    VStack(alignment: .leading, spacing: 12) { stylingFields }
                }
                HStack {
                    Button("推荐搭配", systemImage: "sparkles", action: recommend).buttonStyle(.borderedProminent)
                    Button("自由搭配", systemImage: "square.grid.2x2") { showManualPicker = true }
                        .disabled(garments.filter(\.isAvailable).isEmpty)
                    Spacer()
                    Text("本地规则推荐").font(.caption).foregroundStyle(.secondary)
                }
            }
            if let result {
                ForEach(result.messages, id: \.self) { Text($0).font(.subheadline).foregroundStyle(.secondary) }
                HStack {
                    ForEach(Array(result.outfits.enumerated()), id: \.element.id) { index, suggestion in
                        Button("方案 \(index + 1) · \(suggestion.title)") { selectedSuggestion = suggestion; notice = nil }
                            .buttonStyle(.bordered)
                            .tint(selectedSuggestion?.id == suggestion.id ? .teal : .secondary)
                    }
                }
            }
            if let suggestion = selectedSuggestion {
                HStack(alignment: .top, spacing: 22) {
                    OutfitBoardView(garments: suggestion.garments, subtitle: boardSubtitle).frame(maxWidth: 570)
                    VStack(alignment: .leading, spacing: 16) {
                        Text("搭配思路").font(.headline)
                        ForEach(suggestion.reasons, id: \.self) { reason in
                            Label(reason, systemImage: "checkmark").font(.subheadline).foregroundStyle(.secondary)
                        }
                        Divider()
                        Button("保存穿搭计划", systemImage: "bookmark") { save(suggestion) }.buttonStyle(.borderedProminent)
                        Button("导出穿搭图", systemImage: "square.and.arrow.up") {
                            do { try OutfitBoardExporter.export(garments: suggestion.garments, subtitle: boardSubtitle) }
                            catch { errorMessage = error.localizedDescription }
                        }
                        Text("保存后可在穿搭记录中标记实际穿着，逐渐形成自己的搭配习惯。")
                            .font(.caption).foregroundStyle(.secondary)
                    }.frame(maxWidth: 260, alignment: .leading).padding(.top, 14)
                }
            } else if result == nil {
                ContentUnavailableView("今天想怎么穿？", systemImage: "sparkles", description: Text("选择气温和场合生成建议，或自由挑选衣橱中的单品。"))
                    .frame(minHeight: 260)
            }
        }
    }

    @ViewBuilder private var stylingFields: some View {
        DatePicker("日期", selection: $date, displayedComponents: .date).frame(maxWidth: 230)
        Stepper("\(Int(temperature))°C", value: $temperature, in: -20...45, step: 1).frame(width: 110)
            .accessibilityLabel("参考气温")
        Picker("场合", selection: $occasion) {
            ForEach(WardrobeOccasion.allCases) { Text($0.displayName).tag($0) }
        }.frame(width: 150)
        Picker("季节", selection: $season) {
            ForEach(WardrobeSeason.allCases) { Text($0.displayName).tag($0) }
        }.frame(width: 145)
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("已保存 \(records.count) 套 · 实际穿过 \(records.filter(\.isWorn).count) 套").foregroundStyle(.secondary)
            if records.isEmpty {
                ContentUnavailableView("让喜欢的搭配留下来", systemImage: "bookmark", description: Text("在搭配工作台保存计划，再记录实际穿着；保存计划不会增加穿着次数。"))
            }
            ForEach(records) { record in
                OutfitRecordCard(record: record) {
                    markWorn(record)
                } onDelete: {
                    delete(record)
                }
            }
        }
    }

    private func invalidate() { result = nil; selectedSuggestion = nil; notice = nil }
    private func recommend() {
        guard let currentMember else { return }
        result = OutfitRecommendationService.recommend(
            garments: garments.map { $0.snapshot() }, history: records.map(\.wearSnapshot),
            context: OutfitContext(ownerID: currentMember.id, temperature: temperature, occasion: occasion, date: OutfitContext.referenceDate(for: date), season: season)
        )
        selectedSuggestion = result?.outfits.first
        notice = nil
    }

    private func save(_ suggestion: OutfitSuggestion) {
        guard let currentMember else { return }
        let ids = Set(suggestion.garments.map(\.id))
        if records.contains(where: { Calendar.current.isDate($0.date, inSameDayAs: date) && $0.occasion == occasion && Set($0.garments.map(\.id)) == ids }) {
            notice = "这一天的同一套搭配已经保存，可在穿搭记录中查看。"
            return
        }
        let transaction = ModelContext(context.container)
        transaction.autosaveEnabled = false
        transaction.insert(OutfitRecord(suggestion: suggestion, ownerID: currentMember.id, date: date, temperature: temperature, occasion: occasion))
        do { try transaction.save(); notice = "已保存穿搭计划，实际穿着后可到记录页标记。" }
        catch { transaction.rollback(); errorMessage = error.localizedDescription }
    }

    private func markWorn(_ record: OutfitRecord) {
        mutate(record) { $0.markWorn(at: .now) }
    }
    private func delete(_ record: OutfitRecord) {
        mutate(record, removing: true) { _ in }
    }
    private func mutate(_ record: OutfitRecord, removing: Bool = false, action: (OutfitRecord) -> Void) {
        let transaction = ModelContext(context.container)
        transaction.autosaveEnabled = false
        do {
            let id = record.id
            guard let fresh = try transaction.fetch(FetchDescriptor<OutfitRecord>(predicate: #Predicate { $0.id == id })).first,
                  fresh.ownerID == currentMember?.id else { return }
            if removing { transaction.delete(fresh) } else { action(fresh) }
            try transaction.save()
            notice = removing ? "已删除这条穿搭计划。" : "已记录今天实际穿着，后续推荐会参考这次记录。"
            result = nil; selectedSuggestion = nil
        } catch { transaction.rollback(); errorMessage = error.localizedDescription }
    }
}

private struct GarmentEditorRequest: Identifiable {
    let id = UUID()
    let garment: WardrobeGarment?
}
