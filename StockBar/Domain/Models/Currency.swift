import Foundation

enum Currency: String, Codable, CaseIterable, Sendable {
    case cny = "CNY"
    case usd = "USD"
    case hkd = "HKD"

    var symbol: String {
        switch self {
        case .cny: return "¥"
        case .usd: return "$"
        case .hkd: return "HK$"
        }
    }

    func format(_ value: Decimal, fractionDigits: Int = 2) -> String {
        let text = DecimalFormatting.string(
            value,
            minimumFractionDigits: fractionDigits,
            maximumFractionDigits: fractionDigits,
            usesGroupingSeparator: true
        ) ?? "\(value)"
        return "\(symbol)\(text)"
    }

    /// 行情价最多显示三位小数，避免 ETF 等品种的实际价格被截成两位。
    /// 普通股票价格没有第三位时仍保持两位显示。
    func formatQuote(_ value: Decimal) -> String {
        let text = DecimalFormatting.string(
            value,
            minimumFractionDigits: 2,
            maximumFractionDigits: 3,
            usesGroupingSeparator: true
        ) ?? "\(value)"
        return "\(symbol)\(text)"
    }
}
