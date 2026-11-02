# Markdown の表示

`Markdown.swift` が HTML を作り、アプリのプレビューと Quick Look がそれを見せる。変更の印は [changes.md](changes.md)、付箋の印は [app.md](app.md)。

## Markdown の変換（`Markdown.swift`）

### 変換

- cmark-gfm（拡張は table / strikethrough / autolink / tagfilter / tasklist、footnotes）。オプションは `SOURCEPOS | UNSAFE | FOOTNOTES`。行番号は `data-sourcepos="開始行:列-終了行:列"`。
- 前処理（ファイル本体は変更しない。**行数は変えない**ので行番号はずれない）。コードフェンスの中はスキップする：
  1. 日本語太字の補正：行内で対になった `**…**` のうち、CommonMark の flanking 判定で太字にならない組だけを `<strong>…</strong>` に置き換える（インラインコード・バックスラッシュエスケープ・セル境界 `|` をまたぐ組は除外。`**` が奇数個の行には触れない）。
  2. 全角スペースの救済：行頭の `#{1,6}　`・`-　`・`*　`・`+　`・`1.　` の全角スペースを半角にする。
  3. フロントマター：1行目の `---` から次の `---`／`...` まで（中身の最初の行が `key:` の形のときだけ。水平線で始まる文書と取り違えないため）は空行にして cmark に渡さず、HTML の先頭に折りたたみの `<details class="front-matter">`（項目名と値の2列。続きの行は直前の項目の値に加える）を差し込む。開いた状態は書き換え後も保つ。エディタでは等幅・淡い色にする（行数が変わったら全体を整形し直す）。
- 1回のパースで HTML・TOC（見出しのレベル・行・テキスト）・文字数を同時に得る。

### 大きな文書

- 大きな文書（1MB で HTML は約 2.5MB）でも固まらないように：
  - 本文から作るもの（描画・変更の差分・「変更」欄・付箋の追従。`DerivedContent`）はメインスレッドの外で作り（`DocumentModel.refreshDerived`）、できた時に本文が変わっていなければ反映する。外部更新の前の内容は反映するまで持ち越す（「最新の更新」の差分の元）。開いた直後は描画ができるまでプレビューに何も渡さない（`hasRendered`）。ほかの文書のリンクの見出しへの移動は描画を待つ。
  - cmark の HTML の書き換え（表の入れ物・見出しの id・アラート）は `Markdown.postprocess` が `<` の位置だけを memchr で拾ってバイト列のまま1回で行う（Swift の Regex で何度も置き換えると数百 ms かかった）。前処理は直すもの（全角スペース・`**`）を含む行だけを、バイト列で探して直す。
  - 検索の正規化と、エディタの大きな選択（2 万字超）の文字数もメインスレッドの外で行う。
  - 目安（Debug ビルド・1MB）：描画 約 0.5 秒 → 約 0.2 秒。外部更新のたびのメインスレッドの停止 約 0.57 秒 → ほぼ 0。エディタに初めて切り替えた時の全体の整形（約 0.25 秒）はメインスレッドに残る（文字の属性はメインスレッドでしか付けられない）。

### 見出しの id と文字数

- 見出しには GitHub（github-slugger）と同じ規則の id を `user-content-` 付きで付ける（`Slugger`）。`#fragment` のリンクは `user-content-<id>` → 書かれたままの id・name の順に本文の中だけを探す（外枠の `#content` などに飛ばない）。
- **文字数の数え方**：TEXT と インラインCODE ノードの文字（書記素）から空白・改行を除いて数える。コードブロック・URL・画像の alt・生HTMLは数えない。選択文字数は選択テキストの空白以外の書記素数。

## プレビュー（WKWebView）

### 読み込みと更新

- 外枠HTML（`Resources/preview.html|css|js`）を独自スキーム `yomitoki://app/` から**一度だけ読み込み、以後はリロードしない**。外枠への遷移は Swift から読み込みを始めた時（`shellLoadPending`）だけ許可する（文書の meta refresh で再読み込みが延々と続かないように）。更新は `callAsyncJavaScript("render(html, base)")`（引数バインドで渡すのでエスケープ事故がない）。
- `WKURLSchemeHandler`：`yomitoki://app/<name>` は同梱リソース、`yomitoki://file/<絶対パス>` はディスク上の**画像だけ**を返す（`no-store`。シンボリックリンクは解決した先も画像の名前であること、通常のファイルで 100MB 以下であることを確かめる）。文書ごとに `<base href="yomitoki://file/<元フォルダ>/">` を設定するので、相対パス・絶対パスの画像が一時ファイルなしで表示される。
- WebContent プロセスが落ちたら外枠を再読み込みして再描画する。ScriptMessageHandler は弱参照プロキシ経由で登録し、`dismantleNSView` で外す。
- DOM は最上位ブロック単位でモーフィングする（`data-sourcepos` を除いた `outerHTML` で比較。一致したノードは使い回して行番号だけ書き換える。上に行が挿入されても画像を再読み込みしない）。更新前に「画面上部の要素（top ≤ 16px の文書順で最後の要素）」と周辺ブロックの位置を控え、同じ JS タスク内で復元する。`ResizeObserver` で画像読み込みや幅の変化による高さの変化を補正する。
- スクロール位置は「上部の要素の開始行・終了行・要素内の割合」で JS から通知し、`ScrollMemory`（UserDefaults）に保存する。外枠を読み込んだ直後の描画で復元してから表示する。

### 文書を信用しないための対策

- リモート画像（http/https）は既定で表示する。「表示」メニューの「リモート画像を読み込む」（`AppSettings.loadRemoteImages`）でオフにすると、`WKContentRuleList`（`RemoteContentBlocker`）で http/https の読み込みそのものを止める（srcset・CSS の背景・SVG の image なども含む。ブロッカーを入れ終えてから描画する）。あわせて JS が文書へ入れる前に img の src を `data-remote-src` に退避し、オンに戻した時に読み込み直す。CSP は `img-src` のみ外部許可、スクリプト・CSS・iframe は同梱のものだけ。ATS は `NSAllowsArbitraryLoadsInWebContent`。読み込み失敗時は `img.broken` で枠と alt を表示する。
- `#content` は `contain: paint`（文書の生 HTML の `position: fixed` を本文の中に閉じ込め、画面全体を覆う偽の表示やリンクを置かせない）。
- 文書の生 HTML は差し込む前に `defuse()` で meta・base・link・object・embed を取り除き、form は中身だけ残し、img の name を外す（meta refresh と DOM clobbering で外枠の JS が止まるのを防ぐ）。
- リンク：http(s)/mailto は既定ブラウザで開く。相対パスの `.md` は新しいタブで開く（開いていれば前面に出す）。`other.md#見出し` なら、その文書の見出しの slug（`RenderedMarkdown.anchors`）から行を探して移動する（`Markdown.headingLine`：`user-content-` 付き・見出しの文字をそのまま書いたものも探す。開いたばかりなら最初の描画で戻す前回の位置の代わりにその見出しを出す。見つからなければ開くだけ）。確認用は `Samples/links.md`。それ以外のローカルファイルは**開かずに Finder で示すだけ**（`.app` や `.command` が起動してしまうため。git clone したファイルには quarantine が無く Gatekeeper も止めない）。`#fragment` は JS でページ内スクロール。それ以外のナビゲーションは全てキャンセルする。

### 見た目

- ネイティブ感：`drawsBackground=false`、`color-scheme: light dark`、`-apple-system-*` システムカラー、`-apple-system`／ヒラギノ、`line-height: 1.75`、`line-break: strict`、見出しに `palt`。初回表示は `ready` まで WebView を透明にしておく。
- 見出し：段の違いは大きさ・太さ・濃さで、節の区切りは上の余白で示す（下線は文書の題になる h1 だけ）。上の段ほど上の余白を広くし、見出しの直後に見出しが続くときは詰める。引用の文字は本文の 78% の濃さ（secondary-label では薄すぎるため）。
- 表は Swift 側で `<div class="table-wrap">` で包み、表単体で横スクロールできるようにする（角丸枠・ヘッダー背景・ストライプ）。
  - 見出し行の固定：`.table-wrap` が横スクロールの入れ物なので `position: sticky` は画面に効かない。見出し行が画面の上に隠れた表があれば、JS が見出し行の複製（列の幅を写す・`box-sizing: border-box`）を画面の上端に重ね（`#sticky-head`）、表の横スクロールに合わせて動かし、表の終わりで押し上げる。表の行へ移動するときは見出し行の高さだけ下に出す。
- 文字の大きさ（「表示」の拡大 ⌘+／縮小 ⌘−／実際のサイズ ⌘0、`AppSettings.textScale`、全ウィンドウ共通）：プレビューは `WKWebView.pageZoom`、エディタは `NSScrollView.magnification`。100% 以外のときはステータスバーに倍率を出し、クリックで戻す。本文の幅（狭い 40em・標準 52em・広い 68em・ウインドウの幅、`AppSettings.contentWidth`）はプレビューの CSS 変数 `--content-width`。どちらも見ていた位置を保つ（JS の resize・ResizeObserver、エディタは表示位置の文字を基準に戻す）。
- 行番号（「表示」の「行番号を表示」・設定ウィンドウ、`AppSettings.showLineNumbers`、全ウィンドウ共通、既定はオフ）：元のファイルの行番号を、左の余白の付箋の印のさらに左に出す。出す間は本文の余白を広げる。
  - プレビュー：`#gutter` 層に、付箋を付けられる要素（`targets`）の開始行を置く（同じ行の入れ子は1つだけ。段落の途中の行やコードブロックの中の行には出ない）。文書全体に置くと大きな文書で重いので、画面の前後 800px の分だけ置いてスクロールで置き直す。本文の外の層なので、文字のコピーと印刷には入らない。
  - エディタ：`EditorMarksView` が見えている行だけ描く（折り返した行は1段目だけ。本文の基準線にそろえる）。行の先頭の位置は入力のたびに作り直す（decorate の 200ms を待つと、改行してから番号が出るまで遅れて見える）。IME の変換中は textDidChange が来ないことがあるので、描く時に本文の長さが変わっていたら作り直す（古い位置のままだと、変換している行より下の番号が1行上にずれる）。余白は NSTextView の仕様で左右同じになる。幅は桁数で決まり、4桁になるまでは変わらない（文書が伸びるたびに本文の折り返しが変わらないように）。

### コード・図・数式・アラート

- コードブロック：言語が書かれたもの（`language-xxx`）だけ highlight.js で色付けする（推測はしない）。新しく入ったブロックだけに行い、比較は色付け前の HTML で行う。差分更新で行番号を写すときは行番号を持つ要素どうしで対応させる（色付けの span で数がずれないように）。マウスを載せると右上に言語名とコピーのボタン（`#code-tools`、本文の外に重ねる。コピーは Swift が NSPasteboard に書く）。配色は GitHub に近い自前の CSS（ライト／ダーク）。
- Mermaid（` ```mermaid `）：図のある文書を開いた時に初めて `mermaid.min.js` を読み込む（約 5.5MB）。pre 要素は残して中身を SVG に置き換える（差分更新で pre ごと使い回すので、変わらない図は描き直さない）。`securityLevel: 'strict'`、配色はライト／ダークに合わせ、見た目が変わったら描き直す。描けなければ理由と元のコードを出す。コピーのボタンは元のコードを写す。描くのは1つずつ順番に（`mermaidQueue`）。
- 数式（GitHub と同じ書き方）：
  - Swift の前処理（`Markdown.protectMath`）が、行の中の `$…$`・`$$…$$`・`` $`…`$ `` を `<span class="math" data-tex="…">`（表示用は `math-display` も）にする。中身は属性に入れるので Markdown として読まれない（`_` が斜体になったり `\\` が減ったりしない）。`|`・`*`・`` ` `` は文字参照にして、表のセルの区切りや太字の補正にも読ませない。`$$` だけの行で囲んだ数式は ```math のフェンスにする（行数は変えない。閉じる `$$` が無ければ何もしない）。
  - `$` の規則は Pandoc・GitHub と同じ：開く `$` の後と閉じる `$` の前は空白でなく、閉じる `$` の後は数字でない（`$5 と $10` を数式にしない）。`\$` とインラインコードの中は数式にしない。閉じる `$` はインラインコードの手前までしか探さない。
  - JS は数式のある文書を開いた時に初めて KaTeX（約 270KB ＋フォント）を読み込み、span と `code.language-math` のコードブロックを描く（Mermaid と同じく要素は残して中身を置き換えるので、変わらない数式は描き直さない）。書き方の誤りは KaTeX が赤い文字で元の式を出す。色は文字色に従う。コピーのボタンは元の式を写す。
  - 数式は文字数に数えない（生 HTML と同じ扱い）。Quick Look では描かず、書いたままの式をコードとして見せる。確認用は `Samples/math.md`。
- GitHub のアラート（`> [!NOTE]`・TIP・IMPORTANT・WARNING・CAUTION、大文字小文字は問わない。記号の後に同じ行で本文が続くものは対象外）：cmark-gfm は対応していないので、Swift が出力した HTML の引用を `blockquote.alert.alert-xxx` と見出しの段落（メモ・ヒント・重要・警告・注意）に書き換える。アイコンは CSS の mask（data URI の SVG）。

### 操作

- タスクリストのチェックボックス：プレビューでクリックすると Swift が元の行の `[ ]`／`[x]` を入れ替える（`MarkdownFormatter.toggleTask`。引用の中・全角スペースの書き方も対象）。未保存の編集が無ければすぐ保存し、あれば本文だけ書き換えて未保存のままにする（ほかの編集を勝手に保存しない）。JS 側では見た目を変えず、描き直しを待つ。⌘Z／⇧⌘Z で戻せる・やり直せる（ウィンドウの取り消しの履歴に積む。エディタの NSTextView と同じ履歴なので、エディタでの入力と順に戻せる。取り消し・やり直しも同じ書き換えで、同じく未保存の編集が無ければすぐ保存する。書き換えた直後の内容と違えば何もしない。変更を戻す時も同じ `replaceText`）。エディタがあれば本文の編集として映し（`applyWithoutUndo`）、外部更新のようにエディタの取り消しの履歴を消さない。外部更新が来たら履歴は消す。
- 印刷（⌘P）・「PDF として書き出す…」：表示中のモードにかかわらずプレビューを `WKWebView.printOperation` で印刷する（PDF は保存先を選んで同じページ割りで書き出す）。印刷の間だけ WebView の見た目をライトにし、Mermaid もライトで描き直してから始める（終わったら戻す）。`@media print` で画面用の印・ルーラー・ボタンを出さず、本文だけを紙の幅で組む。
- 戻る（⌘[）・進む（⌘]）：見出し一覧・⌘J／⇧⌘J・付箋・文書内リンク・ルーラーで移動する前の位置（`ScrollPosition`）を積み、行番号で戻す（プレビューとエディタ共通）。JS からの移動は `willJump` を先に送る。
  - マウスの戻る／進むボタン（buttonNumber 3・4）と、トラックパッドの「ページ間をスワイプ」でも同じ（`AppDelegate` のローカルイベントモニタ。本文の上だけ）。3本指の設定では swipe のイベントで届く。2本指の設定では scrollWheel を自分で数える（`handleSwipeScroll`）：指を置いてから少し動いて横向きと分かり、その向きに戻れる／進める時だけスワイプにして、以後のスクロール（指を離した後の慣性も）は本文に渡さない。矢印の丸（`SwipeIndicator`）は指の動いた量だけ端から出て、110pt で出切って止まり、そこで指を離すと戻る／進む（手前で離したら何もしない）。AppKit の `trackSwipeEvent` は指を離した後も慣性で動き続けて勝手に決まるので使わない。丸はすりガラスにしない（速く動かすと残像になる）。横にスクロールできる表・コード（`.table-wrap`・`pre`）の上では、端まで行っていてもスワイプにしない（JS が `horizontalScroll` で知らせる。事故防止）。

## Quick Look（機能拡張：`MDYomitokiQuickLook`）

### 仕組み

- Finder のスペースキーで Markdown を見せる機能拡張（`com.apple.quicklook.preview`）。アプリの `Contents/PlugIns` に入る。対象は `net.daringfireball.markdown`。
- HTML を作って渡す方式（`QLPreviewProvider`・`QLIsDataBasedPreview`）。表示は macOS がする。WebView を自分で持つ方式より軽く、壊れにくい。
  - Markdown の変換（`Markdown.swift`）・ファイルの読み込み（`TextFile.swift`：文字コードの判別・大きさの上限）・見た目（`preview.css`）はアプリと共通（project.yml で同じファイルを両方のターゲットに入れる）。
  - コードの色付けは、アプリと同じ `highlight.min.js` を JavaScriptCore で動かして HTML にしておく（言語が書かれたものだけ。合わせて 300KB まで。機能拡張の中では JIT が使えず遅いため）。Mermaid の図は描かない（コードのまま）。
  - Sandbox が必須（`QuickLook.entitlements`）。読めるのは渡されたファイルだけで、ネットにもつながない（見ただけで外に通信しない）ので、画像は「画像：代替テキスト」の枠にする。
  - Content-Security-Policy でスクリプト・外部の読み込みを止め、文書の生 HTML の meta・base・link・object・embed・form は文字にする。
  - 描くのは先頭の 1MB まで（Quick Look には時間の制限がある）。切ったときは冒頭にその旨を出す。10MB を超えるファイルは読まない（Quick Look の既定の表示になる）。
- 配布：Xcode が Developer ID・Hardened Runtime・タイムスタンプで署名する（xcconfig がすべてのターゲットに効く）。`make archive` が機能拡張の Hardened Runtime も確かめる。

### 別のアプリとの競合

- 別のアプリ（MDHero など）も Markdown の Quick Look を持っていると、そちらが使われることがある。「システム設定」→「一般」→「ログイン項目と機能拡張」→「Quick Look」で切り替える。登録の状況は `pluginkit -m -v -p com.apple.quicklook.preview`。開発中のビルドの機能拡張は、`make build` の後に起動するか `pluginkit -a <appex>` で登録される。

### 試してやめたこと

- ⌘F での本文の検索は試作して確かめたがやめた（macOS 27.0.1 の Finder のスペースキーのパネル）。ビュー方式（`QLIsDataBasedPreview` を外して自前の WKWebView を持つ）にしても、本文や検索欄をクリックした後でもキー入力は機能拡張のプロセスに届かなかった（⌘F は Finder の検索が動き、文字は Finder の頭文字選択に回り、スペースはパネルを閉じる）。ビュー方式の WKWebView は `com.apple.security.network.client` が無いと WebContent プロセスが落ちて白紙になった。
- Finder のアイコンの縮図（Thumbnail の機能拡張）は作って試したがやめた。macOS 27 では Markdown（public.plain-text の一種）に標準のテキストの縮図（`com.apple.quicklook.thumbnail.TextExtension`）が優先され、登録して有効にしても、アプリを Applications に置いても呼ばれなかった。
