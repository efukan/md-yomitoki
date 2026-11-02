import AppKit
import SwiftUI

struct EditorView: NSViewRepresentable {
    let model: DocumentModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> NSScrollView {
        context.coordinator.scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.update(text: model.text, marks: model.marks, isActive: model.mode == .editor)
        context.coordinator.setScale(AppSettings.shared.textScale)
        context.coordinator.setLineNumbers(AppSettings.shared.showLineNumbers)
    }

    static func dismantleNSView(_ scrollView: NSScrollView, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        let scrollView = NSScrollView()
        let textView = NSTextView(usingTextLayoutManager: false)  // TextKit 1（一時属性を使うため）
        private let marksView = EditorMarksView()
        private let model: DocumentModel
        /// ビューとモデルで一致している最後の内容。IME 変換中はビューだけが先行する。
        private var syncedText: String
        private var marks = PreviewMarks()
        private var editedRange: NSRange?
        private var needsFullRestyle = false
        /// 先頭のフロントマターの行数。変わったら全体を整形し直す（中の文字の編集では整形し直さない）。
        private var frontMatterLines: Int?
        private var didInitialScroll = false
        private var showsLineNumbers = false
        private var decorateTask: Task<Void, Never>?
        private var scrollReportTask: Task<Void, Never>?
        private var selectionCountTask: Task<Void, Never>?
        private var searchRanges: [NSRange] = []
        private var searchCurrent = -1

        init(model: DocumentModel) {
            self.model = model
            syncedText = model.text
            super.init()
            configure()
            textView.textStorage?.setAttributedString(NSAttributedString(string: model.text, attributes: EditorStyle.base))
            if let storage = textView.textStorage {
                MarkdownStyler.style(storage, in: NSRange(location: 0, length: storage.length))
                frontMatterLines = Markdown.frontMatterLineCount(storage.string)
            }
            NotificationCenter.default.addObserver(
                self, selector: #selector(boundsDidChange), name: NSView.boundsDidChangeNotification, object: scrollView.contentView
            )
            model.editor = self
        }

        private func configure() {
            scrollView.hasVerticalScroller = true
            scrollView.drawsBackground = false
            scrollView.borderType = .noBorder
            scrollView.contentView.postsBoundsChangedNotifications = true

            textView.minSize = .zero
            textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude)
            textView.isVerticallyResizable = true
            textView.isHorizontallyResizable = false
            textView.autoresizingMask = [.width]
            textView.textContainer?.widthTracksTextView = true
            textView.textContainerInset = NSSize(width: EditorStyle.textInset, height: EditorStyle.textInsetTop)
            textView.drawsBackground = false
            textView.isRichText = false
            textView.importsGraphics = false
            textView.allowsUndo = true
            textView.usesFindBar = false
            textView.isAutomaticQuoteSubstitutionEnabled = false
            textView.isAutomaticDashSubstitutionEnabled = false
            textView.isAutomaticTextReplacementEnabled = false
            textView.isAutomaticSpellingCorrectionEnabled = false
            textView.isContinuousSpellCheckingEnabled = false
            textView.smartInsertDeleteEnabled = false
            textView.layoutManager?.allowsNonContiguousLayout = true
            textView.typingAttributes = EditorStyle.base
            textView.delegate = self
            scrollView.documentView = textView
            marksView.textView = textView
            marksView.frame = textView.bounds
            marksView.autoresizingMask = [.width, .height]
            textView.addSubview(marksView)
        }

        func tearDown() {
            NotificationCenter.default.removeObserver(self)
            decorateTask?.cancel()
            scrollReportTask?.cancel()
            marksView.closePopover()
            model.editor = nil
        }

        // MARK: モデル → ビュー

        /// 文字の大きさはスクロールビューの拡大率で変える（折り返しも拡大後の幅でやり直される）。見ていた位置は保つ。
        func setScale(_ scale: Double) {
            guard scrollView.magnification != scale else { return }
            let anchor = visibleAnchor()
            scrollView.magnification = scale
            if let anchor { restoreAnchor(index: anchor.index, offset: anchor.offset) }
        }

        func setLineNumbers(_ show: Bool) {
            guard show != showsLineNumbers else { return }
            showsLineNumbers = show
            marksView.showsLineNumbers = show
            refreshLineNumbers()
        }

        /// 番号の位置を今の本文に合わせ、番号の欄の分だけ本文の余白を広げる（幅が変わるのは桁が増減した時だけ）。
        /// 入力のたびに呼ぶ（decorate を待つと、改行してから番号が出るまで遅れて見える）。
        private func refreshLineNumbers() {
            var inset = EditorStyle.textInset
            if showsLineNumbers {
                let starts = lineStarts(textView.string as NSString)
                marksView.setLineStarts(starts)
                inset = EditorStyle.textInset(lineCount: starts.count)
            }
            guard textView.textContainerInset.width != inset else { return }
            let anchor = visibleAnchor()
            textView.textContainerInset = NSSize(width: inset, height: EditorStyle.textInsetTop)
            if let anchor { restoreAnchor(index: anchor.index, offset: anchor.offset) }
            marksView.needsDisplay = true
        }

        func update(text: String, marks: PreviewMarks, isActive: Bool) {
            scrollView.isHidden = !isActive
            if text != syncedText && !textView.hasMarkedText() {
                applyExternal(text)
            }
            if marks != self.marks {
                self.marks = marks
                scheduleDecorate(after: 0)
            }
            if isActive && !didInitialScroll {
                didInitialScroll = true
                // 初回はまだビューの幅が決まっていないので、レイアウト後にスクロールする
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.activate(at: self.model.scrollPosition)
                }
            }
        }

        /// 外部更新（再読み込み）。共通する先頭と末尾を除いた中間だけを置き換えるので、選択範囲と表示位置が保たれる。
        private func applyExternal(_ text: String) {
            guard let storage = textView.textStorage else { return }
            let old = storage.string as NSString
            let new = text as NSString
            var prefix = 0
            let limit = min(old.length, new.length)
            while prefix < limit && old.character(at: prefix) == new.character(at: prefix) { prefix += 1 }
            var suffix = 0
            while suffix < limit - prefix
                    && old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) { suffix += 1 }
            // サロゲートペアや結合文字の途中で切らない
            if prefix < old.length { prefix = old.rangeOfComposedCharacterSequence(at: prefix).location }
            if suffix > 0 {
                let oldEnd = old.length - suffix
                let sequence = old.rangeOfComposedCharacterSequence(at: oldEnd)
                if sequence.location < oldEnd { suffix = old.length - NSMaxRange(sequence) }
            }
            let replaced = NSRange(location: prefix, length: old.length - prefix - suffix)
            let replacement = new.substring(with: NSRange(location: prefix, length: new.length - prefix - suffix))
            let delta = (replacement as NSString).length - replaced.length

            let anchor = visibleAnchor()
            let fenceTouched = MarkdownStyler.containsFence(old.substring(with: replaced)) || MarkdownStyler.containsFence(replacement)
            storage.beginEditing()
            storage.replaceCharacters(in: replaced, with: NSAttributedString(string: replacement, attributes: EditorStyle.base))
            storage.endEditing()
            let styled = fenceTouched || frontMatterLinesChanged()
                ? NSRange(location: 0, length: storage.length)
                : (storage.string as NSString).lineRange(for: NSRange(location: replaced.location, length: (replacement as NSString).length))
            MarkdownStyler.style(storage, in: styled)
            textView.undoManager?.removeAllActions()
            syncedText = text

            if let anchor {
                let index = anchor.index < replaced.location ? anchor.index
                    : anchor.index >= NSMaxRange(replaced) ? anchor.index + delta : replaced.location
                restoreAnchor(index: index, offset: anchor.offset)
            }
            if showsLineNumbers { refreshLineNumbers() }
            scheduleDecorate(after: 0)
        }

        /// フロントマターの行数が変わったか（変わっていたら覚え直す）
        private func frontMatterLinesChanged() -> Bool {
            let lines = Markdown.frontMatterLineCount(textView.string)
            guard lines != frontMatterLines else { return false }
            frontMatterLines = lines
            return true
        }

        // MARK: ビュー → モデル

        func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            let string = textView.string as NSString
            // フェンス（```）の行に触れる編集は、それ以降の行の解釈が変わるので全体を整形し直す
            if MarkdownStyler.containsFence(string.substring(with: string.lineRange(for: range)))
                || MarkdownStyler.containsFence(replacementString ?? "") {
                needsFullRestyle = true
            }
            let inserted = NSRange(location: range.location, length: (replacementString as NSString?)?.length ?? 0)
            editedRange = editedRange.map { NSUnionRange($0, inserted) } ?? inserted
            model.editorWillChange()
            return true
        }

        func textDidChange(_ notification: Notification) {
            // IME の変換中は属性もモデルも触らない（文字消え・カーソル飛びの防止）。確定時にもう一度呼ばれる。
            guard !textView.hasMarkedText(), let storage = textView.textStorage else { return }
            let string = storage.string as NSString
            var range: NSRange?
            if needsFullRestyle {
                range = NSRange(location: 0, length: string.length)
            } else if let edited = editedRange {
                let location = min(edited.location, string.length)
                range = string.lineRange(for: NSRange(location: location, length: min(edited.length, string.length - location)))
            }
            if frontMatterLinesChanged() {
                range = NSRange(location: 0, length: string.length)
            }
            needsFullRestyle = false
            editedRange = nil
            if let range { MarkdownStyler.style(storage, in: range) }
            textView.typingAttributes = EditorStyle.base

            syncedText = storage.string
            model.editorTextDidChange(syncedText)
            if showsLineNumbers { refreshLineNumbers() }
            scheduleDecorate(after: 200)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard model.mode == .editor else { return }
            selectionCountTask?.cancel()
            let selected = textView.selectedRange()
            guard selected.length > 0 else {
                model.selectionCount = 0
                return
            }
            let text = (textView.string as NSString).substring(with: selected)
            // 数えるのに描画するので、大きな選択（すべてを選択など）はメインスレッドの外で数える
            guard selected.length > 20_000 else {
                model.selectionCount = Markdown.render(text).charCount
                return
            }
            selectionCountTask = Task { [weak self] in
                let count = await Task.detached(priority: .userInitiated) { Markdown.render(text).charCount }.value
                guard let self, !Task.isCancelled else { return }
                self.model.selectionCount = count
            }
        }

        // MARK: 書式

        /// 書式を付ける／外す。shouldChangeText〜didChangeText で囲むので ⌘Z で取り消せ、
        /// textDidChange 経由で整形とモデルへの反映も通常の入力と同じように行われる。
        func apply(_ format: MarkdownFormat) {
            guard !textView.hasMarkedText() else { return }
            let edit = MarkdownFormatter.edit(format, in: textView.string, selection: textView.selectedRange())
            // 変化の無い操作で、空の取り消し履歴を残さない
            guard edit.range.length > 0 || !edit.replacement.isEmpty else {
                NSSound.beep()
                return
            }
            guard apply(edit) else { return }
            textView.scrollRangeToVisible(edit.selection)
            textView.window?.makeFirstResponder(textView)
        }

        /// 置き換えを1回の取り消し単位として適用する（書式・置換の共通の入口）。IME の変換中は何もしない。
        @discardableResult
        func apply(_ edit: TextEdit) -> Bool {
            guard !textView.hasMarkedText(), NSMaxRange(edit.range) <= (textView.string as NSString).length,
                  textView.shouldChangeText(in: edit.range, replacementString: edit.replacement) else { return false }
            textView.replaceCharacters(in: edit.range, with: edit.replacement)
            textView.didChangeText()
            textView.setSelectedRange(edit.selection)
            return true
        }

        /// 文書側で行った編集（プレビューのチェックボックス）を映す。外部更新と違って取り消しの履歴は消さず、
        /// 取り消しは文書側が登録する（ここでは登録しない）。変わった所が1か所でなければ（映せなければ）false。
        func applyWithoutUndo(from old: String, to new: String) -> Bool {
            guard !textView.hasMarkedText(), textView.string == old else { return false }
            let before = old as NSString, after = new as NSString
            guard before.length == after.length else { return false }
            var start = 0
            while start < before.length && before.character(at: start) == after.character(at: start) { start += 1 }
            var end = before.length
            while end > start && before.character(at: end - 1) == after.character(at: end - 1) { end -= 1 }
            let range = NSRange(location: start, length: end - start)
            textView.breakUndoCoalescing()
            textView.undoManager?.disableUndoRegistration()
            defer { textView.undoManager?.enableUndoRegistration() }
            return apply(TextEdit(range: range, replacement: after.substring(with: range), selection: textView.selectedRange()))
        }

        /// 右クリックメニューの先頭に書式を並べる。
        func textView(_ view: NSTextView, menu: NSMenu, for event: NSEvent, at charIndex: Int) -> NSMenu? {
            var index = 0
            for format in MarkdownFormat.menuLayout {
                let item: NSMenuItem
                if let format {
                    item = NSMenuItem(title: format.title, action: #selector(formatMenuItemSelected(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = format.rawValue
                    item.image = NSImage(systemSymbolName: format.symbol, accessibilityDescription: nil)
                } else {
                    item = .separator()
                }
                menu.insertItem(item, at: index)
                index += 1
            }
            menu.insertItem(.separator(), at: index)
            return menu
        }

        @objc private func formatMenuItemSelected(_ sender: NSMenuItem) {
            guard let raw = sender.representedObject as? String, let format = MarkdownFormat(rawValue: raw) else { return }
            apply(format)
        }

        // MARK: 検索

        var currentText: String { textView.string }

        func cursorLine() -> Int {
            lineNumber(at: textView.selectedRange().location, in: textView.string as NSString)
        }

        func firstVisibleCharacterIndex() -> Int {
            visibleAnchor()?.index ?? 0
        }

        func showSearch(_ ranges: [NSRange], current: Int) {
            searchRanges = ranges
            searchCurrent = current
            decorate()
            guard ranges.indices.contains(current), NSMaxRange(ranges[current]) <= (textView.string as NSString).length else { return }
            textView.scrollRangeToVisible(ranges[current])
            textView.showFindIndicator(for: ranges[current])
        }

        // MARK: 一時属性（変更ハイライト・全角スペース・検索）

        private func scheduleDecorate(after milliseconds: Int) {
            decorateTask?.cancel()
            decorateTask = Task { [weak self] in
                if milliseconds > 0 { try? await Task.sleep(for: .milliseconds(milliseconds)) }
                guard !Task.isCancelled else { return }
                self?.decorate()
            }
        }

        private func decorate() {
            guard let layoutManager = textView.layoutManager else { return }
            let string = textView.string as NSString
            let all = NSRange(location: 0, length: string.length)
            layoutManager.removeTemporaryAttribute(.backgroundColor, forCharacterRange: all)

            let starts = lineStarts(string)
            func characterRange(of lines: ClosedRange<Int>) -> NSRange? {
                guard lines.lowerBound <= starts.count else { return nil }
                let start = starts[lines.lowerBound - 1]
                let end = lines.upperBound < starts.count ? starts[lines.upperBound] : string.length
                return NSRange(location: start, length: end - start)
            }
            // 未確認の変更は左の余白の線だけ（EditorMarksView）。本文は最新の更新だけ淡く塗る。
            for lines in marks.latest.changed {
                if let range = characterRange(of: lines) {
                    layoutManager.addTemporaryAttribute(.backgroundColor, value: EditorStyle.latestChange, forCharacterRange: range)
                }
            }
            // うっかり入った全角スペースを見えるようにする
            var search = all
            while true {
                let found = string.range(of: "\u{3000}", options: .literal, range: search)
                guard found.location != NSNotFound else { break }
                layoutManager.addTemporaryAttribute(.backgroundColor, value: EditorStyle.fullwidthSpace, forCharacterRange: found)
                search = NSRange(location: NSMaxRange(found), length: string.length - NSMaxRange(found))
            }
            for (index, range) in searchRanges.enumerated() where NSMaxRange(range) <= string.length {
                let color = index == searchCurrent ? EditorStyle.searchCurrent : EditorStyle.searchMatch
                layoutManager.addTemporaryAttribute(.backgroundColor, value: color, forCharacterRange: range)
            }
            marksView.update(
                marks: marks,
                bookmarkIndexes: marks.bookmarks.compactMap { $0 <= starts.count ? starts[$0 - 1] : nil },
                lineStarts: starts
            )
        }

        // MARK: スクロール位置（行番号で同期する）

        func activate(at position: ScrollPosition) {
            scroll(to: position)
            textView.window?.makeFirstResponder(textView)
        }

        /// 変更箇所・見出しへ移動し、行を一瞬強調する。
        func jump(toLine line: Int) {
            scroll(to: ScrollPosition(line: line, endLine: line, ratio: 0))
            // 移動した直後の位置をすぐ知らせる（⌘J を続けて押したかどうかの判定に使う。スクロールしなかった時も）
            if let position = topPosition() { model.updateScrollPosition(position, from: .editor) }
            guard let range = characterRange(ofLine: line) else { return }
            textView.setSelectedRange(NSRange(location: range.location, length: 0))
            textView.showFindIndicator(for: range)
        }

        /// 戻る・進む：保存しておいた位置を画面上部に出し、すぐ知らせる。
        func show(_ position: ScrollPosition) {
            scroll(to: position)
            if let top = topPosition() { model.updateScrollPosition(top, from: .editor) }
        }

        /// 位置（開始行・終了行・その範囲内の割合）の場所が画面上部に来るようにスクロールする。
        private func scroll(to position: ScrollPosition) {
            guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
            let span = Double(max(1, position.endLine - position.line + 1))
            let exact = Double(position.line) + position.ratio * span
            let line = max(1, Int(exact))
            guard let range = characterRange(ofLine: line) else {
                textView.scrollToEndOfDocument(nil)
                return
            }
            layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: NSMaxRange(range)))
            let glyphs = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
            let y = rect.minY + rect.height * (exact - Double(line)) + textView.textContainerInset.height - Self.topMargin
            textView.scroll(NSPoint(x: 0, y: max(0, y)))
        }

        /// 「画面上部」とみなす位置（表示領域の上端から）。scroll(to:) と topPosition() で同じ値を使い、切り替えのたびにずれないようにする。
        private static let topMargin: CGFloat = 8

        /// 画面上部に見えている行と、その行（折り返しを含む）の中での割合。
        func topPosition() -> ScrollPosition? {
            guard let layoutManager = textView.layoutManager, let container = textView.textContainer,
                  !textView.string.isEmpty else { return nil }
            let string = textView.string as NSString
            let top = scrollView.contentView.bounds.minY + Self.topMargin - textView.textContainerInset.height
            let glyph = layoutManager.glyphIndex(for: NSPoint(x: 0, y: max(0, top)), in: container)
            let index = layoutManager.characterIndexForGlyph(at: glyph)
            let line = lineNumber(at: index, in: string)
            let lineRange = string.lineRange(for: NSRange(location: min(index, string.length), length: 0))
            let glyphs = layoutManager.glyphRange(forCharacterRange: lineRange, actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: glyphs, in: container)
            let ratio = rect.height > 0 ? min(1, max(0, (top - rect.minY) / rect.height)) : 0
            return ScrollPosition(line: line, endLine: line, ratio: ratio)
        }

        /// スクロール中も 80ms ごとに通知する（止まるまで待つと見出し一覧の追従が遅れる）。
        @objc private func boundsDidChange() {
            guard scrollReportTask == nil else { return }
            scrollReportTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(80))
                guard let self, !Task.isCancelled else { return }
                self.scrollReportTask = nil
                if let position = self.topPosition() {
                    self.model.updateScrollPosition(position, from: .editor)
                }
            }
        }

        /// 画面上部にある文字の位置と、その文字が画面上部から何 pt 下にあるか。
        private func visibleAnchor() -> (index: Int, offset: CGFloat)? {
            guard let layoutManager = textView.layoutManager, let container = textView.textContainer,
                  textView.string.isEmpty == false else { return nil }
            let visible = scrollView.contentView.bounds
            let point = NSPoint(x: 0, y: max(0, visible.minY - textView.textContainerInset.height))
            let glyph = layoutManager.glyphIndex(for: point, in: container)
            let index = layoutManager.characterIndexForGlyph(at: glyph)
            let rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            return (index, rect.minY + textView.textContainerInset.height - visible.minY)
        }

        private func restoreAnchor(index: Int, offset: CGFloat) {
            guard let layoutManager = textView.layoutManager else { return }
            let length = (textView.string as NSString).length
            guard length > 0 else { return }
            let clamped = min(index, length - 1)
            layoutManager.ensureLayout(forCharacterRange: NSRange(location: 0, length: clamped + 1))
            let glyph = layoutManager.glyphIndexForCharacter(at: clamped)
            let rect = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            textView.scroll(NSPoint(x: 0, y: max(0, rect.minY + textView.textContainerInset.height - offset)))
        }

        private func characterRange(ofLine line: Int) -> NSRange? {
            let string = textView.string as NSString
            let starts = lineStarts(string)
            guard line >= 1, line <= starts.count else { return nil }
            return string.lineRange(for: NSRange(location: starts[line - 1], length: 0))
        }

        private func lineStarts(_ string: NSString) -> [Int] {
            EditorMarksView.lineStarts(string)
        }

        private func lineNumber(at index: Int, in string: NSString) -> Int {
            var line = 1
            var search = NSRange(location: 0, length: min(index, string.length))
            while true {
                let found = string.range(of: "\n", options: .literal, range: search)
                guard found.location != NSNotFound else { break }
                line += 1
                search = NSRange(location: NSMaxRange(found), length: search.upperBound - NSMaxRange(found))
            }
            return line
        }
    }
}

/// エディタの本文に重ねて、行番号・付箋・変更の線・削除の印（赤線・三角・行数）を描く層。
/// NSTextView 自身の draw では文字の領域の外が切り取られるため、子ビューにする。クリックは素通しし、
/// 変更の線・削除の三角と行数にマウスを載せたときだけ、変更前の内容（削除された行）を吹き出しで見せる。
/// 印の位置はレイアウトから求めるので、描く範囲（見えている範囲）の分だけ調べる。
final class EditorMarksView: NSView {
    weak var textView: NSTextView?
    var showsLineNumbers = false {
        didSet { needsDisplay = true }
    }
    /// 付箋のある行の先頭の文字位置
    private var bookmarkIndexes: [Int] = []
    private var marks = PreviewMarks()
    /// 各行の先頭の文字位置
    private var lineStarts: [Int] = [0]
    /// lineStarts を作った時の本文の長さ
    private var lineStartsLength = 0
    private var popover: NSPopover?
    private var shownKey: MarkKey?
    private var watchTask: Task<Void, Never>?
    /// 文字単位の差分を計算している間の印（マウスを動かすたびに計算し直さないように）
    private var pendingKey: MarkKey?
    private var inlineTask: Task<Void, Never>?

    private enum Mark {
        case bar(rect: NSRect, latest: Bool, lines: ClosedRange<Int>)
        /// y は赤線の中心
        case deletion(y: CGFloat, line: Int, count: Int)
    }

    private struct MarkKey: Equatable {
        let deletion: Bool
        let line: Int
    }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsDisplay = true  // 幅が変わると折り返しが変わり、印の位置も変わる
    }

    func update(marks: PreviewMarks, bookmarkIndexes: [Int], lineStarts: [Int]) {
        self.marks = marks
        self.bookmarkIndexes = bookmarkIndexes
        setLineStarts(lineStarts)
    }

    func setLineStarts(_ lineStarts: [Int]) {
        self.lineStarts = lineStarts
        lineStartsLength = (textView?.string as NSString?)?.length ?? 0
        needsDisplay = true
    }

    static func lineStarts(_ string: NSString) -> [Int] {
        var starts = [0]
        var search = NSRange(location: 0, length: string.length)
        while true {
            let found = string.range(of: "\n", options: .literal, range: search)
            guard found.location != NSNotFound else { break }
            starts.append(NSMaxRange(found))
            search = NSRange(location: NSMaxRange(found), length: string.length - NSMaxRange(found))
        }
        return starts
    }

    // MARK: 描画

    override func draw(_ dirtyRect: NSRect) {
        guard let textView else { return }
        let textLeft = textView.textContainerOrigin.x + (textView.textContainer?.lineFragmentPadding ?? 0)

        if showsLineNumbers { drawLineNumbers(in: dirtyRect, right: textLeft - EditorStyle.lineNumberRight) }

        EditorStyle.bookmark.setFill()
        for index in bookmarkIndexes {
            // 本文の左端（文字の開始位置）から 13pt 離して置く
            let mark = NSRect(x: textLeft - 22, y: textMiddle(at: index) - 6.5, width: 9, height: 13)
            guard mark.intersects(dirtyRect) else { continue }
            EditorStyle.bookmarkPath(in: mark).fill()
        }

        let textRight = textRightEdge(textView)
        for mark in changeMarks(in: dirtyRect) {
            switch mark {
            case .bar(let rect, let latest, _):
                (latest ? EditorStyle.latestBar : EditorStyle.changedBar).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 1, yRadius: 1).fill()
            case .deletion(let y, _, let count):
                EditorStyle.deletionLine.setFill()
                NSRect(x: textLeft, y: y - 1, width: textRight - textLeft, height: 2).fill()
                EditorStyle.deletion.setFill()
                let triangle = NSBezierPath()
                triangle.move(to: NSPoint(x: textLeft - 9, y: y - 4))
                triangle.line(to: NSPoint(x: textLeft - 3, y: y))
                triangle.line(to: NSPoint(x: textLeft - 9, y: y + 4))
                triangle.close()
                triangle.fill()
                drawCountBadge(count, at: badgeRect(count, y: y, textRight: textRight))
            }
        }
    }

    /// rect の高さにある行の番号を、付箋の印の左に右寄せで描く。
    private func drawLineNumbers(in rect: NSRect, right: CGFloat) {
        let ascender = NSFont.monospacedDigitSystemFont(ofSize: EditorStyle.lineNumberFontSize, weight: .regular).ascender
        for (line, baseline) in lineNumberBaselines(in: rect) {
            let text = NSAttributedString(string: "\(line)", attributes: EditorStyle.lineNumberAttributes)
            text.draw(at: NSPoint(x: right - text.size().width, y: baseline - ascender))
        }
    }

    /// 文字位置の行の基準線（ビューの座標）とその文字のフォント。
    /// 行の高さの倍率の分の余白は文字の上に入るので、印は行の矩形ではなく文字の位置にそろえる（行の中央だと文字より上に寄る）。
    private func textLine(at index: Int) -> (baseline: CGFloat, font: NSFont) {
        guard let textView, let layoutManager = textView.layoutManager, let storage = textView.textStorage else {
            return (0, EditorStyle.bodyFont)
        }
        let originY = textView.textContainerOrigin.y
        guard index < storage.length else {
            let extra = layoutManager.extraLineFragmentRect
            if extra.isEmpty && storage.length > 0 { return textLine(at: storage.length - 1) }
            return (extra.minY + EditorStyle.lastLineBaseline + originY, EditorStyle.bodyFont)
        }
        let glyph = layoutManager.glyphIndexForCharacter(at: index)
        let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
        let font = storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont ?? EditorStyle.bodyFont
        return (fragment.minY + layoutManager.location(forGlyphAt: glyph).y + originY, font)
    }

    /// 文字位置の行の文字の上端（ビューの座標）
    func textTop(at index: Int) -> CGFloat {
        let line = textLine(at: index)
        return line.baseline - line.font.ascender
    }

    /// 文字位置の行の文字の高さの中央（ビューの座標）
    func textMiddle(at index: Int) -> CGFloat {
        let line = textLine(at: index)
        return line.baseline - (line.font.ascender + line.font.descender) / 2
    }

    /// rect の高さにある行の番号と基準線の高さ（ビューの座標。折り返した行は1段目だけ）
    func lineNumberBaselines(in rect: NSRect) -> [(line: Int, baseline: CGFloat)] {
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer else { return [] }
        let string = textView.string as NSString
        let length = string.length
        // IME の変換中は textDidChange が来ないことがある。古い位置のままだと、変換している行より下の番号が1行上にずれる。
        if length != lineStartsLength {
            lineStarts = Self.lineStarts(string)
            lineStartsLength = length
        }
        let origin = textView.textContainerOrigin
        let area = NSRect(x: 0, y: rect.minY - origin.y, width: container.size.width, height: rect.height)
        let visible = layoutManager.characterRange(
            forGlyphRange: layoutManager.glyphRange(forBoundingRect: area, in: container), actualGlyphRange: nil
        )
        // 見えている最初の文字を含む行を二分探索する
        var lo = 0, hi = lineStarts.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if lineStarts[mid] <= visible.location { lo = mid } else { hi = mid - 1 }
        }
        var result: [(line: Int, baseline: CGFloat)] = []
        for line in lo..<lineStarts.count {
            let start = lineStarts[line]
            guard start <= NSMaxRange(visible), start <= length else { break }
            guard start < length || !layoutManager.extraLineFragmentRect.isEmpty else { continue }
            result.append((line + 1, textLine(at: start).baseline))
        }
        return result
    }

    /// 削除した行数の丸い印。「−」は文字だと高さがずれるので、印の中心（＝赤線の中心）に図形で描く。
    private func drawCountBadge(_ count: Int, at rect: NSRect) {
        EditorStyle.deletion.setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        NSColor.white.setFill()
        NSBezierPath(roundedRect: NSRect(x: rect.minX + 5, y: rect.midY - 1, width: 6, height: 2), xRadius: 1, yRadius: 1).fill()
        let text = NSAttributedString(string: "\(count)", attributes: EditorStyle.badgeAttributes)
        let size = text.size()
        // 数字は下に寄って見えるので 1pt 上げ、「−」と高さをそろえる
        text.draw(at: NSPoint(x: rect.minX + 13, y: rect.midY - size.height / 2 - 1))
    }

    private func badgeRect(_ count: Int, y: CGFloat, textRight: CGFloat) -> NSRect {
        let width = max(18, 13 + NSAttributedString(string: "\(count)", attributes: EditorStyle.badgeAttributes).size().width + 5)
        let x = min(textRight + 6, bounds.width - width - 2)
        return NSRect(x: x, y: y - 8, width: width, height: 16)
    }

    private func textRightEdge(_ textView: NSTextView) -> CGFloat {
        guard let container = textView.textContainer else { return bounds.width }
        return textView.textContainerOrigin.x + container.size.width - container.lineFragmentPadding
    }

    /// rect の高さにある変更の線と削除の印。線は rect の範囲に切り詰める（長い変更でも見える分だけレイアウトする）。
    private func changeMarks(in rect: NSRect) -> [Mark] {
        guard let textView, let layoutManager = textView.layoutManager, let container = textView.textContainer,
              !marks.changes.isEmpty || !marks.latest.isEmpty else { return [] }
        let string = textView.string as NSString
        let origin = textView.textContainerOrigin
        let textLeft = origin.x + container.lineFragmentPadding
        let area = rect.offsetBy(dx: -origin.x, dy: -origin.y).insetBy(dx: 0, dy: -24)
        let glyphs = layoutManager.glyphRange(forBoundingRect: NSRect(x: 0, y: area.minY, width: container.size.width, height: area.height), in: container)
        let visible = layoutManager.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
        let visibleEnd = NSMaxRange(visible)

        func characterRange(_ lines: ClosedRange<Int>) -> NSRange? {
            guard lines.lowerBound <= lineStarts.count else { return nil }
            let start = lineStarts[lines.lowerBound - 1]
            let end = lines.upperBound < lineStarts.count ? lineStarts[lines.upperBound] - 1 : string.length
            return NSRange(location: start, length: max(0, end - start))
        }
        /// 文字位置の行の矩形（ビューの座標）
        func lineRect(at index: Int) -> NSRect {
            let fragment = index < string.length
                ? layoutManager.lineFragmentRect(forGlyphAt: layoutManager.glyphIndexForCharacter(at: index), effectiveRange: nil)
                : layoutManager.extraLineFragmentRect.isEmpty
                    ? layoutManager.lineFragmentRect(forGlyphAt: max(0, layoutManager.numberOfGlyphs - 1), effectiveRange: nil)
                    : layoutManager.extraLineFragmentRect
            return fragment.offsetBy(dx: origin.x, dy: origin.y)
        }

        var result: [Mark] = []
        for (changes, latest) in [(marks.changes, false), (marks.latest, true)] {
            for lines in changes.changed {
                guard let range = characterRange(lines),
                      range.location <= visibleEnd, NSMaxRange(range) >= visible.location else { continue }
                // 見えている範囲の中の最初と最後の文字（空行は改行の位置）
                let first = max(range.location, visible.location)
                let last = max(first, min(NSMaxRange(range), visibleEnd) - 1)
                let top = textTop(at: first), bottom = lineRect(at: last).maxY
                let bar = NSRect(x: textLeft - 9, y: top, width: 3, height: max(2, bottom - top - 1))
                result.append(.bar(rect: bar, latest: latest, lines: lines))
            }
        }
        for line in marks.changes.deletedBefore {
            let atEnd = line > lineStarts.count
            let index = atEnd ? string.length : lineStarts[line - 1]
            guard index >= visible.location - 1, index <= visibleEnd + 1 else { continue }
            // 赤線（2px）は上の行の文字と下の行の文字の間の余白の中央に、末尾の削除は最後の行の下端の下に引く
            let y = atEnd ? lineRect(at: max(0, string.length - 1)).maxY + 1 : (lineRect(at: index).minY + textTop(at: index)) / 2
            result.append(.deletion(y: y, line: line, count: marks.changes.removed[line]?.lineCount ?? 0))
        }
        return result
    }

    // MARK: 吹き出し

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self))
    }

    override func mouseMoved(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let (key, anchor) = hit(at: point), key != shownKey, key != pendingKey else { return }
        showPopover(for: key, anchor: anchor)
    }

    /// 変更の線（左右 5pt の当たり判定）・削除の三角・行数の印の上なら、その印と吹き出しの基準の矩形。
    private func hit(at point: NSPoint) -> (MarkKey, NSRect)? {
        guard let textView else { return nil }
        let textLeft = textView.textContainerOrigin.x + (textView.textContainer?.lineFragmentPadding ?? 0)
        let textRight = textRightEdge(textView)
        // 最新の更新の線は未確認の変更の線の上に描くので、先に調べる
        for mark in changeMarks(in: NSRect(x: 0, y: point.y - 1, width: bounds.width, height: 2)).reversed() {
            switch mark {
            case .bar(let rect, _, let lines):
                if rect.insetBy(dx: -5, dy: 0).contains(point) {
                    return (MarkKey(deletion: false, line: lines.lowerBound), NSRect(x: rect.minX, y: point.y, width: rect.width, height: 1))
                }
            case .deletion(let y, let line, let count):
                let triangle = NSRect(x: textLeft - 13, y: y - 8, width: 14, height: 16)
                let badge = badgeRect(count, y: y, textRight: textRight).insetBy(dx: -2, dy: -2)
                if triangle.contains(point) || badge.contains(point) {
                    return (MarkKey(deletion: true, line: line), triangle.contains(point) ? triangle : badge)
                }
            }
        }
        return nil
    }

    private func showPopover(for key: MarkKey, anchor: NSRect) {
        let removed = marks.changes.removed
        if key.deletion {
            let entry = removed[key.line]
            present(RemovedLinesView(title: "削除された \(entry?.lineCount ?? 0)行", text: entry?.text), for: key, anchor: anchor)
            return
        }
        let lines = marks.changes.changed.first { $0.lowerBound == key.line }
            ?? marks.latest.changed.first { $0.lowerBound == key.line } ?? key.line...key.line
        let deleted = Set(marks.changes.deletedBefore)
        let entries = removed.filter { lines.contains($0.key) && !deleted.contains($0.key) }.sorted { $0.key < $1.key }.map(\.value)
        if entries.isEmpty {
            present(RemovedLinesView(title: "追加された行（変更前の内容はありません）"), for: key, anchor: anchor)
            return
        }
        // 書き換えは文字単位の差分をメインスレッドの外で計算してから出す
        pendingKey = key
        inlineTask?.cancel()
        inlineTask = Task { [weak self] in
            let diffs = await Task.detached { entries.map(\.inlineDiff) }.value
            guard let self, !Task.isCancelled else { return }
            // 計算の間にマウスが離れたり印が変わったりしたら出さない
            guard self.isMouseOver(key), self.marks.changes.removed == removed else {
                self.pendingKey = nil
                return
            }
            let rewrites = zip(entries, diffs).map { RemovedLinesView.Rewrite(text: $0.text, inline: $1) }
            self.present(RemovedLinesView(rewrites: rewrites), for: key, anchor: anchor)
        }
    }

    private func isMouseOver(_ key: MarkKey?) -> Bool {
        guard let key, let window, !isHiddenOrHasHiddenAncestor else { return false }
        return hit(at: convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil))?.0 == key
    }

    private func present(_ content: RemovedLinesView, for key: MarkKey, anchor: NSRect) {
        popover?.close()
        pendingKey = nil
        let host = NSHostingController(rootView: content)
        host.sizingOptions = [.preferredContentSize]
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.animates = false
        popover.contentViewController = host
        popover.show(relativeTo: anchor, of: self, preferredEdge: .maxY)
        self.popover = popover
        shownKey = key
        watchMouse()
    }

    /// 吹き出しの中の文字を選べるよう、マウスが印か吹き出しの上にある間は出しておく。
    private func watchMouse() {
        watchTask?.cancel()
        watchTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, let popover = self.popover, popover.isShown else { return }
                if popover.contentViewController?.view.window?.frame.contains(NSEvent.mouseLocation) == true { continue }
                if self.isMouseOver(self.shownKey) { continue }
                // 次の印の吹き出しを計算している途中かもしれないので、それは止めない
                self.closeShownPopover()
                return
            }
        }
    }

    private func closeShownPopover() {
        watchTask?.cancel()
        popover?.close()
        popover = nil
        shownKey = nil
    }

    func closePopover() {
        inlineTask?.cancel()
        pendingKey = nil
        closeShownPopover()
    }
}

/// エディタの吹き出しの中身（変更前の内容・削除された行）。長いときはスクロールする。
private struct RemovedLinesView: View {
    struct Rewrite {
        let text: String
        let inline: InlineDiff?
    }

    /// 削除と追加の見出し（書き換えには無い）
    var title: String?
    /// 削除された行
    var text: String?
    var rewrites: [Rewrite] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title { heading(title) }
            if let text { block(AttributedString(text), bar: .systemRed) }
            // かたまりごとに変更前と変更後を並べ、組の間に線を引く
            ForEach(Array(rewrites.enumerated()), id: \.offset) { index, rewrite in
                if index > 0 { Divider().padding(.vertical, 4) }
                heading("変更前")
                if let inline = rewrite.inline {
                    block(attributed(inline.old, color: .systemRed.withAlphaComponent(0.35)), bar: .systemOrange)
                    heading("変更後").padding(.top, 4)
                    block(attributed(inline.new, color: .systemOrange.withAlphaComponent(0.45)), bar: .systemOrange)
                } else {
                    Text("変更が大きいため、文字ごとには比べていません")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    block(AttributedString(rewrite.text), bar: .systemOrange)
                }
            }
        }
        .padding(10)
        .frame(width: 380, alignment: .leading)
        // 既定の透けた背景だと後ろの本文の文字が重なって読みにくく、本文と同じ白だと境目が無くなるので、不透明の淡い灰色にする
        .background(Color(nsColor: .underPageBackgroundColor))
    }

    private func heading(_ text: String) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
    }

    private func attributed(_ segments: [InlineDiff.Segment], color: NSColor) -> AttributedString {
        segments.reduce(into: AttributedString()) { result, segment in
            var part = AttributedString(segment.text)
            if segment.changed { part.backgroundColor = Color(nsColor: color) }
            result += part
        }
    }

    @ViewBuilder private func block(_ content: AttributedString, bar: NSColor) -> some View {
        let plain = String(content.characters)
        let body = Text(content)
            .font(.system(size: 13))
            .foregroundStyle(Color(nsColor: .textColor))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, 8)
            .overlay(alignment: .leading) {
                Rectangle().fill(Color(nsColor: bar)).frame(width: 3)
            }
        if plain.count > 600 || plain.split(separator: "\n", omittingEmptySubsequences: false).count > 16 {
            ScrollView { body }.frame(height: 280)
        } else {
            body
        }
    }
}

// MARK: - 見た目

@MainActor
enum EditorStyle {
    static let fontSize: CGFloat = 14
    static let bodyFont = NSFont.systemFont(ofSize: fontSize)
    static let monoFont = NSFont.monospacedSystemFont(ofSize: fontSize - 1, weight: .regular)
    static let markerColor = NSColor.tertiaryLabelColor
    // 変更の印はプレビューと同じ：左の余白の線（未確認は淡く・最新は濃く）、本文の塗りは最新の更新だけごく淡く
    static let changedBar = NSColor.systemOrange.withAlphaComponent(0.45)
    static let latestBar = NSColor.systemOrange
    static let latestChange = NSColor.systemOrange.withAlphaComponent(0.1)
    static let deletion = NSColor.systemRed
    static let deletionLine = NSColor.systemRed.withAlphaComponent(0.75)
    static let badgeAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 10, weight: .semibold), .foregroundColor: NSColor.white,
    ]
    static let fullwidthSpace = NSColor.systemTeal.withAlphaComponent(0.3)
    static let searchMatch = NSColor.systemYellow.withAlphaComponent(0.45)
    static let searchCurrent = NSColor.systemOrange.withAlphaComponent(0.85)
    static let bookmark = NSColor.controlAccentColor
    static let textInset: CGFloat = 28
    static let textInsetTop: CGFloat = 24
    static let lineNumberFontSize: CGFloat = 11
    static let lineNumberAttributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: lineNumberFontSize, weight: .regular), .foregroundColor: NSColor.tertiaryLabelColor,
    ]
    /// 文字の無い最後の行の基準線（行の上端から）。本文の行と同じ行の高さの倍率で組んだ時の位置。
    static let lastLineBaseline: CGFloat = {
        let layoutManager = NSLayoutManager()
        let storage = NSTextStorage(string: "0", attributes: base)
        let container = NSTextContainer(size: NSSize(width: 100, height: 100))
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)
        return layoutManager.location(forGlyphAt: 0).y
    }()
    /// 行番号の右端から本文の左端までの距離（付箋の印の左）
    static let lineNumberRight: CGFloat = 24

    /// 行番号を出す時の本文の余白（3桁までは同じ幅。文書が伸びても本文の折り返しが変わらないように）
    static func textInset(lineCount: Int) -> CGFloat {
        let digitWidth = ("0" as NSString).size(withAttributes: lineNumberAttributes).width
        // 左端の 8pt ＋番号の幅＋番号から本文までの距離。本文の左端は余白より lineFragmentPadding（5pt）右にある
        return (8 + CGFloat(max(3, String(lineCount).count)) * digitWidth + lineNumberRight - 5).rounded(.up)
    }

    /// 付箋の形（下端に切れ込みのあるしおりのリボン）。座標は上が小さい（反転した座標系）。
    static func bookmarkPath(in rect: NSRect) -> NSBezierPath {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.minY))
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        path.line(to: NSPoint(x: rect.midX, y: rect.maxY - 3.5))
        path.line(to: NSPoint(x: rect.minX, y: rect.maxY))
        path.close()
        return path
    }

    static let paragraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.lineHeightMultiple = 1.3
        return style
    }()

    static let base: [NSAttributedString.Key: Any] = [
        .font: bodyFont, .foregroundColor: NSColor.textColor, .paragraphStyle: paragraphStyle,
    ]

    static func headingFont(level: Int) -> NSFont {
        let sizes: [CGFloat] = [24, 20, 17, 15.5, 14, 14]
        return NSFont.systemFont(ofSize: sizes[min(max(level, 1), 6) - 1], weight: .bold)
    }
}

/// 記号を残したまま、見出し・太字・コード・表の行などに文字属性を付ける（ライブスタイリング）。
@MainActor
enum MarkdownStyler {
    private static let heading = try! NSRegularExpression(pattern: "^(#{1,6})[ \\t\\u3000]")
    private static let listMarker = try! NSRegularExpression(pattern: "^[ \\t]*(?:[-*+]|\\d{1,9}[.)])(?=[ \\t\\u3000])")
    private static let quote = try! NSRegularExpression(pattern: "^[ \\t]{0,3}>")
    private static let bold = try! NSRegularExpression(pattern: "\\*\\*(?=\\S)(.+?)(?<=\\S)\\*\\*")
    private static let code = try! NSRegularExpression(pattern: "`[^`\\n]+`")

    static func containsFence(_ text: String) -> Bool {
        text.contains("```") || text.contains("~~~")
    }

    /// range を含む行を整形する。コードフェンスの内側かどうかは、range より前の行を走査して求める。
    static func style(_ storage: NSTextStorage, in range: NSRange) {
        let string = storage.string as NSString
        let lines = string.lineRange(for: range)
        var openFence = fenceState(string, before: lines.location)
        let frontMatter = frontMatterEnd(string)
        storage.beginEditing()
        string.enumerateSubstrings(in: lines, options: .byLines) { line, lineRange, enclosingRange, _ in
            guard let line else { return }
            storage.setAttributes(EditorStyle.base, range: enclosingRange)
            if lineRange.location < frontMatter {
                let isDelimiter = line.hasPrefix("---") || line.hasPrefix("...")
                storage.addAttributes([
                    .font: EditorStyle.monoFont,
                    .foregroundColor: isDelimiter ? EditorStyle.markerColor : NSColor.secondaryLabelColor,
                ], range: lineRange)
            } else if let fence = fenceCharacter(line) {
                storage.addAttributes([.font: EditorStyle.monoFont, .foregroundColor: EditorStyle.markerColor], range: lineRange)
                if openFence == nil { openFence = fence } else if openFence == fence { openFence = nil }
            } else if openFence != nil {
                storage.addAttribute(.font, value: EditorStyle.monoFont, range: lineRange)
            } else {
                styleLine(storage, line: line, at: lineRange.location)
            }
        }
        storage.endEditing()
    }

    private static func styleLine(_ storage: NSTextStorage, line: String, at offset: Int) {
        let length = (line as NSString).length
        let whole = NSRange(location: 0, length: length)
        func global(_ range: NSRange) -> NSRange { NSRange(location: range.location + offset, length: range.length) }

        if let match = heading.firstMatch(in: line, range: whole) {
            let level = match.range(at: 1).length
            storage.addAttribute(.font, value: EditorStyle.headingFont(level: level), range: global(whole))
            storage.addAttribute(.foregroundColor, value: EditorStyle.markerColor, range: global(match.range(at: 1)))
            return
        }
        if line.drop(while: { $0 == " " || $0 == "\t" }).hasPrefix("|") {
            storage.addAttribute(.font, value: EditorStyle.monoFont, range: global(whole))
        }
        if let match = quote.firstMatch(in: line, range: whole) {
            storage.addAttribute(.foregroundColor, value: NSColor.secondaryLabelColor, range: global(whole))
            storage.addAttribute(.foregroundColor, value: EditorStyle.markerColor, range: global(match.range))
        }
        if let match = listMarker.firstMatch(in: line, range: whole) {
            storage.addAttribute(.foregroundColor, value: NSColor.controlAccentColor, range: global(match.range))
        }
        for match in bold.matches(in: line, range: whole) {
            let range = global(match.range)
            let font = storage.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont ?? EditorStyle.bodyFont
            storage.addAttribute(.font, value: NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask), range: range)
            storage.addAttribute(.foregroundColor, value: EditorStyle.markerColor, range: NSRange(location: range.location, length: 2))
            storage.addAttribute(.foregroundColor, value: EditorStyle.markerColor, range: NSRange(location: NSMaxRange(range) - 2, length: 2))
        }
        for match in code.matches(in: line, range: whole) {
            let range = global(match.range)
            storage.addAttribute(.font, value: EditorStyle.monoFont, range: range)
            storage.addAttribute(.foregroundColor, value: EditorStyle.markerColor, range: NSRange(location: range.location, length: 1))
            storage.addAttribute(.foregroundColor, value: EditorStyle.markerColor, range: NSRange(location: NSMaxRange(range) - 1, length: 1))
        }
    }

    /// 先頭の YAML フロントマターの終わり（UTF-16 の位置）。無ければ 0。
    /// 範囲が変わったら後ろの行の解釈も変わるので、呼び出し側は全体を整形し直す。
    static func frontMatterEnd(_ string: NSString) -> Int {
        guard string.hasPrefix("---"), let count = Markdown.frontMatterLineCount(string as String) else { return 0 }
        var end = 0
        for _ in 0..<count { end = NSMaxRange(string.lineRange(for: NSRange(location: end, length: 0))) }
        return end
    }

    private static func fenceCharacter(_ line: String) -> Character? {
        let body = line.drop { $0 == " " || $0 == "\t" || $0 == ">" }
        if body.hasPrefix("```") { return "`" }
        if body.hasPrefix("~~~") { return "~" }
        return nil
    }

    private static func fenceState(_ string: NSString, before location: Int) -> Character? {
        var open: Character?
        guard location > 0 else { return nil }
        string.enumerateSubstrings(in: NSRange(location: 0, length: location), options: .byLines) { line, _, _, _ in
            guard let line, let fence = fenceCharacter(line) else { return }
            if open == nil { open = fence } else if open == fence { open = nil }
        }
        return open
    }
}
