import AppKit
import Foundation
import Testing
@testable import MDYomitoki

@MainActor
struct EditorLineNumberTests {
    /// 「一行目\n二行目\n三行目\n」を入れたエディタで、行番号を出した状態にして渡す。
    /// 履歴などの保存データに触らないよう、ファイルは読まずに本文を直接入れる。
    private func withEditor(_ body: (NSTextView, EditorMarksView) throws -> Void) throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        let coordinator = EditorView.Coordinator(model: DocumentModel(url: url))
        defer { coordinator.tearDown() }
        let textView = coordinator.textView
        textView.setFrameSize(NSSize(width: 600, height: 400))
        textView.textStorage?.setAttributedString(NSAttributedString(string: "一行目\n二行目\n三行目\n", attributes: EditorStyle.base))
        coordinator.setLineNumbers(true)
        let marks = try #require(textView.subviews.compactMap { $0 as? EditorMarksView }.first)
        try body(textView, marks)
    }

    /// 文字位置の行の基準線（ビューの座標）
    private func baseline(at index: Int, in textView: NSTextView) throws -> CGFloat {
        let layoutManager = try #require(textView.layoutManager)
        let glyph = layoutManager.glyphIndexForCharacter(at: index)
        return layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil).minY
            + layoutManager.location(forGlyphAt: glyph).y + textView.textContainerOrigin.y
    }

    @Test func numbersStayOnTheirLinesWhileTyping() throws {
        try withEditor { textView, marks in
            textView.setSelectedRange(NSRange(location: 3, length: 0))
            textView.insertText("追加", replacementRange: NSRange(location: 3, length: 0))
            let numbers = marks.lineNumberBaselines(in: textView.bounds)
            let secondLine = try baseline(at: 6, in: textView)
            #expect(numbers.prefix(3).map(\.line) == [1, 2, 3])
            #expect(numbers[1].baseline == secondLine)
        }
    }

    /// IME の変換中は本文の文字が増えるので、古い行の先頭の位置のままだと下の行の番号が1行上にずれる。
    @Test func numbersStayOnTheirLinesDuringMarkedText() throws {
        try withEditor { textView, marks in
            textView.setSelectedRange(NSRange(location: 3, length: 0))
            textView.setMarkedText(
                "へんかん", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0)
            )
            #expect(textView.hasMarkedText())
            let numbers = marks.lineNumberBaselines(in: textView.bounds)
            // 「一行目へんかん\n」の次の文字が2行目の先頭
            let secondLine = try baseline(at: 8, in: textView)
            #expect(numbers.prefix(3).map(\.line) == [1, 2, 3])
            #expect(numbers[1].baseline == secondLine)
        }
    }

    /// 行の高さの倍率の分の余白は文字の上に入るので、印を置く文字の中央は行の矩形の中央より下になる。
    @Test func marksAlignWithTheTextNotTheLineFragment() throws {
        try withEditor { textView, marks in
            let layoutManager = try #require(textView.layoutManager)
            let glyph = layoutManager.glyphIndexForCharacter(at: 4)
            let fragment = layoutManager.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
                .offsetBy(dx: 0, dy: textView.textContainerOrigin.y)
            #expect(marks.textTop(at: 4) > fragment.minY)
            #expect(marks.textMiddle(at: 4) > fragment.midY)
            #expect(marks.textMiddle(at: 4) < fragment.maxY)
            // 文字の無い最後の行も本文の行と同じ位置
            let lastLine = (textView.string as NSString).length
            let offset = marks.textTop(at: 4) - fragment.minY
            let extra = layoutManager.extraLineFragmentRect.offsetBy(dx: 0, dy: textView.textContainerOrigin.y)
            #expect(abs((marks.textTop(at: lastLine) - extra.minY) - offset) < 0.5)
        }
    }

    @Test func emptyLastLineGetsANumberOnTheBodyBaseline() throws {
        try withEditor { textView, marks in
            let numbers = marks.lineNumberBaselines(in: textView.bounds)
            #expect(numbers.map(\.line) == [1, 2, 3, 4])
            // 行の高さは同じなので、番号の間隔もそろう
            #expect(abs((numbers[3].baseline - numbers[2].baseline) - (numbers[2].baseline - numbers[1].baseline)) < 0.5)
        }
    }
}
