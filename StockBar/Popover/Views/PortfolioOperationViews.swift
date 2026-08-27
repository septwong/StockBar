import SwiftUI

enum PortfolioTradeMode: String {
    case buy
    case sell
    case clear
    case adjust

    var titleKey: String {
        switch self {
        case .buy: return "trade.buyTitle"
        case .sell: return "trade.sellTitle"
        case .clear: return "trade.clearTitle"
        case .adjust: return "trade.adjustTitle"
        }
    }

    var actionKey: String {
        switch self {
        case .buy: return "action.buy"
        case .sell: return "action.sell"
        case .clear: return "action.clear"
        case .adjust: return "action.adjust"
        }
    }
}

struct PortfolioTradeSheetRequest: Identifiable {
    let id = UUID()
    let mode: PortfolioTradeMode
    let holding: Holding?

    init(mode: PortfolioTradeMode, holding: Holding? = nil) {
        self.mode = mode
        self.holding = holding
    }
}

/// Shared action list used by both the context menu and the visible action
/// button on a holding row.
struct PortfolioHoldingActionItems: View {
    let includeOpenInBrowser: Bool
    let onTrade: (PortfolioTradeMode) -> Void
    let onHistory: () -> Void
    let onEdit: () -> Void
    let onOpenInBrowser: () -> Void

    var body: some View {
        Button(L("action.buy", comment: "")) { onTrade(.buy) }
        Button(L("action.sell", comment: "")) { onTrade(.sell) }
        Button(L("action.clear", comment: "")) { onTrade(.clear) }
        Button(L("action.history", comment: ""), action: onHistory)
        Button(L("action.adjust", comment: "")) { onTrade(.adjust) }
        Divider()
        Button(L("action.edit", comment: ""), action: onEdit)
        if includeOpenInBrowser {
            Button(L("action.openInBrowser", comment: ""), action: onOpenInBrowser)
        }
    }
}

struct PortfolioTradeEditorSheet: View {
    @Environment(\.container) private var container

    let request: PortfolioTradeSheetRequest
    var onSaved: () -> Void
    var onCancel: () -> Void

    @State private var market: Market = .a
    @State private var code = ""
    @State private var name = ""
    @State private var quantity = ""
    @State private var price = ""
    @State private var fee = "0"
    @State private var occurredAt = Date()
    @State private var note = ""
    @State private var error: String?
    @State private var showingClearConfirmation = false

    @StateObject private var searchVM = SymbolSearchViewModel()

    private var mode: PortfolioTradeMode { request.mode }
    private var holding: Holding? { request.holding }
    private var isNewBuy: Bool { mode == .buy && holding == nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L(mode.titleKey, comment: "Portfolio operation title"))
                .font(.title3)

            if isNewBuy {
                SymbolSearchField(vm: searchVM, onPick: { result in
                    market = result.symbol.market
                    code = result.symbol.code
                    name = result.name
                    if let quote = container?.refresher.quotes[result.symbol] {
                        price = decimalText(quote.price)
                    }
                })
            }

            Form {
                if isNewBuy {
                    Picker(L("col.market", comment: ""), selection: $market) {
                        ForEach(Market.allCases, id: \.self) { item in
                            Text(item.displayName).tag(item)
                        }
                    }
                    TextField(L("col.symbol", comment: ""), text: $code)
                        .textFieldStyle(.roundedBorder)
                    TextField(L("col.name", comment: ""), text: $name)
                        .textFieldStyle(.roundedBorder)
                } else if let holding {
                    LabeledContent(L("col.symbol", comment: "")) {
                        Text(displayCode(holding.symbol))
                            .monospacedDigit()
                    }
                    LabeledContent(L("col.name", comment: "")) {
                        Text(holding.name)
                            .lineLimit(1)
                    }
                }

                if mode == .adjust {
                    TextField(L("trade.targetQuantity", comment: ""), text: $quantity)
                        .textFieldStyle(.roundedBorder)
                    TextField(L("trade.targetCost", comment: ""), text: $price)
                        .textFieldStyle(.roundedBorder)
                } else {
                    if mode == .clear, let holding {
                        LabeledContent(L("trade.quantity", comment: "")) {
                            Text(decimalText(holding.quantity))
                                .monospacedDigit()
                        }
                    } else {
                        TextField(L("trade.quantity", comment: ""), text: $quantity)
                            .textFieldStyle(.roundedBorder)
                    }
                    TextField(L("trade.price", comment: ""), text: $price)
                        .textFieldStyle(.roundedBorder)
                    TextField(L("trade.fee", comment: ""), text: $fee)
                        .textFieldStyle(.roundedBorder)
                }

                DatePicker(
                    L("trade.occurredAt", comment: ""),
                    selection: $occurredAt,
                    displayedComponents: [.date, .hourAndMinute]
                )
                TextField(L("trade.note", comment: ""), text: $note)
                    .textFieldStyle(.roundedBorder)
            }
            .environment(\.calendar, marketCalendar)

            if let error {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
            }

            HStack {
                Spacer()
                Button(L("action.cancel", comment: ""), action: onCancel)
                Button(L(mode.actionKey, comment: ""), action: save)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear {
            prefill()
            searchVM.bind(container?.symbolSearch)
        }
        .alert(
            L("trade.clearConfirmTitle", comment: ""),
            isPresented: $showingClearConfirmation
        ) {
            Button(L("action.cancel", comment: ""), role: .cancel) { }
            Button(L("action.clear", comment: ""), role: .destructive) {
                executeSave()
            }
        } message: {
            Text(L("trade.clearConfirmBody", comment: ""))
        }
    }

    private var marketCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = market.timeZone
        return calendar
    }

    private func prefill() {
        guard let holding else {
            occurredAt = Date()
            return
        }
        market = holding.symbol.market
        code = holding.symbol.code
        name = holding.name
        let quotePrice = container?.refresher.quotes[holding.symbol]?.price ?? holding.costPrice
        quantity = decimalText(mode == .clear ? holding.quantity : holding.quantity)
        price = decimalText(mode == .adjust ? holding.costPrice : quotePrice)
        fee = "0"
        occurredAt = Date()
    }

    private func save() {
        if mode == .clear {
            showingClearConfirmation = true
        } else {
            executeSave()
        }
    }

    private func executeSave() {
        guard let container else {
            error = L("error.operationUnavailable", comment: "")
            return
        }

        let trimmedCode = code.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCode.isEmpty else {
            error = L("error.codeRequired", comment: "")
            return
        }

        do {
            switch mode {
            case .buy:
                guard let qty = decimal(from: quantity), qty > 0 else {
                    throw PortfolioOperationError.invalidQuantity
                }
                guard let executionPrice = decimal(from: price), executionPrice > 0 else {
                    throw PortfolioOperationError.invalidPrice
                }
                let totalFee = try feeValue()
                _ = try container.portfolioOperations.buy(
                    symbol: SymbolID(code: trimmedCode, market: market),
                    name: name.trimmingCharacters(in: .whitespacesAndNewlines),
                    quantity: qty,
                    price: executionPrice,
                    fee: totalFee,
                    occurredAt: occurredAt,
                    note: normalizedNote
                )
            case .sell:
                guard let holding else { throw PortfolioOperationError.noHolding }
                guard let qty = decimal(from: quantity), qty > 0 else {
                    throw PortfolioOperationError.invalidQuantity
                }
                guard let executionPrice = decimal(from: price), executionPrice > 0 else {
                    throw PortfolioOperationError.invalidPrice
                }
                _ = try container.portfolioOperations.sell(
                    holdingID: holding.id,
                    quantity: qty,
                    price: executionPrice,
                    fee: try feeValue(),
                    occurredAt: occurredAt,
                    note: normalizedNote
                )
            case .clear:
                guard let holding else { throw PortfolioOperationError.noHolding }
                guard let executionPrice = decimal(from: price), executionPrice > 0 else {
                    throw PortfolioOperationError.invalidPrice
                }
                _ = try container.portfolioOperations.clear(
                    holdingID: holding.id,
                    price: executionPrice,
                    fee: try feeValue(),
                    occurredAt: occurredAt,
                    note: normalizedNote
                )
            case .adjust:
                guard let holding else { throw PortfolioOperationError.noHolding }
                guard let targetQuantity = decimal(from: quantity), targetQuantity >= 0 else {
                    throw PortfolioOperationError.invalidQuantity
                }
                guard let targetCost = decimal(from: price), targetCost > 0 else {
                    throw PortfolioOperationError.invalidPrice
                }
                _ = try container.portfolioOperations.adjust(
                    holdingID: holding.id,
                    targetQuantity: targetQuantity,
                    targetCostPrice: targetCost,
                    occurredAt: occurredAt,
                    note: normalizedNote
                )
            }
            onSaved()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private var normalizedNote: String? {
        let value = note.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func feeValue() throws -> Decimal {
        guard let value = decimal(from: fee), value >= 0 else {
            throw PortfolioOperationError.invalidFee
        }
        return value
    }

    private func decimal(from text: String) -> Decimal? {
        Decimal(string: text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func decimalText(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }

    private func displayCode(_ symbol: SymbolID) -> String {
        symbol.market == .us ? symbol.code.uppercased() : symbol.code
    }
}

struct PortfolioHistorySheet: View {
    @Environment(\.container) private var container

    /// nil shows the compact global history entry available from Settings;
    /// a value shows only the selected holding's history.
    let holding: Holding?
    var onCancel: () -> Void

    @State private var entries: [PortfolioTransactionEntry] = []
    @State private var error: String?
    @State private var editingFeeTransaction: PortfolioTransaction?
    @State private var deletingEntry: PortfolioTransactionEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(holding.map { String(format: L("trade.historyFor", comment: ""), $0.name) }
                 ?? L("trade.history", comment: ""))
                .font(.title3)

            if let error {
                Text(error).foregroundColor(.red).font(.caption)
            } else if entries.isEmpty {
                Text(L("trade.historyEmpty", comment: ""))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(entries) { entry in
                            historyRow(entry)
                            Divider().opacity(0.45)
                        }
                    }
                }
                .frame(maxHeight: 340)
            }

            HStack {
                Spacer()
                Button(L("action.ok", comment: ""), action: onCancel)
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(24)
        .frame(width: 460)
        .onAppear(perform: load)
        .sheet(item: $editingFeeTransaction) { transaction in
            PortfolioFeeEditorSheet(transaction: transaction, onSaved: {
                editingFeeTransaction = nil
                load()
                container?.refresher.refreshNow()
            }, onCancel: {
                editingFeeTransaction = nil
            })
        }
        .alert(item: $deletingEntry) { entry in
            SwiftUI.Alert(
                title: Text(L("trade.deleteTitle", comment: "")),
                message: Text(L("trade.deleteBody", comment: "")),
                primaryButton: .destructive(Text(L("action.delete", comment: ""))) {
                    delete(entry)
                },
                secondaryButton: .cancel(Text(L("action.cancel", comment: "")))
            )
        }
    }

    private func load() {
        guard let container else { return }
        do {
            let transactions: [PortfolioTransaction]
            if let holding {
                transactions = try container.transactionsRepo.all(for: holding.id)
            } else {
                transactions = try container.transactionsRepo.all()
            }
            let grouped = Dictionary(grouping: transactions, by: \.holdingID)
            entries = grouped.values
                .flatMap { (try? PortfolioLedger.replay(Array($0)).entries) ?? [] }
                .sorted { $0.transaction.occurredAt > $1.transaction.occurredAt }
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func historyRow(_ entry: PortfolioTransactionEntry) -> some View {
        let transaction = entry.transaction
        return VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Text(transactionTypeName(transaction.type))
                    .font(.system(size: 12, weight: .semibold))
                if holding == nil {
                    Text(displayCode(transaction.symbol))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text(formatDate(transaction.occurredAt, market: transaction.symbol.market))
                    .font(.caption)
                    .foregroundColor(.secondary)
                Button {
                    deletingEntry = entry
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .foregroundColor(.secondary)
                .help(L("action.delete", comment: ""))
                .accessibilityLabel(L("action.delete", comment: ""))
            }
            HStack(spacing: 8) {
                Text(String(format: L("trade.historyQuantity", comment: ""), decimalText(transaction.quantity)))
                Text(String(format: L("trade.historyPrice", comment: ""), transaction.currency.format(transaction.price)))
                if canEditFee(transaction.type) {
                    Text(String(format: L("trade.historyFee", comment: ""), transaction.currency.format(transaction.fee)))
                    Text(feeStatusName(transaction.feeStatus))
                        .foregroundColor(.secondary)
                }
                if entry.realizedPnL != 0 {
                    Text(String(format: L("trade.historyRealized", comment: ""), transaction.currency.format(entry.realizedPnL)))
                        .foregroundColor(entry.realizedPnL >= 0 ? .green : .red)
                }
            }
            .font(.caption)
            .monospacedDigit()
            if canEditFee(transaction.type) {
                Button(L("action.editFee", comment: "")) {
                    editingFeeTransaction = transaction
                }
                .buttonStyle(.link)
                .font(.caption)
            }
            if let note = transaction.note, !note.isEmpty {
                Text(note).font(.caption2).foregroundColor(.secondary)
            }
        }
    }

    private func delete(_ entry: PortfolioTransactionEntry) {
        guard let container else {
            error = L("error.operationUnavailable", comment: "")
            return
        }
        do {
            _ = try container.portfolioOperations.deleteTransaction(transactionID: entry.transaction.id)
            load()
            container.refresher.refreshNow()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func transactionTypeName(_ type: PortfolioTransactionType) -> String {
        switch type {
        case .openingBalance: return L("trade.typeOpening", comment: "")
        case .buy: return L("action.buy", comment: "")
        case .sell: return L("action.sell", comment: "")
        case .clear: return L("action.clear", comment: "")
        case .adjustment: return L("action.adjust", comment: "")
        }
    }

    private func canEditFee(_ type: PortfolioTransactionType) -> Bool {
        type == .buy || type == .sell || type == .clear
    }

    private func feeStatusName(_ status: PortfolioTransactionFeeStatus) -> String {
        switch status {
        case .estimated: return L("trade.feeStatusEstimated", comment: "")
        case .confirmed: return L("trade.feeStatusConfirmed", comment: "")
        }
    }

    private func formatDate(_ date: Date, market: Market) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = market.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    private func decimalText(_ value: Decimal) -> String {
        NSDecimalNumber(decimal: value).stringValue
    }

    private func displayCode(_ symbol: SymbolID) -> String {
        symbol.market == .us ? symbol.code.uppercased() : symbol.code
    }
}

struct PortfolioFeeEditorSheet: View {
    @Environment(\.container) private var container

    let transaction: PortfolioTransaction
    var onSaved: () -> Void
    var onCancel: () -> Void

    @State private var fee = ""
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(L("trade.editFeeTitle", comment: ""))
                .font(.title3)

            Form {
                LabeledContent(L("col.symbol", comment: "")) {
                    Text(displayCode(transaction.symbol)).monospacedDigit()
                }
                LabeledContent(L("trade.occurredAt", comment: "")) {
                    Text(formatDate(transaction.occurredAt, market: transaction.symbol.market))
                        .monospacedDigit()
                }
                TextField(L("trade.fee", comment: ""), text: $fee)
                    .textFieldStyle(.roundedBorder)
            }

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
        .frame(width: 460)
        .onAppear {
            fee = decimalText(transaction.fee)
        }
    }

    private func save() {
        guard let container else {
            error = L("error.operationUnavailable", comment: "")
            return
        }
        guard let value = Decimal(string: fee.trimmingCharacters(in: .whitespacesAndNewlines)), value >= 0 else {
            error = PortfolioOperationError.invalidFee.localizedDescription
            return
        }
        do {
            _ = try container.portfolioOperations.updateFee(transactionID: transaction.id, fee: value)
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

    private func formatDate(_ date: Date, market: Market) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = market.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
