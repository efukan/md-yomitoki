import Foundation
import cmark_gfm
import cmark_gfm_extensions

struct OutlineItem: Identifiable, Equatable {
    let level: Int
    let title: String
    let line: Int
    var id: Int { line }
}

struct RenderedMarkdown: Equatable {
    var html = ""
    var outline: [OutlineItem] = []
    /// 見出しのアンカー（slug → 行）。ほかの文書のリンク（`other.md#見出し`）で見出しへ移動するため。
    var anchors: [String: Int] = [:]
    var charCount = 0
}

/// Markdown → HTML / TOC / 文字数。1回のパースでまとめて得る。
enum Markdown {
    private static let options = CMARK_OPT_SOURCEPOS | CMARK_OPT_UNSAFE | CMARK_OPT_FOOTNOTES
    private static let extensionNames = ["table", "strikethrough", "autolink", "tagfilter", "tasklist"]

    static func render(_ source: String) -> RenderedMarkdown {
        cmark_gfm_core_extensions_ensure_registered()
        guard let parser = cmark_parser_new(options) else { return RenderedMarkdown() }
        defer { cmark_parser_free(parser) }
        for name in extensionNames {
            if let ext = cmark_find_syntax_extension(name) {
                cmark_parser_attach_syntax_extension(parser, ext)
            }
        }
        preprocess(source).withCString { cmark_parser_feed(parser, $0, strlen($0)) }
        guard let doc = cmark_parser_finish(parser) else { return RenderedMarkdown() }
        defer { cmark_node_free(doc) }

        var result = RenderedMarkdown()
        let anchors = collectOutlineAndCount(doc, into: &result)
        result.anchors = Dictionary(anchors.map { ($1, $0) }, uniquingKeysWith: min)
        if let cHTML = cmark_render_html(doc, options, cmark_parser_get_syntax_extensions(parser)) {
            result.html = cHTML.withMemoryRebound(to: UInt8.self, capacity: 1) { bytes in
                postprocess(UnsafeBufferPointer(start: bytes, count: strlen(cHTML)), anchors: anchors)
            }
            free(cHTML)
        }
        if let count = frontMatterLineCount(source) {
            let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
            result.html = frontMatterHTML(Array(lines[1..<(count - 1)]), lineCount: count) + result.html
        }
        return result
    }

    /// 空白・改行を除いた書記素の数。
    static func countChars(_ text: some StringProtocol) -> Int {
        text.reduce(0) { $1.isWhitespace ? $0 : $0 + 1 }
    }

    /// リンクの `#fragment` が指す見出しの行。GitHub の slug（`user-content-` 付きも）をそのまま探し、
    /// 無ければ見出しの文字を書いたもの（`#はじめに 2` など）とみなして slug にして探す。
    static func headingLine(forFragment fragment: String, anchors: [String: Int]) -> Int? {
        let id = fragment.hasPrefix("user-content-") ? String(fragment.dropFirst("user-content-".count)) : fragment
        return anchors[id] ?? anchors[Slugger.slug(id)]
    }

    // MARK: - AST 走査

    /// 文字数は TEXT とインライン CODE だけを数える（コードブロック・URL・画像の alt・生HTMLは除外）。
    /// 見出しのアンカー（開始行 → slug）を返す。
    private static func collectOutlineAndCount(
        _ doc: UnsafeMutablePointer<cmark_node>, into result: inout RenderedMarkdown
    ) -> [Int: String] {
        guard let iter = cmark_iter_new(doc) else { return [:] }
        defer { cmark_iter_free(iter) }
        var heading: (level: Int, line: Int, title: String)?
        var imageDepth = 0
        var anchors: [Int: String] = [:]
        var slugger = Slugger()

        while true {
            let event = cmark_iter_next(iter)
            if event == CMARK_EVENT_DONE { break }
            guard let node = cmark_iter_get_node(iter) else { continue }
            let entering = event == CMARK_EVENT_ENTER

            switch cmark_node_get_type(node) {
            case CMARK_NODE_HEADING:
                if entering {
                    heading = (Int(cmark_node_get_heading_level(node)), Int(cmark_node_get_start_line(node)), "")
                } else if let h = heading {
                    let title = h.title.trimmingCharacters(in: .whitespaces)
                    result.outline.append(OutlineItem(level: h.level, title: title.isEmpty ? "（無題）" : title, line: h.line))
                    let anchor = slugger.slug(h.title)
                    if !anchor.isEmpty { anchors[h.line] = anchor }
                    heading = nil
                }
            case CMARK_NODE_IMAGE:
                imageDepth += entering ? 1 : -1
            case CMARK_NODE_TEXT, CMARK_NODE_CODE:
                guard imageDepth == 0, let literal = cmark_node_get_literal(node) else { break }
                let text = String(cString: literal)
                result.charCount += countChars(text)
                heading?.title += text
            default:
                break
            }
        }
        return anchors
    }

    // MARK: - GitHub のアラート

    // MARK: - HTML の書き換え

    /// cmark が出力した HTML を書き換える。大きな文書（1MB で HTML は約 2.5MB）でも速いよう、`<` の位置だけを memchr で拾い、
    /// バイト列のまま1回の走査で行う（Swift の Regex で何度も置き換えると数百 ms かかったため）。
    /// - 表を `<div class="table-wrap">` で包む（表単体で横スクロールさせる）。
    /// - 見出しに GitHub と同じ id を付ける（文書内の `[目次](#概要)` を効かせるため）。GitHub と同じく接頭辞を付け、
    ///   外枠の要素の id（content など）とぶつからないようにする。
    /// - `> [!NOTE]` のように、引用の最初の行がアラートの記号だけの引用を GitHub と同じアラートの枠にする（cmark-gfm は
    ///   対応していない）。記号の行は見出し（種類の名前）に置き換える。記号の後に続く行があれば同じ段落に残す。
    static func postprocess(_ html: UnsafeBufferPointer<UInt8>, anchors: [Int: String]) -> String {
        guard let base = html.baseAddress else { return "" }
        var out: [UInt8] = []
        out.reserveCapacity(html.count + html.count / 8)
        var copied = 0  // html のここまでを out に写した

        func matches(_ literal: StaticString, at index: Int) -> Bool {
            let length = literal.utf8CodeUnitCount
            return index + length <= html.count && memcmp(base + index, literal.utf8Start, length) == 0
        }
        func copy(upTo index: Int) {
            out.append(contentsOf: UnsafeBufferPointer(start: base + copied, count: index - copied))
            copied = index
        }
        /// index から `"` の手前までの位置（無ければ nil）
        func quoteEnd(from index: Int) -> Int? {
            guard index < html.count, let found = memchr(base + index, Int32(UInt8(ascii: "\"")), html.count - index) else { return nil }
            return base.distance(to: found.assumingMemoryBound(to: UInt8.self))
        }
        func text(_ range: Range<Int>) -> String {
            String(decoding: UnsafeBufferPointer(start: base + range.lowerBound, count: range.count), as: UTF8.self)
        }

        var i = 0
        while i < html.count, let found = memchr(base + i, Int32(UInt8(ascii: "<")), html.count - i) {
            i = base.distance(to: found.assumingMemoryBound(to: UInt8.self))
            if matches("<table", at: i) {
                copy(upTo: i)
                out.append(contentsOf: #"<div class="table-wrap">"#.utf8)
                i += 6
            } else if matches("</table>", at: i) {
                i += 8
                copy(upTo: i)
                out.append(contentsOf: "</div>".utf8)
            } else if matches("<h", at: i), i + 2 < html.count, (UInt8(ascii: "1")...UInt8(ascii: "6")).contains(html[i + 2]),
                      matches(#" data-sourcepos=""#, at: i + 3) {
                var end = i + 20
                var line = 0
                while end < html.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(html[end]) {
                    line = line * 10 + Int(html[end] - UInt8(ascii: "0"))
                    end += 1
                }
                if end > i + 20, end < html.count, html[end] == UInt8(ascii: ":"), let anchor = anchors[line] {
                    copy(upTo: i + 3)
                    out.append(contentsOf: #" id="user-content-\#(anchor)""#.utf8)
                }
                i += 3
            } else if matches(#"<blockquote data-sourcepos=""#, at: i), let alert = alert(at: i) {
                copy(upTo: i)
                out.append(contentsOf: alert.replacement.utf8)
                i = alert.end
                copied = i
            } else {
                i += 1
            }
        }
        copy(upTo: html.count)
        return String(decoding: out, as: UTF8.self)

        /// `<blockquote data-sourcepos="A">\n<p data-sourcepos="B">[!KIND]` に続けて改行か `</p>\n`。
        func alert(at start: Int) -> (replacement: String, end: Int)? {
            let quoteStart = start + 28
            guard let quoteClose = quoteEnd(from: quoteStart), matches("\">\n<p data-sourcepos=\"", at: quoteClose),
                  let paragraphClose = quoteEnd(from: quoteClose + 22), matches("\">[!", at: paragraphClose) else { return nil }
            let kindStart = paragraphClose + 4
            var kindEnd = kindStart
            while kindEnd < html.count, kindEnd - kindStart <= 9, html[kindEnd] != UInt8(ascii: "]") { kindEnd += 1 }
            let kind = text(kindStart..<kindEnd).lowercased()
            guard kindEnd < html.count, let title = alertTitles[kind] else { return nil }
            let open = #"<blockquote class="alert alert-\#(kind)" data-sourcepos="\#(text(quoteStart..<quoteClose))">"#
                + "\n<p class=\"alert-title\">\(title)</p>\n"
            if matches("]\n", at: kindEnd) {
                return (open + #"<p data-sourcepos="\#(text((quoteClose + 22)..<paragraphClose))">"#, kindEnd + 2)
            }
            if matches("]</p>\n", at: kindEnd) {
                return (open, kindEnd + 6)
            }
            return nil
        }
    }

    private static let alertTitles = ["note": "メモ", "tip": "ヒント", "important": "重要", "warning": "警告", "caution": "注意"]

    // MARK: - フロントマター

    /// YAML のトップレベルの `key: value` の行（Regex は Sendable ではないが、変更しないので共有してよい）
    nonisolated(unsafe) private static let yamlField = /([^\s#:\-][^:]*?)[ \t]*:(?:[ \t]+(.*))?/

    /// 先頭の YAML フロントマター（1行目の `---` から、次の `---` か `...` まで）の行数（区切りの行を含む）。
    /// 水平線で始まる文書を取り違えないよう、中身の最初の行が `key:` の形のときだけフロントマターとみなす。
    static func frontMatterLineCount(_ source: String) -> Int? {
        guard source.hasPrefix("---") else { return nil }
        var count = 0
        var sawField = false
        var rest = source[...]
        while true {
            let end = rest.firstIndex(of: "\n") ?? rest.endIndex
            let line = rest[..<end].replacing(/[ \t]+$/, with: "")
            count += 1
            if count == 1 {
                guard line == "---" else { return nil }
            } else if line == "---" || line == "..." {
                return sawField ? count : nil
            } else if !sawField && !line.isEmpty {
                guard line.wholeMatch(of: yamlField) != nil else { return nil }
                sawField = true
            }
            guard end < rest.endIndex else { return nil }
            rest = rest[rest.index(after: end)...]
        }
    }

    /// フロントマターのトップレベルの項目。続きの行（字下げした行・リスト）は直前の項目の値に加える。
    /// YAML を正しく解釈するのではなく、読むための見せ方を整えるだけ。
    static func frontMatterFields(_ lines: [Substring]) -> [(key: String, value: String)] {
        var fields: [(key: String, value: String)] = []
        for line in lines {
            if let match = line.wholeMatch(of: yamlField) {
                var value = String(match.2 ?? "").trimmingCharacters(in: .whitespaces)
                if ["|", "|-", "|+", ">", ">-", ">+"].contains(value) {
                    value = ""  // ブロックの書き方の記号は見せない
                } else if value.count >= 2, let quote = value.first, quote == "\"" || quote == "'", value.last == quote {
                    value = String(value.dropFirst().dropLast())
                }
                fields.append((String(match.1), value))
            } else if !fields.isEmpty, !line.allSatisfy(\.isWhitespace) {
                let continuation = line.trimmingCharacters(in: .whitespaces)
                fields[fields.count - 1].value += fields[fields.count - 1].value.isEmpty ? continuation : "\n" + continuation
            }
        }
        return fields
    }

    /// 折りたたんだ「フロントマター」。閉じている間は項目名だけを出す。
    private static func frontMatterHTML(_ lines: [Substring], lineCount: Int) -> String {
        let fields = frontMatterFields(lines)
        let keys = fields.map { escapeHTML($0.key) }.joined(separator: " · ")
        let rows = fields.map { "<dt>\(escapeHTML($0.key))</dt><dd>\(escapeHTML($0.value))</dd>" }.joined()
        return "<details class=\"front-matter\" data-sourcepos=\"1:1-\(lineCount):3\">"
            + "<summary>フロントマター<span class=\"fm-keys\">\(keys)</span></summary>"
            + "<dl>\(rows)</dl></details>\n"
    }

    private static func escapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    // MARK: - 前処理（行数は変えない。コードフェンスの中はスキップする）

    static func preprocess(_ source: String) -> String {
        // フロントマターは cmark に渡さない（水平線と見出しになってしまう）。行番号がずれないよう空行にする。
        let frontMatter = frontMatterLineCount(source) ?? 0
        // 直すもの（全角スペース・`**`・数式の `$`）が無ければそのまま渡す（大きな文書で行ごとに調べない）
        guard frontMatter > 0 || contains(source[...], "\u{3000}") || contains(source[...], "**")
                || contains(source[...], "$") else { return source }
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        var openFence: (char: Character, count: Int)?
        var mathBlockEnd: Int?  // `$$` だけの行で囲んだ数式の、閉じ側の行
        var out = ""
        out.reserveCapacity(source.utf8.count + 64)
        for (index, line) in lines.enumerated() {
            if index > 0 { out += "\n" }
            if index < frontMatter {
                continue
            } else if let end = mathBlockEnd {
                // 数式のブロックはコードフェンス（```math）にして、中身を Markdown として読ませない
                if index == end {
                    out += mathFence(line, opening: false)
                    mathBlockEnd = nil
                } else {
                    out += line
                }
            } else if let fence = fence(in: line) {
                if let open = openFence {
                    if fence.char == open.char, fence.count >= open.count, fence.bare { openFence = nil }
                } else {
                    openFence = (fence.char, fence.count)
                }
                out += line
            } else if openFence != nil {
                out += line
            } else if isMathDelimiter(line),
                      let end = lines[(index + 1)...].firstIndex(where: { isMathDelimiter($0) || fence(in: $0) != nil }),
                      isMathDelimiter(lines[end]) {
                out += mathFence(line, opening: true)
                mathBlockEnd = end
            } else {
                var fixed = contains(line, "$") ? protectMath(String(line)) : String(line)
                if contains(line, "\u{3000}") || contains(line, "**") {
                    fixed = fixJapaneseBold(rescueFullwidthMarker(fixed))
                }
                out += fixed
            }
        }
        return out
    }

    // MARK: - 数式（GitHub と同じ書き方。描くのはプレビューの KaTeX）

    /// `$$` だけの行（数式のブロックの区切り。リストや引用の中でも拾えるように、先頭の空白と `>` は無視する）。
    private static func isMathDelimiter(_ line: Substring) -> Bool {
        line.drop { $0 == " " || $0 == "\t" || $0 == ">" }.trimmingCharacters(in: .whitespaces) == "$$"
    }

    /// `$$` の行を ```math のフェンスにする（先頭の空白と `>` は残す）。
    private static func mathFence(_ line: Substring, opening: Bool) -> String {
        let prefix = line.prefix { $0 == " " || $0 == "\t" || $0 == ">" }
        return prefix + (opening ? "```math" : "```")
    }

    /// 行の中の数式（`$…$`・`$$…$$`・`` $`…`$ ``）を、中身を属性に入れた空の span にする。
    /// 属性の中は Markdown として読まれない（`_` が斜体になったり `\\` が減ったりしない）。
    /// `$` の規則は Pandoc・GitHub と同じ：開く `$` の後と閉じる `$` の前は空白でなく、閉じる `$` の後は数字でない
    /// （`$5 と $10` のような金額を数式にしない）。インラインコードの中と `\$` は数式にしない。
    static func protectMath(_ line: String) -> String {
        let chars = Array(line)
        var out = ""
        var changed = false
        var i = 0
        while i < chars.count {
            switch chars[i] {
            case "\\":
                out.append(chars[i])
                if i + 1 < chars.count { out.append(chars[i + 1]) }
                i += 2
            case "`":
                let n = runLength(chars, at: i)
                let end = closingBackticks(chars, from: i + n, length: n).map { $0 + n } ?? i + n
                out += String(chars[i..<end])
                i = end
            case "$":
                if let (tex, display, end) = math(in: chars, at: i) {
                    out += "<span class=\"\(display ? "math math-display" : "math")\" data-tex=\"\(attributeEscaped(tex))\"></span>"
                    changed = true
                    i = end
                } else {
                    out.append(chars[i])
                    i += 1
                }
            default:
                out.append(chars[i])
                i += 1
            }
        }
        return changed ? out : line
    }

    /// i の `$` から始まる数式の中身と、表示用（`$$`）か、数式の後ろの位置。
    private static func math(in chars: [Character], at i: Int) -> (String, display: Bool, end: Int)? {
        let next = i + 1 < chars.count ? chars[i + 1] : nil
        if next == "`" {
            // $`…`$（GitHub の書き方。中身に `$` を書ける）
            let n = runLength(chars, at: i + 1)
            guard let close = closingBackticks(chars, from: i + 1 + n, length: n),
                  close + n < chars.count, chars[close + n] == "$", close > i + 1 + n else { return nil }
            return (String(chars[(i + 1 + n)..<close]), false, close + n + 1)
        }
        if next == "$" {
            // $$…$$（行の中の表示用の数式）
            var j = i + 2
            while j + 1 < chars.count {
                if chars[j] == "\\" { j += 2; continue }
                if chars[j] == "`" { return nil }
                if chars[j] == "$" && chars[j + 1] == "$" {
                    let tex = String(chars[(i + 2)..<j])
                    return tex.trimmingCharacters(in: .whitespaces).isEmpty ? nil : (tex, true, j + 2)
                }
                j += 1
            }
            return nil
        }
        guard let next, !next.isWhitespace else { return nil }
        var j = i + 1
        while j < chars.count {
            if chars[j] == "\\" { j += 2; continue }
            // インラインコードの中の `$` を閉じ側にしない（`$5 と `$x$`` を数式にしない）
            if chars[j] == "`" { return nil }
            if chars[j] == "$" {
                let after = j + 1 < chars.count ? chars[j + 1] : nil
                if j > i + 1, !chars[j - 1].isWhitespace, !(after?.isASCII == true && after?.isNumber == true) {
                    return (String(chars[(i + 1)..<j]), false, j + 1)
                }
            }
            j += 1
        }
        return nil
    }

    /// 属性の値に入れる。`|`（表のセルの区切り）・`*`（太字の補正）・`` ` ``（インラインコード）も文字参照にして、
    /// cmark とこのファイルの前処理に記号として読ませない。
    private static func attributeEscaped(_ text: String) -> String {
        var out = ""
        for c in text {
            switch c {
            case "&": out += "&amp;"
            case "\"": out += "&quot;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "|": out += "&#124;"
            case "*": out += "&#42;"
            case "`": out += "&#96;"
            default: out.append(c)
            }
        }
        return out
    }

    /// バイト列で探す（Character 単位の contains は大きな文書では遅いため）。
    private static func contains(_ text: Substring, _ pattern: StaticString) -> Bool {
        let found = text.utf8.withContiguousStorageIfAvailable { buffer in
            guard let base = buffer.baseAddress else { return false }
            return memmem(base, buffer.count, pattern.utf8Start, pattern.utf8CodeUnitCount) != nil
        }
        return found ?? text.contains(String(describing: pattern))
    }

    /// ``` / ~~~ のフェンス行。リストや引用の中でも拾えるように、先頭の空白と `>` は無視する。
    private static func fence(in line: Substring) -> (char: Character, count: Int, bare: Bool)? {
        let body = line.drop { $0 == " " || $0 == "\t" || $0 == ">" }
        guard let char = body.first, char == "`" || char == "~" else { return nil }
        let count = body.prefix { $0 == char }.count
        guard count >= 3 else { return nil }
        let rest = body.dropFirst(count)
        if char == "`" && rest.contains("`") { return nil }
        return (char, count, rest.allSatisfy(\.isWhitespace))
    }

    /// 行頭の `#　見出し` `-　項目` `1.　項目` の全角スペースを半角にして、見出し・リストとして認識させる。
    static func rescueFullwidthMarker(_ line: String) -> String {
        guard line.contains("\u{3000}") else { return line }
        return line.replacing(/^([ \t]*(?:#{1,6}|[-*+]|\d{1,9}[.)]))\u{3000}/) { "\($0.1) " }
    }

    /// `**「重要」**な点` のように CommonMark の flanking 規則で太字にならない `**` の組を `<strong>` に置き換える。
    /// cmark が正しく扱える組には触れない。
    static func fixJapaneseBold(_ line: String) -> String {
        guard line.contains("**") else { return line }
        let chars = Array(line)
        var runs: [Int] = []  // ちょうど2個の `*` の連なりの開始位置
        var i = 0
        while i < chars.count {
            switch chars[i] {
            case "\\":
                i += 2
            case "`":
                let n = runLength(chars, at: i)
                i = closingBackticks(chars, from: i + n, length: n).map { $0 + n } ?? i + n
            case "*":
                let n = runLength(chars, at: i)
                if n == 2 { runs.append(i) }
                i += n
            default:
                i += 1
            }
        }
        guard runs.count >= 2, runs.count.isMultiple(of: 2) else { return line }

        var replacements: [Int: String] = [:]
        for k in stride(from: 0, to: runs.count, by: 2) {
            let open = runs[k], close = runs[k + 1]
            let inner = chars[(open + 2)..<close]
            guard let first = inner.first, let last = inner.last,
                  !first.isWhitespace, !last.isWhitespace, !inner.contains("|") else { continue }
            let before = open > 0 ? chars[open - 1] : nil
            let after = close + 2 < chars.count ? chars[close + 2] : nil
            let canOpen = !isPunctuation(first) || before.map { $0.isWhitespace || isPunctuation($0) } ?? true
            let canClose = !isPunctuation(last) || after.map { $0.isWhitespace || isPunctuation($0) } ?? true
            if canOpen && canClose { continue }
            replacements[open] = "<strong>"
            replacements[close] = "</strong>"
        }
        guard !replacements.isEmpty else { return line }

        var out = ""
        i = 0
        while i < chars.count {
            if let tag = replacements[i] {
                out += tag
                i += 2
            } else {
                out.append(chars[i])
                i += 1
            }
        }
        return out
    }

    private static func runLength(_ chars: [Character], at start: Int) -> Int {
        var end = start
        while end < chars.count && chars[end] == chars[start] { end += 1 }
        return end - start
    }

    /// インラインコードの閉じ側（同じ長さのバッククォート列）の位置。
    private static func closingBackticks(_ chars: [Character], from start: Int, length: Int) -> Int? {
        var i = start
        while i < chars.count {
            if chars[i] == "`" {
                let n = runLength(chars, at: i)
                if n == length { return i }
                i += n
            } else {
                i += 1
            }
        }
        return nil
    }

    /// CommonMark の「Unicode 句読点」。新しい仕様に合わせて記号（S*）も含める。
    /// 含めすぎても、cmark が扱える組を `<strong>` に置き換えるだけなので結果は変わらない。
    private static func isPunctuation(_ c: Character) -> Bool {
        guard let scalar = c.unicodeScalars.first else { return false }
        switch scalar.properties.generalCategory {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation,
             .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
            return true
        default:
            return false
        }
    }
}

/// 見出しのアンカー。GitHub（github-slugger）と同じ規則にして、GitHub 向けに書かれた `#見出し` のリンクを効かせる。
struct Slugger {
    private var occurrences: [String: Int] = [:]

    /// 小文字にし、文字・結合文字・数字・連結符（_）・空白・ハイフン以外を取り除き、空白をハイフンにする。
    /// 同じ slug が続いたら `-1` `-2` を付ける。
    mutating func slug(_ text: String) -> String {
        let base = Self.slug(text)
        var result = base
        while occurrences[result] != nil {
            occurrences[base, default: 0] += 1
            result = "\(base)-\(occurrences[base]!)"
        }
        occurrences[result] = 0
        return result
    }

    static func slug(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.lowercased().unicodeScalars {
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .nonspacingMark, .spacingMark, .enclosingMark,
                 .decimalNumber, .letterNumber, .otherNumber, .connectorPunctuation:
                scalars.append(scalar)
            default:
                if scalar == " " || scalar == "-" { scalars.append("-") }
            }
        }
        return String(scalars)
    }
}
