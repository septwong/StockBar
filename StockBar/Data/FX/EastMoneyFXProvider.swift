import Foundation

/// 货币对方向:`from → to`,持有 from 1 单位可换 to 多少。
struct FXRate: Equatable, Codable, Sendable {
    let from: Currency
    let to: Currency
    let rate: Decimal
    let asOf: Date
}

protocol FXProvider: Sendable {
    var id: String { get }
    func fetch(pairs: [(Currency, Currency)]) async throws -> [FXRate]
}

extension FXProvider {
    var id: String { String(describing: Self.self) }
}

/// 东方财富外汇接口。
///
/// 只拉 2 个基础对:
///   - USDCNY:`120.USDCNYC`(美元人民币中间价)
///   - HKDCNY:`120.HKDCNYC`(港币人民币中间价)
///
/// 其他所有方向(USD→HKD / CNY→USD / CNY→HKD / HKD→USD 等)
/// 在 FXService 里用 CNY 作枢轴换算。
struct EastMoneyFXProvider: FXProvider {
    let id = "eastmoney"
    let http: HTTPClient

    init(http: HTTPClient = HTTPClient(defaultHeaders: ["Referer": "https://quote.eastmoney.com/"])) {
        self.http = http
    }

    func fetch(pairs: [(Currency, Currency)]) async throws -> [FXRate] {
        // 只关心需要的基础对(USDCNY, HKDCNY),其它在 FXService 算。
        // 直接全拉,简化逻辑(2 个 secid 而已)。
        var rates: [FXRate] = []
        var firstError: Error?
        for request in [
            ("120.USDCNYC", Currency.usd, Currency.cny),
            ("120.HKDCNYC", Currency.hkd, Currency.cny)
        ] {
            do {
                if let rate = try await fetchSecid(request.0, from: request.1, to: request.2) {
                    rates.append(rate)
                }
            } catch {
                firstError = firstError ?? error
                Log.fx.warning("eastmoney pair \(request.1.rawValue, privacy: .public)/\(request.2.rawValue, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }
        if rates.isEmpty { throw firstError ?? ProviderError.empty }
        return rates
    }

    private func fetchSecid(_ secid: String, from: Currency, to: Currency) async throws -> FXRate? {
        var comps = URLComponents(string: "https://push2.eastmoney.com/api/qt/stock/get")!
        comps.queryItems = [
            URLQueryItem(name: "fltt", value: "2"),
            URLQueryItem(name: "invt", value: "2"),
            URLQueryItem(name: "fields", value: "f43,f57,f58"),
            URLQueryItem(name: "secid", value: secid)
        ]
        guard let url = comps.url else { return nil }
        let data = try await http.fetchData(url: url)

        struct Resp: Decodable {
            let data: Item?
            struct Item: Decodable {
                let f43: Double?
            }
        }
        let resp = try JSONDecoder().decode(Resp.self, from: data)
        guard let raw = resp.data?.f43, raw > 0 else { return nil }
        return FXRate(from: from, to: to, rate: Decimal(raw), asOf: Date())
    }
}

/// 腾讯外汇接口。字段 3 为最新价，字段 5 为北京时间戳。
struct TencentFXProvider: FXProvider {
    let id = "tencent"
    let http: HTTPClient

    init(http: HTTPClient = HTTPClient(defaultHeaders: ["Referer": "https://gu.qq.com/"])) {
        self.http = http
    }

    func fetch(pairs: [(Currency, Currency)]) async throws -> [FXRate] {
        var comps = URLComponents(string: "https://qt.gtimg.cn/")!
        comps.queryItems = [URLQueryItem(name: "q", value: "whUSDCNY,whHKDCNY")]
        guard let url = comps.url else { throw ProviderError.empty }
        let text = try await http.fetchString(url: url, encoding: GBKDecoder.encoding)
        let rates = parse(text)
        let requested = Set(pairs.map { Self.key($0.0, $0.1) })
        let filtered = rates.filter { requested.contains(Self.key($0.from, $0.to)) }
        if filtered.isEmpty { throw ProviderError.empty }
        return filtered
    }

    func parse(_ text: String, asOf: Date = Date()) -> [FXRate] {
        let mapping: [String: (Currency, Currency)] = [
            "whUSDCNY": (.usd, .cny),
            "whHKDCNY": (.hkd, .cny)
        ]
        return text
            .split(whereSeparator: { $0 == "\n" || $0 == ";" })
            .compactMap { raw -> FXRate? in
                let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard line.hasPrefix("v_"), let equals = line.firstIndex(of: "=") else { return nil }
                let code = String(line[line.index(line.startIndex, offsetBy: 2)..<equals])
                guard let pair = mapping[code] else { return nil }
                let value = line[line.index(after: equals)...]
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
                let fields = value.split(separator: "~", omittingEmptySubsequences: false)
                guard fields.count > 3,
                      let rate = Decimal(string: String(fields[3])), rate > 0 else { return nil }
                return FXRate(from: pair.0, to: pair.1, rate: rate, asOf: asOf)
            }
    }

    private static func key(_ from: Currency, _ to: Currency) -> String {
        from.rawValue + to.rawValue
    }
}

/// 免费的日汇率兜底。Frankfurter 返回 USD→CNY 与 USD→HKD，后者用于推导 HKD→CNY。
struct FrankfurterFXProvider: FXProvider {
    let id = "frankfurter"
    let http: HTTPClient

    init(http: HTTPClient = HTTPClient()) {
        self.http = http
    }

    func fetch(pairs: [(Currency, Currency)]) async throws -> [FXRate] {
        var comps = URLComponents(string: "https://api.frankfurter.app/latest")!
        comps.queryItems = [
            URLQueryItem(name: "from", value: "USD"),
            URLQueryItem(name: "to", value: "CNY,HKD")
        ]
        guard let url = comps.url else { throw ProviderError.empty }
        let data = try await http.fetchData(url: url)
        struct Response: Decodable { let rates: [String: Double] }
        let response = try JSONDecoder().decode(Response.self, from: data)
        guard let usdCny = response.rates["CNY"], usdCny > 0,
              let usdHkd = response.rates["HKD"], usdHkd > 0 else {
            throw ProviderError.empty
        }
        let now = Date()
        let available = [
            FXRate(from: .usd, to: .cny, rate: Decimal(usdCny), asOf: now),
            FXRate(from: .hkd, to: .cny, rate: Decimal(usdCny / usdHkd), asOf: now)
        ]
        let requested = Set(pairs.map { $0.0.rawValue + $0.1.rawValue })
        return available.filter { requested.contains($0.from.rawValue + $0.to.rawValue) }
    }
}

/// 按顺序尝试多个汇率源，并用后续数据源补齐前一数据源缺失的货币对。
struct FallbackFXProvider: FXProvider {
    let id = "fallback"
    let providers: [any FXProvider]

    func fetch(pairs: [(Currency, Currency)]) async throws -> [FXRate] {
        var remaining = pairs
        var result: [String: FXRate] = [:]
        var firstError: Error?

        for provider in providers where !remaining.isEmpty {
            do {
                let rates = try await provider.fetch(pairs: remaining)
                for rate in rates {
                    let key = Self.key(rate.from, rate.to)
                    guard result[key] == nil else { continue }
                    result[key] = rate
                }
                remaining.removeAll { result[Self.key($0.0, $0.1)] != nil }
                Log.fx.info("provider=\(provider.id, privacy: .public) ok pairs=\(rates.count, privacy: .public) remaining=\(remaining.count, privacy: .public)")
            } catch {
                firstError = firstError ?? error
                Log.fx.warning("provider=\(provider.id, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            }
        }

        if result.isEmpty { throw firstError ?? ProviderError.empty }
        return pairs.compactMap { result[Self.key($0.0, $0.1)] }
    }

    private static func key(_ from: Currency, _ to: Currency) -> String {
        from.rawValue + to.rawValue
    }
}
