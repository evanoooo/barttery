APP        = Barttery
BRIDGE_INC = /opt/homebrew/include
BUNDLED_LIB_DIR = Sources/Resources/lib
BUNDLE     = Barttery.app
CONTENTS   = $(BUNDLE)/Contents
BIN_DIR    = .build/release
SIGN        ?= NativeToolbox Dev
KEYCHAIN    ?= $(shell [ -f "/Users/$$(id -un)/Library/Keychains/login.keychain-db" ] && echo "/Users/$$(id -un)/Library/Keychains/login.keychain-db" || echo "$$HOME/Library/Keychains/login.keychain-db")
SIGN_FLAGS  ?= $(shell [ -f "$(KEYCHAIN)" ] && echo "--keychain $(KEYCHAIN)")
NOTARY_PROFILE ?=
MODULE_CACHE ?= /tmp/clang-module-cache
WIDGET_APPEX = $(CONTENTS)/PlugIns/BartteryWidget.appex

.PHONY: all build run install clean dmg release test-watchlog widgets widgets-check widget-preview

all: build

build:
	rm -rf $(BUNDLE)
	swift build -c release --arch arm64
	@mkdir -p $(CONTENTS)/MacOS $(CONTENTS)/Resources $(WIDGET_APPEX)/Contents/MacOS $(WIDGET_APPEX)/Contents/Resources
	@cp $(BIN_DIR)/$(APP) $(CONTENTS)/MacOS/$(APP)
	@chmod +x $(CONTENTS)/MacOS/$(APP)
	@cp Info.plist $(CONTENTS)/
	@cp AppIcon.icns $(CONTENTS)/Resources/
	@cp Sources/Resources/idevice_id Sources/Resources/ideviceinfo Sources/Resources/comptest Sources/Resources/bartbeat Sources/Resources/mobilebeat Sources/Resources/wifiwatch $(CONTENTS)/Resources/
	@cp Sources/Resources/lib/*.dylib $(CONTENTS)/Resources/
	@cp -R Sources/Resources/*.lproj $(CONTENTS)/Resources/
	@chmod +x $(CONTENTS)/Resources/idevice_id $(CONTENTS)/Resources/ideviceinfo $(CONTENTS)/Resources/comptest $(CONTENTS)/Resources/bartbeat $(CONTENTS)/Resources/mobilebeat $(CONTENTS)/Resources/wifiwatch
	@python3 scripts/prepare-device-helpers.py "$(CONTENTS)/Resources"
	@mkdir -p $(MODULE_CACHE)
	@xcrun swiftc -module-cache-path $(MODULE_CACHE) -parse-as-library -application-extension -target arm64-apple-macos14.0 -O \
		-Xlinker -e -Xlinker _NSExtensionMain \
		Sources/WidgetSnapshot.swift Widgets/BartteryWidget.swift \
		-o $(WIDGET_APPEX)/Contents/MacOS/BartteryWidget
	@chmod +x $(WIDGET_APPEX)/Contents/MacOS/BartteryWidget
	@python3 -c 'import plistlib; p=plistlib.load(open("Widgets/Widget-Info.plist", "rb")); p["CFBundleExecutable"]="BartteryWidget"; p["CFBundleIdentifier"]="me.yura.barttery.widget"; p["CFBundleName"]="BartteryWidget"; p["CFBundleDisplayName"]="Barttery"; p["CFBundleDevelopmentRegion"]="en"; p["CFBundleShortVersionString"]="1.1.6"; p["CFBundleVersion"]="1"; p["CFBundleSupportedPlatforms"]=["MacOSX"]; p["LSMinimumSystemVersion"]="14.0"; plistlib.dump(p, open("$(WIDGET_APPEX)/Contents/Info.plist", "wb"))'
	@set -e; \
	[ -f "$(KEYCHAIN)" ] && security list-keychains -d user -s "$(KEYCHAIN)" /Library/Keychains/System.keychain 2>/dev/null || true; \
	for f in $(CONTENTS)/Resources/*.dylib $(CONTENTS)/Resources/idevice_id $(CONTENTS)/Resources/ideviceinfo $(CONTENTS)/Resources/comptest $(CONTENTS)/Resources/bartbeat $(CONTENTS)/Resources/mobilebeat $(CONTENTS)/Resources/wifiwatch; do \
	  [ -f "$$f" ] && codesign --force --sign "$(SIGN)" $(SIGN_FLAGS) "$$f"; \
	done; \
	codesign --force --sign "$(SIGN)" $(SIGN_FLAGS) --entitlements Widgets/BartteryWidget.entitlements $(WIDGET_APPEX); \
	codesign --force --sign "$(SIGN)" $(SIGN_FLAGS) --entitlements Barttery.entitlements $(BUNDLE)
	@echo "=> Built $(BUNDLE)"

run: build
	open $(BUNDLE)

install: build
	@killall Barttery mobilebeat wifiwatch comptest 2>/dev/null || true
	@sleep 1
	rm -rf /Applications/$(BUNDLE)
	ditto $(BUNDLE) /Applications/$(BUNDLE)
	xattr -dr com.apple.quarantine /Applications/$(BUNDLE) 2>/dev/null || true
	@mkdir -p "$$HOME/Library/Containers/me.yura.barttery.widget/Data/Documents" "$$HOME/Library/Containers/me.yura.barttery.widget/Data/Library/Application Support" 2>/dev/null || true
	@pluginkit -a /Applications/$(BUNDLE)/Contents/PlugIns/BartteryWidget.appex 2>/dev/null || true
	@pluginkit -e use -i me.yura.barttery.widget 2>/dev/null || true
	@pluginkit -e use -i com.yura.barttery.widget 2>/dev/null || true
	@killall chronod 2>/dev/null || true
	@killall NotificationCenter 2>/dev/null || true
	@echo "=> Installed to /Applications/$(BUNDLE)"
	@open -a /Applications/$(BUNDLE)

# Public, non-widget release. Never replace Developer ID signatures with ad-hoc ones.
dmg:
	@SIGN="$(SIGN)" NOTARY_PROFILE="$(NOTARY_PROFILE)" bash scripts/release.sh

release: dmg

bartbeat:
	clang -o Sources/Resources/bartbeat bridge/bartbeat.c \
		-I$(BRIDGE_INC) \
		-L$(BUNDLED_LIB_DIR) \
		-limobiledevice-1.0.6 \
		-lusbmuxd-2.0.6 \
		-lplist-2.0.4 \
		-limobiledevice-glue-1.0.0 \
		-arch arm64
	@echo "=> Built bartbeat"

mobilebeat:
	clang -o Sources/Resources/mobilebeat bridge/mobilebeat.c \
		-framework CoreFoundation \
		-F/Library/Apple/System/Library/PrivateFrameworks \
		-framework MobileDevice \
		-arch arm64
	@echo "=> Built mobilebeat"

wifiwatch:
	clang -o Sources/Resources/wifiwatch bridge/wifiwatch.c \
		-I$(BRIDGE_INC) \
		-L$(BUNDLED_LIB_DIR) \
		-lssl.3 \
		-lcrypto.3 \
		-lplist-2.0.4 \
		-lusbmuxd-2.0.6 \
		-limobiledevice-glue-1.0.0 \
		-arch arm64
	@echo "=> Built wifiwatch"

test-watchlog:
	@TEST_BIN=$$(mktemp -t barttery-watchlog); \
	trap 'rm -f "$$TEST_BIN"' EXIT; \
	clang -Wall -Wextra -Werror bridge/tests/watchlog_test.c -o "$$TEST_BIN" && "$$TEST_BIN"

# Separate Xcode build: never replaces the existing DMG bundle.
# Register the shared App Group for both targets before a signed build.
widgets:
	@test -n "$(TEAM)" || (echo "Usage: make widgets TEAM=<Apple Developer Team ID>"; exit 1)
	xcodegen generate
	xcodebuild -quiet -project Barttery.xcodeproj -scheme Barttery -configuration Release \
		-derivedDataPath .build/xcode DEVELOPMENT_TEAM="$(TEAM)" ARCHS=arm64 build

widgets-check:
	xcodegen generate
	xcodebuild -quiet -project Barttery.xcodeproj -scheme Barttery -configuration Debug \
		-derivedDataPath .build/xcode CODE_SIGNING_ALLOWED=NO build

widget-preview:
	@mkdir -p .build
	xcrun swiftc -parse-as-library -D WIDGET_RENDER -target arm64-apple-macos14.0 \
		Sources/WidgetSnapshot.swift Widgets/BartteryWidget.swift Tests/WidgetPreview.swift \
		-o .build/widget-preview
	.build/widget-preview

clean:
	rm -rf .build $(BUNDLE) Sources/Resources/bartbeat Sources/Resources/mobilebeat Sources/Resources/wifiwatch
