import Testing
@testable import MDYomitoki

struct BookmarksTests {
    private func bookmark(_ line: Int, in text: String) -> Bookmark {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        return Bookmark(line: line, snippet: Bookmarks.snippet(of: lines[line - 1]))
    }

    @Test func snippetStripsMarkdownSyntax() {
        #expect(Bookmarks.snippet(of: "### 概要") == "概要")
        #expect(Bookmarks.snippet(of: "  - [x] **完了**した") == "完了した")
        #expect(Bookmarks.snippet(of: "> 1. `code` と ~~消し~~") == "code と 消し")
        #expect(Bookmarks.snippet(of: "| 項目 | 値 |") == "項目 値")
        #expect(Bookmarks.snippet(of: "snake_case") == "snake_case")
        #expect(Bookmarks.snippet(of: String(repeating: "あ", count: 50)).count == 30)
    }

    @Test func followsInsertionAbove() {
        let old = "# A\n本文\n## B"
        let new = "# 追加\n\n# A\n本文\n## B"
        let result = Bookmarks.remap([bookmark(3, in: old)], from: old, to: new)
        #expect(result.map(\.line) == [5])
    }

    @Test func duplicateTextFollowsTheSameLineNotTheFirstMatch() {
        // 「### 概要」が2つある。2つ目に付けた付箋は、上に行が増えても2つ目を指し続ける。
        let old = "### 概要\na\n### 概要\nb"
        let new = "前書き\n### 概要\na\n### 概要\nb"
        let result = Bookmarks.remap([bookmark(3, in: old)], from: old, to: new)
        #expect(result.map(\.line) == [4])
    }

    @Test func movedLinePicksNearestMatchAmongNewLines() {
        // 付箋の行が別の場所へ移動した（削除＋挿入）。変わっていない同じ文面の行ではなく、新しく入った行を選ぶ。
        let old = "### 概要\nx\n### 詳細\ny\n### 概要\nz"
        let new = "### 概要\nx\ny\n### 概要\nz\n### 詳細"
        let result = Bookmarks.remap([bookmark(3, in: old)], from: old, to: new)
        #expect(result.map(\.line) == [6])
        #expect(result.first?.snippet == "詳細")
    }

    @Test func editedLineKeepsItsPosition() {
        let old = "a\nb\n古い文\nc"
        let new = "a\nb\n新しい文\nc"
        let result = Bookmarks.remap([bookmark(3, in: old)], from: old, to: new)
        #expect(result == [Bookmark(line: 3, snippet: "新しい文")])
    }

    @Test func deletedLineFallsBackToEstimatedPosition() {
        let old = "a\nb\nc\nd"
        let new = "a\nd"
        #expect(Bookmarks.remap([bookmark(3, in: old)], from: old, to: new).map(\.line) == [2])
        // 末尾を消した場合は最終行に収める
        #expect(Bookmarks.remap([bookmark(4, in: old)], from: old, to: "a").map(\.line) == [1])
    }

    @Test func bookmarksCollapsingOntoOneLineAreMerged() {
        let old = "a\nb\nc\nd"
        let result = Bookmarks.remap([bookmark(2, in: old), bookmark(3, in: old)], from: old, to: "a\nd")
        #expect(result.count == 1)
    }

    @Test func relocateFindsNearestLineWithSameSnippet() {
        // 前回閉じた後に書き換えられていた（元の内容は無い）。
        let stored = [Bookmark(line: 2, snippet: "概要"), Bookmark(line: 9, snippet: "消えた行")]
        let text = "x\ny\n### 概要\nz\n### 概要"
        #expect(Bookmarks.relocate(stored, in: text).map(\.line) == [3, 5])
    }
}
