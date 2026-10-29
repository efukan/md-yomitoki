setting = $(shell awk -F' *= *' '/^$(1) /{print $$2}' Config/App.xcconfig)
PRODUCT := $(call setting,PRODUCT_NAME)
DISPLAY := $(call setting,APP_DISPLAY_NAME)
VERSION := $(call setting,MARKETING_VERSION)
BUILD := $(call setting,CURRENT_PROJECT_VERSION)
REPO := $(call setting,GITHUB_REPOSITORY)
# Xcode の出力は名前が .noindex で終わるフォルダに置く（Spotlight が調べないので、開発中のアプリが
# Spotlight やランチャーに「MDよみとき」として並ばない）。
DERIVED := build/DerivedData.noindex
APP := $(DERIVED)/Build/Products/Debug/$(PRODUCT).app
XCODEBUILD := xcodebuild -project MDYomitoki.xcodeproj -scheme MDYomitoki -derivedDataPath $(DERIVED) -destination 'platform=macOS,arch=$(shell uname -m)'

.PHONY: gen build test run open register archive dmg release preflight appcast publish clean

gen:
	xcodegen generate --quiet

build: gen
	$(XCODEBUILD) -configuration Debug -quiet build

test: gen
	$(XCODEBUILD) -quiet test

run: build
	open "$(APP)"

open: build
	open -a "$(abspath $(APP))" "$(FILE)"

register: build
	/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$(abspath $(APP))"

# 配布：Developer ID で署名した Release ビルド（arm64・x86_64）を dmg にし、公証してチケットを付け、
# 自動アップデートの更新情報（appcast.xml）を作る。公開は make publish（GitHub の Release に dmg と appcast.xml を置く）。
# 公証の資格情報は先に `xcrun notarytool store-credentials MDYomitoki` でキーチェーンに入れておく。
# 証明書を変えて途中まで試すとき：make dmg SIGN="Apple Development"
SIGN ?= Developer ID Application
NOTARY_PROFILE ?= MDYomitoki
RELEASE := build/release
ARCHIVE := $(RELEASE)/$(PRODUCT).xcarchive
RELEASE_APP := $(ARCHIVE)/Products/Applications/$(PRODUCT).app
SPARKLE_FW := $(RELEASE_APP)/Contents/Frameworks/Sparkle.framework
# dmg の名前に版を入れないのは、releases/latest/download/MDYomitoki.dmg を「常に最新版」のダウンロード先として
# 使えるようにするため（Web サイトのダウンロードボタンなど）。Release ごとの URL はタグで分かれる。
DMG := $(RELEASE)/$(PRODUCT).dmg
NOTES := ReleaseNotes/$(VERSION).md
SPARKLE_BIN := $(DERIVED)/SourcePackages/artifacts/sparkle/Sparkle/bin
APPCAST_DIR := $(RELEASE)/appcast
# dmg の名前で版を見分けられないので、appcast に載った版がこのビルド番号かで確かめる。
CHECK_APPCAST = grep -q "<sparkle:version>$(BUILD)</sparkle:version>" "$(APPCAST_DIR)/appcast.xml" || { echo "appcast.xml がこの版（ビルド番号 $(BUILD)）のものではありません（make release）"; exit 1; }

archive: gen
	rm -rf "$(ARCHIVE)"
	xcodebuild -project MDYomitoki.xcodeproj -scheme MDYomitoki -configuration Release -destination 'generic/platform=macOS' \
		-derivedDataPath $(DERIVED) -archivePath "$(ARCHIVE)" -quiet archive CODE_SIGN_IDENTITY="$(SIGN)"
	@# archive が途中に作るアプリの写しは macOS に登録され、Quick Look がそちらの機能拡張を使ってしまう（開発中のビルドの
	@# Quick Look が効かなくなる）。登録を外して消す。
	/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u \
		"$(DERIVED)/Build/Intermediates.noindex/ArchiveIntermediates/MDYomitoki/InstallationBuildProductsLocation/Applications/$(PRODUCT).app" 2>/dev/null || true
	rm -rf "$(DERIVED)/Build/Intermediates.noindex/ArchiveIntermediates"
	@# Sparkle の中の部品は ad-hoc 署名のまま入る（Xcode の書き出しを通さないため）。公証に通るよう、内側から順に署名し直す。
	for x in XPCServices/Installer.xpc XPCServices/Downloader.xpc Autoupdate Updater.app; do \
		codesign -f -s "$(SIGN)" -o runtime --timestamp --preserve-metadata=entitlements "$(SPARKLE_FW)/Versions/B/$$x" || exit 1; \
	done
	codesign -f -s "$(SIGN)" -o runtime --timestamp "$(SPARKLE_FW)"
	codesign -f -s "$(SIGN)" -o runtime --timestamp --preserve-metadata=entitlements "$(RELEASE_APP)"
	codesign --verify --deep --strict "$(RELEASE_APP)"
	@# アプリと中の Quick Look の機能拡張（Xcode が Developer ID・Hardened Runtime・タイムスタンプで署名する）を確かめる
	for x in "$(RELEASE_APP)" "$(RELEASE_APP)"/Contents/PlugIns/*.appex; do \
		codesign -dv "$$x" 2>&1 | grep -q 'flags=.*runtime' || { echo "Hardened Runtime が付いていません：$$x"; exit 1; }; \
	done

# dmg は dmgbuild で作る（背景・アイコンの並び・ウィンドウの大きさ・ディスクのアイコン。設定は Config/dmg_settings.py）。
# 版を固定して build/ の中の専用の Python 環境に入れる（make clean で消えたら次の make dmg で入れ直す）。
DMGBUILD := build/dmgbuild/bin/dmgbuild

$(DMGBUILD):
	python3 -m venv build/dmgbuild
	build/dmgbuild/bin/pip install -q --disable-pip-version-check dmgbuild==1.6.7

dmg: archive $(DMGBUILD)
	rm -f "$(DMG)"
	"$(DMGBUILD)" -s Config/dmg_settings.py -D app="$(RELEASE_APP)" \
		-D icon="$(RELEASE_APP)/Contents/Resources/AppIcon.icns" -D background=Design/dmg/background.tiff \
		"$(DISPLAY) $(VERSION)" "$(DMG)"
	codesign --sign "$(SIGN)" --timestamp "$(DMG)"
	@echo "→ $(DMG)"

release: preflight dmg
	xcrun notarytool submit "$(DMG)" --keychain-profile "$(NOTARY_PROFILE)" --wait --output-format json > "$(RELEASE)/notary.json"
	@status=$$(plutil -extract status raw "$(RELEASE)/notary.json"); echo "公証：$$status"; \
	if [ "$$status" != Accepted ]; then \
		xcrun notarytool log "$$(plutil -extract id raw "$(RELEASE)/notary.json")" --keychain-profile "$(NOTARY_PROFILE)"; exit 1; \
	fi
	xcrun stapler staple "$(DMG)"
	spctl --assess --type open --context context:primary-signature -vv "$(DMG)"
	$(MAKE) appcast

# 公証に時間がかかるので、出せない理由があれば最初に止める。Sparkle はビルド番号で新旧を比べるので、
# 公開中の版より大きくないと更新が届かない（黙って何も起きない）。
preflight:
	@test -f "$(NOTES)" || { echo "$(NOTES) にリリースノートを書いてください（アップデートの画面と GitHub の Release に出る）"; exit 1; }
	@gh release view "v$(VERSION)" --repo "$(REPO)" >/dev/null 2>&1 && { echo "v$(VERSION) はもう公開されています（MARKETING_VERSION を上げてください）"; exit 1; } || true
	@latest=$$(curl -fsL "https://github.com/$(REPO)/releases/latest/download/appcast.xml" 2>/dev/null | sed -n 's|.*<sparkle:version>\(.*\)</sparkle:version>.*|\1|p' | head -1); \
	if [ -n "$$latest" ] && [ "$(BUILD)" -le "$$latest" ]; then \
		echo "CURRENT_PROJECT_VERSION（$(BUILD)）を公開中の版のビルド番号（$$latest）より大きくしてください"; exit 1; \
	fi

# チケットを付けた後の dmg に Sparkle の鍵（キーチェーンの MDYomitoki）で署名し、この版だけを載せた appcast.xml を作る。
appcast:
	rm -rf "$(APPCAST_DIR)"
	mkdir -p "$(APPCAST_DIR)"
	cp "$(DMG)" "$(APPCAST_DIR)/"
	cp "$(NOTES)" "$(APPCAST_DIR)/$(PRODUCT).md"
	"$(SPARKLE_BIN)/generate_appcast" --account MDYomitoki --embed-release-notes \
		--download-url-prefix "https://github.com/$(REPO)/releases/download/v$(VERSION)/" \
		--full-release-notes-url "https://github.com/$(REPO)/releases" --link "https://github.com/$(REPO)" \
		"$(APPCAST_DIR)"
	@$(CHECK_APPCAST)
	@echo "→ $(DMG)"
	@echo "→ $(APPCAST_DIR)/appcast.xml"

# 今のコミット（push 済みであること）に v<版> のタグを付けて Release を作り、dmg と appcast.xml を添付する。
# 最新の Release の appcast.xml を見に来るので、添付した時点で既存の利用者に届く。
publish:
	@git diff --quiet HEAD || { echo "コミットしていない変更があります"; exit 1; }
	@xcrun stapler validate -q "$(DMG)" || { echo "$(DMG) が公証されていません（make release）"; exit 1; }
	@test "$(APPCAST_DIR)/appcast.xml" -nt "$(DMG)" || { echo "appcast.xml が dmg より古いです（make appcast）"; exit 1; }
	@$(CHECK_APPCAST)
	gh release create "v$(VERSION)" "$(DMG)" "$(APPCAST_DIR)/appcast.xml" --repo "$(REPO)" \
		--target "$$(git rev-parse HEAD)" --title "$(DISPLAY) $(VERSION)" --notes-file "$(NOTES)"

clean:
	rm -rf build MDYomitoki.xcodeproj
