# MDよみとき（MDYomitoki）

AIエージェント（Claude Code等）が外部で書き換える日本語Markdownを監視し、表・変更箇所を素早く「よみとく（閲覧・検索・微修正）」ための macOS ネイティブリーダー兼エディタ。

利用者向けの説明は `README.md`。このファイルは開発する人と AI エージェント向けの仕様とルールで、実装の理由（なぜそうしたか）も残す。

- 表示名：『MDよみとき』／内部ターゲット名：`MDYomitoki`／Bundle ID：`jp.efukan.mdyomitoki`
- 名称・識別子・バージョン・著作権表示（`APP_COPYRIGHT`、「© 2026 efukan」）・公開先（`GITHUB_REPOSITORY`）・問い合わせ先（`SUPPORT_EMAIL`）は **`Config/App.xcconfig` の1箇所だけ** で管理する（Info.plist は変数参照のみ）
  - Finder がローカライズ名を出すのは「Info.plist の CFBundleName/DisplayName がバンドルのファイル名と一致する」ときだけなので、Info.plist 側は `$(PRODUCT_NAME)` にしている。日本語の表示名はビルドスクリプト（project.yml の `Localized Display Name`）が `APP_DISPLAY_NAME` から `ja.lproj` / `en.lproj` の `InfoPlist.strings` を生成する（`LSHasLocalizedDisplayName = YES`）。

## 作業ルール（必ず守る）

1. 変更したら `make build` と `make test` を通し、エラーと警告を0にする。まとまった機能を入れたら、次の作業へ勝手に進まず、作業を止めてユーザーに動作確認を求める。
2. **KISS**：ファイル数は最小限、フラットな構成にする。不要なProtocol抽象化やレイヤー分割はしない。推論はエッジケース（ファイル競合・IME・スクロール飛び・リーク）の事前回避に使う。
3. 純粋関数（太字補正・文字数・差分・検索正規化）はユニットテスト（Swift Testing）で固める。
4. 仕様や実装の理由が変わったら、このファイルの該当箇所も直す。

## 開発コマンド

必要なもの：Xcode（macOS 15 SDK 以降）と XcodeGen（`brew install xcodegen`）。

```
make gen       # xcodegen で MDYomitoki.xcodeproj を生成（project.yml が正。xcodeproj は git 管理外）
make build     # Debug ビルド（出力先 build/DerivedData.noindex/。名前が .noindex のフォルダは Spotlight が調べないので、開発中のアプリが Spotlight やランチャーに並ばない）
make test      # ユニットテスト
make run       # ビルドして起動
make open FILE=path/to/file.md   # ビルド済みアプリでファイルを開く
make register  # LaunchServices に再登録（ファイル関連付けのテスト用）
make release   # 配布用の dmg を作って公証し、自動アップデートの appcast.xml を作る（build/release/）
make publish   # GitHub に v<版> の Release を作って dmg と appcast.xml を添付する（＝利用者に配信）
make dmg SIGN="Apple Development"   # 公証の手前まで（証明書を変えて手順だけ試す）
```

- 開発中のビルドは公開版と同じ Bundle ID なので、最近使ったファイル・付箋・設定などの保存データ（UserDefaults）を、この Mac で使っている公開版と共有している。履歴が空の状態などを試すときは、Bundle ID を変えた別のコピーで行う（`xcodebuild -project MDYomitoki.xcodeproj -scheme MDYomitoki -configuration Debug -derivedDataPath <一時フォルダ>.noindex PRODUCT_BUNDLE_IDENTIFIER=jp.efukan.mdyomitoki.uitest build`。試した後はコピーと `jp.efukan.mdyomitoki.uitest` の保存データを消す）。起動引数（`-recentFiles …`）で読む値を上書きする方法は使わない。読むのは上書きした値でも、アプリが書き込むと本物の保存データに入り、履歴を消してしまう。

## 技術仕様

### ビルド・署名・依存
- 直接配布（Developer ID ＋公証、**App Sandbox なし**）。開発中は Apple Development 証明書で署名する（チームID は xcconfig）。Hardened Runtime は Release のみ有効にする（Debug はテストバンドル注入のため無効）。
- ⚠️ Sandbox なしでも、`~/Documents`・`~/Desktop`・`~/Downloads` などの中にある「ユーザーが直接開いていないファイル」（隣の画像など）を初めて読むときは、プライバシー保護（TCC）の許可ダイアログが出て、許可されるまで `open()` が**ブロックされる**。
  - ディスク I/O はメインスレッドで行わない（スキームハンドラはバックグラウンドで読む）。
  - ad-hoc 署名だとビルドのたびに TCC の許可がリセットされるので使わない。
- エンタイトルメントは無し（WebKit の JIT は WebContent プロセス側なので不要。cmark は静的リンク）。
- 最小OSは **macOS 15**。Swift 6（strict concurrency）。UI 状態は `@MainActor`。
- XcodeGen（`project.yml`）＋ `Config/App.xcconfig` ＋ `Makefile`。依存は `swiftlang/swift-cmark`（gfm ブランチを revision で固定）と Sparkle（2.10.1、MIT）と、同梱の highlight.js（`Resources/highlight.min.js`、v11.11.1 のよく使う言語の版、BSD-3）と Mermaid（`Resources/mermaid.min.js`、v12.2.0、MIT、jsDelivr の `dist/mermaid.min.js`）。更新するときは同じ名前で差し替える。

### リリースと自動アップデート（`make release` / `make publish`）
- 配布の手順（`make release`）：`archive`（Release・arm64＋x86_64・Developer ID・Hardened Runtime・`--timestamp`。Sparkle の中の部品〈XPC サービス 2 つ・Autoupdate・Updater.app〉は ad-hoc 署名のまま入るので、内側から順に署名し直してからアプリにも署名し直す。署名と Hardened Runtime を確かめる）→ `dmg`（dmgbuild で、アプリと `/Applications` への別名・背景・アイコンの並び・ウィンドウの大きさ・ディスクのアイコンを ULFO の dmg に。dmg にも署名）→ 公証（`notarytool submit --wait`。通らなければログを出して止まる）→ dmg にチケットを付ける（`stapler staple`）→ `spctl` で確かめる → `appcast`。公証するのは dmg だけで、中のアプリにはチケットを付けない（初回起動時に Gatekeeper がネットで確かめる）。
  - 版は `Config/App.xcconfig` の `MARKETING_VERSION`（表示）と `CURRENT_PROJECT_VERSION`（ビルド番号。出すたびに上げる。Sparkle はこちらで新旧を比べる）。リリースノートは `ReleaseNotes/<版>.md`。Markdown で書き、GitHub の Release のページと、更新の画面（更新先の版のノートだけが出る）に出る。初版の 0.1.0 は誰も更新では見ないので、Release のページで初めて知る人向けのアプリの紹介にした。2版目からはその版で変わったことを書く。見出しは `###` まで（Release のページでは題が大きく出るので、`##` だと本文の見出しが題と張り合う）。その下の区切りは太字の1行にする。
  - dmg の名前は版なしの `MDYomitoki.dmg`（`https://github.com/<GITHUB_REPOSITORY>/releases/latest/download/MDYomitoki.dmg` が常に最新版を指すので、Web サイトのダウンロードボタンに使える。Release ごとの URL はタグで分かれるので Sparkle の更新にも差し支えない）。名前で版を見分けられないので、`appcast` と `publish` は appcast.xml の `sparkle:version` がこのビルド番号かを確かめる。
  - `preflight`（公証の前に止める）：リリースノートが無い・`v<版>` の Release がもうある・ビルド番号が公開中の appcast の `sparkle:version` 以下（更新が黙って届かなくなる）。`publish` の前には、コミットしていない変更が無いこと・dmg が公証済み（`stapler validate`）・appcast.xml が dmg より新しいことを確かめる。
  - archive も同じ `-derivedDataPath` で作る（Sparkle の `generate_appcast` などを `build/DerivedData.noindex/SourcePackages` から使うため）。
  - 出す時：版を上げる → `ReleaseNotes/<版>.md` を書く → `make release` → コミットして push → `make publish`。
  - 前準備（1回だけ・ユーザーが行う）：Developer ID Application 証明書をキーチェーンに入れる（Xcode の Settings → Accounts → Manage Certificates）。公証の資格情報を `xcrun notarytool store-credentials MDYomitoki --apple-id <Apple ID> --team-id 4NJNS5T7UM` で保存する（App 用パスワードを聞かれる）。プロファイル名は `NOTARY_PROFILE` で変えられる。
- dmg の見た目（`make dmg`）：[dmgbuild](https://github.com/dmgbuild/dmgbuild)（版を固定して `build/dmgbuild` の専用の Python 環境に入れる。無ければ `make dmg` が入れる）で作る。設定は `Config/dmg_settings.py`。
  - 背景は `Design/dmg/background.tiff`（`make_background.py` が Pillow で描く。紙の色の地に、アプリから Applications への矢印と「ドラッグしてください」の一言。Retina 用の 2 倍の絵と `tiffutil` で 1 つにまとめる）。アイコンの中心の座標は設定と背景のスクリプトで合わせる。
  - Finder でパスバーを出している人は、ウィンドウの下の 22pt ほどが隠れる（dmg の設定で消しても、利用者の Finder の設定が勝つ）ので、背景の下は空けておく。
  - 背景の絵がある時は、ダークモードでもアイコンの名前は黒い文字で描かれる（確かめた）。
  - 開いたときのディスクのアイコンはアプリのアイコン（`AppIcon.icns`）。ダウンロードした dmg ファイル自体のアイコンは、付けてもブラウザでのダウンロードで落ちるので付けない。
  - dmgbuild は中で `hdiutil` を使うので、この macOS では非推奨の警告が出る（動作には差し支えない）。
- 自動アップデート（`Updater.swift`、Sparkle 2）：更新情報は `https://github.com/<GITHUB_REPOSITORY>/releases/latest/download/appcast.xml`（Info.plist の `SUFeedURL`。最新の Release に添付した appcast.xml を指すので、ブランチや GitHub Pages は使わない）。`make appcast` が Sparkle の `generate_appcast` でこの版だけを載せた appcast を作る（チケットを付けた後の dmg に EdDSA で署名、リリースノートの Markdown を埋め込む）。1日1回確かめて知らせる（`SUEnableAutomaticChecks`）。自動でダウンロード・インストールするか、確かめるかは設定ウィンドウと Sparkle の UserDefaults。「MDよみとき」メニューに「アップデートを確認…」。Debug ビルドでは動かさない（開発中のアプリが公開版に置き換わらないように）。
  - 署名の鍵：秘密鍵はログインキーチェーンの `MDYomitoki`（`generate_keys --account MDYomitoki`）、公開鍵は Info.plist の `SUPublicEDKey`。**秘密鍵を無くすと既存の利用者に更新を届けられない**ので、`generate_keys --account MDYomitoki -x <ファイル>` で書き出して安全な場所に保管する。
  - 手元で試す方法：古い版のアプリを取っておき、新しい版の dmg と `generate_appcast --download-url-prefix http://127.0.0.1:<port>/` で作った appcast を `python3 -m http.server` で配り、`defaults write jp.efukan.mdyomitoki SUFeedURL http://127.0.0.1:<port>/appcast.xml`（試した後は SU で始まる項目を消す）。

### ライセンス表示
- 同梱するライブラリ（cmark-gfm・Sparkle・highlight.js・Mermaid）のライセンスを `Resources/Credits.html` に置き（冒頭に名前・用途・ライセンスの種類・リンクの一覧、その下に全文。全文は元のファイルの改行を外して段落にし、同梱しているほかのコードの区切りは太字）、「MDよみとき について」（自前のメニュー項目 → `AppDelegate.showAboutPanel`）に出す。HTML のままだとリンクが固定の青になり OS によっては本文も黒になるので、読み込んでから文字色の指定を外して渡す。アイコンも既定（`NSApp.applicationIconImage`）だと白紙の汎用アイコンになったので、`NSWorkspace` のアイコンを 64pt で渡す。ライブラリを足したり更新したりしたら Credits.html も更新する（Mermaid に含まれる他のライブラリの表示は mermaid.min.js の中にある）。
- アプリ自体は MIT（`LICENSE`）。著作権表示は xcconfig の `APP_COPYRIGHT`。

### アプリアイコン
- Icon Composer 形式の `MDYomitoki/AppIcon.icon`（`ASSETCATALOG_COMPILER_APPICON_NAME: AppIcon`）。macOS 26 以降はレイヤーから描かれ、角丸の形・光沢・影はシステムが付ける。macOS 15 向けの PNG と `AppIcon.icns` はビルド時に Xcode が書き出す。
- デザイン：紙色の地に、左 22% の濃い焦げ茶の帯（アプリのサイドバー＝見出し一覧。3行を紙面の3行と同じ高さに並べ、今読んでいる行だけ濃く）、紙面に真ん中を広く開けた `#`・見出し・本文2行（下の行に蛍光ペン）、右上から垂れるコーラル色の栞。
- レイヤーは手前から Ribbon／Page（墨・本文・蛍光ペン）／Sidebar（行・帯）。紙面を色ごとに分けているのは、ダークモードで紙を暗い焦げ茶に、墨と本文を明るい色に差し替えるため（`fill-specializations`）。
- **`Design/AppIcon/make_appicon.py` が正**（SVG と `icon.json` を書き出す）。Icon Composer で直接いじった場合は、スクリプトを再実行すると上書きされる。README のアイコン（`Design/icon.png`）は `ictool` で書き出した 256px の画像。
- 確認は `ictool`（`/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool`）で `--platform macOS --rendition Default|Dark|TintedLight|…` を書き出して見る。
- `.icon` はサイズごとに別の絵を持てないので、16・32px も同じ絵を縮めて描かれる。

### ウィンドウ・起動導線
- SwiftUI `App` は `Settings` シーンとメニューコマンドだけを担当する。設定ウィンドウ（⌘,、`SettingsView`）は `AppSettings` をまとめて見せるだけで、どの設定もメニューやツールバーからも変えられる（表示：文字の大きさ・本文の幅・リモート画像、変更の比較：新しく開いたファイルの基準）。ドキュメントウィンドウは **AppDelegate が AppKit の `NSWindow` ＋ `NSHostingController`** で生成・管理する（DocumentGroup/NSDocument は外部変更監視とぶつかるため使わない）。
- 複数ファイルは OS 標準のウィンドウタブで扱う（`tabbingMode = .preferred`、前面ウィンドウに `addTabbedWindow`）。タブの「＋」は `newWindowForTab:` で「最近使ったファイル」のパネルを出す。
- 閉じる（⌘W）・ウインドウを閉じる（⇧⌘W、タブごと）・閉じたタブを開き直す（⇧⌘T、閉じた順に新しいものから。終了すると忘れる）は「ファイル」メニュー（標準の「閉じる」は置き換えた保存の欄に入っているので自前で用意する）。
- 外観（設定ウィンドウ：端末に合わせる・ライト・ダーク、`AppSettings.appearance`）は `NSApp.appearance` で全体に効かせる（プレビューの WebView・Mermaid も追従する）。
- 開く導線：`Cmd+O`、`⇧⌘O`（最近使ったファイル）、Finder（`application(_:open:)`）、Dock アイコンへのドロップ、ウィンドウへの D&D（SwiftUI の `dropDestination` と WKWebView サブクラスのドラッグ受け口）。同じファイルを再度開いたら既存ウィンドウを前面に出す。
- 見えていない間（裏のタブ・隠れた／しまったウィンドウ。`occlusionState` とタブの選択で判断）に外部更新が来たら、タブにオレンジの点（`tab.accessoryView`）を出し、Dock のバッジにその文書の数を出す。ウィンドウがキーになるか見えるようになったら消す。横に並べて見ている時は出さない。
- ファイルを開いていないとき（起動時・ウィンドウが無い状態で Dock をクリック）は「最近使ったファイル」のパネルを出す。SwiftUI のアプリでは `applicationOpenUntitledFile` が呼ばれないので、`applicationDidFinishLaunching`（Finder から渡されたファイルを待つため main.async）と `applicationShouldHandleReopen` で判断する。
  - 履歴が空のとき（初めて起動したとき）は、一覧の代わりに「ようこそ」の案内（何をするアプリか・開くボタン）を出す。このパネルにもファイルをドロップして開ける。
- .md を開く既定のアプリ：Info.plist の `LSHandlerRank` は Alternate（ほかのアプリが既定なら勝手に奪わない）。設定ウィンドウの「Markdown ファイル」で、今の既定のアプリを見せ、`NSWorkspace.setDefaultApplication(at:toOpen:)` で MDよみとき にできる。同じ Bundle ID の別のコピー（開発中のビルドと公開版）が既定なら、もう MDよみとき とみなす。
- 「ヘルプ」メニュー：標準の「MDよみとき ヘルプ」はヘルプブックが無いと「ヘルプはありません」と出るだけなので、GitHub の README・不具合の報告と要望（メールと GitHub の Issue の2つ。Issue はアカウントが要るので、無い人のためにメールも置く。どちらも本文にアプリと macOS の版を入れておく）・Releases へのリンクに置き換える（`ProjectLinks`。リポジトリと宛先は xcconfig の `GITHUB_REPOSITORY`・`SUPPORT_EMAIL` を Info.plist の `MDYGitHubRepository`・`MDYSupportEmail` で渡す）。
- メニューコマンドは前面ウィンドウのモデル（`AppDelegate.activeModel`。アプリが前面に無い時は一番手前の文書ウィンドウ）へ届ける。**キーボードショートカットは必ずメニュー（SwiftUI の `.commands`）に置く**。ツールバーのボタンに `.keyboardShortcut` を付けても、AppKit の NSWindow に SwiftUI のツールバーを橋渡しする構成では効かない。

### プレビュー（WKWebView）
- 外枠HTML（`Resources/preview.html|css|js`）を独自スキーム `yomitoki://app/` から**一度だけ読み込み、以後はリロードしない**。外枠への遷移は Swift から読み込みを始めた時（`shellLoadPending`）だけ許可する（文書の meta refresh で再読み込みが延々と続かないように）。更新は `callAsyncJavaScript("render(html, base)")`（引数バインドで渡すのでエスケープ事故がない）。
- `WKURLSchemeHandler`：`yomitoki://app/<name>` は同梱リソース、`yomitoki://file/<絶対パス>` はディスク上の**画像だけ**を返す（`no-store`。シンボリックリンクは解決した先も画像の名前であること、通常のファイルで 100MB 以下であることを確かめる）。文書ごとに `<base href="yomitoki://file/<元フォルダ>/">` を設定するので、相対パス・絶対パスの画像が一時ファイルなしで表示される。
- リモート画像（http/https）は既定で表示する。「表示」メニューの「リモート画像を読み込む」（`AppSettings.loadRemoteImages`）でオフにすると、`WKContentRuleList`（`RemoteContentBlocker`）で http/https の読み込みそのものを止める（srcset・CSS の背景・SVG の image なども含む。ブロッカーを入れ終えてから描画する）。あわせて JS が文書へ入れる前に img の src を `data-remote-src` に退避し、オンに戻した時に読み込み直す。CSP は `img-src` のみ外部許可、スクリプト・CSS・iframe は同梱のものだけ。ATS は `NSAllowsArbitraryLoadsInWebContent`。読み込み失敗時は `img.broken` で枠と alt を表示する。
- `#content` は `contain: paint`（文書の生 HTML の `position: fixed` を本文の中に閉じ込め、画面全体を覆う偽の表示やリンクを置かせない）。
- 見出し：段の違いは大きさ・太さ・濃さで、節の区切りは上の余白で示す（下線は文書の題になる h1 だけ）。上の段ほど上の余白を広くし、見出しの直後に見出しが続くときは詰める。引用の文字は本文の 78% の濃さ（secondary-label では薄すぎるため）。
- ネイティブ感：`drawsBackground=false`、`color-scheme: light dark`、`-apple-system-*` システムカラー、`-apple-system`／ヒラギノ、`line-height: 1.75`、`line-break: strict`、見出しに `palt`。初回表示は `ready` まで WebView を透明にしておく。
- 表は Swift 側で `<div class="table-wrap">` で包み、表単体で横スクロールできるようにする（角丸枠・ヘッダー背景・ストライプ）。
  - 見出し行の固定：`.table-wrap` が横スクロールの入れ物なので `position: sticky` は画面に効かない。見出し行が画面の上に隠れた表があれば、JS が見出し行の複製（列の幅を写す・`box-sizing: border-box`）を画面の上端に重ね（`#sticky-head`）、表の横スクロールに合わせて動かし、表の終わりで押し上げる。表の行へ移動するときは見出し行の高さだけ下に出す。
- 文字の大きさ（「表示」の拡大 ⌘+／縮小 ⌘−／実際のサイズ ⌘0、`AppSettings.textScale`、全ウィンドウ共通）：プレビューは `WKWebView.pageZoom`、エディタは `NSScrollView.magnification`。100% 以外のときはステータスバーに倍率を出し、クリックで戻す。本文の幅（狭い 40em・標準 52em・広い 68em・ウインドウの幅、`AppSettings.contentWidth`）はプレビューの CSS 変数 `--content-width`。どちらも見ていた位置を保つ（JS の resize・ResizeObserver、エディタは表示位置の文字を基準に戻す）。
- コードブロック：言語が書かれたもの（`language-xxx`）だけ highlight.js で色付けする（推測はしない）。新しく入ったブロックだけに行い、比較は色付け前の HTML で行う。差分更新で行番号を写すときは行番号を持つ要素どうしで対応させる（色付けの span で数がずれないように）。マウスを載せると右上に言語名とコピーのボタン（`#code-tools`、本文の外に重ねる。コピーは Swift が NSPasteboard に書く）。配色は GitHub に近い自前の CSS（ライト／ダーク）。
- Mermaid（` ```mermaid `）：図のある文書を開いた時に初めて `mermaid.min.js` を読み込む（約 5.5MB）。pre 要素は残して中身を SVG に置き換える（差分更新で pre ごと使い回すので、変わらない図は描き直さない）。`securityLevel: 'strict'`、配色はライト／ダークに合わせ、見た目が変わったら描き直す。描けなければ理由と元のコードを出す。コピーのボタンは元のコードを写す。描くのは1つずつ順番に（`mermaidQueue`）。
- タスクリストのチェックボックス：プレビューでクリックすると Swift が元の行の `[ ]`／`[x]` を入れ替える（`MarkdownFormatter.toggleTask`。引用の中・全角スペースの書き方も対象）。未保存の編集が無ければすぐ保存し、あれば本文だけ書き換えて未保存のままにする（ほかの編集を勝手に保存しない）。JS 側では見た目を変えず、描き直しを待つ。⌘Z／⇧⌘Z で戻せる・やり直せる（ウィンドウの取り消しの履歴に積む。エディタの NSTextView と同じ履歴なので、エディタでの入力と順に戻せる。取り消し・やり直しも同じ切り替えで、同じく未保存の編集が無ければすぐ保存する。切り替えた直後の内容と違えば何もしない）。エディタがあれば本文の1文字の編集として映し（`applyWithoutUndo`）、外部更新のようにエディタの取り消しの履歴を消さない。外部更新が来たら履歴は消す。
- 印刷（⌘P）・「PDF として書き出す…」：表示中のモードにかかわらずプレビューを `WKWebView.printOperation` で印刷する（PDF は保存先を選んで同じページ割りで書き出す）。印刷の間だけ WebView の見た目をライトにし、Mermaid もライトで描き直してから始める（終わったら戻す）。`@media print` で画面用の印・ルーラー・ボタンを出さず、本文だけを紙の幅で組む。
- 戻る（⌘[）・進む（⌘]）：見出し一覧・⌘J／⇧⌘J・付箋・文書内リンク・ルーラーで移動する前の位置（`ScrollPosition`）を積み、行番号で戻す（プレビューとエディタ共通）。JS からの移動は `willJump` を先に送る。
  - マウスの戻る／進むボタン（buttonNumber 3・4）と、トラックパッドの「ページ間をスワイプ」でも同じ（`AppDelegate` のローカルイベントモニタ。本文の上だけ）。3本指の設定では swipe のイベントで届く。2本指の設定では scrollWheel を自分で数える（`handleSwipeScroll`）：指を置いてから少し動いて横向きと分かり、その向きに戻れる／進める時だけスワイプにして、以後のスクロール（指を離した後の慣性も）は本文に渡さない。矢印の丸（`SwipeIndicator`）は指の動いた量だけ端から出て、110pt で出切って止まり、そこで指を離すと戻る／進む（手前で離したら何もしない）。AppKit の `trackSwipeEvent` は指を離した後も慣性で動き続けて勝手に決まるので使わない。丸はすりガラスにしない（速く動かすと残像になる）。横にスクロールできる表・コード（`.table-wrap`・`pre`）の上では、端まで行っていてもスワイプにしない（JS が `horizontalScroll` で知らせる。事故防止）。
- GitHub のアラート（`> [!NOTE]`・TIP・IMPORTANT・WARNING・CAUTION、大文字小文字は問わない。記号の後に同じ行で本文が続くものは対象外）：cmark-gfm は対応していないので、Swift が出力した HTML の引用を `blockquote.alert.alert-xxx` と見出しの段落（メモ・ヒント・重要・警告・注意）に書き換える。アイコンは CSS の mask（data URI の SVG）。
- リンク：http(s)/mailto は既定ブラウザで開く。相対パスの `.md` は新しいタブで開く（開いていれば前面に出す）。`other.md#見出し` なら、その文書の見出しの slug（`RenderedMarkdown.anchors`）から行を探して移動する（`Markdown.headingLine`：`user-content-` 付き・見出しの文字をそのまま書いたものも探す。開いたばかりなら最初の描画で戻す前回の位置の代わりにその見出しを出す。見つからなければ開くだけ）。確認用は `Samples/links.md`。それ以外のローカルファイルは**開かずに Finder で示すだけ**（`.app` や `.command` が起動してしまうため。git clone したファイルには quarantine が無く Gatekeeper も止めない）。`#fragment` は JS でページ内スクロール。それ以外のナビゲーションは全てキャンセルする。
- WebContent プロセスが落ちたら外枠を再読み込みして再描画する。ScriptMessageHandler は弱参照プロキシ経由で登録し、`dismantleNSView` で外す。
- 文書の生 HTML は差し込む前に `defuse()` で meta・base・link・object・embed を取り除き、form は中身だけ残し、img の name を外す（meta refresh と DOM clobbering で外枠の JS が止まるのを防ぐ）。
- DOM は最上位ブロック単位でモーフィングする（`data-sourcepos` を除いた `outerHTML` で比較。一致したノードは使い回して行番号だけ書き換える。上に行が挿入されても画像を再読み込みしない）。更新前に「画面上部の要素（top ≤ 16px の文書順で最後の要素）」と周辺ブロックの位置を控え、同じ JS タスク内で復元する。`ResizeObserver` で画像読み込みや幅の変化による高さの変化を補正する。
- スクロール位置は「上部の要素の開始行・終了行・要素内の割合」で JS から通知し、`ScrollMemory`（UserDefaults）に保存する。外枠を読み込んだ直後の描画で復元してから表示する。

### Markdown 処理（Swift：`Markdown.swift`）
- cmark-gfm（拡張は table / strikethrough / autolink / tagfilter / tasklist、footnotes）。オプションは `SOURCEPOS | UNSAFE | FOOTNOTES`。行番号は `data-sourcepos="開始行:列-終了行:列"`。
- 前処理（ファイル本体は変更しない。**行数は変えない**ので行番号はずれない）。コードフェンスの中はスキップする：
  1. 日本語太字の補正：行内で対になった `**…**` のうち、CommonMark の flanking 判定で太字にならない組だけを `<strong>…</strong>` に置き換える（インラインコード・バックスラッシュエスケープ・セル境界 `|` をまたぐ組は除外。`**` が奇数個の行には触れない）。
  2. 全角スペースの救済：行頭の `#{1,6}　`・`-　`・`*　`・`+　`・`1.　` の全角スペースを半角にする。
  3. フロントマター：1行目の `---` から次の `---`／`...` まで（中身の最初の行が `key:` の形のときだけ。水平線で始まる文書と取り違えないため）は空行にして cmark に渡さず、HTML の先頭に折りたたみの `<details class="front-matter">`（項目名と値の2列。続きの行は直前の項目の値に加える）を差し込む。開いた状態は書き換え後も保つ。エディタでは等幅・淡い色にする（行数が変わったら全体を整形し直す）。
- 1回のパースで HTML・TOC（見出しのレベル・行・テキスト）・文字数を同時に得る。
- 大きな文書（1MB で HTML は約 2.5MB）でも固まらないように：
  - 本文から作るもの（描画・変更の差分・「変更」欄・付箋の追従。`DerivedContent`）はメインスレッドの外で作り（`DocumentModel.refreshDerived`）、できた時に本文が変わっていなければ反映する。外部更新の前の内容は反映するまで持ち越す（「最新の更新」の差分の元）。開いた直後は描画ができるまでプレビューに何も渡さない（`hasRendered`）。ほかの文書のリンクの見出しへの移動は描画を待つ。
  - cmark の HTML の書き換え（表の入れ物・見出しの id・アラート）は `Markdown.postprocess` が `<` の位置だけを memchr で拾ってバイト列のまま1回で行う（Swift の Regex で何度も置き換えると数百 ms かかった）。前処理は直すもの（全角スペース・`**`）を含む行だけを、バイト列で探して直す。
  - 検索の正規化と、エディタの大きな選択（2 万字超）の文字数もメインスレッドの外で行う。
  - 目安（Debug ビルド・1MB）：描画 約 0.5 秒 → 約 0.2 秒。外部更新のたびのメインスレッドの停止 約 0.57 秒 → ほぼ 0。エディタに初めて切り替えた時の全体の整形（約 0.25 秒）はメインスレッドに残る（文字の属性はメインスレッドでしか付けられない）。
- 見出しには GitHub（github-slugger）と同じ規則の id を `user-content-` 付きで付ける（`Slugger`）。`#fragment` のリンクは `user-content-<id>` → 書かれたままの id・name の順に本文の中だけを探す（外枠の `#content` などに飛ばない）。
- ステータスバーの左に最終更新（ファイルの更新日時。開いた時・外部更新・自分の保存で読み直す）を「たった今／N分前／日時（1 時間以上前）」（`UpdateTime`）で出し、15 秒ごとに表示を進める。1 分以内の更新はオレンジ（AI がまだ書いているかもしれない）。開いてから（確認済みにしてから）外部で更新された回数も「外部で N回更新」と出す。マウスを載せると正確な日時。
- **文字数の数え方**：TEXT と インラインCODE ノードの文字（書記素）から空白・改行を除いて数える。コードブロック・URL・画像の alt・生HTMLは数えない。選択文字数は選択テキストの空白以外の書記素数。

### Diff とベースライン
- S0＝ベースライン（ファイルを開いた時／「確認済み」を押した時）、S_prev＝直前の外部更新が来る前、S_now＝現在。
- 未確認の変更＝diff(S0, S_now)（淡い色、累積するので消えない）、最新の更新＝diff(S_prev, S_now)（濃い色）。
- `⌘J`（次）／`⇧⌘J`（前）：⌘J は更新後の最初の1回は最新の変更の先頭へ、以降は現在位置から文書順に巡回する。⇧⌘J は現在位置より手前へ逆順に巡回する（端まで行ったら反対の端へ回る。選び方は `LineChanges.nextJumpLine` / `previousJumpLine`）。確認済みボタンで S0＝S_prev＝S_now にそろえる。
- 行から要素を探す（`elementForLine`）ときは、開始行がその行以下で一番後ろの要素を全部の中から選ぶ。脚注は HTML の末尾にまとめて出て文書順でも行番号が戻るので、順に見て途中で打ち切ると、脚注より後の行（末尾への追記など）が文書の前の方へ飛んでしまう。
- 行単位の差分は Swift の `difference(from:)`。JS は `data-sourcepos` の範囲と変更行が重なる要素に `.chg` / `.chg-latest`、削除位置の直後（末尾なら直前）の要素に `.del-before` / `.del-after` を付ける（クラス自体には見た目を付けない。赤線は `#gutter` 層に引く。要素の影で描くと、移動した時に光らせる枠の角の丸みに沿って端が曲がったため）。エディタは本文に重ねた `EditorMarksView` に同じ印を描き、最新の更新だけ一時属性で淡く塗る。
- 差分は共通の行で区切った「かたまり」単位で数え、消えた行（`LineChanges.removed`：削除の位置か書き換えた範囲の先頭行 → 行数と本文。200行まで）も持つ。間に空行しか無い削除は1つにまとめる（見出しと本文を消すと間の空行だけが残り、削除が2つに分かれて見えるため）。
- プレビューの変更の印は控えめにする（本文は最新の更新だけごく淡く塗る。削除の位置は本文の幅で 2px の赤線、左に赤い三角、右端（列の右の余白）に赤い丸い「−行数」の印。三角と印は赤線の中心にそろえ、「−」は文字だと高さがずれるので図形で描く）。色はオレンジ1系統で、濃さで新しさを表す。
  - 本文の列の左 6px に 3px の縦線（未確認の変更は淡い、最新の更新は濃い。縦に接する要素は1本にまとめ、最新を上に重ねる）。削除の位置には赤い小さな三角。どちらも `#gutter` 層に置く（当たり判定は線の左右 5px）。
  - 線・三角・「−行数」にマウスを載せるとすぐ吹き出しで、変更前の内容（追加だけなら「変更前の内容はありません」）・削除された行を見せる。吹き出しへマウスを移しても消えないので文字を選べる。
  - 付箋のホバー印は、本文のすぐ左（線の当たり判定）では出さない。
  - エディタも同じ印（`EditorMarksView`：本文に重ねた子ビュー。クリックは素通し。見えている範囲の分だけレイアウトから位置を求めて描く）。吹き出しは NSPopover（SwiftUI の `RemovedLinesView`）で、マウスが印か吹き出しの上にある間は出しておく（200ms ごとに確かめる）。
- プレビューの右端のルーラー（`#ruler`、当たり判定 10px・印は 3px の1列）：文書全体を画面の高さに縮めて、変更と削除の位置を並べる（検索中だけ一致の位置を上に重ねる。付箋はサイドバーにあるので出さない）。印の近く（6px 以内）をクリックするとそこへ移動する。エディタには出さない（正確な位置を出すには文書全体のレイアウトが要り、編集のたびに重くなるため）。
- 自分で編集・保存した内容も「確認済み以降の変更」として表示する（3-way差分はしない）。
- 比較の基準（`BaselineSource`）はツールバーのメニューで「開いた時点・確認済みの時点」と「git HEAD」を切り替える（`Git.swift`：`git -C <dir> show HEAD:./<name>` をメインスレッド外で実行）。git HEAD の基準は外部更新のたびに読み直す。「確認済み」はどちらの基準でも今の内容を新しい基準にする（git HEAD を選んでいた場合は通常の基準に戻る）。最後に選んだ基準は `AppSettings.compareWithGitHead` で次に開くファイルへ引き継ぐ（git 管理外なら黙って通常の基準）。

### ファイル監視（`FileWatcher.swift`）
- `O_EVTONLY` で開いたファイルを vnode の `DispatchSource`（write/extend/delete/rename）で監視する。delete/rename を受けたら監視を外して同じパスを最大約1秒リトライして開き直す（アトミック保存対応）。見つからなければバナーを出し、表示内容は残す（読み込めない理由が他にあればそれを出す）。
- イベント後は 150ms デバウンスしてから読み込む。空ファイルを読んだら1回だけ再試行する（truncate→write の途中を拾わないため）。**最後に読み書きした内容と同一なら何もしない**（自分の保存による自己発火防止を兼ねる）。
- 読み込みは `Data(regularFileAt:limit:)`：通常のファイルだけを 10MB（Finder と同じ 1000 単位）まで（FIFO で固まったり、/dev/zero へのシンボリックリンクでメモリを使い果たしたりしないよう、`O_NONBLOCK` で開いて fstat で確かめる）。読まない理由は `FileReadRefusal`（通常のファイルでない・大きすぎる〈実際の大きさと上限〉・文字コードを判別できない）で、開いた時は「読み込めませんでした」の説明に、外部更新の時はバナーに出す（表示は最後に読んだ内容のまま）。UTF-8 →だめなら Shift_JIS。BOM はバイト列で判定する（Foundation の UTF-8 デコードは BOM を黙って取り除くため）。内部では改行を LF に正規化し、保存時に元の文字コード・改行コード・BOM（`FileFormat`）で書き戻す。

### エディタ（`EditorView.swift`）
- `NSTextView`（**TextKit 1 を明示**）。見出し・太字・コード・テーブル行のライブスタイリング。`hasMarkedText()` 中は再スタイルしない。フォントは本物の属性、色付け・Diff・検索・全角スペースは一時属性で付ける。`typingAttributes` は毎回リセットする。
- 外部リロードは共通する先頭と末尾を除いた中間部分だけを置き換える（選択とスクロールを維持）。未保存の編集がある時はバナーで「再読み込み」か「上書き保存」を選ばせる。`Cmd+S` は `.atomic` で保存する。
- 書式（見出し・太字・斜体・取り消し線・コード・リンク・リスト・引用・コードブロック・表）は `MarkdownFormatter`（純粋関数・切り替え式）で置き換え内容を作り、エディタは shouldChangeText〜didChangeText で囲んで適用する（⌘Z で取り消せる）。入口は右クリックメニュー（`textView(_:menu:for:at:)`）、「書式」メニュー（⌘1〜3・本文 ⌥⌘0・⌘B・⌘I・⇧⌘X・⌘K。⌘0 は macOS の標準どおり「実際のサイズ」）、エディタ表示中だけ出るツールバーの「書式」ボタン。
  - 文字の書式：選択の前後の空白・改行は記号の外に出す。複数行は行ごとに囲む。未選択なら、カーソルが記号で囲まれた範囲の中にあれば外し、なければ空の組を入れて間にカーソル（「****」の間でもう一度押すと消す）。太字の中で斜体の空の組は入れない。
  - 行の書式：空の行では記号（`# ` `- ` `1. ` `> ` など）だけ入れて後ろにカーソル。表は前後に空行を確保する（段落に続けると表にならない）。
- プレビューとエディタは両方とも生かしたまま隠すだけにする（WKWebView の再読み込みと Undo 履歴の消失を防ぐ。エディタは初回に作る）。スクロール位置の通知は表示中のビューからだけ受け付ける。
- 未保存の編集中、または編集開始〜確定前（IME の変換中を含む）の外部更新は `pendingDiskText` に保留し、バナーで選ばせる。ウィンドウを閉じる時とアプリ終了時に、未保存なら保存を確認する。
- モード間の同期は「先頭に見えている行番号＋ブロック内での比率」で行う。`UserDefaults` にファイルパスをキーにして保存する（最近使った200件まで）。

### あいまい検索（`FuzzySearch.swift`）
- 書記素単位で NFKC → NFC（Foundation の NFKC は ｶﾞ を合成しないため）→ ひらがなをカタカナへ → 小文字化。正規化結果は本文が変わるまでキャッシュする（1MB で約 0.7 秒〈Debug〉かかるので、メインスレッドの外で作る）。正規化後と元の UTF-16 オフセットの対応表を作る。濁点の有無までは無視しない。
- エディタ：`textView.string` に照合し、一時属性でハイライトする。プレビュー：JS が DOM テキストを Swift へ送り、Swift で照合して範囲を返す。JS は CSS Custom Highlight API で塗る（DOM は変更しない）。両モード共通の自前検索バー（⌘F／⌘G／⇧⌘G は「編集」メニューの textEditing を置き換え）。
- 検索バーは Safari の「ページ内を検索」と同じ構成（AppKit の NSSearchField・前後の ControlGroup・件数・完了）。Return で次、Shift+Return で前、esc で閉じる。
- 置換（⌥⌘F・検索バーの左の ˃）：エディタだけ（プレビューで押したらエディタに切り替える）。検索バーの2段目に置換後の文字・「置換」（今の一致を置き換えて、その後ろの一致へ。Return でも）・「すべて置換」（件数を出す）。置き換えるのは検索で光っている一致（あいまい検索で見つけたものも含む）。`SearchReplace`（純粋関数）で `TextEdit` を作り、書式と同じ `apply(_:)` で適用する。「すべて置換」は最初の一致から最後の一致までを1回の置き換えにまとめるので、⌘Z の1回で戻せる。置き換えた直後は編集で予約された遅い再検索を取り消して照合し直す。

### サイドバー（変更・付箋・見出しの欄）
- サイドバーは上から「変更」「付箋」「見出し」の3つの欄に分け、区切り線をはさんで別々にスクロールする。変更と付箋は 0 件なら欄ごと出さず、中身の高さだけ取り、上限（変更はサイドバーの 3 割〈最低 96pt〉、付箋は 2 割〈最低 72pt〉。`CappedScrollView`）を超えたらその欄の中でスクロールする。残りを見出し一覧が使う（欄の名前は上に固定）。見出しの多い文書の下の方を読んでいても変更の一覧が常に見え、変更が多くても付箋が隠れない。
- サイドバーの一番上の「変更」欄（変更が無ければ出さない。見出しの右の件数と ˅ で畳める）：変更のかたまりを文書順に1行ずつ（`LineChanges.items` → `ChangeItem`。書き換え・追加・削除、最新の更新か、変わった行の書き出し）。印はプレビューと同じ色（未確認は淡いオレンジ・最新は濃いオレンジ・削除は赤い三角で、削除は消えた行を取り消し線で出す）。マウスを載せると行番号の前に種類（書き換え・追加・削除、最新か）をすぐ出す（ツールチップは出るまで 1 秒ほどかかるので使わない）。クリックで移動（⌘[ で戻れ、続けて ⌘J ／ ⇧⌘J を押すとそこから進む）。一覧は変更が変わった時だけ作り直す（スクロールのたびに作らない）。
- 見出し一覧は標準の List ではなく ScrollView＋LazyVStack（行間 0）で自前に描く。List は行間に当たり判定の無い隙間があってホバーが途切れて点滅し、選択色も調整できないため。段の深さは一番浅い見出しを 0 段目として数え、字下げと文字で示す（0 段目は太字、1 段目は通常、2 段目以降は小さく淡く）。今読んでいる見出し（`activeHeadingLine`）はアクセント色の淡い背景で示し（文字色は変えない。太字にすると 0 段目と区別できないので使わない）、ホバーはそれより薄い背景（各行の中で状態を持つ）。一覧自体も scrollTo で追従させる。節（見出しから次の見出しの直前まで）に変更があれば右端にオレンジの点を出す（最新の更新は濃く、未確認の変更は淡く。`LineChanges.sectionLines`）。「見出し」欄の見出しは付箋の有無にかかわらず常に出す。
- スクロール位置の通知は debounce ではなく **throttle（80ms）** にする（debounce だとスクロールが止まるまで追従しない）。UserDefaults への保存だけは 500ms の debounce。サイドバーの表示状態はモデルで持ち、ツールバーと ⌃⌘S で切り替える。

### 付箋（`Bookmarks.swift`）
- `Bookmark { line, snippet }`。snippet は行頭の Markdown 記号・強調記号・表の `|` を除いた先頭30文字。ファイルパスごとに `BookmarkStore`（UserDefaults、200件まで）へ保存する。
- **追従は行単位の差分で行う**（`LineDiff.lineMap`）。付箋の行が書き換えられていなければ差分でそのまま新しい行へ移す（同じ文面の行が複数あっても迷わない）。付箋の行自体が書き換え・移動された場合だけ、新しく入った行から同じ snippet の行を探し、前後の変わっていない行から推定した位置に一番近いものを選ぶ。無ければ推定位置に置く。追従後は snippet をその行の内容に更新する。
- 外部更新・自分の編集（描画の 300ms デバウンス後）・プレビューへの切り替えのたびに `updateBookmarks()` で追従させる。開いた時は元の内容が無いので、snippet が合わない付箋を一番近い同じ snippet の行へ移す（`relocate`）。
- 印は3か所（プレビュー・エディタ・サイドバー）とも、アクセント色の縦向きのしおりリボン（下端に切れ込み）にそろえる。横に倒すと本文を指す矢印に見えるので使わない。
- プレビュー：本文の要素には手を加えず、`body` 直下の `#gutter` 層に絶対配置で印を置く（本文の列の左の余白、1行目の高さの中央）。付けられる要素は入れ物（ul/ol/blockquote/table）とセルを除いたもの（表は tr ごと）。本文の列の左の余白にマウスを置いたときだけ（本文の上では目障りなので出さない）、その高さの要素に薄い印を出し、クリックで `toggleBookmark`（要素に付いている付箋の行をまとめて送る。無ければ開始行に付ける）。印の位置は描画・ResizeObserver・ウィンドウのリサイズで置き直す。ホバーの印は、マウスがプレビューの外へ出たら消す（WebKit は mouseleave を送らないことがあるので、`DocumentWebView.mouseExited` からも `hideBookmarkHover()` を呼ぶ）。
- エディタ：NSTextView の子ビュー `BookmarkGutterView`（左の余白の幅、クリックは素通し）が印を描く。NSTextView 自身の `draw` では文字の領域の外が切り取られるため。
- `⌘D`（「表示」メニュー）：エディタではカーソル行、プレビューでは画面上部の要素の行範囲でトグルする。サイドバーの「変更」の下に「付箋」欄（0件なら出さない。抜粋・行番号。件数と ˅ で畳める）。クリックで `jump(toLine:)`。一覧は移動に使うので、押し間違えて外さないよう行に × は出さず、外すのは右クリックのメニュー（「この付箋を外す」「すべての付箋を外す…」。すべて外す時は確認する）か ⌘D・プレビューの左の余白の印。

### 最近開いたファイル（`RecentFiles.swift`）
- `RecentFile { path, project, pinned, openedAt }` を UserDefaults に JSON で保存する。並びはピン留め → それ以外、それぞれ最近開いた順。ピン留め以外は 30 件まで。開いた時（既存ウィンドウを前面に出した時も）に `noteOpened`、あわせて `NSDocumentController.noteNewRecentDocumentURL` も呼ぶ。
- プロジェクト名（`ProjectRoot.name`）：親フォルダを遡って `.git`（worktree・サブモジュールではファイル）のあるフォルダの名前。無ければ親フォルダの名前。ディスクを見るので開いた時に1回だけメインスレッドの外で調べ、履歴に保存する。
- ウィンドウのサブタイトルにプロジェクト名を出す。サブタイトルはタブに出ないので、**同じ名前のファイルを複数開いている時だけ** `window.tab.title` を「名前 — プロジェクト」にする。
- `RecentFilesPanel`（NSPanel ＋ SwiftUI の `RecentFilesView`）がクイックスイッチャーと起動画面を兼ねる。開くたびにビューを作り直す（絞り込みと選択を初期化）。今開いているファイルは「表示中」と出し、初期選択は次の候補にする。絞り込みは空白区切りの全語が名前・プロジェクト・パスのどれかに含まれるか（大文字小文字・全角半角は区別しない）。↑↓・return・esc。文書ウィンドウがある時だけ、他をクリックしたら閉じる（起動直後はアプリが前面に出る前に閉じてしまうため）。
- 行：ファイル名＋プロジェクト名のバッジ、2行目はフォルダのパス（~ に置換、中間を省略）。ホバーでピン留めと削除、右クリックで Finder に表示。消えたファイルは自動では消さず（外部ディスクや一時的な移動のため）、一覧を出す時にメインスレッドの外で調べて灰色で表示し、「見つからない N件を削除」を出す。履歴から存在しないファイルを開こうとしたら、履歴から削除するか尋ねる。
- 前回のタブの復元（`OpenFilesSession`、`AppSettings.restoreOpenFiles`、既定でオン）：ウィンドウごとのタブの並び・選んでいたタブ・ウィンドウの位置と大きさ・一番手前のファイルを、ファイルを開くたび・閉じ終わった時・終了する時に、開いているものがあれば記録する（閉じたタブは記録から外れる）。全部閉じた時は記録し直さないので、全部閉じる直前の並びが残る（閉じるボタンはタブをまとめて閉じるので、閉じ終わってから判断する）。起動した時と、ウィンドウを全部閉じてから Dock のアイコンをクリックした時（`applicationShouldHandleReopen`）に同じ並びで開き直す。消えたファイルは黙って飛ばす（`restorable`）。Finder からファイルを開いて起動した時は復元しない。何も開けなければ最近使ったファイルの一覧を出す。
- 「ファイル」メニューの「最近使ったファイル」サブメニュー（名前 — プロジェクト、「履歴を消去（ピン留めは残す）」）。

### Quick Look（機能拡張：`MDYomitokiQuickLook`）
- Finder のスペースキーで Markdown を見せる機能拡張（`com.apple.quicklook.preview`）。アプリの `Contents/PlugIns` に入る。対象は `net.daringfireball.markdown`。
- HTML を作って渡す方式（`QLPreviewProvider`・`QLIsDataBasedPreview`）。表示は macOS がする。WebView を自分で持つ方式より軽く、壊れにくい。
  - Markdown の変換（`Markdown.swift`）・ファイルの読み込み（`TextFile.swift`：文字コードの判別・大きさの上限）・見た目（`preview.css`）はアプリと共通（project.yml で同じファイルを両方のターゲットに入れる）。
  - コードの色付けは、アプリと同じ `highlight.min.js` を JavaScriptCore で動かして HTML にしておく（言語が書かれたものだけ。合わせて 300KB まで。機能拡張の中では JIT が使えず遅いため）。Mermaid の図は描かない（コードのまま）。
  - Sandbox が必須（`QuickLook.entitlements`）。読めるのは渡されたファイルだけで、ネットにもつながない（見ただけで外に通信しない）ので、画像は「画像：代替テキスト」の枠にする。
  - Content-Security-Policy でスクリプト・外部の読み込みを止め、文書の生 HTML の meta・base・link・object・embed・form は文字にする。
  - 描くのは先頭の 1MB まで（Quick Look には時間の制限がある）。切ったときは冒頭にその旨を出す。10MB を超えるファイルは読まない（Quick Look の既定の表示になる）。
- 別のアプリ（MDHero など）も Markdown の Quick Look を持っていると、そちらが使われることがある。「システム設定」→「一般」→「ログイン項目と機能拡張」→「Quick Look」で切り替える。登録の状況は `pluginkit -m -v -p com.apple.quicklook.preview`。開発中のビルドの機能拡張は、`make build` の後に起動するか `pluginkit -a <appex>` で登録される。
- 配布：Xcode が Developer ID・Hardened Runtime・タイムスタンプで署名する（xcconfig がすべてのターゲットに効く）。`make archive` が機能拡張の Hardened Runtime も確かめる。

## ファイル構成

```
project.yml / Makefile / Config/App.xcconfig
Config/dmg_settings.py # dmg のウィンドウの見た目（dmgbuild の設定）
MDYomitoki/
  App.swift            # @main・メニューコマンド・AppDelegate・DocumentWindowController
  DocumentModel.swift  # 1文書の状態
  ContentView.swift    # NavigationSplitView・TOC・ステータスバー
  PreviewView.swift    # WKWebView・独自スキームのハンドラ・JSとの橋渡し
  Markdown.swift       # 前処理・cmark-gfm・TOC・文字数
  FileWatcher.swift    # vnode 監視と張り直し
  LineDiff.swift       # 行単位の差分（LineChanges）
  EditorView.swift     # NSTextView（TextKit 1）・ライブスタイリング（MarkdownStyler）
  MarkdownFormatter.swift # 書式の付け外し（純粋関数）
  FuzzySearch.swift    # 日本語あいまい検索（NormalizedText）
  Git.swift            # git HEAD 時点の内容を取り出す
  Bookmarks.swift      # 付箋（抜粋・行の追従・保存）
  RecentFiles.swift    # 最近開いたファイル（履歴・プロジェクト名・クイックスイッチャー）
  AppSettings.swift    # アプリ全体の設定（UserDefaults）
  Updater.swift        # 自動アップデート（Sparkle）
  TextFile.swift       # ファイルの読み込み（文字コード・上限。Quick Look と共通）
  Info.plist
  AppIcon.icon/        # アプリアイコン（Icon Composer 形式。make_appicon.py で生成）
  Resources/preview.html, preview.css, preview.js
  Resources/Credits.html # 「このアプリについて」に出すライセンス表示
MDYomitokiQuickLook/   # Quick Look の機能拡張（PreviewProvider.swift・Info.plist・QuickLook.entitlements）
MDYomitokiTests/
ReleaseNotes/          # 版ごとのリリースノート（<版>.md。アップデートの画面と GitHub の Release に出る）
Design/AppIcon/make_appicon.py  # アイコンの生成スクリプト（AppIcon.icon の正）
Design/icon.png        # README のアイコン
Design/dmg/            # dmg の背景（make_background.py が background.tiff を書き出す）
Samples/               # 表示の確認用（sample.md：表・太字・画像など、links.md：ほかのファイルの見出しへのリンク）
README.md / LICENSE
```
