import AppKit
import Observation

/// 変更ハイライトの比較の基準
enum BaselineSource: Hashable {
    /// 開いた時点、または最後に「確認済み」にした時点
    case reviewed
    /// git の最後のコミット（HEAD）
    case gitHead
}

enum ViewMode: String, CaseIterable {
    case preview, editor

    var title: String { self == .preview ? "プレビュー" : "エディタ" }
}

/// 1つの文書（＝1ウィンドウ）の状態。
@Observable
@MainActor
final class DocumentModel {
    let url: URL
    /// 表示中の内容（エディタで編集すると未保存の内容になる）
    private(set) var text = ""
    /// 本文から作った HTML・見出し・文字数。大きな文書では作るのに時間がかかるので、メインスレッドの外で作る（`refreshDerived`）。
    private(set) var rendered = RenderedMarkdown()
    /// 開いてから一度でも描画を作り終えた（それまではプレビューに何も渡さない）
    private(set) var hasRendered = false
    /// 開けなかった理由（「読み込めませんでした」の説明として出す）
    private(set) var loadError: String?
    /// 外部更新を読み込み直せなかった理由（バナーに出す。表示は最後に読んだ内容のまま）
    private(set) var reloadError: String?
    private(set) var mode = ViewMode.preview
    /// 未保存の編集がある
    private(set) var isDirty = false
    /// 未保存の編集中に外部で更新されたディスクの内容。ユーザーが「再読み込み」か「上書き保存」を選ぶまで保留する。
    private(set) var pendingDiskText: String?
    var selectionCount = 0
    /// ファイルの最終更新日時（開いた時・外部更新・自分の保存で読み直す）。ステータスバーに出す。
    private(set) var modifiedAt: Date?
    /// 開いてから（「確認済み」にしてから）外部で更新された回数
    private(set) var externalUpdateCount = 0
    /// 左の見出し一覧（TOC）を表示しているか
    var sidebarVisible = true
    /// 画面上部に見えている位置が属する見出しの行（見出し一覧の選択をスクロールに追従させる）
    private(set) var activeHeadingLine: Int?

    // 検索（Cmd+F）
    private(set) var isSearching = false
    var searchQuery = "" {
        didSet {
            if searchQuery != oldValue {
                replacedCount = nil
                scheduleSearch()
            }
        }
    }
    private(set) var searchResultCount = 0
    /// 置換の欄を出しているか（エディタの時だけ使える）
    private(set) var isReplacing = false
    var replacement = ""
    /// 「すべて置換」で置き換えた件数。検索語を変えるまで件数の代わりに出す。
    private(set) var replacedCount: Int?
    private(set) var searchCurrentIndex = 0
    /// 検索欄にフォーカスを移す合図（値が変わるたびに移す）
    private(set) var searchFocusRequest = 0
    @ObservationIgnored private var searchRanges: [NSRange] = []
    @ObservationIgnored private var searchIndex: NormalizedText?
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    /// 確認済み（ベースライン）以降の変更。外部更新が続いても累積するので消えない。
    private(set) var changes = LineChanges()
    /// 直近の外部更新 1 回分の変更。
    private(set) var latestChanges = LineChanges()
    /// サイドバーの「変更」欄（変更のかたまりを文書順に）。変更が変わった時だけ作り直す（スクロールのたびに作らない）。
    private(set) var changeItems: [ChangeItem] = []
    /// 付箋（行順）
    private(set) var bookmarks: [Bookmark] = []
    /// 付箋の行番号が指している内容。本文が変わったら、ここからの差分で付箋を追従させる。
    @ObservationIgnored private var bookmarkText = ""

    /// 最後にディスクから読んだ／ディスクへ書いた内容
    @ObservationIgnored private var savedText = ""
    @ObservationIgnored private var format = FileFormat()
    private(set) var baselineSource = BaselineSource.reviewed
    /// 開いた時点か、最後に「確認済み」にした時点の内容
    @ObservationIgnored private var reviewedBaseline = ""
    /// git HEAD 時点の内容
    @ObservationIgnored private var gitBaseline: String?
    @ObservationIgnored private var watcher: FileWatcher?
    @ObservationIgnored private var retriedEmptyRead = false
    @ObservationIgnored private var renderTask: Task<Void, Never>?
    /// `rendered` を作った本文（今の本文と違えば、作り直しを待っている）
    @ObservationIgnored private var renderedText: String?
    /// まだ反映していない外部更新の前の内容（「最新の更新」の差分の元）。作り直しが取り消されても引き継ぐ。
    @ObservationIgnored private var pendingLatestFrom: String?
    /// 描画ができてから移動する見出し（ほかの文書のリンクで開いた直後）
    @ObservationIgnored private var pendingFragment: String?
    @ObservationIgnored private var saveScrollTask: Task<Void, Never>?
    /// エディタで編集が始まった（IME の変換中を含む）。この間の外部更新は未保存の編集と同じく保留する。
    @ObservationIgnored private var isEditing = false
    /// 外部更新の後、最初の ⌘J は最新の変更の先頭へ飛ぶ。
    @ObservationIgnored private var jumpToLatestFirst = false
    /// 直前に ⌘J／⇧⌘J で移動した変更箇所と、移動した直後の表示位置。表示位置がそのままなら続けて押されたとみなし、
    /// その先（手前）から探す。行番号で比べると、空行（削除の位置など）へ移動したときに画面上部の要素が別の行になり、
    /// 同じ所へ移動し続けてしまうため。
    @ObservationIgnored private var lastJump: (line: Int, position: ScrollPosition?)?
    /// 戻る（⌘[）・進む（⌘]）の履歴。見出し一覧・⌘J・付箋・文書内リンク・ルーラーで移動する前の位置を積む。
    @ObservationIgnored private var backStack: [ScrollPosition] = []
    @ObservationIgnored private var forwardStack: [ScrollPosition] = []
    /// トラックパッドの2本指のスワイプで戻る／進む途中の印（端から出てくる矢印）
    private(set) var swipeIndicator: SwipeIndicator?
    @ObservationIgnored private var swipe: SwipeState?
    /// スワイプした後の慣性のスクロールを本文に渡さない
    @ObservationIgnored private var swallowsMomentum = false

    /// 画面上部に見えている位置（表示中のビューから通知される）。モード切り替えと再開時の基準。
    @ObservationIgnored private(set) var scrollPosition: ScrollPosition
    /// ウィンドウの取り消しの履歴（エディタの NSTextView と共通）
    @ObservationIgnored weak var undoManager: UndoManager?
    @ObservationIgnored weak var preview: PreviewView.Coordinator?
    @ObservationIgnored weak var editor: EditorView.Coordinator?
    @ObservationIgnored var onDirtyChange: ((Bool) -> Void)?
    /// 外部でファイルの内容が変わった（保留した場合も含む）。見ていないタブに印を付けるため。
    @ObservationIgnored var onExternalUpdate: (() -> Void)?

    init(url: URL) {
        self.url = url
        scrollPosition = ScrollMemory.load(for: url) ?? ScrollPosition()
    }

    var statusText: String {
        let total = "全 \(rendered.charCount.formatted())文字"
        return selectionCount > 0 ? "選択 \(selectionCount.formatted())文字 / \(total)" : total
    }

    var changeCount: Int { changes.jumpLines.count }

    /// プレビューとエディタに渡す印（変更ハイライトと付箋）
    var marks: PreviewMarks {
        PreviewMarks(changes: changes, latest: latestChanges, bookmarks: bookmarks.map(\.line))
    }

    /// 比較の基準（S0）
    private var baseline: String {
        baselineSource == .gitHead ? gitBaseline ?? reviewedBaseline : reviewedBaseline
    }

    func load() {
        do {
            (text, format) = try Self.readText(at: url)
            savedText = text
            reviewedBaseline = text
            refreshDerived()
            loadError = nil
            refreshModifiedAt()
            let stored = BookmarkStore.load(for: url)
            bookmarks = Bookmarks.relocate(stored, in: text)
            bookmarkText = text
            if bookmarks != stored { BookmarkStore.save(bookmarks, for: url) }
            watcher = FileWatcher(url: url) { [weak self] in self?.reloadFromDisk() }
            // 前回 git HEAD と比較していたなら引き継ぐ（git 管理外なら黙って通常の基準のまま）
            if AppSettings.shared.compareWithGitHead {
                Task { await loadGitBaseline(showErrors: false) }
            }
        } catch {
            loadError = error.localizedDescription
        }
    }

    func close() {
        watcher?.stop()
        watcher = nil
        renderTask?.cancel()
        saveScrollTask?.cancel()
        ScrollMemory.save(scrollPosition, for: url)
    }

    // MARK: 外部更新

    private func reloadFromDisk() {
        let newText: String, newFormat: FileFormat
        do {
            (newText, newFormat) = try Self.readText(at: url)
        } catch CocoaError.fileReadNoSuchFile {
            reloadError = "ファイルが見つかりません。移動または削除された可能性があります（元の場所に戻れば自動で再読み込みします）。"
            return
        } catch {
            reloadError = "更新されたファイルを読み込めません：\(error.localizedDescription)表示は最後に読み込んだ内容のままです。"
            return
        }
        reloadError = nil
        // truncate → write の途中を読んだ可能性があるので、空なら一度だけ読み直す。
        if newText.isEmpty && !savedText.isEmpty && !retriedEmptyRead {
            retriedEmptyRead = true
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                self?.reloadFromDisk()
            }
            return
        }
        retriedEmptyRead = false
        // 自分の保存（内容が同じ）ならここで止まる
        guard newText != savedText else {
            pendingDiskText = nil
            return
        }
        format = newFormat
        if isDirty || isEditing {
            pendingDiskText = newText
        } else {
            applyExternal(newText)
        }
        externalUpdateCount += 1
        refreshModifiedAt()
        onExternalUpdate?()
    }

    private func refreshModifiedAt() {
        modifiedAt = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    private func applyExternal(_ newText: String) {
        // 外から書き換わったら、取り消しの履歴は使えない（エディタも同じく消す）
        undoManager?.removeAllActions()
        let previous = text
        savedText = newText
        text = newText
        pendingDiskText = nil
        lastJump = nil
        refreshDerived(latestFrom: pendingLatestFrom ?? previous)
        updateDirty()
        if isSearching { scheduleSearch(delay: 300) }
        // AI が書き換えと同時にコミットしていることもあるので、HEAD も読み直す
        if baselineSource == .gitHead {
            Task { await loadGitBaseline(showErrors: false) }
        }
    }

    // MARK: 比較の基準

    func setBaselineSource(_ source: BaselineSource) {
        switch source {
        case .reviewed:
            baselineSource = .reviewed
            AppSettings.shared.compareWithGitHead = false
            recomputeChanges()
        case .gitHead:
            Task { await loadGitBaseline(showErrors: true) }
        }
    }

    func toggleGitBaseline() {
        setBaselineSource(baselineSource == .gitHead ? .reviewed : .gitHead)
    }

    private func loadGitBaseline(showErrors: Bool) async {
        do {
            let (head, _) = try Self.decode(try await Git.headVersion(of: url))
            gitBaseline = head
            baselineSource = .gitHead
            AppSettings.shared.compareWithGitHead = true
            recomputeChanges()
        } catch {
            guard showErrors else { return }
            let alert = NSAlert()
            alert.messageText = "git HEAD と比較できません"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private func recomputeChanges() {
        lastJump = nil
        refreshDerived()
    }

    /// バナーの「再読み込み」：編集を破棄してディスクの内容にする。
    func discardEditsAndReload() {
        guard let disk = pendingDiskText else { return }
        applyExternal(disk)
    }

    // MARK: 編集・保存

    func editorWillChange() {
        isEditing = true
    }

    /// エディタからの変更通知（IME の変換中は呼ばれない）。
    func editorTextDidChange(_ newText: String) {
        isEditing = false
        guard newText != text else { return }
        text = newText
        clearLatestChanges()
        updateDirty()
        // 文字数・プレビュー・差分の再計算は打鍵ごとではなく、少し落ち着いてから
        refreshDerived(after: .milliseconds(300))
        if isSearching { scheduleSearch(delay: 300) }
    }

    // MARK: 印刷・PDF

    /// ⌘P：プレビューを印刷する（エディタ表示中でも、描画した本文を印刷する）。
    func printDocument() {
        preview?.printDocument(toPDF: nil)
    }

    /// 「PDF として書き出す…」：保存先を選んで、印刷と同じページ割りの PDF にする。
    func exportPDF() {
        guard let window = preview?.webView.window else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.pdf]
        panel.directoryURL = url.deletingLastPathComponent()
        panel.nameFieldStringValue = url.deletingPathExtension().lastPathComponent + ".pdf"
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let destination = panel.url else { return }
            self?.preview?.printDocument(toPDF: destination)
        }
    }

    /// プレビューのチェックボックスのクリック。未保存の編集が無ければすぐ保存する（AI の TODO に印を付ける用途）。
    /// 未保存の編集がある時は、その編集と一緒に保存されるよう本文だけ書き換えて未保存のままにする。
    /// ⌘Z で戻せる（取り消し・やり直しも同じ切り替えで、同じく未保存の編集が無ければすぐ保存する）。
    /// expected は取り消し・やり直しの時に、その切り替えの直後の内容。違えば（外部更新などで変わった）何もしない。
    func toggleTask(line: Int, expected: String? = nil) {
        guard expected == nil || expected == text else {
            NSSound.beep()
            return
        }
        guard let newText = MarkdownFormatter.toggleTask(in: text, line: line) else { return }
        let wasClean = !isDirty && !isEditing && pendingDiskText == nil
        // エディタがあれば本文の編集として映す（外部更新と違って、エディタの取り消しの履歴を消さない）
        if editor?.applyWithoutUndo(from: text, to: newText) != true {
            text = newText
        }
        undoManager?.registerUndo(withTarget: self) { model in
            MainActor.assumeIsolated { model.toggleTask(line: line, expected: newText) }
        }
        undoManager?.setActionName("チェックボックスの切り替え")
        clearLatestChanges()
        refreshDerived()
        updateDirty()
        if wasClean { save() }
        if isSearching { scheduleSearch(delay: 300) }
    }

    /// Cmd+S。元の文字コード・改行コード・BOM のまま、アトミックに書き込む。
    func save() {
        guard isDirty || pendingDiskText != nil else { return }
        do {
            try format.encode(text).write(to: url, options: .atomic)
            savedText = text
            pendingDiskText = nil
            updateDirty()
            refreshModifiedAt()
        } catch {
            let alert = NSAlert(error: error)
            alert.messageText = "保存できませんでした"
            alert.runModal()
        }
    }

    private func updateDirty() {
        let dirty = text != savedText
        guard dirty != isDirty else { return }
        isDirty = dirty
        onDirtyChange?(dirty)
    }

    /// 書式メニュー・ツールバー・ショートカットから。エディタ表示中だけ使える。
    func applyFormat(_ format: MarkdownFormat) {
        guard mode == .editor, let editor else {
            NSSound.beep()
            return
        }
        editor.apply(format)
    }

    // MARK: 表示モード

    func toggleMode() {
        setMode(mode == .preview ? .editor : .preview)
    }

    func setMode(_ newMode: ViewMode) {
        guard newMode != mode else { return }
        if mode == .editor, let position = editor?.topPosition() {
            scrollPosition = position
        }
        mode = newMode
        selectionCount = 0
        if newMode == .preview {
            // エディタの編集を待たずに描き直す（描き終わるまでは前の描画のまま見せる）
            if renderedText != text { refreshDerived() }
            preview?.activate(at: scrollPosition)
        } else {
            editor?.activate(at: scrollPosition)
        }
        if isSearching { scheduleSearch(delay: 50) }
    }

    // MARK: 検索

    /// ⌘F は検索だけ、⌥⌘F は置換の欄も出す（プレビューで押したらエディタに切り替える。置換は元の文書に対して行うため）。
    func showSearch(replacing: Bool = false) {
        // エディタを初めて出す時はビューができるのを少し待ってから照合する
        let switching = replacing && mode != .editor
        if switching { setMode(.editor) }
        isReplacing = replacing
        isSearching = true
        searchFocusRequest += 1
        scheduleSearch(delay: switching ? 50 : 0)
    }

    func toggleReplace() {
        if isReplacing {
            isReplacing = false
        } else {
            showSearch(replacing: true)
        }
    }

    func hideSearch() {
        isSearching = false
        isReplacing = false
        replacedCount = nil
        searchTask?.cancel()
        searchRanges = []
        searchResultCount = 0
        preview?.clearSearch()
        editor?.showSearch([], current: -1)
    }

    /// Cmd+G / Shift+Cmd+G・検索欄で Return。
    func findNext(forward: Bool = true) {
        guard isSearching else {
            showSearch()
            return
        }
        guard !searchRanges.isEmpty else {
            NSSound.beep()
            return
        }
        let count = searchRanges.count
        searchCurrentIndex = (searchCurrentIndex + (forward ? 1 : -1) + count) % count
        switch mode {
        case .editor:
            editor?.showSearch(searchRanges, current: searchCurrentIndex)
        case .preview:
            let ranges = searchRanges, index = searchCurrentIndex
            Task { await preview?.highlightSearch(ranges, current: index) }
        }
    }

    /// 今の一致を置き換え、その後ろの一致を次の対象にする。
    func replaceCurrent() {
        guard mode == .editor, let editor, searchRanges.indices.contains(searchCurrentIndex) else {
            NSSound.beep()
            return
        }
        let edit = SearchReplace.replace(searchRanges[searchCurrentIndex], with: replacement)
        guard editor.apply(edit) else { return }
        replacedCount = nil
        searchAgain(from: NSMaxRange(edit.selection))
    }

    /// すべての一致を置き換える（⌘Z の1回で戻せる）。
    func replaceAll() {
        guard mode == .editor, let editor,
              let edit = SearchReplace.replaceAll(searchRanges, with: replacement, in: editor.currentText) else {
            NSSound.beep()
            return
        }
        let count = searchRanges.count
        guard editor.apply(edit) else { return }
        searchAgain(from: edit.selection.location)
        replacedCount = count
    }

    /// 置き換えた直後に照合し直す（編集で予約された遅い再検索は取り消し、対象を location 以降の最初の一致にする）。
    private func searchAgain(from location: Int) {
        guard let editor else { return }
        searchTask?.cancel()
        let text = editor.currentText, query = searchQuery
        // 照合し終わるまでは古い範囲で置き換えない
        searchRanges = []
        searchTask = Task { [weak self] in
            guard let self else { return }
            let ranges = await self.matches(of: query, in: text)
            guard !Task.isCancelled, query == self.searchQuery, editor.currentText == text else { return }
            self.searchRanges = ranges
            self.searchResultCount = ranges.count
            self.searchCurrentIndex = ranges.firstIndex { $0.location >= location } ?? 0
            editor.showSearch(ranges, current: self.searchCurrentIndex)
        }
    }

    private func scheduleSearch(delay milliseconds: Int = 120) {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            if milliseconds > 0 { try? await Task.sleep(for: .milliseconds(milliseconds)) }
            guard !Task.isCancelled else { return }
            await self?.performSearch()
        }
    }

    /// 表示中のビューの本文で照合し、ハイライトする。最初の一致は「画面に見えている位置以降」から選ぶ。
    private func performSearch() async {
        let query = searchQuery
        guard isSearching, !query.isEmpty else {
            searchRanges = []
            searchResultCount = 0
            searchCurrentIndex = 0
            preview?.clearSearch()
            editor?.showSearch([], current: -1)
            return
        }
        switch mode {
        case .editor:
            guard let editor else { return }
            let text = editor.currentText
            let ranges = await matches(of: query, in: text)
            guard !Task.isCancelled, query == searchQuery, mode == .editor, editor.currentText == text else { return }
            let visible = editor.firstVisibleCharacterIndex()
            searchRanges = ranges
            searchResultCount = ranges.count
            searchCurrentIndex = ranges.firstIndex { $0.location >= visible } ?? 0
            editor.showSearch(ranges, current: searchCurrentIndex)
        case .preview:
            guard let preview, let text = await preview.searchText(), query == searchQuery, mode == .preview else { return }
            let ranges = await matches(of: query, in: text)
            guard !Task.isCancelled, query == searchQuery, mode == .preview else { return }
            searchRanges = ranges
            searchResultCount = ranges.count
            searchCurrentIndex = max(0, await preview.highlightSearch(ranges, current: nil))
        }
    }

    /// 照合する。正規化は本文が変わったときだけやり直し（1MB で数百 ms かかる）、メインスレッドの外で行う。
    private func matches(of query: String, in text: String) async -> [NSRange] {
        if let index = searchIndex, index.source == text { return index.ranges(of: query) }
        let index = await Task.detached(priority: .userInitiated) { NormalizedText(text) }.value
        searchIndex = index
        return index.ranges(of: query)
    }

    // MARK: 変更箇所

    /// 確認済み：今の内容を新しいベースラインにする。
    /// git HEAD と比較していた場合も、今の内容を基準にする（＝通常の基準に戻る）。
    func markAsReviewed() {
        reviewedBaseline = text
        externalUpdateCount = 0
        baselineSource = .reviewed
        changes = LineChanges()
        latestChanges = LineChanges()
        pendingLatestFrom = nil
        changeItems = []
        jumpToLatestFirst = false
        // 作り直しの途中なら、新しい基準で作り直す（古い基準の差分を後から反映しない）
        if renderTask != nil { refreshDerived() }
        lastJump = nil
    }

    /// ⌘J：次の変更箇所へ。
    func jumpToNextChange() {
        jumpToChange(forward: true)
    }

    /// ⇧⌘J：前の変更箇所へ。
    func jumpToPreviousChange() {
        jumpToChange(forward: false)
    }

    /// 端まで行ったら反対の端へ回る。外部更新の後の最初の ⌘J だけは最新の変更の先頭へ飛ぶ（⇧⌘J は今の位置から手前へ）。
    private func jumpToChange(forward: Bool) {
        let target: Int?
        if forward, jumpToLatestFirst, let first = latestChanges.jumpLines.first {
            target = first
        } else if let last = lastJump, last.position == nil || last.position == scrollPosition || scrollPosition.contains(last.line) {
            // 移動してから表示位置が動いていない＝続けて押された。同じ要素内の変更で止まらないよう、移動先の先（手前）へ。
            target = forward ? changes.nextJumpLine(after: last.line, inclusive: false) : changes.previousJumpLine(before: last.line)
        } else {
            target = forward
                ? changes.nextJumpLine(after: scrollPosition.line, inclusive: true)
                : changes.previousJumpLine(before: scrollPosition.line)
        }
        guard let target else {
            NSSound.beep()
            return
        }
        jumpToLatestFirst = false
        recordJump()
        lastJump = (target, nil)  // 移動した直後の表示位置は、ビューからの通知で埋める
        switch mode {
        case .preview: preview?.jump(toLine: target)
        case .editor: editor?.jump(toLine: target)
        }
    }

    // MARK: 付箋

    /// lines のどれかに付箋があれば外し、無ければ先頭の行に付ける。
    /// プレビューでは1つの要素が複数行にまたがるので、要素の行をまとめて渡す。
    func toggleBookmark(lines: [Int]) {
        updateBookmarks()
        let targets = Set(lines)
        if bookmarks.contains(where: { targets.contains($0.line) }) {
            bookmarks.removeAll { targets.contains($0.line) }
        } else {
            let textLines = text.split(separator: "\n", omittingEmptySubsequences: false)
            guard let line = lines.first, textLines.indices.contains(line - 1) else { return }
            bookmarks.append(Bookmark(line: line, snippet: Bookmarks.snippet(of: textLines[line - 1])))
            bookmarks.sort { $0.line < $1.line }
        }
        BookmarkStore.save(bookmarks, for: url)
    }

    /// ⌘D：エディタではカーソルの行、プレビューでは画面上部に見えている要素。
    func toggleBookmarkAtCurrentPosition() {
        switch mode {
        case .editor:
            guard let line = editor?.cursorLine() else { return }
            toggleBookmark(lines: [line])
        case .preview:
            toggleBookmark(lines: Array(scrollPosition.line...max(scrollPosition.line, scrollPosition.endLine)))
        }
    }

    func removeBookmark(line: Int) {
        bookmarks.removeAll { $0.line == line }
        BookmarkStore.save(bookmarks, for: url)
    }

    func removeAllBookmarks() {
        bookmarks = []
        BookmarkStore.save(bookmarks, for: url)
    }

    func goToBookmark(line: Int) {
        recordJump()
        switch mode {
        case .preview: preview?.jump(toLine: line)
        case .editor: editor?.jump(toLine: line)
        }
    }

    /// 「最新の更新」は外部更新だけを指すので、自分の編集では消す。
    private func clearLatestChanges() {
        latestChanges = LineChanges()
        pendingLatestFrom = nil
    }

    // MARK: 本文から作るもの

    /// 本文から作るもの（描画・変更の差分・「変更」欄・付箋の追従）を作り直す。1MB の文書で数百 ms かかるので、
    /// メインスレッドの外で作り、できた時に本文が変わっていなければ反映する（変わっていれば次の作り直しに任せる）。
    /// latestFrom は外部更新の前の内容（「最新の更新」の差分を取る）。無ければ今の「最新の更新」をそのまま使う。
    private func refreshDerived(latestFrom previous: String? = nil, after delay: Duration? = nil) {
        if let previous { pendingLatestFrom = previous }
        let text = text, baseline = baseline, latestFrom = pendingLatestFrom, currentLatest = latestChanges
        let bookmarks = bookmarks, bookmarkText = bookmarkText
        renderTask?.cancel()
        renderTask = Task { [weak self] in
            if let delay { try? await Task.sleep(for: delay) }
            guard !Task.isCancelled else { return }
            let derived = await Task.detached(priority: .userInitiated) {
                DerivedContent(text: text, baseline: baseline, latestFrom: latestFrom, currentLatest: currentLatest,
                               bookmarks: bookmarks, bookmarkText: bookmarkText)
            }.value
            guard let self, !Task.isCancelled, self.text == text else { return }
            self.apply(derived, text: text, fromExternal: latestFrom != nil, bookmarks: bookmarks, bookmarkText: bookmarkText)
            self.renderTask = nil
        }
    }

    private func apply(_ derived: DerivedContent, text: String, fromExternal: Bool, bookmarks: [Bookmark], bookmarkText: String) {
        rendered = derived.rendered
        renderedText = text
        hasRendered = true
        changes = derived.changes
        latestChanges = derived.latest
        if derived.items != changeItems { changeItems = derived.items }
        if fromExternal {
            pendingLatestFrom = nil
            jumpToLatestFirst = !derived.latest.isEmpty
        }
        // 作っている間に付箋を付け外ししていたら、その付箋を優先する（次の作り直しで追従する）
        if let updated = derived.bookmarks, self.bookmarks == bookmarks, self.bookmarkText == bookmarkText {
            self.bookmarkText = text
            if updated != self.bookmarks {
                self.bookmarks = updated
                BookmarkStore.save(updated, for: url)
            }
        }
        if let fragment = pendingFragment {
            pendingFragment = nil
            reveal(fragment: fragment)
        }
    }

    /// サイドバーの「変更」欄のクリック。⌘[ で戻れ、続けて ⌘J ／ ⇧⌘J を押すとここから次（前）へ進む。
    func goToChange(line: Int) {
        recordJump()
        jumpToLatestFirst = false
        lastJump = (line, nil)
        switch mode {
        case .preview: preview?.jump(toLine: line)
        case .editor: editor?.jump(toLine: line)
        }
    }

    /// 本文が変わっていたら、付箋を新しい行番号へ追従させる（外部更新・自分の編集の両方）。
    private func updateBookmarks() {
        guard text != bookmarkText else { return }
        let updated = Bookmarks.remap(bookmarks, from: bookmarkText, to: text)
        bookmarkText = text
        guard updated != bookmarks else { return }
        bookmarks = updated
        BookmarkStore.save(updated, for: url)
    }

    // MARK: スクロール位置

    /// 見出し一覧のクリック。
    func selectHeading(line: Int) {
        recordJump()
        activeHeadingLine = line
        scrollToHeading(line: line)
    }

    /// ほかの文書のリンク（`other.md#見出し`）の見出しへ移動する。見つからなければ開くだけ。
    func reveal(fragment: String) {
        guard renderedText == text else {
            pendingFragment = fragment
            return
        }
        guard let line = Markdown.headingLine(forFragment: fragment, anchors: rendered.anchors) else { return }
        activeHeadingLine = line
        switch mode {
        case .preview where preview?.hasShownDocument == true:
            recordJump()
            preview?.jump(toLine: line)
        case .editor where editor != nil:
            recordJump()
            editor?.jump(toLine: line)
        default:
            // 開いたばかりでまだ描いていない。最初の描画で戻す位置（前回の位置）の代わりにこの見出しを出す。
            scrollPosition = ScrollPosition(line: line, endLine: line)
        }
    }

    func scrollToHeading(line: Int) {
        switch mode {
        case .preview: preview?.scroll(toLine: line)
        case .editor: editor?.jump(toLine: line)
        }
    }

    // MARK: 戻る・進む

    /// 移動する前の位置を「戻る」の履歴に積む（直前と同じ位置なら積まない）。新しく移動したら「進む」の履歴は捨てる。
    func recordJump() {
        if backStack.last != scrollPosition { backStack.append(scrollPosition) }
        if backStack.count > 100 { backStack.removeFirst() }
        forwardStack.removeAll()
    }

    /// ⌘[：移動する前の位置へ戻る。
    func goBack() {
        guard let position = backStack.popLast() else {
            NSSound.beep()
            return
        }
        forwardStack.append(scrollPosition)
        show(position)
    }

    /// ⌘]：戻る前の位置へ進む。
    func goForward() {
        guard let position = forwardStack.popLast() else {
            NSSound.beep()
            return
        }
        backStack.append(scrollPosition)
        show(position)
    }

    // MARK: トラックパッド・マウスでの戻る／進む

    /// 本文（プレビューかエディタ）の上か。サイドバーやバーの上では戻る／進むにしない。
    func isContent(_ view: NSView?) -> Bool {
        guard let view else { return false }
        return preview.map { view.isDescendant(of: $0.webView) } == true
            || editor.map { view.isDescendant(of: $0.scrollView) } == true
    }

    /// トラックパッドの2本指の横スワイプ（システム設定の「ページ間をスワイプ」）。スクロールのイベントを自分で数える。
    /// - 指を置いてから少し動いて横向きと分かり、その向きに戻れる／進めて、マウスの下に横にスクロールできる表・コードが
    ///   無い時だけスワイプにする（表の上では端まで行っていても戻らない）。以後このジェスチャーのスクロールは本文に渡さない。
    /// - 矢印は指の動いた量だけ出し（慣性では動かさない）、指を離した時に `swipeDistance` 以上動いていれば戻る／進む。
    ///   AppKit の trackSwipeEvent は指を離した後も慣性で動き続けて勝手に決まるので使わない。
    /// スクロールを本文に渡さない時は true。
    func handleSwipeScroll(_ event: NSEvent) -> Bool {
        // 指を離した後の慣性のスクロールは、スワイプした時だけ捨てる
        if !event.momentumPhase.isEmpty { return swallowsMomentum }
        guard NSEvent.isSwipeTrackingFromScrollEventsEnabled else { return false }
        switch event.phase {
        case .began:
            swipe = .pending(.zero)
            swallowsMomentum = false
            return false
        case .changed:
            switch swipe {
            case .pending(var moved):
                moved.width += event.scrollingDeltaX
                moved.height += event.scrollingDeltaY
                swipe = .pending(moved)
                guard abs(moved.width) + abs(moved.height) >= 8 else { return false }
                // スクロールの量が正なら、左へスクロールしようとしている（左の端を越えた先＝戻る）
                let back = moved.width > 0
                let overTable = mode == .preview && preview?.isOverHorizontalScroll == true
                guard abs(moved.width) > abs(moved.height) * 2, !overTable,
                      back ? !backStack.isEmpty : !forwardStack.isEmpty else {
                    swipe = nil
                    return false
                }
                swipe = .active(back: back, distance: abs(moved.width))
            case .active(let back, let distance):
                swipe = .active(back: back, distance: max(0, distance + (back ? 1 : -1) * event.scrollingDeltaX))
            case nil:
                return false
            }
            if case .active(let back, let distance) = swipe {
                swipeIndicator = SwipeIndicator(back: back, amount: min(1, distance / Self.swipeDistance))
            }
            return true
        case .ended, .cancelled:
            defer { swipe = nil }
            guard case .active(let back, let distance) = swipe else { return false }
            swipeIndicator = nil
            swallowsMomentum = true
            if event.phase == .ended && distance >= Self.swipeDistance { back ? goBack() : goForward() }
            return true
        default:
            return false
        }
    }

    /// 戻る／進むに必要な指の移動量（ポイント）。矢印はここで出切って止まる。
    private static let swipeDistance: CGFloat = 110

    private enum SwipeState {
        /// 指を置いた。向きが決まるまで動いた量を貯める
        case pending(CGSize)
        /// スワイプ中。distance はその向きに動いた量
        case active(back: Bool, distance: CGFloat)
    }

    private func show(_ position: ScrollPosition) {
        lastJump = nil  // 戻った位置から ⌘J で探し直す
        switch mode {
        case .preview: preview?.show(position)
        case .editor: editor?.show(position)
        }
    }

    /// 表示中のビューからだけ受け付ける（隠れているビューのスクロールで上書きしない）。
    func updateScrollPosition(_ position: ScrollPosition, from source: ViewMode) {
        guard source == mode else { return }
        scrollPosition = position
        if lastJump != nil && lastJump?.position == nil { lastJump?.position = position }
        // 通知はスクロール中に頻繁に来るので、保存は止まってからまとめて行う（閉じる時にも保存する）
        saveScrollTask?.cancel()
        saveScrollTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard let self, !Task.isCancelled else { return }
            ScrollMemory.save(self.scrollPosition, for: self.url)
        }
        let heading = rendered.outline.last { $0.line <= position.line }?.line
        if heading != activeHeadingLine { activeHeadingLine = heading }
    }

    // MARK: 読み込み

    /// これより大きい文書は開かない（描画がメインスレッドで 1MB あたり約 0.5 秒かかるため）。
    /// Finder の表示（1000 単位）とそろえる。
    nonisolated static let maxFileSize: Int64 = 10_000_000

    /// UTF-8（BOM は除去）→ Shift_JIS の順に試す。改行は LF に正規化する。
    nonisolated static func readText(at url: URL) throws -> (String, FileFormat) {
        try decode(try Data(regularFileAt: url, limit: maxFileSize))
    }

    nonisolated static func decode(_ fileData: Data) throws -> (String, FileFormat) {
        var data = fileData
        var format = FileFormat()
        // Foundation の UTF-8 デコードは BOM を黙って取り除くので、バイト列で判定する
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            format.hasBOM = true
            data.removeFirst(3)
        }
        let text: String
        if let utf8 = String(data: data, encoding: .utf8) {
            text = utf8
        } else if let sjis = String(data: data, encoding: .shiftJIS) {
            text = sjis
            format.encoding = .shiftJIS
        } else {
            throw FileReadRefusal.unsupportedEncoding
        }
        if text.utf8.contains(13) { format.lineEnding = "\r\n" }
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return (normalized, format)
    }
}

extension Data {
    /// 通常のファイルだけを、上限の大きさまで読む。FIFO で固まったり、/dev/zero へのシンボリックリンクや
    /// 巨大なファイルでメモリを使い果たしたりしないよう、開いた記述子で種類と大きさを確かめてから読む。
    nonisolated init(regularFileAt url: URL, limit: Int64) throws {
        // O_NONBLOCK：FIFO は open() の時点で書き手を待って固まるため（通常のファイルの読み込みには影響しない）
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            let code: CocoaError.Code = switch errno {
            case ENOENT: .fileReadNoSuchFile
            case EACCES, EPERM: .fileReadNoPermission
            default: .fileReadUnknown
            }
            throw CocoaError(code, userInfo: [NSFilePathErrorKey: url.path])
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        guard info.st_mode & S_IFMT == S_IFREG else { throw FileReadRefusal.notRegularFile }
        guard info.st_size <= limit else { throw FileReadRefusal.tooLarge(size: info.st_size, limit: limit) }
        // 読んでいる間に書き足されても上限を超えて読まない
        let data = try handle.read(upToCount: Int(limit) + 1) ?? Data()
        guard data.count <= limit else { throw FileReadRefusal.tooLarge(size: Int64(data.count), limit: limit) }
        self = data
    }
}

/// 読み込まないファイルの理由。画面にそのまま出す。
enum FileReadRefusal: LocalizedError, Equatable {
    case notRegularFile
    case tooLarge(size: Int64, limit: Int64)
    case unsupportedEncoding

    var errorDescription: String? {
        switch self {
        case .notRegularFile:
            "通常のファイルではありません（名前付きパイプやデバイスなどは開けません）。"
        case .tooLarge(let size, let limit):
            "ファイルが大きすぎます（\(Self.format(size))）。開けるのは \(Self.format(limit)) までです。"
        case .unsupportedEncoding:
            "文字コードを判別できませんでした（UTF-8 と Shift_JIS に対応しています）。"
        }
    }

    private static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// 読み込んだファイルの文字コード・改行コード・BOM。保存時に元の形式へ戻すために覚えておく。
struct FileFormat: Equatable {
    var encoding = String.Encoding.utf8
    var lineEnding = "\n"
    var hasBOM = false

    func encode(_ text: String) throws -> Data {
        var output = lineEnding == "\n" ? text : text.replacingOccurrences(of: "\n", with: lineEnding)
        if hasBOM { output = "\u{FEFF}" + output }
        guard let data = output.data(using: encoding) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return data
    }
}

/// 画面上部に見えている要素の行範囲と、その要素内でのスクロール割合。
/// 本文から作るもの。メインスレッドの外で作る。
struct DerivedContent: Sendable {
    let rendered: RenderedMarkdown
    let changes: LineChanges
    let latest: LineChanges
    let items: [ChangeItem]
    /// 付箋を追従させた結果（付箋の元の内容と同じなら nil）
    let bookmarks: [Bookmark]?

    init(text: String, baseline: String, latestFrom: String?, currentLatest: LineChanges,
         bookmarks: [Bookmark], bookmarkText: String) {
        rendered = Markdown.render(text)
        changes = LineDiff.changes(from: baseline, to: text)
        latest = latestFrom.map { LineDiff.changes(from: $0, to: text) } ?? currentLatest
        items = changes.isEmpty ? [] : changes.items(in: text.split(separator: "\n", omittingEmptySubsequences: false), latest: latest)
        self.bookmarks = bookmarkText == text ? nil : Bookmarks.remap(bookmarks, from: bookmarkText, to: text)
    }
}

struct SwipeIndicator: Equatable {
    var back: Bool
    /// 0〜1（1 で端から出切る）
    var amount: Double
}

struct ScrollPosition: Equatable {
    var line = 1
    var endLine = 1
    var ratio = 0.0

    func contains(_ line: Int) -> Bool { (self.line...max(self.line, endLine)).contains(line) }
}

/// ファイルパスごとのスクロール位置を UserDefaults に保存する（最近使った 200 件まで）。
enum ScrollMemory {
    private static let key = "scrollPositions"
    private static let limit = 200

    static func load(for url: URL) -> ScrollPosition? {
        guard let entry = all()[url.path], entry.count >= 2 else { return nil }
        return ScrollPosition(line: Int(entry[0]), endLine: Int(entry[0]), ratio: entry[1])
    }

    static func save(_ position: ScrollPosition, for url: URL) {
        var entries = all()
        entries[url.path] = [Double(position.line), position.ratio, Date().timeIntervalSince1970]
        if entries.count > limit {
            let oldest = entries.sorted { ($0.value.last ?? 0) < ($1.value.last ?? 0) }.prefix(entries.count - limit)
            for (path, _) in oldest { entries[path] = nil }
        }
        UserDefaults.standard.set(entries, forKey: key)
    }

    private static func all() -> [String: [Double]] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: [Double]] ?? [:]
    }
}
