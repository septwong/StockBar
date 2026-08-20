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
VERSION ?= 0.1.0
BUILD_DIR := build/Release
APP_PATH := $(BUILD_DIR)/$(APP_NAME).app
DMG_PATH := build/$(APP_NAME)-$(VERSION).dmg
ZIP_PATH := build/$(APP_NAME)-$(VERSION).zip

-include .env
export

.PHONY: help
help:
	@echo "StockBar build targets:"
	@echo "  make build            # Debug build"
	@echo "  make test             # Unit tests"
	@echo "  make run              # Build and launch StockBar-Dev"
	@echo "  make kill             # Stop StockBar-Dev"
	@echo "  make open             # Open the Xcode project"
	@echo "  make icons            # Regenerate app icons"
	@echo "  make release-build    # Create a Release archive"
	@echo "  make sign             # Sign with Developer ID"
	@echo "  make notarize         # Submit and staple notarization"
	@echo "  make dmg              # Create a DMG"
	@echo "  make zip              # Create a ZIP"
	@echo "  make clean            # Remove local build products"

.PHONY: resolve
resolve:
	xcodebuild -resolvePackageDependencies -project $(PROJECT) -scheme $(SCHEME) $(PACKAGE_ARGS)

.PHONY: build
build: resolve
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -derivedDataPath $(DERIVED) $(PACKAGE_ARGS) CODE_SIGNING_ALLOWED=NO build

.PHONY: test
test: resolve
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Debug -derivedDataPath $(DERIVED) $(PACKAGE_ARGS) -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test

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
release-build:
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release -derivedDataPath $(DERIVED) $(PACKAGE_ARGS) MARKETING_VERSION=$(VERSION) CURRENT_PROJECT_VERSION=$(shell date +%s) CODE_SIGNING_ALLOWED=NO build
	mkdir -p $(BUILD_DIR)
	ditto $(DERIVED)/Build/Products/Release/$(APP_NAME).app $(APP_PATH)
	@echo "✓ Built $(APP_PATH)"

.PHONY: sign
sign:
	@test -n "$(DEV_ID)" || (echo "✗ DEV_ID not set in .env" && exit 1)
	codesign --force --options=runtime --timestamp --sign "$(DEV_ID)" --entitlements Config/StockBar.entitlements --deep $(APP_PATH)
	codesign --verify --deep --strict --verbose=2 $(APP_PATH)

.PHONY: zip
zip:
	@test -d "$(APP_PATH)" || (echo "✗ Run make release-build first" && exit 1)
	cd $(BUILD_DIR) && ditto -c -k --keepParent --sequesterRsrc $(APP_NAME).app ../$(APP_NAME)-$(VERSION).zip

.PHONY: notarize
notarize: zip
	@test -n "$(NOTARY_KEYCHAIN_PROFILE)" || (echo "✗ NOTARY_KEYCHAIN_PROFILE not set in .env" && exit 1)
	xcrun notarytool submit $(ZIP_PATH) --keychain-profile "$(NOTARY_KEYCHAIN_PROFILE)" --wait
	xcrun stapler staple $(APP_PATH)
	xcrun stapler validate $(APP_PATH)

.PHONY: dmg
dmg:
	@test -d "$(APP_PATH)" || (echo "✗ Run make release-build first" && exit 1)
	@command -v create-dmg >/dev/null || (echo "✗ Install create-dmg first" && exit 1)
	create-dmg --volname "$(APP_NAME) $(VERSION)" --window-size 540 380 --icon-size 100 --icon "$(APP_NAME).app" 140 190 --app-drop-link 400 190 --no-internet-enable $(DMG_PATH) $(APP_PATH)

.PHONY: clean
clean:
	rm -rf build/ DerivedData/
