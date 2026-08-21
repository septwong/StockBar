import AppKit

/// 菜单栏个股展示共用的文本格式,确保滚动和固定单股模式的名称/价格精度一致。
enum TickerDisplayFormatting {
    static func shortenedName(_ name: String, market: Market) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "" }
        let isChinese = trimmed.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) }
        let limit = isChinese ? 6 : 12
        if trimmed.count <= limit { return trimmed }
        return String(trimmed.prefix(limit)) + "…"
    }

    static func price(_ price: Decimal) -> String {
        let formatter = NumberFormatter()
        formatter.minimumFractionDigits = 2
        formatter.maximumFractionDigits = 2
        return formatter.string(from: NSDecimalNumber(decimal: price)) ?? "\(price)"
    }

    static func percent(_ changePct: Double) -> String {
        let normalized = changePct == 0 ? 0 : changePct
        return String(format: "%+.2f%%", normalized * 100)
    }
}
