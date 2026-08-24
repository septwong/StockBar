import SwiftUI

struct IndicesPane: View {
    @Environment(\.container) private var container
    @State private var items: [IndexDescriptor] = []
    @State private var showAdd = false
    @State private var editing: IndexDescriptor?
    @State private var deleting: IndexDescriptor?
    @State private var selectedID: String?
    @State private var dropTargetID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("settings.indices", comment: ""))
                    .font(.title3)
                Spacer()
                Button(action: restoreDefaults) {
                    Label(L("indices.restoreDefaults", comment: ""), systemImage: "arrow.counterclockwise")
                }
                Button(action: { showAdd = true }) {
                    Label(L("action.add", comment: ""), systemImage: "plus")
                }
            }

            indicesList

            if items.isEmpty {
                Text(L("indices.settings.empty", comment: ""))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 20)
            }
        }
        .padding(20)
        .onAppear(perform: reload)
        .sheet(isPresented: $showAdd) {
            IndexEditorSheet(initial: nil, onSaved: {
                showAdd = false
                reload()
                container?.refresher.refreshIndicesNow()
            }, onCancel: { showAdd = false })
        }
        .sheet(item: $editing) { existing in
            IndexEditorSheet(initial: existing, onSaved: {
                editing = nil
                reload()
                container?.refresher.refreshIndicesNow()
            }, onCancel: { editing = nil })
        }
        .alert(
            String(format: L("delete.confirm.title", comment: ""), deleting?.displayName ?? ""),
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
        ) {
            Button(L("action.cancel", comment: ""), role: .cancel) { deleting = nil }
            Button(L("action.delete", comment: ""), role: .destructive) {
                if let item = deleting {
                    try? container?.indexRepo.delete(id: item.id)
                    if let container {
                        var selected = container.tickerPrefs.tickerIndexIDs
                        selected.remove(item.id)
                        container.tickerPrefs.tickerIndexIDs = selected
                    }
                    reload()
                    container?.refresher.refreshIndicesNow()
                }
                deleting = nil
            }
        } message: {
            Text(L("delete.confirm.body", comment: ""))
        }
    }

    private var indicesList: some View {
        GeometryReader { proxy in
            let columns = IndexColumnWidths(totalWidth: proxy.size.width)

            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: columns.spacing) {
                    Text("").frame(width: columns.drag)
                    Text(L("col.name", comment: ""))
                        .frame(width: columns.name, alignment: .leading)
                    Text(L("col.market", comment: ""))
                        .frame(width: columns.market, alignment: .leading)
                    Text(L("indices.tencentCode", comment: ""))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(width: columns.tencentCode, alignment: .leading)
                    Text(L("indices.eastMoneySecid", comment: ""))
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                        .frame(width: columns.eastMoneySecid, alignment: .leading)
                    Spacer().frame(width: columns.actions)
                }
                .font(.system(size: 11, weight: .semibold))
                .foregroundColor(.secondary)
                .padding(.horizontal, columns.horizontalPadding)
                .padding(.vertical, 6)
                .background(Color.secondary.opacity(0.08))

                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            indexRow(
                                item,
                                index: index,
                                isAlternate: index.isMultiple(of: 2),
                                columns: columns
                            )
                        }
                    }
                }
                .background(Color(NSColor.controlBackgroundColor))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                )
            }
        }
        .frame(minHeight: 260)
    }

    @ViewBuilder
    private func indexRow(
        _ item: IndexDescriptor,
        index: Int,
        isAlternate: Bool,
        columns: IndexColumnWidths
    ) -> some View {
        let isSelected = selectedID == item.id
        let isDropTarget = dropTargetID == item.id

        HStack(spacing: columns.spacing) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.55))
                .frame(width: columns.drag)
                .help(L("action.dragToReorder", comment: ""))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.displayName)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if !item.nameEn.isEmpty && item.nameEn != item.nameZh {
                    Text(item.nameEn)
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: columns.name, alignment: .leading)

            Text(item.market.displayName)
                .frame(width: columns.market, alignment: .leading)
                .foregroundColor(.secondary)

            Text(item.tencentCode)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .frame(width: columns.tencentCode, alignment: .leading)

            Text(item.emSecid)
                .font(.system(size: 11, design: .monospaced))
                .lineLimit(1)
                .frame(width: columns.eastMoneySecid, alignment: .leading)

            HStack(spacing: 4) {
                Button { editing = item } label: {
                    Image(systemName: "pencil")
                }
                .buttonStyle(.borderless)
                .help(L("action.edit", comment: ""))
                Button(role: .destructive) {
                    deleting = item
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
            .frame(width: columns.actions)
        }
        .padding(.horizontal, columns.horizontalPadding)
        .padding(.vertical, 6)
        .background(rowBackground(isSelected: isSelected, isAlternate: isAlternate))
        .overlay(alignment: .top) {
            if isDropTarget {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { editing = item }
        .onTapGesture { selectedID = item.id }
        .draggable(item.id) {
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal")
                Text(item.displayName).bold()
            }
            .padding(8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        }
        .dropDestination(for: String.self) { droppedIDs, _ in
            handleDrop(droppedIDs: droppedIDs, ontoIndex: index)
        } isTargeted: { hovering in
            dropTargetID = hovering ? item.id : (dropTargetID == item.id ? nil : dropTargetID)
        }
    }

    /// 在设置窗口较窄时压缩代码列，保留名称和操作列的完整布局，避免右侧按钮被推出窗口。
    private struct IndexColumnWidths {
        let spacing: CGFloat = 6
        let horizontalPadding: CGFloat = 10
        let drag: CGFloat = 16
        let name: CGFloat
        let market: CGFloat = 52
        let tencentCode: CGFloat
        let eastMoneySecid: CGFloat
        let actions: CGFloat = 52

        init(totalWidth: CGFloat) {
            let fixedWidth = horizontalPadding * 2 + spacing * 5 + drag + market + actions
            let flexibleWidth = max(0, totalWidth - fixedWidth)
            tencentCode = min(104, max(72, flexibleWidth * 0.28))
            eastMoneySecid = min(112, max(78, flexibleWidth * 0.30))
            name = max(0, flexibleWidth - tencentCode - eastMoneySecid)
        }
    }

    private func rowBackground(isSelected: Bool, isAlternate: Bool) -> Color {
        if isSelected { return Color.accentColor.opacity(0.20) }
        return isAlternate ? Color.secondary.opacity(0.05) : Color.clear
    }

    private func handleDrop(droppedIDs: [String], ontoIndex target: Int) -> Bool {
        guard let firstID = droppedIDs.first,
              let sourceIndex = items.firstIndex(where: { $0.id == firstID }),
              sourceIndex != target else { return false }
        let item = items.remove(at: sourceIndex)
        let insertAt = sourceIndex < target ? target - 1 : target
        items.insert(item, at: insertAt)
        try? container?.indexRepo.reorder(ids: items.map(\.id))
        container?.refresher.refreshIndicesNow()
        return true
    }

    private func reload() {
        items = (try? container?.indexRepo.all()) ?? []
    }

    private func restoreDefaults() {
        items = (try? container?.indexRepo.restoreDefaults()) ?? items
        container?.refresher.refreshIndicesNow()
    }
}

private struct IndexEditorSheet: View {
    @Environment(\.container) private var container

    let initial: IndexDescriptor?
    var onSaved: () -> Void
    var onCancel: () -> Void

    @State private var nameZh = ""
    @State private var nameEn = ""
    @State private var market: Market = .a
    @State private var currency: Currency = .cny
    @State private var tencentCode = ""
    @State private var emSecid = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(initial == nil
                 ? L("indices.addTitle", comment: "")
                 : L("indices.editTitle", comment: ""))
                .font(.title3)

            Form {
                TextField(L("indices.nameZh", comment: ""), text: $nameZh)
                    .textFieldStyle(.roundedBorder)
                TextField(L("indices.nameEn", comment: ""), text: $nameEn)
                    .textFieldStyle(.roundedBorder)

                Picker(L("col.market", comment: ""), selection: $market) {
                    ForEach(Market.allCases, id: \.self) { item in
                        Text(item.displayName).tag(item)
                    }
                }
                Picker(L("indices.currency", comment: ""), selection: $currency) {
                    ForEach(Currency.allCases, id: \.self) { item in
                        Text("\(item.rawValue) (\(item.symbol))").tag(item)
                    }
                }

                TextField(L("indices.tencentCode", comment: ""), text: $tencentCode)
                    .textFieldStyle(.roundedBorder)
                TextField(L("indices.eastMoneySecid", comment: ""), text: $emSecid)
                    .textFieldStyle(.roundedBorder)
            }

            Text(L("indices.providerCodeHint", comment: ""))
                .font(.caption)
                .foregroundColor(.secondary)

            if let error {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
            }

            HStack {
                Spacer()
                Button(L("action.cancel", comment: ""), action: onCancel)
                Button(L("action.save", comment: ""), action: save)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 500)
        .onAppear(perform: prefill)
        .onChange(of: market) { newMarket in
            if initial == nil {
                currency = newMarket.defaultCurrency
            }
        }
    }

    private func prefill() {
        guard let initial else {
            currency = market.defaultCurrency
            return
        }
        nameZh = initial.nameZh
        nameEn = initial.nameEn
        market = initial.market
        currency = initial.currency
        tencentCode = initial.tencentCode
        emSecid = initial.emSecid
    }

    private func save() {
        let zh = nameZh.trimmingCharacters(in: .whitespacesAndNewlines)
        let en = nameEn.trimmingCharacters(in: .whitespacesAndNewlines)
        let descriptor = IndexDescriptor(
            id: initial?.id ?? UUID().uuidString,
            nameZh: zh.isEmpty ? en : zh,
            nameEn: en.isEmpty ? zh : en,
            market: market,
            emSecid: emSecid.trimmingCharacters(in: .whitespacesAndNewlines),
            tencentCode: tencentCode.trimmingCharacters(in: .whitespacesAndNewlines),
            currency: currency
        )

        do {
            try container?.indexRepo.validate(descriptor, excludingID: descriptor.id)
            try container?.indexRepo.upsert(descriptor)
            onSaved()
        } catch let validation as IndexRepositoryError {
            error = validationMessage(validation)
        } catch {
            self.error = "\(error)"
        }
    }

    private func validationMessage(_ error: IndexRepositoryError) -> String {
        switch error {
        case .nameRequired: return L("indices.error.nameRequired", comment: "")
        case .tencentCodeRequired: return L("indices.error.tencentCodeRequired", comment: "")
        case .eastMoneySecidRequired: return L("indices.error.eastMoneySecidRequired", comment: "")
        case .duplicateTencentCode: return L("indices.error.duplicateTencentCode", comment: "")
        case .duplicateEastMoneySecid: return L("indices.error.duplicateEastMoneySecid", comment: "")
        }
    }
}
