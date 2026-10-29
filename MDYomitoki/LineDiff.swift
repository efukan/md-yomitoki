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

    static let maxLines = 200

    init(_ lines: [Substring]) {
        lineCount = lines.count
        text = lines.prefix(Self.maxLines).joined(separator: "\n")
        if lines.count > Self.maxLines { text += "\n…（ほか \(lines.count - Self.maxLines)行）" }
    }
}

enum LineDiff {
    static func changes(from old: String, to new: String) -> LineChanges {
        guard old != new else { return LineChanges() }
        let oldLines = old.split(separator: "\n", omittingEmptySubsequences: false)
        let newLines = new.split(separator: "\n", omittingEmptySubsequences: false)
        let diff = newLines.difference(from: oldLines)

        var removed = Set<Int>()
        var inserted = Set<Int>()
        for change in diff {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }

        // 両方の配列を共通の行で揃えながら歩き、続けて削除・追加された行をひとかたまりにする。
        // 追加を含むかたまりは「変更」（削除もあれば書き換え）、削除だけのかたまりは「削除の位置」になる。
        var result = LineChanges()
        // 直前の削除だけのかたまり。間に空行しか無い削除は1つにまとめる（見出しと本文をまとめて消すと、
        // 間の空行だけが共通の行として残り、削除が2つに分かれて見えるため）。
        var lastDeletion: (line: Int, gone: [Substring])?
        var i = 0, j = 0
        while i < oldLines.count || j < newLines.count {
            guard removed.contains(i) || inserted.contains(j) else {
                i += 1
                j += 1
                continue
            }
            let start = j
            var gone: [Substring] = []
            while removed.contains(i) || inserted.contains(j) {
                if removed.contains(i) {
                    gone.append(oldLines[i])
                    i += 1
                } else {
                    j += 1
                }
            }
            let line = start + 1
            if j > start {
                result.changed.append(line...j)
                lastDeletion = nil
            } else if let last = lastDeletion,
                      newLines[(last.line - 1)..<start].allSatisfy({ $0.allSatisfy(\.isWhitespace) }) {
                let merged = last.gone + newLines[(last.line - 1)..<start] + gone
                result.removed[last.line] = RemovedLines(merged)
                lastDeletion = (last.line, merged)
                continue
            } else {
                result.deletedBefore.append(line)
                lastDeletion = (line, gone)
            }
            if !gone.isEmpty { result.removed[line] = RemovedLines(gone) }
        }
        return result
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
