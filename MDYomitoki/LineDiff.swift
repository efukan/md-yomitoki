import Foundation

/// 新しいテキスト側から見た行単位の変更。行番号は 1 始まり。
struct LineChanges: Equatable {
    /// 追加・変更された行の範囲
    var changed: [ClosedRange<Int>] = []
    /// 行が削除された位置（この行の直前で削除された。末尾での削除は「行数＋1」）
    var deletedBefore: [Int] = []
    /// 消えた行。キーは削除の位置（`deletedBefore`）か、書き換えられた範囲の先頭行（`changed` の lowerBound）。
    /// 行を足しただけの変更には無い。
    var removed: [Int: RemovedLines] = [:]

    var isEmpty: Bool { changed.isEmpty && deletedBefore.isEmpty }

    /// 変更箇所へのジャンプ先（各変更の先頭行）
    var jumpLines: [Int] {
        Array(Set(changed.map(\.lowerBound) + deletedBefore)).sorted()
    }

    /// line より後（inclusive なら line も含む）の最初の変更箇所。無ければ先頭の変更箇所へ回る。
    func nextJumpLine(after line: Int, inclusive: Bool) -> Int? {
        let lines = jumpLines
        return lines.first { inclusive ? $0 >= line : $0 > line } ?? lines.first
    }

    /// line より前の最後の変更箇所。無ければ最後の変更箇所へ回る。
    func previousJumpLine(before line: Int) -> Int? {
        let lines = jumpLines
        return lines.last { $0 < line } ?? lines.last
    }

    /// 変更を含む節の見出しの行（`headings` は文書順の見出しの行）。節は見出しの行から次の見出しの直前まで
    /// （下位の見出しの節は含めない）。削除は直前の行で数える。最初の見出しより前の変更は数えない。
    func sectionLines(headings: [Int]) -> Set<Int> {
        guard !headings.isEmpty, !isEmpty else { return [] }
        func section(of line: Int) -> Int? { headings.last { $0 <= line } }
        var result = Set<Int>()
        for range in changed {
            if let heading = section(of: range.lowerBound) { result.insert(heading) }
            result.formUnion(headings.filter { range.contains($0) })
        }
        for line in deletedBefore {
            if let heading = section(of: line - 1) { result.insert(heading) }
        }
        return result
    }

    /// 新しいテキストの行（0 始まり）のかたまりに重なる印を除いたもの（そのかたまりを確認済みにした時）。
    func excluding(_ lines: Range<Int>) -> LineChanges {
        var result = LineChanges()
        // 行番号は 1 始まり。削除はかたまりの直後の行の前に出ることがある
        result.changed = changed.filter { !$0.overlaps((lines.lowerBound + 1)..<(lines.upperBound + 1)) }
        result.deletedBefore = deletedBefore.filter { !((lines.lowerBound + 1)...(lines.upperBound + 1)).contains($0) }
        let kept = Set(result.changed.map(\.lowerBound) + result.deletedBefore)
        result.removed = removed.filter { kept.contains($0.key) }
        return result
    }
}

/// 差分のかたまり1つ。行は 0 始まりの半開区間。
struct LineHunk: Equatable {
    var old: Range<Int>
    var new: Range<Int>
    /// 削除だけのかたまり（間に空行をはさんだ削除をまとめた時は、その空行が new に残る）
    var isDeletion: Bool
    /// `LineChanges` でこのかたまりを指す行（1 始まり）
    var line: Int { new.lowerBound + 1 }
}

/// サイドバーの「変更」欄の1行（変更のかたまり1つ）。
struct ChangeItem: Hashable {
    enum Kind { case rewritten, added, deleted }

    /// 変わった範囲の先頭行（削除なら削除の位置）
    let line: Int
    let kind: Kind
    /// 直近の外部更新に含まれる
    let isLatest: Bool
    /// 変わった行（削除なら消えた行）のうち、最初の空でない行の書き出し
    let snippet: String
}

extension LineChanges {
    /// 変更のかたまりを文書順に並べる。lines は今の本文の行、latest は直近の外部更新の変更（行番号は同じ今の本文のもの）。
    func items(in lines: [Substring], latest: LineChanges) -> [ChangeItem] {
        func firstSnippet(_ lines: some Sequence<Substring>) -> String {
            lines.lazy.map { Bookmarks.snippet(of: $0) }.first { !$0.isEmpty } ?? ""
        }
        var items: [ChangeItem] = []
        for range in changed where range.lowerBound <= lines.count {
            items.append(ChangeItem(
                line: range.lowerBound,
                kind: removed[range.lowerBound] == nil ? .added : .rewritten,
                isLatest: latest.changed.contains { $0.overlaps(range) },
                snippet: firstSnippet(lines[(range.lowerBound - 1)..<min(range.upperBound, lines.count)])
            ))
        }
        for line in deletedBefore {
            let gone = removed[line]?.text.split(separator: "\n", omittingEmptySubsequences: false) ?? []
            items.append(ChangeItem(line: line, kind: .deleted, isLatest: latest.deletedBefore.contains(line), snippet: firstSnippet(gone)))
        }
        return items.sorted { $0.line < $1.line }
    }
}

/// 消えた行（削除された行・書き換える前の行）。長いときは先頭だけを持つ。
struct RemovedLines: Equatable {
    var lineCount: Int
    var text: String
    /// 書き換えた後の行（文字単位の差分の相手）。削除には無い。省略して比べられない時も持たない。
    var replacement: String?

    static let maxLines = 200

    init(_ lines: [Substring], replacement: ArraySlice<Substring>? = nil) {
        lineCount = lines.count
        text = lines.prefix(Self.maxLines).joined(separator: "\n")
        if lines.count > Self.maxLines {
            text += "\n…（ほか \(lines.count - Self.maxLines)行）"
        } else {
            self.replacement = replacement?.joined(separator: "\n")
        }
    }

    /// 文字単位の差分。吹き出しを開く時にメインスレッドの外で計算する（見ないかたまりの分は計算しない）。
    var inlineDiff: InlineDiff? {
        replacement.flatMap { LineDiff.inlineDiff(from: text, to: $0) }
    }
}

/// 書き換えの前後の文字列を、変わった部分とそれ以外に分けたもの（吹き出しで強調する）。
struct InlineDiff: Equatable {
    struct Segment: Equatable {
        let text: String
        let changed: Bool
    }

    let old: [Segment]
    let new: [Segment]
}

enum LineDiff {
    /// 文字単位で比べる範囲（前後の共通部分を除く）の片側の文字数の上限。
    /// 全く違う文字列どうしの比較は文字数の2乗で重くなる（片側 1000 字で Debug ビルド 約 0.3 秒）。
    static let inlineLimit = 1000
    /// 共通の文字が短い方の文字列のこの割合に満たなければ、書き直しとみなして強調しない（細切れになるだけなので）。
    static let inlineMinCommon = 0.5
    /// 片側がこの文字数を超える時だけ、長い共通部分を省いて変わった所の前後を残す（吹き出しに変わった所が収まるように）。
    static let inlineElideOver = 300
    static let inlineContext = 40

    /// 書記素単位で比べる（濁点などを分けない）。比べない時は nil。
    static func inlineDiff(from old: String, to new: String) -> InlineDiff? {
        let a = Array(old), b = Array(new)
        guard !a.isEmpty, !b.isEmpty, a != b else { return nil }
        // 1段落の中の小さな直しがほとんどなので、前後の共通部分を除いてから比べる
        let shorter = min(a.count, b.count)
        var prefix = 0
        while prefix < shorter, a[prefix] == b[prefix] { prefix += 1 }
        var suffix = 0
        while suffix < shorter - prefix, a[a.count - 1 - suffix] == b[b.count - 1 - suffix] { suffix += 1 }
        let aMiddle = Array(a[prefix..<(a.count - suffix)]), bMiddle = Array(b[prefix..<(b.count - suffix)])
        var runs = [InlineRun(count: prefix)]
        if aMiddle.isEmpty || bMiddle.isEmpty {
            // 足しただけ・消しただけなら比べるまでもない（長い段落を足しても上限に数えない）
            runs.append(InlineRun(old: aMiddle.count, new: bMiddle.count))
        } else {
            guard aMiddle.count <= inlineLimit, bMiddle.count <= inlineLimit else { return nil }
            runs += inlineRuns(from: aMiddle, to: bMiddle)
        }
        runs.append(InlineRun(count: suffix))
        runs = absorbShortCommonRuns(runs.filter { $0.old > 0 || $0.new > 0 })

        let common = runs.reduce(0) { $0 + ($1.common ? $1.old : 0) }
        guard Double(common) >= inlineMinCommon * Double(shorter) else { return nil }
        return InlineDiff(old: segments(a, runs.map { ($0.old, $0.common) }), new: segments(b, runs.map { ($0.new, $0.common) }))
    }

    /// 共通の文字のかたまり（common。old と new は同じ数）か、変わった文字のかたまり。
    private struct InlineRun {
        var old: Int
        var new: Int
        var common: Bool

        init(count: Int) {
            old = count
            new = count
            common = true
        }

        init(old: Int, new: Int) {
            self.old = old
            self.new = new
            common = false
        }
    }

    private static func inlineRuns(from a: [Character], to b: [Character]) -> [InlineRun] {
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in b.difference(from: a) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var runs: [InlineRun] = []
        var i = 0, j = 0
        while i < a.count || j < b.count {
            let start = (i, j)
            while removed.contains(i) || inserted.contains(j) {
                if removed.contains(i) { i += 1 } else { j += 1 }
            }
            if i > start.0 || j > start.1 { runs.append(InlineRun(old: i - start.0, new: j - start.1)) }
            let same = i
            while i < a.count, j < b.count, !removed.contains(i), !inserted.contains(j) {
                i += 1
                j += 1
            }
            if i > same { runs.append(InlineRun(count: i - same)) }
        }
        return runs
    }

    /// 変わった所にはさまれた共通のかたまりは、両隣の変更より長くなければ変更に含める
    /// （「の」「は」だけが一致して強調が細切れになるのを防ぐ）。文書の先頭と末尾の共通部分は残す。
    /// 両隣とも足しただけ・消しただけなら間の文字は本当に変わっていないので含めない（`重要` → `**重要**`）。
    private static func absorbShortCommonRuns(_ input: [InlineRun]) -> [InlineRun] {
        var runs = input
        var index = 1
        while index + 1 < runs.count {
            let before = runs[index - 1], run = runs[index], after = runs[index + 1]
            let onlyAdded = before.old == 0 && after.old == 0, onlyRemoved = before.new == 0 && after.new == 0
            guard run.common, !onlyAdded, !onlyRemoved,
                  run.old <= max(before.old, before.new), run.old <= max(after.old, after.new) else {
                index += 1
                continue
            }
            runs[(index - 1)...(index + 1)] = [InlineRun(old: before.old + run.old + after.old, new: before.new + run.new + after.new)]
            // 変更が長くなったので、一つ前の共通のかたまりも含められるようになったかもしれない
            index = max(1, index - 2)
        }
        return runs
    }

    private static func segments(_ characters: [Character], _ runs: [(count: Int, common: Bool)]) -> [InlineDiff.Segment] {
        let elide = characters.count > inlineElideOver
        var segments: [InlineDiff.Segment] = []
        var start = 0
        for (index, run) in runs.enumerated() where run.count > 0 {
            let part = characters[start..<(start + run.count)]
            start += run.count
            guard run.common, elide, run.count > inlineContext * 2 else {
                segments.append(.init(text: String(part), changed: !run.common))
                continue
            }
            let head = index == 0 ? "" : String(part.prefix(inlineContext))
            let tail = index == runs.count - 1 ? "" : String(part.suffix(inlineContext))
            segments.append(.init(text: head + "…" + tail, changed: false))
        }
        return segments
    }

    static func changes(from old: String, to new: String) -> LineChanges {
        guard old != new else { return LineChanges() }
        let oldLines = lines(of: old), newLines = lines(of: new)
        var result = LineChanges()
        for hunk in hunks(from: oldLines, to: newLines) {
            if hunk.isDeletion {
                result.deletedBefore.append(hunk.line)
                result.removed[hunk.line] = RemovedLines(Array(oldLines[hunk.old]))
            } else {
                result.changed.append(hunk.line...hunk.new.upperBound)
                if !hunk.old.isEmpty {
                    result.removed[hunk.line] = RemovedLines(Array(oldLines[hunk.old]), replacement: newLines[hunk.new])
                }
            }
        }
        return result
    }

    /// line（`LineHunk.line`）のかたまりだけを old の内容に戻した new。かたまりが無ければ nil。
    static func reverting(hunkAt line: Int, from old: String, to new: String) -> String? {
        let oldLines = lines(of: old)
        var newLines = lines(of: new)
        guard let hunk = hunks(from: oldLines, to: newLines).first(where: { $0.line == line }) else { return nil }
        newLines.replaceSubrange(hunk.new, with: oldLines[hunk.old])
        return newLines.joined(separator: "\n")
    }

    /// line（`LineHunk.line`）のかたまりだけを new の内容にした old（＝そのかたまりを確認済みにした基準）と、
    /// そのかたまりの new での行（0 始まり）。かたまりが無ければ nil。
    static func accepting(hunkAt line: Int, from old: String, to new: String) -> (baseline: String, lines: Range<Int>)? {
        var oldLines = lines(of: old)
        let newLines = lines(of: new)
        guard let hunk = hunks(from: oldLines, to: newLines).first(where: { $0.line == line }) else { return nil }
        oldLines.replaceSubrange(hunk.old, with: newLines[hunk.new])
        return (oldLines.joined(separator: "\n"), hunk.new)
    }

    private static func lines(of text: String) -> [Substring] {
        text.split(separator: "\n", omittingEmptySubsequences: false)
    }

    /// 両方の配列を共通の行で揃えながら歩き、続けて削除・追加された行をひとかたまりにする。
    /// 追加を含むかたまりは「変更」（削除もあれば書き換え）、削除だけのかたまりは「削除の位置」になる。
    static func hunks(from oldLines: [Substring], to newLines: [Substring]) -> [LineHunk] {
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in newLines.difference(from: oldLines) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var hunks: [LineHunk] = []
        var i = 0, j = 0
        while i < oldLines.count || j < newLines.count {
            guard removed.contains(i) || inserted.contains(j) else {
                i += 1
                j += 1
                continue
            }
            let oldStart = i, newStart = j
            while removed.contains(i) || inserted.contains(j) {
                if removed.contains(i) { i += 1 } else { j += 1 }
            }
            // 間に空行しか無い削除は1つにまとめる（見出しと本文をまとめて消すと、
            // 間の空行だけが共通の行として残り、削除が2つに分かれて見えるため）。
            if j == newStart, let last = hunks.last, last.isDeletion,
               newLines[last.new.lowerBound..<newStart].allSatisfy({ $0.allSatisfy(\.isWhitespace) }) {
                hunks[hunks.count - 1].old = last.old.lowerBound..<i
                hunks[hunks.count - 1].new = last.new.lowerBound..<newStart
            } else {
                hunks.append(LineHunk(old: oldStart..<i, new: newStart..<j, isDeletion: j == newStart))
            }
        }
        return hunks
    }

    /// 古い行（0 始まり）が新しいテキストのどの行に残ったか。削除・書き換えられた行は nil。
    static func lineMap(from oldLines: [Substring], to newLines: [Substring]) -> [Int?] {
        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in newLines.difference(from: oldLines) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var map = [Int?](repeating: nil, count: oldLines.count)
        var i = 0, j = 0
        while i < oldLines.count {
            if removed.contains(i) {
                i += 1
            } else if inserted.contains(j) {
                j += 1
            } else {
                map[i] = j
                i += 1
                j += 1
            }
        }
        return map
    }
}
