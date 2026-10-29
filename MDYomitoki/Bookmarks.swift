import Foundation

/// 付箋。行番号に加えて行頭の抜粋を持ち、ファイルが書き換えられて行がずれたときの探し直しに使う。
struct Bookmark: Codable, Hashable {
    var line: Int
    var snippet: String
}

enum Bookmarks {
    static let snippetLength = 30

    /// 行頭の Markdown 記号（引用・見出し・リスト・チェックボックス）と強調・コードの記号、表の区切りを除いた先頭 30 文字。
    static func snippet(of line: some StringProtocol) -> String {
        var text = String(line)
            .replacingOccurrences(of: #"^\s*(?:>\s*)*(?:#{1,6}\s+|[-*+]\s+(?:\[[ xX]\]\s+)?|\d{1,9}[.)]\s+)?"#,
                                  with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[*`~]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*\|\s*"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespaces)
        return String(text.prefix(snippetLength))
    }

    /// old → new の書き換えに付箋を追従させる。
    /// 1. 付箋の行が書き換えられていなければ、行単位の差分でそのまま新しい行番号へ移す（同じ文面の行が複数あっても迷わない）。
    /// 2. 付箋の行自体が書き換えられた・移動した場合は、新しく入った行から同じ抜粋の行を探し、
    ///    前後の変わっていない行から推定した位置に一番近いものを選ぶ。見つからなければ推定した位置に置く。
    static func remap(_ bookmarks: [Bookmark], from old: String, to new: String) -> [Bookmark] {
        guard !bookmarks.isEmpty, old != new else { return bookmarks }
        let oldLines = old.split(separator: "\n", omittingEmptySubsequences: false)
        let newLines = new.split(separator: "\n", omittingEmptySubsequences: false)
        let map = LineDiff.lineMap(from: oldLines, to: newLines)
        let matched = Set(map.compactMap { $0 })

        let moved = bookmarks.map { bookmark -> Bookmark in
            let index = bookmark.line - 1
            if map.indices.contains(index), let target = map[index] {
                return Bookmark(line: target + 1, snippet: snippet(of: newLines[target]))
            }
            // 直前の変わっていない行からの距離で推定する
            let previous = (0..<min(index, map.count)).last { map[$0] != nil }
            let estimate = previous.map { map[$0]! + (index - $0) } ?? index
            let around = min(max(estimate, 0), newLines.count - 1)
            let target = nearest(bookmark.snippet, around: around, in: newLines) { !matched.contains($0) } ?? around
            return Bookmark(line: target + 1, snippet: snippet(of: newLines[target]))
        }
        return deduplicated(moved)
    }

    /// 前回閉じた後に書き換えられていた場合（元の内容は無い）。行の抜粋が合わなければ、同じ抜粋の一番近い行へ移す。
    static func relocate(_ bookmarks: [Bookmark], in text: String) -> [Bookmark] {
        guard !bookmarks.isEmpty else { return bookmarks }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let moved = bookmarks.map { bookmark -> Bookmark in
            let around = min(max(bookmark.line - 1, 0), lines.count - 1)
            if snippet(of: lines[around]) == bookmark.snippet { return Bookmark(line: around + 1, snippet: bookmark.snippet) }
            let target = nearest(bookmark.snippet, around: around, in: lines) { _ in true } ?? around
            return Bookmark(line: target + 1, snippet: snippet(of: lines[target]))
        }
        return deduplicated(moved)
    }

    /// around から上下に広げながら、抜粋が一致する行を探す（同じ距離なら上を優先）。
    private static func nearest(_ snippet: String, around: Int, in lines: [Substring], where allowed: (Int) -> Bool) -> Int? {
        guard !snippet.isEmpty else { return nil }
        for distance in 0..<lines.count {
            for index in distance == 0 ? [around] : [around - distance, around + distance]
            where lines.indices.contains(index) && allowed(index) && Self.snippet(of: lines[index]) == snippet {
                return index
            }
            if around - distance < 0 && around + distance >= lines.count { break }
        }
        return nil
    }

    /// 同じ行に寄った付箋は1つにまとめ、行順に並べる。
    private static func deduplicated(_ bookmarks: [Bookmark]) -> [Bookmark] {
        var seen = Set<Int>()
        return bookmarks.sorted { $0.line < $1.line }.filter { seen.insert($0.line).inserted }
    }
}

/// ファイルパスごとの付箋を UserDefaults に保存する（最近使った 200 件まで）。
enum BookmarkStore {
    private static let key = "bookmarks"
    private static let limit = 200

    private struct Entry: Codable {
        var bookmarks: [Bookmark]
        var updated: Date
    }

    static func load(for url: URL) -> [Bookmark] {
        all()[url.path]?.bookmarks ?? []
    }

    static func save(_ bookmarks: [Bookmark], for url: URL) {
        var entries = all()
        entries[url.path] = bookmarks.isEmpty ? nil : Entry(bookmarks: bookmarks, updated: Date())
        if entries.count > limit {
            let oldest = entries.sorted { $0.value.updated < $1.value.updated }.prefix(entries.count - limit)
            for (path, _) in oldest { entries[path] = nil }
        }
        UserDefaults.standard.set(try? JSONEncoder().encode(entries), forKey: key)
    }

    private static func all() -> [String: Entry] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: Entry].self, from: data)) ?? [:]
    }
}
