#!/bin/bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 /path/to/StockBar.app" >&2
    exit 2
fi

app="$1"
framework="$app/Contents/Frameworks/Sparkle.framework"

[[ -d "$app" ]] || { echo "app not found: $app" >&2; exit 1; }
[[ -d "$framework" ]] || { echo "Sparkle.framework not found in app" >&2; exit 1; }

# Sign Sparkle from the innermost helpers outward. Do not use --deep for signing;
# it can overwrite helper-specific entitlements and create invalid updates.
codesign --force --sign - --options runtime "$framework/Versions/B/XPCServices/Installer.xpc"
codesign --force --sign - --options runtime --preserve-metadata=entitlements "$framework/Versions/B/XPCServices/Downloader.xpc"
codesign --force --sign - --options runtime "$framework/Versions/B/Autoupdate"
codesign --force --sign - --options runtime "$framework/Versions/B/Updater.app"
codesign --force --sign - --options runtime "$framework"
codesign --force --sign - --options runtime \
    --entitlements "Config/StockBar-Unsigned.entitlements" "$app"
