import Foundation

/// 可供「固定(单股)」模式选择的股票。持仓排在自选前面,同一 SymbolID 只保留一项。
struct SingleQuoteCandidate: Identifiable, Hashable {
    let symbol: SymbolID
    let name: String
    var inTicker: Bool

    var id: SymbolID { symbol }
}

enum SingleQuoteSelection {
    /// 合并持仓和自选,保留各自仓库的顺序,并把重复股票合并为一项。
    /// 重复项优先使用第一次出现的名称,但只要任一来源开启了 ticker 就视为已开启。
    static func candidates(holdings: [Holding], watchlist: [WatchItem]) -> [SingleQuoteCandidate] {
        var result: [SingleQuoteCandidate] = []
        var indexBySymbol: [SymbolID: Int] = [:]

        func append(symbol: SymbolID, name: String, inTicker: Bool) {
            if let index = indexBySymbol[symbol] {
                result[index].inTicker = result[index].inTicker || inTicker
                return
            }
            indexBySymbol[symbol] = result.count
            result.append(SingleQuoteCandidate(symbol: symbol, name: name, inTicker: inTicker))
        }

        for holding in holdings {
            append(symbol: holding.symbol, name: holding.name, inTicker: holding.inTicker)
        }
        for item in watchlist {
            append(symbol: item.symbol, name: item.name, inTicker: item.inTicker)
        }
        return result
    }

    /// 首次使用时优先选择开启 ticker 的股票,否则选择列表第一项。
    static func defaultSymbol(in candidates: [SingleQuoteCandidate]) -> SymbolID? {
        candidates.first(where: \.inTicker)?.symbol ?? candidates.first?.symbol
    }
}
