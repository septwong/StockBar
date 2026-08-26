import SwiftUI

private struct PortfolioColumnWidths {
    let horizontalPadding: CGFloat
    let spacing: CGFloat
    let drag: CGFloat
    let symbol: CGFloat
    let market: CGFloat
    let actions: CGFloat
    let name: CGFloat
    let quantity: CGFloat
    let cost: CGFloat
    let createdAt: CGFloat
    let contentWidth: CGFloat

    init(totalWidth: CGFloat, holdings: [Holding], nameHeader: String) {
        let compact = totalWidth < 620
        horizontalPadding = compact ? 8 : 10
        spacing = compact ? 5 : 8
        drag = compact ? 16 : 18
        symbol = compact ? 58 : 62
        market = compact ? 30 : 34
        actions = compact ? 64 : 68
        createdAt = compact ? 108 : 132

        let quantityBase: CGFloat = compact ? 44 : 48
        let costBase: CGFloat = compact ? 62 : 76
        let nameMinimum: CGFloat = compact ? 72 : 88
        let measuredName = ([nameHeader] + holdings.map(\.name))
            .map(Self.measuredNameWidth)
            .max() ?? Self.measuredNameWidth(nameHeader)
        let reservedWidth = horizontalPadding * 2
            + spacing * 7
            + drag
            + symbol
            + market
            + createdAt
            + actions
            + quantityBase
            + costBase
        let nameCap = max(nameMinimum, min(180, totalWidth * 0.32, totalWidth - reservedWidth))
        name = min(max(nameMinimum, measuredName), nameCap)

        let fixedWidth = horizontalPadding * 2
            + spacing * 7
            + drag
            + symbol
            + name
            + market
            + createdAt
            + actions
        let flexibleBase = quantityBase + costBase
        let extraWidth = max(0, totalWidth - fixedWidth - flexibleBase)

        quantity = quantityBase + extraWidth / 2
        cost = costBase + extraWidth / 2
        contentWidth = fixedWidth + flexibleBase + extraWidth
    }

    private static func measuredNameWidth(_ value: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: 13)
        let width = (value as NSString).size(withAttributes: [.font: font]).width
        return ceil(width) + 8
    }
}

struct PortfolioPane: View {
    @Environment(\.container) private var container
    @State private var holdings: [Holding] = []
    @State private var editing: Holding?
    @State private var deleting: Holding?
    @State private var tradeRequest: PortfolioTradeSheetRequest?
    @State private var showHistory = false
    @State private var selectedID: UUID?
    @State private var dropTargetID: UUID?    // 当前正在被拖入的行 id,用于画 drop indicator

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(L("settings.portfolio", comment: ""))
                    .font(.title3)
                Spacer()
                Button(action: importCSV) {
                    Label(L("action.importCSV", comment: ""), systemImage: "square.and.arrow.down")
                }
                Button(action: exportCSV) {
                    Label(L("action.exportCSV", comment: ""), systemImage: "square.and.arrow.up")
                }
                .disabled(holdings.isEmpty)
                Button(action: { tradeRequest = PortfolioTradeSheetRequest(mode: .buy) }) {
                    Label(L("action.buy", comment: ""), systemImage: "plus")
                }
                Button(action: { showHistory = true }) {
                    Label(L("action.history", comment: ""), systemImage: "clock.arrow.circlepath")
                }
            }

            holdingsList

            if holdings.isEmpty {
                Text(L("holdings.empty", comment: ""))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 20)
            }
        }
        .padding(20)
        .onAppear {
            reload()
            switch SettingsWindowController.pendingAction {
            case .addHolding:
                SettingsWindowController.pendingAction = nil
                tradeRequest = PortfolioTradeSheetRequest(mode: .buy)
            case .editHolding(let id):
                SettingsWindowController.pendingAction = nil
                if let h = holdings.first(where: { $0.id == id }) {
                    editing = h
                }
            default:
                break
            }
        }
        .sheet(item: $tradeRequest) { request in
            PortfolioTradeEditorSheet(request: request, onSaved: {
                tradeRequest = nil
                reload()
                container?.refresher.refreshNow()
            }, onCancel: { tradeRequest = nil })
        }
        .sheet(item: $editing) { existing in
            HoldingEditorSheet(initial: existing, onSaved: {
                editing = nil
                reload()
                container?.refresher.refreshNow()
            }, onCancel: { editing = nil })
        }
        .sheet(isPresented: $showHistory) {
            PortfolioHistorySheet(holding: nil, onCancel: {
                showHistory = false
            })
        }
        .alert(
            String(format: L("delete.confirm.title", comment: ""), deleting?.name ?? ""),
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
        ) {
            Button(L("action.cancel", comment: ""), role: .cancel) { deleting = nil }
            Button(L("action.delete", comment: ""), role: .destructive) {
                if let h = deleting {
                    try? container?.portfolioOperations.deleteHoldingAndHistory(id: h.id)
                    reload()
                    container?.refresher.refreshNow()
                }
                deleting = nil
            }
        } message: {
            Text(L("delete.confirm.body", comment: ""))
        }
    }

    private func reload() {
        holdings = (try? container?.holdingsRepo.all()) ?? []
    }

    /// 设置页沿用券商式“动态成本”展示,但不改写 Holding 中用于账本
    /// 和后续交易的真实加权平均成本。
    private func adjustedCostPrice(for holding: Holding) -> Decimal {
        guard let container,
              let transactions = try? container.transactionsRepo.all(for: holding.id),
              let summary = try? PortfolioLedger.replay(transactions),
              summary.quantity > 0 else {
            return holding.costPrice
        }
        return summary.adjustedCostPrice
    }

    /// 之前用 SwiftUI List + .onMove + selection 在 macOS 反复踩 bug(选中不高亮、
    /// 第二次拖不动)。改成 ScrollView + LazyVStack 手撸,行为完全自己控制。
    /// 拖拽:.draggable(行 ID)+ .dropDestination(整行作为放置目标)。
    /// 选中:单击置 selectedID,改背景色。
    private var holdingsList: some View {
        GeometryReader { proxy in
            let nameHeader = L("col.name", comment: "")
            let columns = PortfolioColumnWidths(totalWidth: proxy.size.width, holdings: holdings, nameHeader: nameHeader)

            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: columns.spacing) {
                        Text("").frame(width: columns.drag)
                        Text(L("col.symbol", comment: "")).frame(width: columns.symbol, alignment: .leading)
                        Text(nameHeader).frame(width: columns.name, alignment: .leading)
                        Text(L("col.market", comment: "")).frame(width: columns.market, alignment: .leading)
                        Text(L("col.qty", comment: "")).frame(width: columns.quantity, alignment: .center)
                        Text(L("col.cost", comment: "")).frame(width: columns.cost, alignment: .center)
                        Text(L("col.createdAt", comment: "")).frame(width: columns.createdAt, alignment: .center)
                        Text("").frame(width: columns.actions)
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, columns.horizontalPadding)
                    .padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.08))

                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(Array(holdings.enumerated()), id: \.element.id) { index, h in
                                holdingRow(h, index: index, isAlternate: index.isMultiple(of: 2), columns: columns)
                            }
                        }
                    }
                    .background(Color(NSColor.controlBackgroundColor))
                    .overlay(
                        RoundedRectangle(cornerRadius: 4)
                            .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
                    )
                }
                .frame(width: columns.contentWidth, height: proxy.size.height, alignment: .topLeading)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .topLeading)
            .clipped()
        }
        .frame(minHeight: 260)
    }

    @ViewBuilder
    private func holdingRow(_ h: Holding, index: Int, isAlternate: Bool, columns: PortfolioColumnWidths) -> some View {
        let isSelected = selectedID == h.id
        let isDropTarget = dropTargetID == h.id
        let displayCostPrice = adjustedCostPrice(for: h)

        HStack(spacing: columns.spacing) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11))
                .foregroundColor(.secondary.opacity(0.55))
                .frame(width: columns.drag)
                .help(L("action.dragToReorder", comment: ""))
            Text(h.symbol.market == .us ? h.symbol.code.uppercased() : h.symbol.code)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.85)
                .frame(width: columns.symbol, alignment: .leading)
            Text(h.name)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: columns.name, alignment: .leading)
            Text(h.symbol.market.displayName)
                .lineLimit(1)
                .frame(width: columns.market, alignment: .leading)
                .foregroundColor(.secondary)
            Text(quantityText(h.quantity))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: columns.quantity, alignment: .center)
            Text(h.currency.format(displayCostPrice, fractionDigits: 3))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: columns.cost, alignment: .center)
            Text(createdAtText(h.createdAt))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(width: columns.createdAt, alignment: .center)
                .foregroundColor(.secondary)
            HStack(spacing: 4) {
                Button { editing = h } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .help(L("action.edit", comment: ""))
                Menu {
                    PortfolioHoldingActionItems(
                        includeOpenInBrowser: false,
                        onTrade: { mode in
                            tradeRequest = PortfolioTradeSheetRequest(mode: mode, holding: h)
                        },
                        onHistory: {
                            tradeRequest = nil
                            showHistory = true
                        },
                        onEdit: { editing = h },
                        onOpenInBrowser: { }
                    )
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.secondary)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .tint(.secondary)
                .help(L("action.more", comment: ""))
                Button(role: .destructive) {
                    deleting = h
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
                // 拖拽时在目标行顶部画一条蓝色横线作 drop indicator
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: 2)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { editing = h }
        .onTapGesture { selectedID = h.id }
        .draggable(h.id.uuidString) {
            // 拖拽时的预览(浮起来的那个小卡片)
            HStack(spacing: 6) {
                Image(systemName: "line.3.horizontal")
                Text(h.name).bold()
            }
            .padding(8)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        }
        .dropDestination(for: String.self) { droppedIDs, _ in
            handleDrop(droppedIDs: droppedIDs, ontoIndex: index)
        } isTargeted: { hovering in
            dropTargetID = hovering ? h.id : (dropTargetID == h.id ? nil : dropTargetID)
        }
        .contextMenu {
            PortfolioHoldingActionItems(
                includeOpenInBrowser: false,
                onTrade: { mode in
                    tradeRequest = PortfolioTradeSheetRequest(mode: mode, holding: h)
                },
                onHistory: {
                    tradeRequest = nil
                    showHistory = true
                },
                onEdit: { editing = h },
                onOpenInBrowser: { }
            )
        }
    }

    private func rowBackground(isSelected: Bool, isAlternate: Bool) -> Color {
        if isSelected { return Color.accentColor.opacity(0.20) }
        return isAlternate ? Color.secondary.opacity(0.05) : Color.clear
    }

    private func quantityText(_ value: Decimal) -> String {
        DecimalFormatting.string(
            value,
            minimumFractionDigits: 0,
            maximumFractionDigits: 6,
            usesGroupingSeparator: true
        ) ?? NSDecimalNumber(decimal: value).stringValue
    }

    private func createdAtText(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        return String(
            format: "%04d-%02d-%02d %02d:%02d",
            parts.year ?? 0,
            parts.month ?? 0,
            parts.day ?? 0,
            parts.hour ?? 0,
            parts.minute ?? 0
        )
    }

    /// 把 droppedIDs(UUID string)对应的行移到 ontoIndex 位置,持久化新 sortOrder。
    private func handleDrop(droppedIDs: [String], ontoIndex target: Int) -> Bool {
        guard let firstStr = droppedIDs.first,
              let firstID = UUID(uuidString: firstStr),
              let sourceIndex = holdings.firstIndex(where: { $0.id == firstID }),
              sourceIndex != target else { return false }
        let item = holdings.remove(at: sourceIndex)
        // 移除后,target 索引可能因为前面少了一个元素需要回退一位
        let insertAt = sourceIndex < target ? target - 1 : target
        holdings.insert(item, at: insertAt)
        let ids = holdings.map { $0.id }
        try? container?.holdingsRepo.reorder(ids: ids)
        return true
    }

    private func exportCSV() {
        let csv = CSVPortfolioIO.exportHoldings(holdings)
        CSVPortfolioIO.presentExportPanel(suggestedName: "stockbar-holdings.csv", content: csv)
    }

    private func importCSV() {
        CSVPortfolioIO.presentImportPanel { text in
            guard let text = text else { return }
            let imported = CSVPortfolioIO.importHoldings(text)
            for h in imported {
                _ = try? container?.portfolioOperations.recordImportedHolding(h)
            }
            reload()
            container?.refresher.refreshNow()
        }
    }
}

private struct HoldingEditorSheet: View {
    @Environment(\.container) private var container
    let initial: Holding
    var onSaved: () -> Void
    var onCancel: () -> Void

    @State private var name = ""
    @State private var note = ""
    @State private var inTicker = true
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("holdings.editTitle", comment: ""))
                .font(.title3)

            Form {
                LabeledContent(L("col.symbol", comment: "")) {
                    Text(displayCode(initial.symbol)).monospacedDigit()
                }
                LabeledContent(L("col.market", comment: "")) {
                    Text(initial.symbol.market.displayName)
                }
                LabeledContent(L("col.qty", comment: "")) {
                    Text(decimalText(initial.quantity)).monospacedDigit()
                }
                LabeledContent(L("col.cost", comment: "")) {
                    Text(initial.currency.format(displayCostPrice, fractionDigits: 3)).monospacedDigit()
                }
                TextField(L("col.name", comment: ""), text: $name)
                    .textFieldStyle(.roundedBorder)
                TextField(L("holding.note", comment: ""), text: $note)
                    .textFieldStyle(.roundedBorder)
                Toggle(L("holding.inTicker", comment: ""), isOn: $inTicker)
            }

            if let error {
                Text(error).foregroundColor(.red).font(.caption)
            }

            HStack {
                Spacer()
                Button(L("action.cancel", comment: ""), action: onCancel)
                Button(L("action.save", comment: ""), action: save)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear(perform: prefill)
    }

    private func prefill() {
        name = initial.name
        note = initial.note ?? ""
        inTicker = initial.inTicker
    }

    private var displayCostPrice: Decimal {
        guard let container,
              let transactions = try? container.transactionsRepo.all(for: initial.id),
              let summary = try? PortfolioLedger.replay(transactions),
              summary.quantity > 0 else {
            return initial.costPrice
        }
        return summary.adjustedCostPrice
    }

    private func save() {
        guard let container else {
            error = L("error.operationUnavailable", comment: "")
            return
        }
        var updated = initial
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.name = trimmedName.isEmpty ? initial.symbol.code : trimmedName
        let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.note = trimmedNote.isEmpty ? nil : trimmedNote
        updated.inTicker = inTicker
        do {
            // 资料编辑只更新名称、备注和菜单栏显示，不触碰数量/成本/标的。
            try container.holdingsRepo.updateMetadata(from: updated)
            onSaved()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func decimalText(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }

    private func displayCode(_ symbol: SymbolID) -> String {
        symbol.market == .us ? symbol.code.uppercased() : symbol.code
    }
}
