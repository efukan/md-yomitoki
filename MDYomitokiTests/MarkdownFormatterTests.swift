import Foundation
import Testing
@testable import MDYomitoki

struct MarkdownFormatterTests {
    /// 書式を適用した結果の全文と、選択範囲の文字列。
    private func apply(_ format: MarkdownFormat, _ text: String, _ selection: NSRange) -> (text: String, selected: String) {
        let edit = MarkdownFormatter.edit(format, in: text, selection: selection)
        let result = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        return (result, (result as NSString).substring(with: edit.selection))
    }

    private func range(of part: String, in text: String) -> NSRange {
        (text as NSString).range(of: part)
    }

    @Test func boldWrapsAndUnwraps() {
        let text = "これは重要な点"
        let wrapped = apply(.bold, text, range(of: "重要", in: text))
        #expect(wrapped.text == "これは**重要**な点")
        #expect(wrapped.selected == "重要")
        let unwrapped = apply(.bold, wrapped.text, range(of: "重要", in: wrapped.text))
        #expect(unwrapped.text == text)
    }

    @Test func boldWithoutSelectionPutsCaretBetweenMarkers() {
        let edit = MarkdownFormatter.edit(.bold, in: "あいう", selection: NSRange(location: 1, length: 0))
        #expect(edit.replacement == "****")
        #expect(edit.selection == NSRange(location: 3, length: 0))
    }

    @Test func italicDoesNotUnwrapBold() {
        let text = "**重要**"
        let result = apply(.italic, text, range(of: "重要", in: text))
        #expect(result.text == "***重要***")
    }

    @Test func headingTogglesAndChangesLevel() {
        let h2 = apply(.heading2, "見出しにする", NSRange(location: 2, length: 0))
        #expect(h2.text == "## 見出しにする")
        #expect(apply(.heading1, h2.text, NSRange(location: 4, length: 0)).text == "# 見出しにする")
        #expect(apply(.heading2, h2.text, NSRange(location: 4, length: 0)).text == "見出しにする")
        #expect(apply(.body, "###　全角", NSRange(location: 4, length: 0)).text == "全角")
    }

    @Test func headingOnlyTouchesCurrentLine() {
        let text = "一行目\n二行目\n三行目"
        #expect(apply(.heading1, text, range(of: "二", in: text)).text == "一行目\n# 二行目\n三行目")
    }

    @Test func listsApplyToSelectedLinesAndConvertBetweenKinds() {
        let text = "りんご\n\nみかん\nぶどう\n後"
        let selection = NSRange(location: 0, length: range(of: "ぶどう", in: text).upperBound)
        let bullets = apply(.bulletList, text, selection)
        #expect(bullets.text == "- りんご\n\n- みかん\n- ぶどう\n後")
        let numbered = apply(.numberedList, bullets.text, NSRange(location: 0, length: bullets.selected.utf16.count))
        #expect(numbered.text == "1. りんご\n\n2. みかん\n3. ぶどう\n後")
        let removed = apply(.numberedList, numbered.text, NSRange(location: 0, length: numbered.selected.utf16.count))
        #expect(removed.text == text)
    }

    @Test func wholeLineSelectionIncludingNewlineDoesNotTouchNextLine() {
        let text = "一行目\n二行目"
        #expect(apply(.taskList, text, NSRange(location: 0, length: 4)).text == "- [ ] 一行目\n二行目")
    }

    @Test func quoteTogglesIncludingBlankLines() {
        let quoted = apply(.quote, "段落1\n\n段落2", NSRange(location: 0, length: 8))
        #expect(quoted.text == "> 段落1\n>\n> 段落2")
        #expect(apply(.quote, quoted.text, NSRange(location: 0, length: quoted.selected.utf16.count)).text == "段落1\n\n段落2")
    }

    @Test func codeBlockWrapsLinesOrInsertsEmptyBlock() {
        let wrapped = apply(.codeBlock, "let a = 1\nlet b = 2", NSRange(location: 0, length: 19))
        #expect(wrapped.text == "```\nlet a = 1\nlet b = 2\n```")
        #expect(apply(.codeBlock, wrapped.text, NSRange(location: 0, length: wrapped.selected.utf16.count)).text == "let a = 1\nlet b = 2")
        let empty = MarkdownFormatter.edit(.codeBlock, in: "前\n\n後", selection: NSRange(location: 2, length: 0))
        #expect(empty.replacement == "```\n\n```")
        #expect(empty.selection == NSRange(location: 6, length: 0))
    }

    @Test func linkSelectsUrlPlaceholder() {
        let result = apply(.link, "公式サイト", NSRange(location: 0, length: 5))
        #expect(result.text == "[公式サイト](https://)")
        #expect(result.selected == "https://")
    }

    @Test func tableIsInsertedAfterCurrentLineAndSelectsFirstHeader() {
        let result = apply(.table, "本文", NSRange(location: 1, length: 0))
        #expect(result.text == "本文\n\n| 見出し1 | 見出し2 |\n| --- | --- |\n| 内容 | 内容 |")
        #expect(result.selected == "見出し1")
    }

    @Test func tableGetsBlankLinesBeforeAndAfter() {
        let table = "| 見出し1 | 見出し2 |\n| --- | --- |\n| 内容 | 内容 |"
        #expect(apply(.table, "前\n\n後", NSRange(location: 2, length: 0)).text == "前\n\n\(table)\n\n後")
        #expect(apply(.table, "本文\n次", NSRange(location: 1, length: 0)).text == "本文\n\n\(table)\n\n次")
        #expect(apply(.table, "", NSRange(location: 0, length: 0)).text == table)
    }

    // MARK: 空の行・選択の端の改行・カーソル位置での解除

    @Test func emptyLineGetsMarkerAndCaretAfterIt() {
        for (format, marker) in [(MarkdownFormat.heading1, "# "), (.heading2, "## "), (.bulletList, "- "),
                                 (.numberedList, "1. "), (.taskList, "- [ ] "), (.quote, "> ")] {
            let edit = MarkdownFormatter.edit(format, in: "前\n\n後", selection: NSRange(location: 2, length: 0))
            let result = ("前\n\n後" as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
            #expect(result == "前\n\(marker)\n後")
            #expect(edit.selection == NSRange(location: 2 + (marker as NSString).length, length: 0))
        }
        #expect(apply(.heading1, "", NSRange(location: 0, length: 0)).text == "# ")
    }

    @Test func trailingNewlineAndSpacesStayOutsideMarkers() {
        let text = "重要な行\n次の行"
        let result = apply(.bold, text, NSRange(location: 0, length: 5))  // 「重要な行\n」
        #expect(result.text == "**重要な行**\n次の行")
        #expect(result.selected == "重要な行")
        #expect(apply(.bold, " 重要 ", NSRange(location: 0, length: 4)).text == " **重要** ")
    }

    @Test func multiLineSelectionIsWrappedPerLine() {
        let text = "一行目\n\n二行目"
        let wrapped = apply(.bold, text, NSRange(location: 0, length: (text as NSString).length))
        #expect(wrapped.text == "**一行目**\n\n**二行目**")
        #expect(apply(.bold, wrapped.text, NSRange(location: 0, length: (wrapped.text as NSString).length)).text == text)
    }

    @Test func caretInsideFormattedTextRemovesIt() {
        let text = "これは**重要**な点"
        let edit = MarkdownFormatter.edit(.bold, in: text, selection: NSRange(location: 6, length: 0))  // 「重」と「要」の間
        #expect((text as NSString).replacingCharacters(in: edit.range, with: edit.replacement) == "これは重要な点")
        #expect(edit.selection == NSRange(location: 4, length: 0))
        let code = "a `code` b"
        let codeEdit = MarkdownFormatter.edit(.inlineCode, in: code, selection: NSRange(location: 4, length: 0))
        #expect((code as NSString).replacingCharacters(in: codeEdit.range, with: codeEdit.replacement) == "a code b")
    }

    @Test func pressingAgainRemovesEmptyMarkers() {
        let first = MarkdownFormatter.edit(.bold, in: "あ", selection: NSRange(location: 1, length: 0))
        let inserted = ("あ" as NSString).replacingCharacters(in: first.range, with: first.replacement)
        let second = MarkdownFormatter.edit(.bold, in: inserted, selection: first.selection)
        #expect((inserted as NSString).replacingCharacters(in: second.range, with: second.replacement) == "あ")
    }

    @Test func italicCaretInsideBoldDoesNotUnwrapBold() {
        let text = "**重要**"
        let edit = MarkdownFormatter.edit(.italic, in: text, selection: NSRange(location: 3, length: 0))
        #expect((text as NSString).replacingCharacters(in: edit.range, with: edit.replacement) == text)
    }

    @Test func selectedUrlBecomesLinkTarget() {
        let result = apply(.link, "https://example.com", NSRange(location: 0, length: 19))
        #expect(result.text == "[リンクテキスト](https://example.com)")
        #expect(result.selected == "リンクテキスト")
    }
}

struct TaskToggleTests {
    @Test func togglesCheckboxOnTheGivenLine() {
        let text = "# TODO\n\n- [ ] 未完了\n- [x] 完了\n  - [X] 入れ子"
        #expect(MarkdownFormatter.toggleTask(in: text, line: 3) == "# TODO\n\n- [x] 未完了\n- [x] 完了\n  - [X] 入れ子")
        #expect(MarkdownFormatter.toggleTask(in: text, line: 4) == "# TODO\n\n- [ ] 未完了\n- [ ] 完了\n  - [X] 入れ子")
        #expect(MarkdownFormatter.toggleTask(in: text, line: 5) == "# TODO\n\n- [ ] 未完了\n- [x] 完了\n  - [ ] 入れ子")
    }

    @Test func handlesOrderedQuotedAndFullwidthItems() {
        #expect(MarkdownFormatter.toggleTask(in: "1. [ ] a", line: 1) == "1. [x] a")
        #expect(MarkdownFormatter.toggleTask(in: "> - [ ] a", line: 1) == "> - [x] a")
        #expect(MarkdownFormatter.toggleTask(in: "-\u{3000}[ ] a", line: 1) == "-\u{3000}[x] a")
    }

    @Test func ignoresNonTaskLines() {
        #expect(MarkdownFormatter.toggleTask(in: "- 普通の項目 [ ]", line: 1) == nil)
        #expect(MarkdownFormatter.toggleTask(in: "[ ] 行頭", line: 1) == nil)
        #expect(MarkdownFormatter.toggleTask(in: "- [ ] a", line: 2) == nil)
    }
}
