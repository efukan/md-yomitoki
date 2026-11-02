import Testing
@testable import MDYomitoki

struct LineDiffTests {
    @Test func identicalTextHasNoChanges() {
        #expect(LineDiff.changes(from: "a\nb", to: "a\nb").isEmpty)
    }

    @Test func modifiedLineIsChangedWithoutDeletionMark() {
        let changes = LineDiff.changes(from: "a\nb\nc", to: "a\nB\nc")
        #expect(changes.changed == [2...2])
        #expect(changes.deletedBefore.isEmpty)
    }

    @Test func consecutiveInsertionsAreMerged() {
        let changes = LineDiff.changes(from: "a\nd", to: "a\nb\nc\nd\ne")
        #expect(changes.changed == [2...3, 5...5])
        #expect(changes.jumpLines == [2, 5])
    }

    @Test func deletionIsMarkedBeforeFollowingLine() {
        let changes = LineDiff.changes(from: "a\nb\nc\nd", to: "a\nd")
        #expect(changes.changed.isEmpty)
        #expect(changes.deletedBefore == [2])
    }

    @Test func deletionAtEndPointsPastLastLine() {
        let changes = LineDiff.changes(from: "a\nb\nc", to: "a")
        #expect(changes.deletedBefore == [2])
    }

    @Test func cumulativeChangesSurviveSuccessiveUpdates() {
        // ベースライン → 1回目の更新 → 2回目の更新。累積は両方、最新は2回目だけ。
        let baseline = "a\nb\nc\nd"
        let first = "a\nB\nc\nd"
        let second = "a\nB\nc\nD"
        #expect(LineDiff.changes(from: baseline, to: second).changed == [2...2, 4...4])
        #expect(LineDiff.changes(from: first, to: second).changed == [4...4])
    }

    @Test func removedLinesAreKeptForDeletionsAndRewrites() {
        let changes = LineDiff.changes(from: "a\nb\nc\nd\ne", to: "a\nB\nd\nf")
        // b,c → B（書き換え）、e → 削除して f を追加（書き換え）
        #expect(changes.changed == [2...2, 4...4])
        #expect(changes.deletedBefore.isEmpty)
        #expect(changes.removed == [2: RemovedLines(["b", "c"], replacement: ["B"]), 4: RemovedLines(["e"], replacement: ["f"])])
        #expect(changes.removed[2]?.text == "b\nc")
        #expect(changes.removed[2]?.lineCount == 2)
    }

    @Test func pureDeletionKeepsTextAtDeletionPoint() {
        let changes = LineDiff.changes(from: "a\nb\nc\nd", to: "a\nd")
        #expect(changes.removed == [2: RemovedLines(["b", "c"])])
        // 行を足しただけの変更には消えた行が無い
        #expect(LineDiff.changes(from: "a\nd", to: "a\nb\nd").removed.isEmpty)
    }

    @Test func deletionsSeparatedOnlyByBlankLinesAreMerged() {
        // 見出しと本文を消すと、間の空行だけが共通の行として残る → 削除は1つ
        let old = "## A\n\n本文A\n\n## B\n\n本文B\n\n## C"
        let changes = LineDiff.changes(from: old, to: "## A\n\n本文A\n\n## C")
        #expect(changes.deletedBefore.count == 1)
        #expect(changes.removed.count == 1)
        #expect(changes.removed.values.first?.text.contains("## B") == true)
        #expect(changes.removed.values.first?.text.contains("本文B") == true)
        // 間に本文の行がある削除はまとめない
        #expect(LineDiff.changes(from: "a\nb\nc\nd\ne", to: "a\nc\ne").deletedBefore == [2, 3])
    }

    @Test func longRemovalsAreTruncated() {
        let old = (1...250).map(String.init).joined(separator: "\n")
        let removed = LineDiff.changes(from: old, to: "").removed[1]
        #expect(removed?.lineCount == 250)
        #expect(removed?.text.hasSuffix("200\n…（ほか 50行）") == true)
    }

    /// 変わった所を [ ] で囲んで文字列にする
    private func marked(_ segments: [InlineDiff.Segment]) -> String {
        segments.map { $0.changed ? "[\($0.text)]" : $0.text }.joined()
    }

    private func inline(_ old: String, _ new: String) -> InlineDiff? {
        LineDiff.inlineDiff(from: old, to: new)
    }

    @Test func inlineDiffMarksOnlyTheChangedCharacters() throws {
        let diff = try #require(inline("本番の手順を書き直す。", "本番の手順を見直す。"))
        #expect(marked(diff.old) == "本番の手順を[書き]直す。")
        #expect(marked(diff.new) == "本番の手順を[見]直す。")
    }

    @Test func inlineDiffHandlesPureInsertionAndDeletion() throws {
        let inserted = try #require(inline("重要です", "**重要**です"))
        #expect(marked(inserted.old) == "重要です")
        #expect(marked(inserted.new) == "[**]重要[**]です")
        let deleted = try #require(inline("前の文。消す文。後の文。", "前の文。後の文。"))
        #expect(marked(deleted.old) == "前の文。[消す文。]後の文。")
        #expect(marked(deleted.new) == "前の文。後の文。")
    }

    @Test func inlineDiffDoesNotSplitGraphemes() throws {
        // か＋結合濁点（NFD）と か は別の1文字として扱う
        let diff = try #require(inline("これはか\u{3099}です", "これはかです"))
        #expect(marked(diff.old) == "これは[か\u{3099}]です")
        #expect(marked(diff.new) == "これは[か]です")
    }

    @Test func inlineDiffAbsorbsShortCommonRunsBetweenChanges() throws {
        // 「の」だけが一致しても、変更を分けない
        let diff = try #require(inline("共通の文章あのい共通の文章", "共通の文章かのき共通の文章"))
        #expect(marked(diff.old) == "共通の文章[あのい]共通の文章")
        #expect(marked(diff.new) == "共通の文章[かのき]共通の文章")
    }

    @Test func inlineDiffGivesUpOnRewrites() {
        #expect(inline("今日は晴れて気持ちのよい朝だった", "明日の会議の資料を作って送る") == nil)
        #expect(inline("同じ", "同じ") == nil)
        #expect(inline("", "追加") == nil)
    }

    @Test func inlineDiffIsBoundedBySize() {
        // 前後の共通部分を除いた範囲が上限を超える
        let huge = String(repeating: "あ", count: LineDiff.inlineLimit + 1)
        let other = String(repeating: "い", count: LineDiff.inlineLimit + 1)
        #expect(inline("共通" + huge, "共通" + other) == nil)
        // 前後の共通部分は長くても上限に数えない
        let long = String(repeating: "あ", count: 10_000)
        #expect(inline(long + "い" + long, long + "う" + long) != nil)
        // 足しただけなら長くても比べられる
        #expect(inline("共通", "共通" + huge + other) != nil)
    }

    @Test func manyRewrittenParagraphsAreAllComparable() {
        // 文書の後ろの段落でも、前の段落の直しに影響されず比べられる
        let paragraphs = (1...60).map { n in "段落\(n)の" + String(repeating: "本文を書いた。", count: 60) }
        let old = paragraphs.joined(separator: "\n\n")
        let new = paragraphs.map { "言い換え" + $0.dropFirst(4).dropLast(4) + "言い換え" }.joined(separator: "\n\n")
        let changes = LineDiff.changes(from: old, to: new)
        #expect(changes.changed.count == 60)
        #expect(changes.changed.allSatisfy { changes.removed[$0.lowerBound]?.inlineDiff != nil })
    }

    @Test func inlineDiffElidesLongCommonRunsOnlyInLongText() throws {
        let body = String(repeating: "あ", count: 200)
        let diff = try #require(inline(body + "い" + body, body + "う" + body))
        let context = String(repeating: "あ", count: LineDiff.inlineContext)
        #expect(marked(diff.old) == "…\(context)[い]\(context)…")
        #expect(marked(diff.new) == "…\(context)[う]\(context)…")
        // 短ければ全文を出す
        let short = String(repeating: "あ", count: 100)
        let whole = try #require(inline(short + "い" + short, short + "う" + short))
        #expect(marked(whole.old) == "\(short)[い]\(short)")
    }

    @Test func inlineDiffsAttachOnlyToRewrites() {
        let old = "残る\n段落を書き直した\n残る2\n消える段落\n最後"
        let new = "残る\n段落を見直した\n残る2\n最後"
        let changes = LineDiff.changes(from: old, to: new)
        #expect(changes.changed == [2...2])
        #expect(changes.deletedBefore == [4])
        #expect(changes.removed[2]?.replacement == "段落を見直した")
        let rewritten = changes.removed[2]?.inlineDiff
        #expect(rewritten.map { marked($0.old) } == "段落を[書き]直した")
        #expect(rewritten.map { marked($0.new) } == "段落を[見]直した")
        // 削除には比べる相手が無い
        #expect(changes.removed[4]?.text == "消える段落")
        #expect(changes.removed[4]?.replacement == nil)
        #expect(changes.removed[4]?.inlineDiff == nil)
    }

    @Test func inlineDiffsSkipTruncatedRemovals() {
        let old = (1...250).map { "行\($0)" }.joined(separator: "\n")
        let new = (1...250).map { "行\($0)x" }.joined(separator: "\n")
        let changes = LineDiff.changes(from: old, to: new)
        #expect(changes.removed[1]?.lineCount == 250)
        #expect(changes.removed[1]?.inlineDiff == nil)
    }

    @Test func jumpTargetsMoveBothWaysAndWrapAround() {
        // 変更箇所は 3・8・12 行目（12 は削除の位置）
        let changes = LineChanges(changed: [3...4, 8...8], deletedBefore: [12])
        #expect(changes.nextJumpLine(after: 3, inclusive: true) == 3)
        #expect(changes.nextJumpLine(after: 3, inclusive: false) == 8)
        #expect(changes.nextJumpLine(after: 13, inclusive: true) == 3)  // 末尾の先は先頭へ
        #expect(changes.previousJumpLine(before: 8) == 3)
        #expect(changes.previousJumpLine(before: 10) == 8)
        #expect(changes.previousJumpLine(before: 3) == 12)  // 先頭の手前は末尾へ
        #expect(LineChanges().previousJumpLine(before: 5) == nil)
    }

    @Test func itemsListChangesInDocumentOrder() {
        let old = "# 題\n\n古い段落\n\n残る段落\n\n消える段落\n\n最後"
        let new = "# 題\n\n**新しい**段落\n\n残る段落\n\n最後\n\n- 追加した項目"
        let changes = LineDiff.changes(from: old, to: new)
        let latest = LineDiff.changes(from: "# 題\n\n**新しい**段落\n\n残る段落\n\n最後", to: new)
        let items = changes.items(in: new.split(separator: "\n", omittingEmptySubsequences: false), latest: latest)
        #expect(items.map(\.kind) == [.rewritten, .deleted, .added])
        #expect(items.map(\.snippet) == ["新しい段落", "消える段落", "追加した項目"])  // 記号は除く
        #expect(items.map(\.isLatest) == [false, false, true])  // 直近の更新は最後の追加だけ
        #expect(items.map(\.line) == items.map(\.line).sorted())
    }

    @Test func sectionLinesFindHeadingsAboveChanges() {
        // 見出しは 1・4・8 行目。5 行目の変更は 4 行目の節、3〜8 行目の変更は 1・4・8 行目の節。
        let headings = [1, 4, 8]
        #expect(LineChanges(changed: [5...5]).sectionLines(headings: headings) == [4])
        #expect(LineChanges(changed: [3...8]).sectionLines(headings: headings) == [1, 4, 8])
        // 見出しより前の変更は数えない
        #expect(LineChanges(changed: [2...2]).sectionLines(headings: [3]).isEmpty)
    }

    @Test func sectionLinesCountDeletionInPrecedingSection() {
        // 8 行目（見出し）の直前で削除された → 4 行目の節。末尾の削除は最後の節。
        let headings = [1, 4, 8]
        #expect(LineChanges(deletedBefore: [8]).sectionLines(headings: headings) == [4])
        #expect(LineChanges(deletedBefore: [11]).sectionLines(headings: headings) == [8])
        #expect(LineChanges(deletedBefore: [1]).sectionLines(headings: headings).isEmpty)
    }

    // MARK: かたまりごとに戻す・確認済みにする

    @Test func revertingRestoresOnlyThatHunk() {
        let old = "a\nb\nc\nd\ne"
        let new = "a\nB\nc\nd\nE"
        #expect(LineDiff.reverting(hunkAt: 2, from: old, to: new) == "a\nb\nc\nd\nE")
        #expect(LineDiff.reverting(hunkAt: 5, from: old, to: new) == "a\nB\nc\nd\ne")
    }

    @Test func revertingAddedLinesRemovesThem() {
        #expect(LineDiff.reverting(hunkAt: 2, from: "a\nc", to: "a\nb1\nb2\nc") == "a\nc")
        // 末尾の改行も行として扱う
        #expect(LineDiff.reverting(hunkAt: 2, from: "a", to: "a\n") == "a")
    }

    @Test func revertingDeletionBringsLinesBack() {
        #expect(LineDiff.reverting(hunkAt: 2, from: "a\nb\nc\nd", to: "a\nd") == "a\nb\nc\nd")
        #expect(LineDiff.reverting(hunkAt: 2, from: "a\nb\nc", to: "a") == "a\nb\nc")
    }

    @Test func revertingMergedDeletionKeepsTheBlankLinesBetween() {
        // 見出しと本文を消して空行だけが残ると、削除は1つにまとめて出す。戻す時も全部戻す。
        let old = "前\n\n# 消える\n\n消える本文\n\n後"
        let new = "前\n\n\n後"
        let changes = LineDiff.changes(from: old, to: new)
        #expect(changes.deletedBefore.count == 1)
        let line = changes.deletedBefore[0]
        #expect(LineDiff.reverting(hunkAt: line, from: old, to: new) == old)
    }

    @Test func revertingHunkOverTheDisplayLimitRestoresEveryLine() {
        // 吹き出しに出す内容は 200 行で切るが、戻す内容は基準から作るので全部戻る
        let long = (1...300).map { "行\($0)" }.joined(separator: "\n")
        let old = "前\n\(long)\n後"
        let new = "前\n後"
        #expect(LineDiff.changes(from: old, to: new).removed[2]?.lineCount == 300)
        #expect(LineDiff.reverting(hunkAt: 2, from: old, to: new) == old)
    }

    @Test func hunkOperationsIgnoreLinesWithoutHunk() {
        #expect(LineDiff.reverting(hunkAt: 1, from: "a\nb", to: "a\nB") == nil)
        #expect(LineDiff.accepting(hunkAt: 1, from: "a\nb", to: "a\nB") == nil)
    }

    @Test func acceptingMovesOnlyThatHunkIntoBaseline() throws {
        let old = "a\nb\nc\nd\ne"
        let new = "a\nB\nc\nd\nE"
        let accepted = try #require(LineDiff.accepting(hunkAt: 2, from: old, to: new))
        #expect(accepted.baseline == "a\nB\nc\nd\ne")
        #expect(accepted.lines == 1..<2)
        // 残りのかたまりは同じ行のまま未確認
        #expect(LineDiff.changes(from: accepted.baseline, to: new).changed == [5...5])
    }

    @Test func acceptingAddedAndDeletedHunks() throws {
        let added = try #require(LineDiff.accepting(hunkAt: 2, from: "a\nc", to: "a\nb\nc"))
        #expect(added.baseline == "a\nb\nc")
        let deleted = try #require(LineDiff.accepting(hunkAt: 2, from: "a\nb\nc", to: "a\nc"))
        #expect(deleted.baseline == "a\nc")
        #expect(deleted.lines == 1..<1)
    }

    @Test func acceptingEveryHunkEndsAtTheCurrentText() throws {
        var baseline = "前\n段落\n\n消える\n\n残る\n"
        let new = "前\n段落を直した\n\n残る\n足した\n"
        while let line = LineDiff.changes(from: baseline, to: new).jumpLines.first {
            baseline = try #require(LineDiff.accepting(hunkAt: line, from: baseline, to: new)).baseline
        }
        #expect(baseline == new)
    }

    @Test func excludingRemovesMarksOfTheAcceptedHunk() {
        let latest = LineChanges(changed: [2...3, 6...6], deletedBefore: [4, 8], removed: [
            2: RemovedLines(["x"]), 6: RemovedLines(["y"]), 4: RemovedLines(["z"]), 8: RemovedLines(["w"]),
        ])
        // 0 始まりの 1..<3 は 2〜3 行目。その直後（4 行目の前）の削除も同じかたまり。
        let rest = latest.excluding(1..<3)
        #expect(rest.changed == [6...6])
        #expect(rest.deletedBefore == [8])
        #expect(Set(rest.removed.keys) == [6, 8])
        // 削除だけのかたまりは行を持たないので、その位置の削除だけ除く
        #expect(latest.excluding(7..<7).deletedBefore == [4])
    }
}
