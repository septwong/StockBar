# StockBar local build and release helpers

SHELL := /bin/bash
PROJECT := StockBar.xcodeproj
SCHEME := StockBar
DERIVED := build/dd
SOURCE_PACKAGES := build/SourcePackages
PACKAGE_ARGS := -clonedSourcePackagesDirPath $(SOURCE_PACKAGES) -disablePackageRepositoryCache
APP_NAME := StockBar
DEV_APP_NAME := StockBar-Dev
DEV_BUNDLE_ID := vip.eztool.StockBar.debug
DEV_APP_PATH := $(DERIVED)/Build/Products/Debug/$(DEV_APP_NAME).app
VERSION ?= 1.0.5
BUILD_NUMBER ?= 6
ARCHS ?= arm64 x86_64
BUILD_DIR := build/Release
ARCHIVE_PATH := build/$(APP_NAME).xcarchive
APP_PATH := $(BUILD_DIR)/$(APP_NAME).app
DMG_PATH := build/$(APP_NAME)-$(VERSION).dmg
ZIP_PATH := build/$(APP_NAME)-$(VERSION).zip
CHECKSUM_PATH := build/SHA256SUMS.txt
UPDATE_DIR := build/updates
SPARKLE_BIN := $(SOURCE_PACKAGES)/artifacts/sparkle/Sparkle/bin
RELEASE_TAG := v$(VERSION)
RELEASE_URL := https://github.com/septwong/StockBar/releases/download/$(RELEASE_TAG)/

.PHONY: help
help:
	@echo "StockBar build targets:"
	@echo "  make build             # Debug build"
	@echo "  make test              # Unit tests"
	@echo "  make localization-check # Validate manually maintained strings"
	@echo "  make run               # Build and launch StockBar-Dev"
	@echo "  make release-build     # Universal, ad-hoc signed Release app"
	@echo "  make package           # ZIP + DMG + signed appcast + checksums"
	@echo "  make verify-release    # Validate the local release artifacts"
	@echo "  make publish           # Create and publish a GitHub Release"

.PHONY: resolve
resolve:
	xcodebuild -resolvePackageDependencies -project $(PROJECT) -scheme $(SCHEME) $(PACKAGE_ARGS)

.PHONY: build
build: resolve
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -derivedDataPath $(DERIVED) $(PACKAGE_ARGS) CODE_SIGNING_ALLOWED=NO build

.PHONY: test
test: resolve
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -derivedDataPath $(DERIVED) $(PACKAGE_ARGS) -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test

.PHONY: localization-check
localization-check:
	swift scripts/validate-localizations.swift

.PHONY: run
run:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -derivedDataPath $(DERIVED) $(PACKAGE_ARGS) CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="-" build
	@pkill -f "$(DEV_APP_NAME).app/Contents/MacOS" 2>/dev/null; true
	open $(DEV_APP_PATH)
	@echo "✓ Launched $(DEV_APP_NAME) ($(DEV_BUNDLE_ID))"

.PHONY: open
open:
	open $(PROJECT)

.PHONY: kill
kill:
	@pkill -f "$(DEV_APP_NAME).app/Contents/MacOS" && echo "✓ Killed $(DEV_APP_NAME)" || echo "(not running)"

.PHONY: icons
icons:
	swift scripts/generate-icons.swift

.PHONY: release-build
release-build: resolve
	@test "$(VERSION)" = "$$(printf '%s' "$(VERSION)" | sed -E 's/^v//')" || (echo "✗ VERSION must not include a v prefix" && exit 1)
	@rm -rf "$(BUILD_DIR)" "$(ARCHIVE_PATH)"
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release -derivedDataPath $(DERIVED) -archivePath "$(ARCHIVE_PATH)" $(PACKAGE_ARGS) \
		MARKETING_VERSION=$(VERSION) CURRENT_PROJECT_VERSION=$(BUILD_NUMBER) \
		ARCHS="$(ARCHS)" ONLY_ACTIVE_ARCH=NO \
		CODE_SIGNING_ALLOWED=NO archive
	mkdir -p "$(BUILD_DIR)"
	ditto "$(ARCHIVE_PATH)/Products/Applications/$(APP_NAME).app" "$(APP_PATH)"
	scripts/sign-adhoc.sh "$(APP_PATH)"
	@! (otool -l "$(APP_PATH)/Contents/MacOS/$(APP_NAME)" | grep -E '__llvm_prf|__LLVM_COV' >/dev/null) || (echo "✗ Release app still contains coverage sections" && exit 1)
	@echo "✓ Built $(APP_PATH)"

.PHONY: zip
zip: release-build
	@rm -f "$(ZIP_PATH)"
	cd "$(BUILD_DIR)" && ditto -c -k --keepParent --sequesterRsrc "$(APP_NAME).app" "../$(APP_NAME)-$(VERSION).zip"

.PHONY: dmg
dmg: release-build
	@rm -rf build/dmg-root
	@rm -f "$(DMG_PATH)"
	mkdir -p build/dmg-root
	ditto "$(APP_PATH)" "build/dmg-root/$(APP_NAME).app"
	ln -s /Applications build/dmg-root/Applications
	hdiutil create -volname "$(APP_NAME) $(VERSION)" -srcfolder build/dmg-root -ov -format UDZO "$(DMG_PATH)"

.PHONY: appcast
appcast: zip
	@test -x "$(SPARKLE_BIN)/generate_appcast" || (echo "✗ Sparkle tools missing; run make resolve" && exit 1)
	# Generate a self-contained feed for this release. Reusing stale local ZIPs
	# would create historical enclosures that are not uploaded by `publish`.
	@rm -rf "$(UPDATE_DIR)"
	mkdir -p "$(UPDATE_DIR)"
	cp "$(ZIP_PATH)" "$(UPDATE_DIR)/"
	cp docs/RELEASE_NOTES.md "$(UPDATE_DIR)/$(APP_NAME)-$(VERSION).md"
	"$(SPARKLE_BIN)/generate_appcast" --account ed25519 \
		--download-url-prefix "$(RELEASE_URL)" \
		--full-release-notes-url "https://github.com/septwong/StockBar/releases/tag/$(RELEASE_TAG)" \
		--link "https://github.com/septwong/StockBar" \
		--maximum-versions 3 "$(UPDATE_DIR)"

.PHONY: checksums
checksums: dmg appcast
	cd build && shasum -a 256 "$(APP_NAME)-$(VERSION).dmg" "$(APP_NAME)-$(VERSION).zip" > SHA256SUMS.txt

.PHONY: package
package: checksums
	@echo "✓ Packaged $(DMG_PATH), $(ZIP_PATH), $(UPDATE_DIR)/appcast.xml"

.PHONY: verify-release
verify-release: package
	@test "$$(plutil -extract CFBundleIdentifier raw "$(APP_PATH)/Contents/Info.plist")" = "vip.eztool.StockBar"
	@test "$$(plutil -extract CFBundleShortVersionString raw "$(APP_PATH)/Contents/Info.plist")" = "$(VERSION)"
	@test "$$(plutil -extract CFBundleVersion raw "$(APP_PATH)/Contents/Info.plist")" = "$(BUILD_NUMBER)"
	@test "$$(plutil -extract SUFeedURL raw "$(APP_PATH)/Contents/Info.plist")" = "https://github.com/septwong/StockBar/releases/latest/download/appcast.xml"
	@test "$$(plutil -extract SUPublicEDKey raw "$(APP_PATH)/Contents/Info.plist")" = "TKMnpZMbM4qwBfbcyjBDZThZD9KFq1+p6Rnjvma147c="
	@archs="$$(lipo -archs "$(APP_PATH)/Contents/MacOS/$(APP_NAME)")"; \
		echo "$$archs" | grep -q arm64 && echo "$$archs" | grep -q x86_64 || (echo "✗ App is not universal: $$archs" && exit 1)
	codesign --verify --deep --strict --verbose=2 "$(APP_PATH)"
	@grep -q 'sparkle:edSignature=' "$(UPDATE_DIR)/appcast.xml" || (echo "✗ appcast update is not EdDSA signed" && exit 1)
	@grep -q 'sparkle-signatures:' "$(UPDATE_DIR)/appcast.xml" || (echo "✗ appcast feed is not signed" && exit 1)
	@test -s "$(DMG_PATH)" -a -s "$(ZIP_PATH)" -a -s "$(UPDATE_DIR)/appcast.xml" -a -s "$(CHECKSUM_PATH)"
	@echo "✓ Release artifacts verified"

.PHONY: preflight
preflight: resolve
	@test "$$(git branch --show-current)" = "main" || (echo "✗ publish must run from main" && exit 1)
	@test -z "$$(git status --porcelain)" || (echo "✗ working tree must be clean" && exit 1)
	@git fetch origin main --quiet
	@test "$$(git rev-parse HEAD)" = "$$(git rev-parse origin/main)" || (echo "✗ local main must match origin/main" && exit 1)
	@gh auth status >/dev/null
	@! gh release view "$(RELEASE_TAG)" >/dev/null 2>&1 || (echo "✗ release $(RELEASE_TAG) already exists" && exit 1)
	@"$(SPARKLE_BIN)/generate_keys" --account ed25519 -p >/dev/null

.PHONY: publish
publish: preflight verify-release
	gh release create "$(RELEASE_TAG)" --draft --latest --target main \
		--title "StockBar $(VERSION)" --notes-file docs/RELEASE_NOTES.md \
		"$(DMG_PATH)" "$(ZIP_PATH)" "$(UPDATE_DIR)/appcast.xml" \
		"$(UPDATE_DIR)/$(APP_NAME)-$(VERSION).md" "$(CHECKSUM_PATH)"
	gh release edit "$(RELEASE_TAG)" --draft=false --latest
	@echo "✓ Published $(RELEASE_TAG)"

.PHONY: clean
clean:
	rm -rf build/ DerivedData/
