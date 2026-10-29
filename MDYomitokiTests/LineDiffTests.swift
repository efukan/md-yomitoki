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
        #expect(changes.removed == [2: RemovedLines(["b", "c"]), 4: RemovedLines(["e"])])
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
}
