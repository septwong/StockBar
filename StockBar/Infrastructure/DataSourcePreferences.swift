import Foundation
import Combine

/// 包装 provider 优先级 + Finnhub Key。普通偏好写入数据库，凭据写入 Keychain。
@MainActor
final class DataSourcePreferences: ObservableObject {
    @Published var preferences: [Market: ProviderPreference]
    @Published var finnhubKey: String {
        didSet {
            if oldValue != finnhubKey {
                do {
                    try secrets.set(finnhubKey, for: Keys.finnhubKey)
                } catch {
                    Log.app.error("saving Finnhub credential failed: \(String(describing: error), privacy: .public)")
                }
                onFinnhubKeyChange?(finnhubKey)
            }
        }
    }

    var onPreferencesChange: (([Market: ProviderPreference]) -> Void)?
    var onFinnhubKeyChange: ((String) -> Void)?

    private let repo: SettingsRepository
    private let secrets: SecretStoring

    enum Keys {
        static let providerPrefs = "provider_prefs"
        static let finnhubKey = "finnhub_api_key"
    }

    init(repo: SettingsRepository, secrets: SecretStoring = KeychainSecretStore()) {
        self.repo = repo
        self.secrets = secrets
        // 加载 prefs
        if let json = repo.string(Keys.providerPrefs),
           let data = json.data(using: .utf8),
           let decoded = try? JSONDecoder().decode([String: ProviderPreference].self, from: data) {
            var loaded: [Market: ProviderPreference] = [:]
            for (k, v) in decoded {
                if let m = Market(rawValue: k) { loaded[m] = v }
            }
            // 用默认值补全缺失市场
            for market in Market.allCases where loaded[market] == nil {
                loaded[market] = ProviderPreference.defaults[market]
            }
            self.preferences = loaded
        } else {
            self.preferences = ProviderPreference.defaults
        }
        let legacyKey = repo.string(Keys.finnhubKey)
        do {
            if let stored = try secrets.string(for: Keys.finnhubKey) {
                self.finnhubKey = stored
            } else if let legacyKey, !legacyKey.isEmpty {
                try secrets.set(legacyKey, for: Keys.finnhubKey)
                self.finnhubKey = legacyKey
            } else {
                self.finnhubKey = ""
            }
            if legacyKey != nil { try repo.remove(Keys.finnhubKey) }
        } catch {
            self.finnhubKey = legacyKey ?? ""
            Log.app.error("migrating Finnhub credential failed: \(String(describing: error), privacy: .public)")
        }
    }

    func importLegacyFinnhubKey(_ key: String?) throws {
        guard let key, !key.isEmpty else { return }
        try secrets.set(key, for: Keys.finnhubKey)
        finnhubKey = key
    }

    func updatePreferences(_ prefs: [Market: ProviderPreference]) {
        self.preferences = prefs
        persist()
        onPreferencesChange?(prefs)
    }

    private func persist() {
        let encoded = preferences.reduce(into: [String: ProviderPreference]()) { acc, kv in
            acc[kv.key.rawValue] = kv.value
        }
        if let data = try? JSONEncoder().encode(encoded),
           let json = String(data: data, encoding: .utf8) {
            try? repo.set(Keys.providerPrefs, json)
        }
    }
}
