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
}
