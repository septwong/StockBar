import Foundation

protocol IndexProvider: Sendable {
    var id: String { get }
    func fetch(_ indices: [IndexDescriptor]) async throws -> [IndexQuote]
}

/// 大盘指数协调器。首选腾讯；某个源只返回部分指数时，继续向后补齐。
actor IndexService {
    private let providers: [any IndexProvider]

    init(providers: [any IndexProvider] = [TencentIndexProvider(), EastMoneyIndexProvider()]) {
        self.providers = providers
    }

    func fetchAll(_ indices: [IndexDescriptor] = IndexCatalog.defaults) async throws -> [IndexQuote] {
        guard !indices.isEmpty else { return [] }
        var remaining = indices
        var result: [String: IndexQuote] = [:]
        var firstError: Error?

        for provider in providers where !remaining.isEmpty {
            do {
                let quotes = try await provider.fetch(remaining)
                for quote in quotes where result[quote.id] == nil {
                    result[quote.id] = quote
                }
                remaining.removeAll { result[$0.id] != nil }
                Log.quote.debug("index provider=\(provider.id, privacy: .public) ok items=\(quotes.count, privacy: .public) remaining=\(remaining.count, privacy: .public)")
            } catch {
                firstError = firstError ?? error
                Log.quote.warning("index provider=\(provider.id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }

        if result.isEmpty { throw firstError ?? ProviderError.empty }
        return indices.compactMap { result[$0.id] }
    }
}

struct TencentIndexProvider: IndexProvider {
    let id = "tencent"
    let http: HTTPClient

    init(http: HTTPClient = HTTPClient(defaultHeaders: ["Referer": "https://gu.qq.com/"])) {
        self.http = http
    }

    func fetch(_ indices: [IndexDescriptor]) async throws -> [IndexQuote] {
        guard !indices.isEmpty else { return [] }
        var comps = URLComponents(string: "https://qt.gtimg.cn/")!
        comps.queryItems = [URLQueryItem(name: "q", value: indices.map(\.tencentCode).joined(separator: ","))]
        guard let url = comps.url else { throw ProviderError.empty }
        let text = try await http.fetchString(url: url, encoding: GBKDecoder.encoding)
        let parsed = parse(text, indices: indices)
        if parsed.isEmpty { throw ProviderError.empty }
        return parsed
    }

    func parse(_ text: String, indices: [IndexDescriptor]) -> [IndexQuote] {
        let lookup = Dictionary(uniqueKeysWithValues: indices.map { ($0.tencentCode, $0) })
        var result: [String: IndexQuote] = [:]

        for raw in text.split(whereSeparator: { $0 == "\n" || $0 == ";" }) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("v_"), let equals = line.firstIndex(of: "=") else { continue }
            let code = String(line[line.index(line.startIndex, offsetBy: 2)..<equals])
            guard let descriptor = lookup[code] else { continue }
            let value = line[line.index(after: equals)...]
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let fields = value.split(separator: "~", omittingEmptySubsequences: false).map(String.init)
            guard fields.count > 32,
                  let price = Decimal(string: fields[3]), price > 0,
                  let previous = Decimal(string: fields[4]),
                  let change = Decimal(string: fields[31]),
                  let percent = Double(fields[32]) else { continue }
            result[descriptor.id] = IndexQuote(
                descriptor: descriptor,
                price: price,
                prevClose: previous,
                change: change,
                changePct: percent / 100.0
            )
        }
        return indices.compactMap { result[$0.id] }
    }
}

struct EastMoneyIndexProvider: IndexProvider {
    let id = "eastmoney"
    let http: HTTPClient

    init(http: HTTPClient = HTTPClient(defaultHeaders: ["Referer": "https://quote.eastmoney.com/"])) {
        self.http = http
    }

    func fetch(_ indices: [IndexDescriptor]) async throws -> [IndexQuote] {
        guard !indices.isEmpty else { return [] }
        let secids = indices.map { $0.emSecid }.joined(separator: ",")
        var comps = URLComponents(string: "https://push2.eastmoney.com/api/qt/ulist.np/get")!
        comps.queryItems = [
            URLQueryItem(name: "fltt", value: "2"),
            URLQueryItem(name: "invt", value: "2"),
            URLQueryItem(name: "fields", value: "f2,f3,f4,f12,f13,f14,f18"),
            URLQueryItem(name: "secids", value: secids),
            URLQueryItem(name: "_", value: "\(Int(Date().timeIntervalSince1970 * 1000))")
        ]
        guard let url = comps.url else { throw ProviderError.empty }
        let data = try await http.fetchData(url: url)
        let parsed = try parse(data, indices: indices)
        if parsed.isEmpty { throw ProviderError.empty }
        return parsed
    }

    func parse(_ data: Data, indices: [IndexDescriptor]) throws -> [IndexQuote] {
        struct Response: Decodable {
            let data: Block?
            struct Block: Decodable { let diff: [Item]? }
            struct Item: Decodable {
                let f2: Double?
                let f3: Double?
                let f4: Double?
                let f12: String?
                let f13: Int?
                let f14: String?
                let f18: Double?
            }
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard let items = response.data?.diff else { return [] }

        let lookup = Dictionary(uniqueKeysWithValues: indices.map { ($0.emSecid, $0) })
        var result: [String: IndexQuote] = [:]
        for item in items {
            guard let code = item.f12, let marketID = item.f13,
                  let descriptor = lookup["\(marketID).\(code)"] else { continue }
            result[descriptor.id] = IndexQuote(
                descriptor: descriptor,
                price: Decimal(item.f2 ?? 0),
                prevClose: Decimal(item.f18 ?? 0),
                change: Decimal(item.f4 ?? 0),
                changePct: (item.f3 ?? 0) / 100.0
            )
        }
        return indices.compactMap { result[$0.id] }
    }
}
