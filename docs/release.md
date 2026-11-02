# ビルド・配布・アイコン

## 依存ライブラリ

- XcodeGen（`project.yml`）＋ `Config/App.xcconfig` ＋ `Makefile`。依存は `swiftlang/swift-cmark`（gfm ブランチを revision で固定）と Sparkle（2.10.1、MIT）と、同梱の highlight.js（`Resources/highlight.min.js`、v11.11.1 のよく使う言語の版、BSD-3）と Mermaid（`Resources/mermaid.min.js`、v12.2.0、MIT、jsDelivr の `dist/mermaid.min.js`）と KaTeX（`Resources/katex.min.js`・`katex.min.css`・`Resources/KaTeX/*.woff2`、v0.18.11、MIT、npm の `dist`。CSS はフォントの指定を woff2 だけにし、`fonts/` を外してアプリと同じ場所から読む）。更新するときは同じ名前で差し替える。

## アプリの表示名

- Finder がローカライズ名を出すのは「Info.plist の CFBundleName/DisplayName がバンドルのファイル名と一致する」ときだけなので、Info.plist 側は `$(PRODUCT_NAME)` にしている。日本語の表示名はビルドスクリプト（project.yml の `Localized Display Name`）が `APP_DISPLAY_NAME` から `ja.lproj` / `en.lproj` の `InfoPlist.strings` を生成する（`LSHasLocalizedDisplayName = YES`）。

## リリース（`make release` / `make publish`）

- 配布の手順（`make release`）：`archive`（Release・arm64＋x86_64・Developer ID・Hardened Runtime・`--timestamp`。Sparkle の中の部品〈XPC サービス 2 つ・Autoupdate・Updater.app〉は ad-hoc 署名のまま入るので、内側から順に署名し直してからアプリにも署名し直す。署名と Hardened Runtime を確かめる）→ `dmg`（dmgbuild で、アプリと `/Applications` への別名・背景・アイコンの並び・ウィンドウの大きさ・ディスクのアイコンを ULFO の dmg に。dmg にも署名）→ 公証（`notarytool submit --wait`。通らなければログを出して止まる）→ dmg にチケットを付ける（`stapler staple`）→ `spctl` で確かめる → `appcast`。公証するのは dmg だけで、中のアプリにはチケットを付けない（初回起動時に Gatekeeper がネットで確かめる）。
  - 版は `Config/App.xcconfig` の `MARKETING_VERSION`（表示）と `CURRENT_PROJECT_VERSION`（ビルド番号。出すたびに上げる。Sparkle はこちらで新旧を比べる）。リリースノートは `ReleaseNotes/<版>.md`。Markdown で書き、GitHub の Release のページと、更新の画面（更新先の版のノートだけが出る）に出る。初版の 0.1.0 は誰も更新では見ないので、Release のページで初めて知る人向けのアプリの紹介にした。2版目からはその版で変わったことを書く。見出しは `###` まで（Release のページでは題が大きく出るので、`##` だと本文の見出しが題と張り合う）。その下の区切りは太字の1行にする。
  - dmg の名前は版なしの `MDYomitoki.dmg`（`https://github.com/<GITHUB_REPOSITORY>/releases/latest/download/MDYomitoki.dmg` が常に最新版を指すので、Web サイトのダウンロードボタンに使える。Release ごとの URL はタグで分かれるので Sparkle の更新にも差し支えない）。名前で版を見分けられないので、`appcast` と `publish` は appcast.xml の `sparkle:version` がこのビルド番号かを確かめる。
  - `preflight`（公証の前に止める）：リリースノートが無い・`v<版>` の Release がもうある・ビルド番号が公開中の appcast の `sparkle:version` 以下（更新が黙って届かなくなる）。`publish` の前には、コミットしていない変更が無いこと・dmg が公証済み（`stapler validate`）・appcast.xml が dmg より新しいことを確かめる。
  - archive が途中に作るアプリの写し（`Intermediates.noindex/ArchiveIntermediates/…/MDYomitoki.app`）は macOS に登録され、Quick Look がそちらの機能拡張を使ってしまう（開発中のビルドの Quick Look が効かなくなる）。`make archive` の終わりに登録を外して消す。
  - archive も同じ `-derivedDataPath` で作る（Sparkle の `generate_appcast` などを `build/DerivedData.noindex/SourcePackages` から使うため）。
  - 出す時：版を上げる → `ReleaseNotes/<版>.md` を書く → `make release` → コミットして push → `make publish`。
  - 前準備（1回だけ・ユーザーが行う）：Developer ID Application 証明書をキーチェーンに入れる（Xcode の Settings → Accounts → Manage Certificates）。公証の資格情報を `xcrun notarytool store-credentials MDYomitoki --apple-id <Apple ID> --team-id 4NJNS5T7UM` で保存する（App 用パスワードを聞かれる）。プロファイル名は `NOTARY_PROFILE` で変えられる。

## dmg の見た目

- dmg の見た目（`make dmg`）：[dmgbuild](https://github.com/dmgbuild/dmgbuild)（版を固定して `build/dmgbuild` の専用の Python 環境に入れる。無ければ `make dmg` が入れる）で作る。設定は `Config/dmg_settings.py`。
  - 背景は `Design/dmg/background.tiff`（`make_background.py` が Pillow で描く。紙の色の地に、アプリから Applications への矢印と「ドラッグしてください」の一言。Retina 用の 2 倍の絵と `tiffutil` で 1 つにまとめる）。アイコンの中心の座標は設定と背景のスクリプトで合わせる。
  - Finder でパスバーを出している人は、ウィンドウの下の 22pt ほどが隠れる（dmg の設定で消しても、利用者の Finder の設定が勝つ）ので、背景の下は空けておく。
  - 背景の絵がある時は、ダークモードでもアイコンの名前は黒い文字で描かれる（確かめた）。
  - 開いたときのディスクのアイコンはアプリのアイコン（`AppIcon.icns`）。ダウンロードした dmg ファイル自体のアイコンは、付けてもブラウザでのダウンロードで落ちるので付けない。
  - dmgbuild は中で `hdiutil` を使うので、この macOS では非推奨の警告が出る（動作には差し支えない）。

## 自動アップデート

- 自動アップデート（`Updater.swift`、Sparkle 2）：更新情報は `https://github.com/<GITHUB_REPOSITORY>/releases/latest/download/appcast.xml`（Info.plist の `SUFeedURL`。最新の Release に添付した appcast.xml を指すので、ブランチや GitHub Pages は使わない）。`make appcast` が Sparkle の `generate_appcast` でこの版だけを載せた appcast を作る（チケットを付けた後の dmg に EdDSA で署名、リリースノートの Markdown を埋め込む）。1日1回確かめて知らせる（`SUEnableAutomaticChecks`）。自動でダウンロード・インストールするか、確かめるかは設定ウィンドウと Sparkle の UserDefaults。「MDよみとき」メニューに「アップデートを確認…」。Debug ビルドでは動かさない（開発中のアプリが公開版に置き換わらないように）。
  - 署名の鍵：秘密鍵はログインキーチェーンの `MDYomitoki`（`generate_keys --account MDYomitoki`）、公開鍵は Info.plist の `SUPublicEDKey`。**秘密鍵を無くすと既存の利用者に更新を届けられない**ので、`generate_keys --account MDYomitoki -x <ファイル>` で書き出して安全な場所に保管する。
  - 手元で試す方法：古い版のアプリを取っておき、新しい版の dmg と `generate_appcast --download-url-prefix http://127.0.0.1:<port>/` で作った appcast を `python3 -m http.server` で配り、`defaults write jp.efukan.mdyomitoki SUFeedURL http://127.0.0.1:<port>/appcast.xml`（試した後は SU で始まる項目を消す）。

## ライセンス表示

- 同梱するライブラリ（cmark-gfm・Sparkle・highlight.js・Mermaid・KaTeX）のライセンスを `Resources/Credits.html` に置き（冒頭に名前・用途・ライセンスの種類・リンクの一覧、その下に全文。全文は元のファイルの改行を外して段落にし、同梱しているほかのコードの区切りは太字）、「MDよみとき について」（自前のメニュー項目 → `AppDelegate.showAboutPanel`）に出す。HTML のままだとリンクが固定の青になり OS によっては本文も黒になるので、読み込んでから文字色の指定を外して渡す。アイコンも既定（`NSApp.applicationIconImage`）だと白紙の汎用アイコンになったので、`NSWorkspace` のアイコンを 64pt で渡す。ライブラリを足したり更新したりしたら Credits.html も更新する（Mermaid に含まれる他のライブラリの表示は mermaid.min.js の中にある）。
- アプリ自体は MIT（`LICENSE`）。著作権表示は xcconfig の `APP_COPYRIGHT`。

## アプリアイコン

- Icon Composer 形式の `MDYomitoki/AppIcon.icon`（`ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`）。macOS 26 以降はレイヤーから描かれ、角丸の形・光沢・影はシステムが付ける。macOS 15 向けの PNG と `AppIcon.icns` はビルド時に Xcode が書き出す。
- デザイン：紙色の地に、左 22% の濃い焦げ茶の帯（アプリのサイドバー＝見出し一覧。3行を紙面の3行と同じ高さに並べ、今読んでいる行だけ濃く）、紙面に真ん中を広く開けた `#`・見出し・本文2行（下の行に蛍光ペン）、右上から垂れるコーラル色の栞。
- レイヤーは手前から Ribbon／Page（墨・本文・蛍光ペン）／Sidebar（行・帯）。紙面を色ごとに分けているのは、ダークモードで紙を暗い焦げ茶に、墨と本文を明るい色に差し替えるため（`fill-specializations`）。
- **`Design/AppIcon/make_appicon.py` が正**（SVG と `icon.json` を書き出す）。Icon Composer で直接いじった場合は、スクリプトを再実行すると上書きされる。README のアイコン（`Design/icon.png`）は `ictool` で書き出した 256px の画像。
- 確認は `ictool`（`/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool`）で `--platform macOS --rendition Default|Dark|TintedLight|…` を書き出して見る。
- `.icon` はサイズごとに別の絵を持てないので、16・32px も同じ絵を縮めて描かれる。
