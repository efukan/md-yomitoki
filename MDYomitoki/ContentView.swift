import AppKit
import SwiftUI

struct ContentView: View {
    let model: DocumentModel
    /// エディタは初めて開いたときに作り、以後は隠すだけにする（Undo の履歴を残すため）。
    @State private var editorCreated = false
    /// サイドバーの「変更」欄を開いているか（変更が多い時に畳めるように）
    @State private var changesExpanded = true
    /// サイドバーの「付箋」欄を開いているか
    @State private var bookmarksExpanded = true
    @State private var confirmsRemovingAllBookmarks = false
    /// サイドバー全体の高さ（変更・付箋の欄の上限を決める）
    @State private var sidebarHeight: CGFloat = 0

    var body: some View {
        // サイドバーの表示状態はモデルで持つ。AppKit のウィンドウでは標準のサイドバー切り替えボタンが出ないため、
        // 自前のボタンとメニュー（⌃⌘S）で戻せるようにする。
        NavigationSplitView(columnVisibility: Binding(
            get: { model.sidebarVisible ? .all : .detailOnly },
            set: { model.sidebarVisible = $0 != .detailOnly }
        )) {
            sidebar
                .navigationSplitViewColumnWidth(min: 160, ideal: 220, max: 400)
        } detail: {
            detail
                .safeAreaInset(edge: .top, spacing: 0) {
                    VStack(spacing: 0) {
                        banner
                        if model.isSearching { SearchBar(model: model) }
                    }
                }
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    StatusBar(
                        text: model.statusText, isDirty: model.isDirty,
                        modifiedAt: model.modifiedAt, externalUpdateCount: model.externalUpdateCount
                    )
                }
        }
        .frame(minWidth: 600, minHeight: 400)
        .onChange(of: model.mode, initial: true) { _, mode in
            if mode == .editor { editorCreated = true }
        }
        .dropDestination(for: URL.self) { urls, _ in
            AppDelegate.shared?.open(urls)
            return true
        }
        .toolbar { toolbar }
    }

    /// サイドバーは上から「変更」「付箋」「見出し」の3つの欄に分け、別々にスクロールする（見出しの多い文書の下の方を
    /// 読んでいても、変更の一覧へ戻るためにスクロールしなくて済むように。変更が多くても付箋が隠れないように）。
    /// 変更と付箋は 0 件なら欄ごと出さず、中身の高さだけ取り、上限（変更はサイドバーの 3 割、付箋は 2 割）を
    /// 超えたらその欄の中でスクロールする。残りを見出し一覧が使う。
    private var sidebar: some View {
        VStack(spacing: 0) {
            if !model.changeItems.isEmpty {
                changesSection
                Divider().padding(.horizontal, 12)
            }
            if !model.bookmarks.isEmpty {
                bookmarksSection
                Divider().padding(.horizontal, 12)
            }
            headingList
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { sidebarHeight = $0 }
    }

    /// 「変更」の欄。見出しの件数と ˅ を押すと畳める。
    private var changesSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SidebarHeader(title: "変更") {
                SectionToggle(count: model.changeItems.count, isExpanded: $changesExpanded, noun: "変更")
            }
            .padding(.top, 8)
            if changesExpanded {
                CappedScrollView(maxHeight: max(96, sidebarHeight * 0.3)) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(model.changeItems, id: \.self) { item in
                            ChangeRow(item: item) { model.goToChange(line: item.line) }
                        }
                    }
                }
            }
            Spacer().frame(height: 6)
        }
    }

    /// 「付箋」の欄。「変更」と同じく、件数と ˅ を押すと畳める。
    /// 一覧はクリックで移動するためのものなので、押し間違えて外さないよう、外すのは右クリックのメニューだけにする
    /// （ほかに ⌘D・プレビューの左の余白の印）。すべて外す時は確かめる。
    private var bookmarksSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            SidebarHeader(title: "付箋") {
                SectionToggle(count: model.bookmarks.count, isExpanded: $bookmarksExpanded, noun: "付箋")
            }
            .padding(.top, 8)
            .contextMenu { removeAllBookmarksButton }
            if bookmarksExpanded {
                CappedScrollView(maxHeight: max(72, sidebarHeight * 0.2)) {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(model.bookmarks, id: \.self) { bookmark in
                            BookmarkRow(bookmark: bookmark) {
                                model.goToBookmark(line: bookmark.line)
                            }
                            .contextMenu {
                                Button("この付箋を外す") { model.removeBookmark(line: bookmark.line) }
                                Divider()
                                removeAllBookmarksButton
                            }
                        }
                    }
                }
            }
            Spacer().frame(height: 6)
        }
        .confirmationDialog(
            "このファイルの付箋（\(model.bookmarks.count)件）をすべて外しますか？",
            isPresented: $confirmsRemovingAllBookmarks
        ) {
            Button("すべて外す", role: .destructive) { model.removeAllBookmarks() }
            Button("キャンセル", role: .cancel) {}
        }
    }

    private var removeAllBookmarksButton: some View {
        Button("すべての付箋を外す…") { confirmsRemovingAllBookmarks = true }
    }

    /// 見出し一覧。「今読んでいる見出し」を強調し、クリックでその見出しへ移動、スクロールすると追従する。
    /// 標準の List は行の間に当たり判定の無い隙間があり（ホバーが途切れて点滅する）、選択色も調整できないため、
    /// 行間 0 の縦並びで自前に描く。欄の名前は一覧の上に固定する。
    private var headingList: some View {
        let outline = model.rendered.outline
        // 一番浅い見出しを 0 段目にする（H1 の無い文書で H2 が字下げされないように）
        let topLevel = outline.map(\.level).min() ?? 1
        let headingLines = outline.map(\.line)
        let changed = model.changes.sectionLines(headings: headingLines)
        let latest = model.latestChanges.sectionLines(headings: headingLines)
        return VStack(alignment: .leading, spacing: 0) {
            SidebarHeader(title: "見出し") {}
                .padding(.top, 8)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if outline.isEmpty {
                            Text("見出しがありません")
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 6)
                        }
                        ForEach(outline) { item in
                            HeadingRow(
                                item: item,
                                depth: item.level - topLevel,
                                isActive: item.line == model.activeHeadingLine,
                                change: latest.contains(item.line) ? .latest : changed.contains(item.line) ? .unreviewed : nil
                            ) {
                                model.selectHeading(line: item.line)
                            }
                            .id(item.line)
                        }
                    }
                    .padding(.bottom, 6)
                }
                .onChange(of: model.activeHeadingLine) { _, line in
                    if let line { proxy.scrollTo(line) }
                }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let error = model.loadError {
            ContentUnavailableView("読み込めませんでした", systemImage: "exclamationmark.triangle", description: Text(error))
        } else {
            ZStack {
                PreviewView(model: model)
                if editorCreated {
                    EditorView(model: model)
                }
            }
            .overlay { SwipeArrow(model: model) }
        }
    }

    @ViewBuilder
    private var banner: some View {
        if model.pendingDiskText != nil {
            Banner(text: "外部でファイルが更新されました。編集中の内容はまだ保存されていません。") {
                Button("再読み込み（編集を破棄）") { model.discardEditsAndReload() }
                Button("上書き保存") { model.save() }
            }
        } else if let error = model.reloadError {
            Banner(text: error) {}
        }
    }

    private var changeSummary: String {
        switch (model.baselineSource, model.changeCount) {
        case (.gitHead, 0): "HEAD から変更なし"
        case (.gitHead, let count): "HEAD から \(count)箇所"
        case (.reviewed, 0): "未確認なし"
        case (.reviewed, let count): "未確認 \(count)箇所"
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button("見出し一覧", systemImage: "sidebar.left") {
                withAnimation { model.sidebarVisible.toggle() }
            }
            .help("見出し一覧を表示／隠す（⌃⌘S）")
        }
        ToolbarItem(placement: .principal) {
            Picker("表示モード", selection: Binding(get: { model.mode }, set: { model.setMode($0) })) {
                ForEach(ViewMode.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .help("プレビューとエディタを切り替え（⌘E）")
        }
        if model.mode == .editor {
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ForEach(Array(MarkdownFormat.menuLayout.enumerated()), id: \.offset) { _, format in
                        if let format {
                            Button(format.title, systemImage: format.symbol) { model.applyFormat(format) }
                        } else {
                            Divider()
                        }
                    }
                } label: {
                    Label("書式", systemImage: "textformat")
                }
                .help("見出し・太字・リストなどの書式を付ける（右クリックでも選べます）")
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            // 件数と比較の基準は1つのボタンにまとめる（クリックで基準を選ぶ）。
            // 文字だけの項目を別に置くと、ツールバーの背景の中で見切れるため。
            Menu {
                Picker("比較の基準", selection: Binding(
                    get: { model.baselineSource },
                    set: { model.setBaselineSource($0) }
                )) {
                    Text("開いた時点・確認済みの時点").tag(BaselineSource.reviewed)
                    Text("git HEAD（最後のコミット）").tag(BaselineSource.gitHead)
                }
                .pickerStyle(.inline)
            } label: {
                Label(changeSummary, systemImage: model.baselineSource == .gitHead
                      ? "arrow.triangle.branch" : "clock.arrow.circlepath")
                    .labelStyle(.titleAndIcon)
                    .monospacedDigit()
            }
            .fixedSize()
            .help("変更ハイライトの比較の基準を選ぶ")
            Button("変更箇所へ移動", systemImage: "arrow.down.to.line") {
                model.jumpToNextChange()
            }
            .help("次の変更箇所へ移動（⌘J。前へは ⇧⌘J）")
            .disabled(model.changeCount == 0)
            Button("確認済みにする", systemImage: "checkmark.circle") {
                model.markAsReviewed()
            }
            .help("変更ハイライトを消し、今の内容を比較の基準にする")
            .disabled(model.changeCount == 0)
        }
    }
}

/// 見出し一覧の1行。段の深さを字下げと文字の大きさ・濃さで示す（0 段目は太字、2 段目以降は小さく淡く）。
/// 今読んでいる見出しはアクセント色の背景で示し（文字色は変えない）、マウスを載せた行にはそれより薄い背景を付ける。
/// 節の中に変更があれば右端に点を出す（最新の更新は濃く、それ以前の未確認の変更は淡く）。
/// 行は隙間なく並べ、当たり判定を行全体にするので、行をまたいでもホバーが途切れない。
private struct HeadingRow: View {
    enum Change { case unreviewed, latest }

    let item: OutlineItem
    let depth: Int
    let isActive: Bool
    let change: Change?
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(item.title)
                    .lineLimit(2)
                    .font(depth == 0 ? .body.weight(.semibold) : depth == 1 ? .body : .callout)
                    .foregroundStyle(depth >= 2 && !isActive ? .secondary : .primary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let change {
                    Circle()
                        .fill(Color.orange.opacity(change == .latest ? 1 : 0.45))
                        .frame(width: 7, height: 7)
                        .help(change == .latest ? "最新の更新があります" : "比較の基準から変更があります")
                }
            }
            .padding(.leading, CGFloat(depth) * 14)
            .padding(.vertical, depth >= 2 ? 4 : 5)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(isActive ? Color.accentColor.opacity(0.18) : Color.primary.opacity(isHovering ? 0.05 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

/// 「変更」欄の1行。プレビューの印と同じ色の印（未確認は淡いオレンジ、最新の更新は濃いオレンジ、削除は赤い三角）、
/// 変わった行の書き出し（削除なら消えた行を取り消し線で）、行番号を出す。マウスを載せると行番号の前に種類を出す
/// （ツールチップは出るまでに 1 秒ほどかかるので使わない）。
private struct ChangeRow: View {
    let item: ChangeItem
    let action: () -> Void
    @State private var isHovering = false

    private var kindName: String {
        switch item.kind {
        case .rewritten: "書き換え"
        case .added: "追加"
        case .deleted: "削除"
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Group {
                    if item.kind == .deleted {
                        Image(systemName: "arrowtriangle.right.fill")
                            .font(.system(size: 7))
                            .foregroundStyle(Color(nsColor: .systemRed))
                    } else {
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color(nsColor: .systemOrange).opacity(item.isLatest ? 1 : 0.45))
                            .frame(width: 3, height: 14)
                    }
                }
                .frame(width: 8)
                Text(item.snippet.isEmpty ? "（空行）" : item.snippet)
                    .strikethrough(item.kind == .deleted)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(item.kind == .deleted || item.snippet.isEmpty ? .secondary : .primary)
                Spacer(minLength: 4)
                Text(isHovering ? "\(kindName)\(item.isLatest ? "（最新）" : "") · \(item.line)行" : "\(item.line)行")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.05 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
    }
}

/// サイドバーの区切りの見出し（「変更」「付箋」「見出し」）。
/// 欄の見出しの右の「件数 ˅」。押すと欄を畳む／開く。
private struct SectionToggle: View {
    let count: Int
    @Binding var isExpanded: Bool
    let noun: String

    var body: some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 4) {
                Text("\(count)")
                    .monospacedDigit()
                Image(systemName: "chevron.right")
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .buttonStyle(.borderless)
        .help(isExpanded ? "\(noun)の一覧を畳む" : "\(noun)の一覧を開く")
    }
}

/// 中身の高さだけ取り、maxHeight を超えたらその中でスクロールする。
private struct CappedScrollView<Content: View>: View {
    let maxHeight: CGFloat
    @ViewBuilder let content: Content
    @State private var contentHeight: CGFloat = 0

    var body: some View {
        ScrollView {
            content.onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: min(contentHeight, maxHeight))
    }
}

private struct SidebarHeader<Accessory: View>: View {
    let title: String
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer()
            accessory
        }
        // 右に「件数 ˅」がある欄と無い欄（見出し）で高さをそろえる
        .frame(minHeight: 22)
        .padding(.horizontal, 20)
        .padding(.bottom, 2)
    }
}

/// 付箋の1行。行頭の抜粋と行番号を出し、マウスを載せると外すボタン（×）を出す。
private struct BookmarkRow: View {
    let bookmark: Bookmark
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "bookmark.fill")
                    .font(.caption)
                    .foregroundStyle(.tint)
                Text(bookmark.snippet.isEmpty ? "（空行）" : bookmark.snippet)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(bookmark.snippet.isEmpty ? .secondary : .primary)
                Spacer(minLength: 4)
                Text("\(bookmark.line)行")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(isHovering ? 0.05 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.12), value: isHovering)
        .help("\(bookmark.line)行目へ移動（外すときは右クリック）")
    }
}

/// 2本指のスワイプで戻る／進む途中の印。スワイプした側の端から、指の動いた量だけ矢印の丸が出てくる（出切ったところで指を離すと移動する）。
private struct SwipeArrow: View {
    let model: DocumentModel

    var body: some View {
        arrow
            // 消える時だけふわっと消す（出てくる時は指に合わせて動くので、アニメーションは付けない）
            .animation(model.swipeIndicator == nil ? .easeOut(duration: 0.1) : nil, value: model.swipeIndicator == nil)
    }

    @ViewBuilder private var arrow: some View {
        if let swipe = model.swipeIndicator {
            let amount = min(swipe.amount, 1)
            Image(systemName: swipe.back ? "chevron.left" : "chevron.right")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 40, height: 40)
                // すりガラスは背景をぼかし直すのが追いつかず、速く動かすと残像のようになるので、不透明の色にする
                .background(Color(nsColor: .controlBackgroundColor), in: Circle())
                .overlay(Circle().strokeBorder(.separator, lineWidth: 0.5))
                .shadow(color: .black.opacity(0.15), radius: 3, y: 1)
                .offset(x: (swipe.back ? 1 : -1) * (-44 + 64 * amount))
                .opacity(min(1, amount * 3))
                // 速いスワイプはイベントごとの移動量が大きいので、間をなめらかにつなぐ（指から遅れない程度に短く）
                .animation(.interactiveSpring(response: 0.12, dampingFraction: 1), value: amount)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: swipe.back ? .leading : .trailing)
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }
}

/// Safari の「ページ内を検索」と同じ構成の検索バー（検索フィールド・件数・前後ボタン・完了）。
/// エディタでは左の ˃ か ⌥⌘F で2段目に置換の欄を出す。
private struct SearchBar: View {
    @Bindable var model: DocumentModel

    private var canReplace: Bool { model.mode == .editor }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            searchRow
            if canReplace && model.isReplacing { replaceRow }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private var replaceToggle: some View {
        Button(model.isReplacing ? "置換を隠す" : "置換を表示",
               systemImage: model.isReplacing ? "chevron.down" : "chevron.right") { model.toggleReplace() }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .frame(width: 16)
            .help(model.isReplacing ? "置換を隠す" : "置換（⌥⌘F）")
    }

    private var searchRow: some View {
        HStack(spacing: 8) {
            if canReplace { replaceToggle }
            NativeSearchField(
                text: $model.searchQuery,
                placeholder: "本文を検索",
                focusRequest: model.searchFocusRequest,
                onSubmit: { backward in model.findNext(forward: !backward) },
                onCancel: { model.hideSearch() }
            )
            .frame(minWidth: 180, maxWidth: 340)
            .help("かな／カナ・全角／半角・大文字／小文字の違いは区別しません")
            ControlGroup {
                Button("前を検索", systemImage: "chevron.left") { model.findNext(forward: false) }
                    .help("前を検索（⇧⌘G）")
                Button("次を検索", systemImage: "chevron.right") { model.findNext() }
                    .help("次を検索（⌘G）")
            }
            .fixedSize()
            .disabled(model.searchResultCount == 0)
            if let replaced = model.replacedCount {
                Text("\(replaced)件を置換しました")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else if !model.searchQuery.isEmpty {
                Text(model.searchResultCount == 0
                     ? "一致なし"
                     : "\(model.searchCurrentIndex + 1) / \(model.searchResultCount)件")
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            Button("完了") { model.hideSearch() }
                .help("検索を閉じる（esc）")
        }
    }

    /// 置き換えるのは検索で光っている一致（かな／カナなどの違いを区別せずに見つけたものも含む）。
    private var replaceRow: some View {
        HStack(spacing: 8) {
            replaceToggle.hidden()
            TextField("置換後の文字", text: $model.replacement)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 180, maxWidth: 340)
                .onSubmit { model.replaceCurrent() }
                .onExitCommand { model.hideSearch() }
                .help("Return で今の一致を置き換えて次へ")
            Group {
                Button("置換") { model.replaceCurrent() }
                    .help("今の一致を置き換えて次へ")
                Button("すべて置換") { model.replaceAll() }
                    .help("光っている一致をすべて置き換える（⌘Z で1回で戻せます）")
            }
            .disabled(model.searchResultCount == 0)
            Spacer()
        }
    }
}

/// AppKit 標準の検索フィールド（虫めがね・消去ボタン付き）。Return で次、Shift+Return で前、esc で閉じる。
private struct NativeSearchField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let focusRequest: Int
    let onSubmit: (_ backward: Bool) -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = placeholder
        field.delegate = context.coordinator
        field.target = context.coordinator
        field.action = #selector(Coordinator.textChanged(_:))
        field.sendsSearchStringImmediately = true
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if context.coordinator.focusRequest != focusRequest {
            context.coordinator.focusRequest = focusRequest
            DispatchQueue.main.async { field.window?.makeFirstResponder(field) }
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: NativeSearchField
        var focusRequest = -1

        init(_ parent: NativeSearchField) {
            self.parent = parent
        }

        @objc func textChanged(_ sender: NSSearchField) {
            if parent.text != sender.stringValue { parent.text = sender.stringValue }
        }

        func controlTextDidChange(_ notification: Notification) {
            if let field = notification.object as? NSSearchField { textChanged(field) }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false)
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }
}

private struct Banner<Actions: View>: View {
    let text: String
    @ViewBuilder let actions: Actions

    var body: some View {
        HStack(spacing: 12) {
            Label(text, systemImage: "exclamationmark.triangle.fill")
                .font(.callout)
                .frame(maxWidth: .infinity, alignment: .leading)
            actions
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.yellow.opacity(0.18))
        .overlay(alignment: .bottom) { Divider() }
    }
}

private struct StatusBar: View {
    let text: String
    let isDirty: Bool
    let modifiedAt: Date?
    let externalUpdateCount: Int
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        HStack(spacing: 10) {
            if isDirty {
                Text("未保存")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let modifiedAt {
                // 「3分前」の表示を進めるため、15 秒ごとに描き直す
                TimelineView(.periodic(from: .now, by: 15)) { context in
                    let fresh = context.date.timeIntervalSince(modifiedAt) < 60
                    HStack(spacing: 0) {
                        Text("最終更新 \(UpdateTime.label(modifiedAt, now: context.date))")
                            // 1 分以内の更新はオレンジ（AI がまだ書いているかもしれない）
                            .foregroundStyle(fresh ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                        if externalUpdateCount > 0 {
                            Text(" · 外部で \(externalUpdateCount)回更新")
                                .foregroundStyle(.secondary)
                        }
                    }
                    .font(.caption)
                    .monospacedDigit()
                    .help("ファイルの最終更新：\(UpdateTime.full(modifiedAt))"
                          + (externalUpdateCount > 0 ? "\n外部で更新された回数は、開いてから（確認済みにしてから）数えます" : ""))
                }
            }
            Spacer()
            // 文字の大きさを変えているときだけ倍率を出す（クリックで元に戻す）
            if settings.textScale != 1 {
                Button("\(Int((settings.textScale * 100).rounded()))%") { settings.textScale = 1 }
                    .buttonStyle(.plain)
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .help("文字の大きさを元に戻す（⌘0）")
            }
            Text(text)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }
}

/// ステータスバーの最終更新の表し方。1 分未満は「たった今」、1 時間未満は「N分前」、それより前は日時。
enum UpdateTime {
    static func label(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "たった今"
        case ..<3600: return "\(Int(seconds / 60))分前"
        default: return date.formatted(.dateTime.month().day().hour().minute().locale(Locale(identifier: "ja_JP")))
        }
    }

    static func full(_ date: Date) -> String {
        date.formatted(.dateTime.year().month().day().hour().minute().second().locale(Locale(identifier: "ja_JP")))
    }
}
