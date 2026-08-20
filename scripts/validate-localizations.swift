#!/usr/bin/env swift
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let catalogURL = root.appendingPathComponent("StockBar/Resources/Localizable.xcstrings")
let sourceRoot = root.appendingPathComponent("StockBar")

let data = try Data(contentsOf: catalogURL)
guard let catalog = try JSONSerialization.jsonObject(with: data) as? [String: Any],
      let entries = catalog["strings"] as? [String: Any] else {
    fputs("Invalid Localizable.xcstrings\n", stderr)
    exit(1)
}

let pattern = try NSRegularExpression(pattern: #"\bL\(\s*\"([^\"]+)\""#)
var usedKeys = Set<String>()
let enumerator = FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: nil)
while let url = enumerator?.nextObject() as? URL {
    guard url.pathExtension == "swift", let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
    let range = NSRange(source.startIndex..., in: source)
    for match in pattern.matches(in: source, range: range) {
        guard let keyRange = Range(match.range(at: 1), in: source) else { continue }
        usedKeys.insert(String(source[keyRange]))
    }
}

var errors: [String] = []
for key in usedKeys.sorted() {
    guard let entry = entries[key] as? [String: Any],
          let localizations = entry["localizations"] as? [String: Any] else {
        errors.append("missing catalog key: \(key)")
        continue
    }
    for language in ["zh-Hans", "en"] {
        guard let localization = localizations[language] as? [String: Any],
              let unit = localization["stringUnit"] as? [String: Any],
              let value = unit["value"] as? String,
              !value.isEmpty else {
            errors.append("missing \(language) translation: \(key)")
            continue
        }
    }
}

if errors.isEmpty {
    print("✓ \(usedKeys.count) localization keys have zh-Hans and en translations")
} else {
    errors.forEach { fputs("✗ \($0)\n", stderr) }
    exit(1)
}
