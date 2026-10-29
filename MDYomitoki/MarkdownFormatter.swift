import Foundation

/// エディタで付けられる書式。
enum MarkdownFormat: String, CaseIterable {
    case heading1, heading2, heading3, body
    case bold, italic, strikethrough, inlineCode, link
    case bulletList, numberedList, taskList, quote, codeBlock, table

    var title: String {
        switch self {
        case .heading1: "見出し1"
        case .heading2: "見出し2"
        case .heading3: "見出し3"
        case .body: "本文（見出しを解除）"
        case .bold: "太字"
        case .italic: "斜体"
        case .strikethrough: "取り消し線"
        case .inlineCode: "インラインコード"
        case .link: "リンク"
        case .bulletList: "箇条書き"
        case .numberedList: "番号付きリスト"
        case .taskList: "チェックリスト"
        case .quote: "引用"
        case .codeBlock: "コードブロック"
        case .table: "表を挿入"
        }
    }

    var symbol: String {
        switch self {
        case .heading1, .heading2, .heading3: "number"
        case .body: "text.alignleft"
        case .bold: "bold"
        case .italic: "italic"
        case .strikethrough: "strikethrough"
        case .inlineCode: "chevron.left.forwardslash.chevron.right"
        case .link: "link"
        case .bulletList: "list.bullet"
        case .numberedList: "list.number"
        case .taskList: "checklist"
        case .quote: "text.quote"
        case .codeBlock: "curlybraces"
        case .table: "tablecells"
        }
    }

    /// メニューでの並び（nil は区切り線）
    static let menuLayout: [MarkdownFormat?] = [
        .heading1, .heading2, .heading3, .body, nil,
        .bold, .italic, .strikethrough, .inlineCode, .link, nil,
        .bulletList, .numberedList, .taskList, .quote, .codeBlock, .table,
    ]
}

/// テキストの置き換え1回分（範囲・置き換える文字列・置き換え後の選択範囲。いずれも UTF-16）。
struct TextEdit: Equatable {
    let range: NSRange
    let replacement: String
    let selection: NSRange
}

/// 書式の付け外し。どの書式も、すでに付いていれば外す（切り替え）。
enum MarkdownFormatter {
    /// line 行目（1 始まり）がタスクリストの項目（`- [ ] …`）なら、`[ ]` と `[x]` を入れ替えた全文を返す。
    /// 引用の中のリストや、全角スペースを挟んだ書き方（`-　[ ]`）も対象にする。項目でなければ nil。
    static func toggleTask(in text: String, line: Int) -> String? {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.indices.contains(line - 1),
              let match = lines[line - 1].firstMatch(of: /^([ \t>]*(?:[-*+]|\d{1,9}[.)])[ \t\u{3000}]+\[)([ xX])\]/) else { return nil }
        let mark: Substring = match.2 == " " ? "x" : " "
        lines[line - 1].replaceSubrange(match.2.startIndex..<match.2.endIndex, with: mark)
        return lines.joined(separator: "\n")
    }

    static func edit(_ format: MarkdownFormat, in text: String, selection: NSRange) -> TextEdit {
        let string = text as NSString
        switch format {
        case .bold: return toggleWrap("**", in: string, selection: selection)
        case .italic: return toggleWrap("*", in: string, selection: selection)
        case .strikethrough: return toggleWrap("~~", in: string, selection: selection)
        case .inlineCode: return toggleWrap("`", in: string, selection: selection)
        case .link: return link(in: string, selection: selection)
        case .table: return table(in: string, selection: selection)
        case .codeBlock:
            if selection.length == 0, string.substring(with: string.lineRange(for: selection)).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let lineStart = string.lineRange(for: selection).location
                let lineEnd = lineContentEnd(string, lineStart: lineStart)
                return TextEdit(range: NSRange(location: lineStart, length: lineEnd - lineStart),
                                replacement: "```\n\n```", selection: NSRange(location: lineStart + 4, length: 0))
            }
            return transformLines(in: string, selection: selection, transform: toggleCodeBlock)
        case .heading1: return transformLines(in: string, selection: selection) { toggleHeading($0, level: 1) }
        case .heading2: return transformLines(in: string, selection: selection) { toggleHeading($0, level: 2) }
        case .heading3: return transformLines(in: string, selection: selection) { toggleHeading($0, level: 3) }
        case .body: return transformLines(in: string, selection: selection) { $0.map(stripHeading) }
        case .bulletList: return transformLines(in: string, selection: selection) { toggleList($0, kind: .bullet) }
        case .numberedList: return transformLines(in: string, selection: selection) { toggleList($0, kind: .numbered) }
        case .taskList: return transformLines(in: string, selection: selection) { toggleList($0, kind: .task) }
        case .quote: return transformLines(in: string, selection: selection, transform: toggleQuote)
        }
    }

    // MARK: 文字列を記号で囲む（太字・斜体・取り消し線・コード）

    private static func toggleWrap(_ marker: String, in string: NSString, selection: NSRange) -> TextEdit {
        let m = (marker as NSString).length
        if selection.length == 0 {
            // 「****」の間にカーソル → 空の記号を消す
            if selection.location >= m, selection.location + m <= string.length,
               string.substring(with: NSRange(location: selection.location - m, length: m)) == marker,
               string.substring(with: NSRange(location: selection.location, length: m)) == marker,
               !(marker == "*" && isPartOfDoubleStar(string, around: selection.location)) {
                return TextEdit(range: NSRange(location: selection.location - m, length: 2 * m), replacement: "",
                                selection: NSRange(location: selection.location - m, length: 0))
            }
            // カーソルが「**重要**」の中 → 外す
            if let span = enclosingSpan(marker, in: string, at: selection.location) {
                let inner = string.substring(with: NSRange(location: span.location + m, length: span.length - 2 * m))
                let caret = min(max(selection.location - m, span.location), span.location + (inner as NSString).length)
                return TextEdit(range: span, replacement: inner, selection: NSRange(location: caret, length: 0))
            }
            // 太字の中で斜体の空の組「**」を入れると太字の記号と区別がつかなくなるので、何もしない
            if marker == "*", enclosingSpan("**", in: string, at: selection.location) != nil {
                return TextEdit(range: selection, replacement: "", selection: selection)
            }
            // 記号を入れて、間にカーソルを置く
            return TextEdit(range: selection, replacement: marker + marker,
                            selection: NSRange(location: selection.location + m, length: 0))
        }

        // 太字などは行をまたげないので、複数行なら行ごとに囲む／外す
        let selected = string.substring(with: selection)
        if selected.trimmingCharacters(in: .whitespacesAndNewlines).contains("\n") {
            let lines = selected.components(separatedBy: "\n")
            let content = lines.filter { !isBlank($0) }
            let remove = content.allSatisfy { isWrapped(splitOuterWhitespace($0).core, marker) }
            let replaced = lines.map { line -> String in
                if isBlank(line) { return line }
                let (lead, core, trail) = splitOuterWhitespace(line)
                return lead + (remove ? unwrap(core, marker) : marker + core + marker) + trail
            }
            let replacement = replaced.joined(separator: "\n")
            return TextEdit(range: selection, replacement: replacement,
                            selection: NSRange(location: selection.location, length: (replacement as NSString).length))
        }

        // 前後の空白・改行は記号の外に出す（「** 重要**」のように内側に空白があると太字にならない）
        let (lead, core, _) = splitOuterWhitespace(selected)
        let coreRange = NSRange(location: selection.location + (lead as NSString).length, length: (core as NSString).length)
        if core.isEmpty {
            return TextEdit(range: NSRange(location: NSMaxRange(selection), length: 0), replacement: marker + marker,
                            selection: NSRange(location: NSMaxRange(selection) + m, length: 0))
        }
        // 選択範囲のすぐ外側に記号がある → 外す
        if coreRange.location >= m, NSMaxRange(coreRange) + m <= string.length,
           string.substring(with: NSRange(location: coreRange.location - m, length: m)) == marker,
           string.substring(with: NSRange(location: NSMaxRange(coreRange), length: m)) == marker,
           !(marker == "*" && (isPartOfDoubleStar(string, around: coreRange.location - 1)
                               || isPartOfDoubleStar(string, around: NSMaxRange(coreRange) + 1))) {
            return TextEdit(range: NSRange(location: coreRange.location - m, length: coreRange.length + 2 * m),
                            replacement: core, selection: NSRange(location: coreRange.location - m, length: coreRange.length))
        }
        // 選択範囲そのものが記号で囲まれている → 外す
        if isWrapped(core, marker) {
            let inner = unwrap(core, marker)
            return TextEdit(range: coreRange, replacement: inner,
                            selection: NSRange(location: coreRange.location, length: (inner as NSString).length))
        }
        return TextEdit(range: coreRange, replacement: marker + core + marker,
                        selection: NSRange(location: coreRange.location + m, length: coreRange.length))
    }

    private static func isWrapped(_ text: String, _ marker: String) -> Bool {
        let m = marker.count
        guard text.count > 2 * m, text.hasPrefix(marker), text.hasSuffix(marker) else { return false }
        // 斜体（*）の判定で、太字（**…**）を斜体と取り違えない
        return marker != "*" || !(text.hasPrefix("**") || text.hasSuffix("**"))
    }

    private static func unwrap(_ text: String, _ marker: String) -> String {
        isWrapped(text, marker) ? String(text.dropFirst(marker.count).dropLast(marker.count)) : text
    }

    /// 前後の空白（全角スペース・改行を含む）と中身に分ける。
    private static func splitOuterWhitespace(_ text: String) -> (lead: String, core: String, trail: String) {
        let lead = text.prefix { $0.isWhitespace }
        let rest = text.dropFirst(lead.count)
        let trail = rest.reversed().prefix { $0.isWhitespace }
        return (String(lead), String(rest.dropLast(trail.count)), String(trail.reversed()))
    }

    /// index の文字が「**」の一部か（斜体の * と区別するため）。
    private static func isPartOfDoubleStar(_ string: NSString, around index: Int) -> Bool {
        func star(_ i: Int) -> Bool { i >= 0 && i < string.length && string.character(at: i) == 0x2A }
        return star(index) && (star(index - 1) || star(index + 1))
    }

    /// カーソル位置を含む「記号で囲まれた範囲」（同じ行の中だけを探す）。
    private static func enclosingSpan(_ marker: String, in string: NSString, at location: Int) -> NSRange? {
        let pattern: String
        switch marker {
        case "**": pattern = #"\*\*(?:(?!\*\*).)+?\*\*"#
        case "*": pattern = #"(?<!\*)\*(?!\*)[^*]+?(?<!\*)\*(?!\*)"#
        case "~~": pattern = #"~~(?:(?!~~).)+?~~"#
        case "`": pattern = #"`[^`]+`"#
        default: return nil
        }
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let line = string.lineRange(for: NSRange(location: location, length: 0))
        let m = (marker as NSString).length
        return regex.matches(in: string as String, range: line).map(\.range).first {
            location >= $0.location + m && location <= NSMaxRange($0) - m
        }
    }

    private static func link(in string: NSString, selection: NSRange) -> TextEdit {
        let url = "https://"
        let label = "リンクテキスト"
        let (lead, core, _) = splitOuterWhitespace(string.substring(with: selection))
        let target = NSRange(location: selection.location + (lead as NSString).length, length: (core as NSString).length)
        if core.isEmpty {
            return TextEdit(range: target, replacement: "[\(label)](\(url))",
                            selection: NSRange(location: target.location + 1, length: (label as NSString).length))
        }
        // URL を選んでいたら、それをリンク先にして表示テキストを入力してもらう
        if core.hasPrefix("http://") || core.hasPrefix("https://") {
            return TextEdit(range: target, replacement: "[\(label)](\(core))",
                            selection: NSRange(location: target.location + 1, length: (label as NSString).length))
        }
        return TextEdit(range: target, replacement: "[\(core)](\(url))",
                        selection: NSRange(location: target.location + target.length + 3, length: (url as NSString).length))
    }

    /// 表のひな形を入れる。空行ならその行に、文字のある行なら次の行に入れ、前後に空行を確保する
    /// （段落に続けて書くと表として認識されないため）。
    private static func table(in string: NSString, selection: NSRange) -> TextEdit {
        let template = "| 見出し1 | 見出し2 |\n| --- | --- |\n| 内容 | 内容 |"
        let lineRange = string.lineRange(for: NSRange(location: selection.location, length: 0))
        let lineIsEmpty = isBlank(string.substring(with: lineRange).trimmingCharacters(in: .newlines))
        let contentEnd = lineContentEnd(string, lineStart: lineRange.location)
        let replaced = lineIsEmpty ? NSRange(location: lineRange.location, length: contentEnd - lineRange.location)
                                   : NSRange(location: contentEnd, length: 0)

        func lineIsBlank(endingAt index: Int) -> Bool {  // index の直前で終わる行が空か
            guard index > 0 else { return true }
            let range = string.lineRange(for: NSRange(location: index - 1, length: 0))
            return isBlank(string.substring(with: range).trimmingCharacters(in: .newlines))
        }
        var prefix = ""
        if !lineIsEmpty {
            prefix = "\n\n"  // 今の行の後ろで改行し、空行を1つ挟む
        } else if !lineIsBlank(endingAt: lineRange.location) {
            prefix = "\n"
        }
        // 後ろ：次の行が続くなら空行を挟む
        let after = NSMaxRange(replaced)
        var suffix = ""
        if after < string.length {
            let rest = string.substring(from: after)
            let nextLine = rest.drop { $0 == "\n" }.prefix { $0 != "\n" }
            suffix = rest.hasPrefix("\n\n") || nextLine.isEmpty ? "" : "\n"
        }
        let headerStart = replaced.location + (prefix as NSString).length + 2
        return TextEdit(range: replaced, replacement: prefix + template + suffix,
                        selection: NSRange(location: headerStart, length: ("見出し1" as NSString).length))
    }

    // MARK: 行単位の書式（見出し・リスト・引用・コードブロック）

    /// 選択範囲を含む行全体を transform で置き換える。未選択なら行末にカーソル、選択していれば変換後の行を選択する。
    private static func transformLines(in string: NSString, selection: NSRange, transform: ([String]) -> [String]) -> TextEdit {
        var target = selection
        // 行を丸ごと選択すると末尾の改行まで選ばれ、次の行まで対象になってしまうのを防ぐ
        if target.length > 0, string.substring(with: NSRange(location: NSMaxRange(target) - 1, length: 1)) == "\n" {
            target.length -= 1
        }
        let lineRange = string.lineRange(for: target)
        let contentEnd = lineContentEnd(string, lineStart: lineRange.location, limit: NSMaxRange(lineRange))
        let range = NSRange(location: lineRange.location, length: contentEnd - lineRange.location)
        let lines = string.substring(with: range).components(separatedBy: "\n")
        let replaced = transform(lines)
        let replacement = replaced.joined(separator: "\n")
        let newSelection = selection.length == 0 && replaced.count == lines.count && lines.count == 1
            ? NSRange(location: range.location + (replacement as NSString).length, length: 0)
            : NSRange(location: range.location, length: (replacement as NSString).length)
        return TextEdit(range: range, replacement: replacement, selection: newSelection)
    }

    /// lineStart から始まる行（limit までの複数行でも可）の、最後の改行を除いた終端。
    private static func lineContentEnd(_ string: NSString, lineStart: Int, limit: Int? = nil) -> Int {
        let end = limit ?? NSMaxRange(string.lineRange(for: NSRange(location: lineStart, length: 0)))
        return end > lineStart && string.substring(with: NSRange(location: end - 1, length: 1)) == "\n" ? end - 1 : end
    }

    private static func isBlank(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).isEmpty
    }

    static func headingLevel(_ line: String) -> Int? {
        line.prefixMatch(of: /(#{1,6})[ \t\u{3000}]+/).map { $0.1.count }
    }

    private static func stripHeading(_ line: String) -> String {
        line.prefixMatch(of: /#{1,6}[ \t\u{3000}]+/).map { String(line[$0.range.upperBound...]) } ?? line
    }

    private static func toggleHeading(_ lines: [String], level: Int) -> [String] {
        let content = lines.filter { !isBlank($0) }
        // 空の行では記号だけ入れて、続けて入力できるようにする
        if content.isEmpty { return lines.count == 1 ? [String(repeating: "#", count: level) + " "] : lines }
        let remove = !content.isEmpty && content.allSatisfy { headingLevel($0) == level }
        return lines.map { line in
            if isBlank(line) { return line }
            let text = stripHeading(line)
            return remove ? text : String(repeating: "#", count: level) + " " + text
        }
    }

    enum ListKind { case bullet, numbered, task }

    static func listKind(_ line: String) -> ListKind? {
        if line.prefixMatch(of: /[ \t]*[-*+][ \t]+\[[ xX]\][ \t]+/) != nil { return .task }
        if line.prefixMatch(of: /[ \t]*[-*+][ \t\u{3000}]+/) != nil { return .bullet }
        if line.prefixMatch(of: /[ \t]*\d{1,9}[.)][ \t\u{3000}]+/) != nil { return .numbered }
        return nil
    }

    /// 行頭の字下げと、リスト記号を除いた本文に分ける（別の種類のリストへの付け替えに使う）。
    private static func splitListMarker(_ line: String) -> (indent: String, body: String) {
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        if let match = line.prefixMatch(of: /[ \t]*(?:[-*+]|\d{1,9}[.)])[ \t\u{3000}]+(?:\[[ xX]\][ \t]+)?/) {
            return (indent, String(line[match.range.upperBound...]))
        }
        return (indent, String(line.dropFirst(indent.count)))
    }

    private static func toggleList(_ lines: [String], kind: ListKind) -> [String] {
        let content = lines.filter { !isBlank($0) }
        if content.isEmpty {
            guard lines.count == 1 else { return lines }
            switch kind {
            case .bullet: return ["- "]
            case .numbered: return ["1. "]
            case .task: return ["- [ ] "]
            }
        }
        let remove = !content.isEmpty && content.allSatisfy { listKind($0) == kind }
        var number = 0
        return lines.map { line in
            if isBlank(line) { return line }
            let (indent, body) = splitListMarker(line)
            if remove { return indent + body }
            number += 1
            switch kind {
            case .bullet: return indent + "- " + body
            case .numbered: return indent + "\(number). " + body
            case .task: return indent + "- [ ] " + body
            }
        }
    }

    private static func toggleQuote(_ lines: [String]) -> [String] {
        let content = lines.filter { !isBlank($0) }
        if content.isEmpty { return lines.count == 1 ? ["> "] : lines }
        let remove = !content.isEmpty && content.allSatisfy { $0.prefixMatch(of: /[ \t]{0,3}>/) != nil }
        return lines.map { line in
            if remove {
                return line.prefixMatch(of: /[ \t]{0,3}>[ \t]?/).map { String(line[$0.range.upperBound...]) } ?? line
            }
            return isBlank(line) ? ">" : "> " + line
        }
    }

    private static func toggleCodeBlock(_ lines: [String]) -> [String] {
        let isFence = { (line: String) in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~")
        }
        if lines.count >= 2, let first = lines.first, let last = lines.last, isFence(first), isFence(last) {
            return Array(lines.dropFirst().dropLast())
        }
        return ["```"] + lines + ["```"]
    }
}
