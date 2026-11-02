import Testing
@testable import MDYomitoki

struct OutlineFoldTests {
    /// 行番号は配列の順に 1, 2, 3…
    private func outline(_ headings: [(Int, String)]) -> [OutlineItem] {
        headings.enumerated().map { OutlineItem(level: $1.0, title: $1.1, line: $0 + 1) }
    }

    private var sample: [OutlineItem] {
        outline([(1, "題"), (2, "背景"), (3, "経緯"), (3, "課題"), (2, "方針"), (1, "付録")])
    }

    private func key(_ fold: OutlineFold, _ title: String) -> String {
        fold.rows(collapsed: []).first { $0.item.title == title }!.key
    }

    @Test func nothingCollapsedShowsEveryHeading() {
        let rows = OutlineFold(sample).rows(collapsed: [])
        #expect(rows.map(\.item.line) == [1, 2, 3, 4, 5, 6])
        #expect(rows.map(\.hasChildren) == [true, true, false, false, false, false])
        #expect(rows.allSatisfy { !$0.isCollapsed && $0.hiddenLines.isEmpty })
    }

    @Test func collapsingHidesDescendantsOnly() {
        let fold = OutlineFold(sample)
        let rows = fold.rows(collapsed: [key(fold, "背景")])
        #expect(rows.map(\.item.title) == ["題", "背景", "方針", "付録"])
        #expect(rows[1].isCollapsed)
        #expect(rows[1].hiddenLines == [3, 4])
    }

    @Test func collapsingParentHidesNestedHeadings() {
        let fold = OutlineFold(sample)
        let rows = fold.rows(collapsed: [key(fold, "題")])
        #expect(rows.map(\.item.title) == ["題", "付録"])
        #expect(rows[0].hiddenLines == [2, 3, 4, 5])
    }

    @Test func skippedLevelsStillCountAsChildren() {
        // 見出し 1 の次が見出し 3、その次が見出し 2 でも、どちらも見出し 1 の子
        let fold = OutlineFold(outline([(1, "題"), (3, "飛んだ"), (2, "戻った")]))
        #expect(fold.rows(collapsed: [])[0].hasChildren)
        #expect(!fold.rows(collapsed: [])[1].hasChildren)
        #expect(fold.rows(collapsed: [key(fold, "題")]).map(\.item.title) == ["題"])
    }

    @Test func keysSurviveLineShifts() {
        // AI が上に行を足して行番号がずれても、同じ見出しが畳まれたまま
        let before = OutlineFold(sample)
        let collapsed: Set = [key(before, "背景")]
        let shifted = sample.map { OutlineItem(level: $0.level, title: $0.title, line: $0.line + 10) }
        let rows = OutlineFold(shifted).rows(collapsed: collapsed)
        #expect(rows.map(\.item.title) == ["題", "背景", "方針", "付録"])
    }

    @Test func renamedHeadingOpensAgain() {
        // 見出しの文字が変わったら開いた状態に戻る（中の変更を隠し続けないように）
        let before = OutlineFold(sample)
        let collapsed: Set = [key(before, "背景")]
        let renamed = OutlineFold(outline([(1, "題"), (2, "背景と経緯"), (3, "経緯"), (3, "課題"), (2, "方針"), (1, "付録")]))
        #expect(renamed.rows(collapsed: collapsed).count == 6)
    }

    @Test func sameTitlesAreKeptApart() {
        // 同じ親の下の同じ名前は順番で、違う親の下の同じ名前は親で区別する
        let fold = OutlineFold(outline([
            (1, "A"), (2, "例"), (3, "x"), (2, "例"), (3, "y"),
            (1, "B"), (2, "例"), (3, "z"),
        ]))
        let keys = fold.rows(collapsed: []).filter { $0.item.title == "例" }.map(\.key)
        #expect(Set(keys).count == 3)
        let rows = fold.rows(collapsed: [keys[1]])
        #expect(rows.map(\.item.title) == ["A", "例", "x", "例", "B", "例", "z"])
    }

    @Test func activeLineFallsBackToNearestVisibleHeading() {
        let fold = OutlineFold(sample)
        let rows = fold.rows(collapsed: [key(fold, "背景")])
        #expect(OutlineFold.visibleLine(of: 4, in: rows) == 2)  // 隠れた「課題」を読んでいる → 親の「背景」
        #expect(OutlineFold.visibleLine(of: 5, in: rows) == 5)  // 見えている見出しはそのまま
        #expect(OutlineFold.visibleLine(of: nil, in: rows) == nil)
    }

    @Test func subtreeKeysIncludeOnlyFoldableHeadings() {
        let fold = OutlineFold(sample)
        #expect(fold.keys(under: key(fold, "題")) == [key(fold, "題"), key(fold, "背景")])
        #expect(fold.keys(under: key(fold, "背景")) == [key(fold, "背景")])
    }

    @Test func foldingByLevel() {
        let fold = OutlineFold(sample)
        #expect(fold.foldableLevels == [1, 2])
        #expect(fold.rows(collapsed: fold.keys(fromLevel: 1)).map(\.item.title) == ["題", "付録"])
        #expect(fold.rows(collapsed: fold.keys(fromLevel: 2)).map(\.item.title) == ["題", "背景", "方針", "付録"])
    }

    @Test func flatOutlineHasNothingToFold() {
        let fold = OutlineFold(outline([(2, "a"), (2, "b")]))
        #expect(fold.foldableLevels.isEmpty)
        #expect(OutlineFold([]).rows(collapsed: []).isEmpty)
    }
}
