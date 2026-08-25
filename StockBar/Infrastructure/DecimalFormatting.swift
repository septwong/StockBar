import Foundation

/// NumberFormatter 构造成本较高；按格式缓存并在锁内使用，保证后台提醒与 UI 并发安全。
enum DecimalFormatting {
    private static let lock = NSLock()
    private static var formatters: [String: NumberFormatter] = [:]

    static func string(
        _ value: Decimal,
        minimumFractionDigits: Int,
        maximumFractionDigits: Int,
        usesGroupingSeparator: Bool
    ) -> String? {
        let key = "\(minimumFractionDigits)|\(maximumFractionDigits)|\(usesGroupingSeparator)"
        lock.lock()
        defer { lock.unlock() }
        let formatter: NumberFormatter
        if let cached = formatters[key] {
            formatter = cached
        } else {
            let created = NumberFormatter()
            created.minimumFractionDigits = minimumFractionDigits
            created.maximumFractionDigits = maximumFractionDigits
            created.usesGroupingSeparator = usesGroupingSeparator
            if usesGroupingSeparator { created.groupingSeparator = "," }
            created.numberStyle = .decimal
            formatters[key] = created
            formatter = created
        }
        return formatter.string(from: NSDecimalNumber(decimal: value))
    }
}
