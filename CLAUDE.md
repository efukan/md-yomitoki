# MDよみとき（MDYomitoki）

AIエージェント（Claude Code等）が外部で書き換える日本語Markdownを監視し、表・変更箇所を素早く「よみとく（閲覧・検索・微修正）」ための macOS ネイティブリーダー兼エディタ。

利用者向けの説明は `README.md`。このファイルは開発する人と AI エージェント向けの入口で、すべての作業に効くルールを置く。機能ごとの仕様と実装の理由（なぜそうしたか）は `docs/` に置く。

- 表示名：『MDよみとき』／内部ターゲット名：`MDYomitoki`／Bundle ID：`jp.efukan.mdyomitoki`
- 名称・識別子・バージョン・著作権表示（`APP_COPYRIGHT`、「© 2026 efukan」）・公開先（`GITHUB_REPOSITORY`）・問い合わせ先（`SUPPORT_EMAIL`）は **`Config/App.xcconfig` の1箇所だけ** で管理する（Info.plist は変数参照のみ）

## 作業ルール（必ず守る）

1. 変更したら `make build` と `make test` を通し、エラーと警告を0にする。まとまった機能を入れたら、次の作業へ勝手に進まず、作業を止めてユーザーに動作確認を求める。
2. **KISS**：ファイル数は最小限、フラットな構成にする。不要なProtocol抽象化やレイヤー分割はしない。推論はエッジケース（ファイル競合・IME・スクロール飛び・リーク）の事前回避に使う。
3. 純粋関数（太字補正・文字数・差分・検索正規化）はユニットテスト（Swift Testing）で固める。
4. 機能に手を入れる前に、下の表の該当する文書を読む。仕様や実装の理由が変わったら、その文書（全体に効くことならこのファイル）も直す。

## 仕様の文書（`docs/`）

| 触るところ | 読む文書 |
|---|---|
| Markdown の変換、プレビューの表示（表・コード・数式・リンク・行番号・印刷・戻る／進むなど）、Quick Look | [preview.md](docs/preview.md) |
| ファイル監視、差分、変更の印、⌘J、ルーラー | [changes.md](docs/changes.md) |
| エディタ、書式、検索と置換 | [editor.md](docs/editor.md) |
| ウィンドウとタブ、開く導線、最近開いたファイル、サイドバー、付箋 | [app.md](docs/app.md) |
| 依存ライブラリ、リリース、dmg、自動アップデート、ライセンス表示、アイコン | [release.md](docs/release.md) |

このファイルは毎回読み込まれるので、機能の詳細は `docs/` に書く（`@` で読み込むと分けた意味が無くなるので、リンクのままにする）。

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

## 全体に効く決まり

- 直接配布（Developer ID ＋公証、**App Sandbox なし**）。開発中は Apple Development 証明書で署名する（チームID は xcconfig）。Hardened Runtime は Release のみ有効にする（Debug はテストバンドル注入のため無効）。
- ⚠️ Sandbox なしでも、`~/Documents`・`~/Desktop`・`~/Downloads` などの中にある「ユーザーが直接開いていないファイル」（隣の画像など）を初めて読むときは、プライバシー保護（TCC）の許可ダイアログが出て、許可されるまで `open()` が**ブロックされる**。
  - ディスク I/O はメインスレッドで行わない（スキームハンドラはバックグラウンドで読む）。
  - ad-hoc 署名だとビルドのたびに TCC の許可がリセットされるので使わない。
- エンタイトルメントは無し（WebKit の JIT は WebContent プロセス側なので不要。cmark は静的リンク）。
- 最小OSは **macOS 15**。Swift 6（strict concurrency）。UI 状態は `@MainActor`。
- XcodeGen（`project.yml`）＋ `Config/App.xcconfig` ＋ `Makefile`。依存ライブラリと更新の仕方は `docs/release.md`。
- メニューコマンドは前面ウィンドウのモデル（`AppDelegate.activeModel`。アプリが前面に無い時は一番手前の文書ウィンドウ）へ届ける。**キーボードショートカットは必ずメニュー（SwiftUI の `.commands`）に置く**。ツールバーのボタンに `.keyboardShortcut` を付けても、AppKit の NSWindow に SwiftUI のツールバーを橋渡しする構成では効かない。

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
docs/                  # 機能ごとの仕様と実装の理由（表は上の「仕様の文書」）
ReleaseNotes/          # 版ごとのリリースノート（<版>.md。アップデートの画面と GitHub の Release に出る）
Design/AppIcon/make_appicon.py  # アイコンの生成スクリプト（AppIcon.icon の正）
Design/icon.png        # README のアイコン
Design/dmg/            # dmg の背景（make_background.py が background.tiff を書き出す）
Samples/               # 表示の確認用（sample.md：表・太字・画像など、links.md：ほかのファイルの見出しへのリンク）
README.md / LICENSE
```
