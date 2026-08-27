import Foundation
import AppKit
import UniformTypeIdentifiers

/// 备份文件载荷:包含所有持仓 / 自选 / 大盘 / 预警 / 设置。
struct BackupBundle: Codable {
    let schemaVersion: Int
    let exportedAt: Date
    let appVersion: String
    let holdings: [Holding]
    let transactions: [PortfolioTransaction]
    let watchlist: [WatchItem]
    let indices: [IndexDescriptor]
    let alerts: [Alert]
    /// 可移植的非敏感设置。API Key 等凭据永不导出。
    let settings: [String: String]

    static let currentSchemaVersion: Int = 3

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, exportedAt, appVersion, holdings, transactions, watchlist, indices, alerts, settings
    }

    init(
        schemaVersion: Int,
        exportedAt: Date,
        appVersion: String,
        holdings: [Holding],
        transactions: [PortfolioTransaction] = [],
        watchlist: [WatchItem],
        indices: [IndexDescriptor],
        alerts: [Alert],
        settings: [String: String]
    ) {
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.appVersion = appVersion
        self.holdings = holdings
        self.transactions = transactions
        self.watchlist = watchlist
        self.indices = indices
        self.alerts = alerts
        self.settings = settings
    }

    /// v1 备份没有 indices 字段,按首次安装时的内置列表兼容读取。
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try values.decode(Int.self, forKey: .schemaVersion)
        exportedAt = try values.decode(Date.self, forKey: .exportedAt)
        appVersion = try values.decode(String.self, forKey: .appVersion)
        holdings = try values.decode([Holding].self, forKey: .holdings)
        transactions = try values.decodeIfPresent([PortfolioTransaction].self, forKey: .transactions) ?? []
        watchlist = try values.decode([WatchItem].self, forKey: .watchlist)
        indices = try values.decodeIfPresent([IndexDescriptor].self, forKey: .indices) ?? IndexCatalog.defaults
        alerts = try values.decode([Alert].self, forKey: .alerts)
        settings = try values.decode([String: String].self, forKey: .settings)
    }
}

struct ImportSummary {
    let holdingsCount: Int
    let watchlistCount: Int
    let indicesCount: Int
    let alertsCount: Int
    let settingsCount: Int
}

@MainActor
final class BackupService {
    private let container: DependencyContainer

    init(container: DependencyContainer) {
        self.container = container
    }

    // MARK: 导出

    func makeBundle() throws -> BackupBundle {
        let holdings = try container.holdingsRepo.allIncludingClosed()
        let transactions = try container.transactionsRepo.all()
        let watchlist = try container.watchlistRepo.all()
        let indices = try container.indexRepo.all()
        let alerts = try container.alertsRepo.all()
        let settings = Self.sanitizedSettings(try container.settingsRepo.allEntries())
        let version = AppVersion.short
        return BackupBundle(
            schemaVersion: BackupBundle.currentSchemaVersion,
            exportedAt: Date(),
            appVersion: version,
            holdings: holdings,
            transactions: transactions,
            watchlist: watchlist,
            indices: indices,
            alerts: alerts,
            settings: settings
        )
    }

    func encode(_ bundle: BackupBundle) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(bundle)
    }

    // MARK: 导入

    func decode(_ data: Data) throws -> BackupBundle {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(BackupBundle.self, from: data)
    }

    /// 全量替换式导入。会清空当前 holdings / watchlist / alerts / settings 再写入。
    /// 调用方需先用 UI 弹窗确认。
    @discardableResult
    func applyReplace(_ bundle: BackupBundle) throws -> ImportSummary {
        guard bundle.schemaVersion <= BackupBundle.currentSchemaVersion else {
            throw BackupError.unsupportedSchema(bundle.schemaVersion)
        }

        let legacyFinnhubKey = bundle.settings[DataSourcePreferences.Keys.finnhubKey]
        let settings = Self.sanitizedSettings(bundle.settings)
        // Credential storage is outside SQLite. Fail before replacing user data
        // if a legacy backup's secret cannot be saved securely.
        try container.dataSourcePrefs.importLegacyFinnhubKey(legacyFinnhubKey)

        // One pool write is one SQLite transaction. Any insert failure restores
        // every table instead of leaving a partially imported portfolio.
        try container.database.dbPool.write { db in
            try container.holdingsRepo.replaceAll(bundle.holdings, in: db)
            let transactions = bundle.transactions.isEmpty
                ? bundle.holdings.map(Self.openingTransaction(for:))
                : bundle.transactions
            try container.transactionsRepo.replaceAll(transactions, in: db)
            try container.watchlistRepo.replaceAll(bundle.watchlist, in: db)
            try container.indexRepo.replaceAll(bundle.indices, in: db)
            try container.alertsRepo.replaceAll(bundle.alerts, in: db)
            try container.settingsRepo.replaceAll(settings, in: db)
        }
        return ImportSummary(
            holdingsCount: bundle.holdings.count,
            watchlistCount: bundle.watchlist.count,
            indicesCount: bundle.indices.count,
            alertsCount: bundle.alerts.count,
            settingsCount: settings.count
        )
    }

    static func sanitizedSettings(_ settings: [String: String]) -> [String: String] {
        var result = settings
        result.removeValue(forKey: DataSourcePreferences.Keys.finnhubKey)
        return result
    }

    private static func openingTransaction(for holding: Holding) -> PortfolioTransaction {
        PortfolioTransaction(
            holdingID: holding.id,
            symbol: holding.symbol,
            name: holding.name,
            type: .openingBalance,
            quantity: holding.quantity,
            price: holding.costPrice,
            currency: holding.currency,
            occurredAt: holding.createdAt,
            recordedAt: holding.createdAt,
            note: holding.note
        )
    }

    // MARK: NSPanel 工具

    func presentExportPanel() {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyyMMdd-HHmm"
        let suggested = "stockbar-backup-\(fmt.string(from: Date())).json"
        let panel = NSSavePanel()
        panel.title = L("backup.exportTitle", comment: "")
        panel.nameFieldStringValue = suggested
        if let json = UTType(filenameExtension: "json") {
            panel.allowedContentTypes = [json]
        }
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let bundle = try makeBundle()
                let data = try encode(bundle)
                try data.write(to: url)
                showExportDoneAlert(bundle: bundle, fileURL: url)
            } catch {
                showError(error)
            }
        }
    }

    private func showExportDoneAlert(bundle: BackupBundle, fileURL: URL) {
        let alert = NSAlert()
        alert.messageText = L("backup.exported.title", comment: "")
        alert.informativeText = String(
            format: L("backup.exported.body", comment: ""),
            bundle.holdings.count,
            bundle.watchlist.count,
            bundle.indices.count,
            bundle.alerts.count,
            bundle.settings.count
        ) + "\n\n" + fileURL.path
        alert.alertStyle = .informational
        alert.addButton(withTitle: L("action.ok", comment: ""))
        alert.addButton(withTitle: L("backup.revealInFinder", comment: ""))
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.activateFileViewerSelecting([fileURL])
        }
    }

    func presentImportPanel(onSuccess: @escaping (ImportSummary) -> Void) {
        let panel = NSOpenPanel()
        panel.title = L("backup.importTitle", comment: "")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        if let json = UTType(filenameExtension: "json") {
            panel.allowedContentTypes = [json]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try Data(contentsOf: url)
            let bundle = try decode(data)
            // 二次确认
            let confirm = NSAlert()
            confirm.messageText = L("backup.confirmReplace.title", comment: "")
            confirm.informativeText = String(
                format: L("backup.confirmReplace.body", comment: ""),
                bundle.holdings.count, bundle.watchlist.count, bundle.indices.count,
                bundle.alerts.count, bundle.settings.count
            )
            confirm.alertStyle = .warning
            confirm.addButton(withTitle: L("backup.confirmReplace.yes", comment: ""))
            confirm.addButton(withTitle: L("action.cancel", comment: ""))
            guard confirm.runModal() == .alertFirstButtonReturn else { return }
            let summary = try applyReplace(bundle)
            onSuccess(summary)
        } catch {
            showError(error)
        }
    }

    private func showError(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = L("backup.error.title", comment: "")
        alert.informativeText = "\(error)"
        alert.alertStyle = .critical
        alert.addButton(withTitle: L("action.ok", comment: ""))
        alert.runModal()
    }
}

enum BackupError: Error, LocalizedError {
    case unsupportedSchema(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let v):
            return "Unsupported backup schema version: \(v)"
        }
    }
}
