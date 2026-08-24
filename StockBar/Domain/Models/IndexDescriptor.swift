import Foundation

/// 大盘指数描述符。每个指数自带本地化名 + 双数据源编码 + 货币。
/// 不复用 SymbolID,因为指数代码空间和股票冲突(000001 既可以是平安银行也可以是上证指数)。
struct IndexDescriptor: Identifiable, Hashable, Codable, Sendable {
    let id: String              // "SH000001"
    var nameZh: String
    var nameEn: String
    var market: Market
    var emSecid: String         // "1.000001"
    var tencentCode: String     // "sh000001"
    var currency: Currency

    var displayName: String {
        if Locale.preferredLanguages.first?.hasPrefix("zh") == true {
            return nameZh.isEmpty ? nameEn : nameZh
        }
        return nameEn.isEmpty ? nameZh : nameEn
    }
}

enum IndexCatalog {
    /// 首次安装和“恢复内置指数”使用的默认配置。运行时列表来自 IndexRepository。
    static let defaults: [IndexDescriptor] = [
        IndexDescriptor(id: "SH000001", nameZh: "上证指数",   nameEn: "SSE Composite",  market: .a,  emSecid: "1.000001", tencentCode: "sh000001", currency: .cny),
        IndexDescriptor(id: "SZ399001", nameZh: "深证成指",   nameEn: "SZSE Component", market: .a,  emSecid: "0.399001", tencentCode: "sz399001", currency: .cny),
        IndexDescriptor(id: "SZ399006", nameZh: "创业板指",   nameEn: "ChiNext",        market: .a,  emSecid: "0.399006", tencentCode: "sz399006", currency: .cny),
        IndexDescriptor(id: "SH000300", nameZh: "沪深300",    nameEn: "CSI 300",        market: .a,  emSecid: "1.000300", tencentCode: "sh000300", currency: .cny),
        IndexDescriptor(id: "HSI",      nameZh: "恒生指数",   nameEn: "Hang Seng",      market: .hk, emSecid: "100.HSI",  tencentCode: "hkHSI", currency: .hkd),
        IndexDescriptor(id: "DJIA",     nameZh: "道琼斯",     nameEn: "Dow Jones",      market: .us, emSecid: "100.DJIA", tencentCode: "usDJI", currency: .usd),
        IndexDescriptor(id: "NDX",      nameZh: "纳斯达克100", nameEn: "NASDAQ 100",    market: .us, emSecid: "100.NDX",  tencentCode: "usNDX", currency: .usd),
        IndexDescriptor(id: "SPX",      nameZh: "标普500",    nameEn: "S&P 500",        market: .us, emSecid: "100.SPX",  tencentCode: "usINX", currency: .usd)
    ]

    /// 仅为旧测试和迁移代码保留的兼容别名，生产运行时不使用它作为列表来源。
    static var all: [IndexDescriptor] { defaults }
}

struct IndexQuote: Identifiable, Equatable, Sendable {
    var id: String { descriptor.id }
    let descriptor: IndexDescriptor
    let price: Decimal
    let prevClose: Decimal
    let change: Decimal
    let changePct: Double
}
