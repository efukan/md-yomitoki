import Foundation
import JavaScriptCore
import QuickLookUI
import UniformTypeIdentifiers

/// Finder のスペースキー（Quick Look）で Markdown を整えて見せる機能拡張。
/// HTML を作って渡すだけで、表示は macOS がする（軽くて速い。スクリプトは動かさない）。
final class PreviewProvider: QLPreviewProvider, QLPreviewingController {
    func providePreview(for request: QLFilePreviewRequest) async throws -> QLPreviewReply {
        let html = try QuickLookPage.html(for: request.fileURL)
        return QLPreviewReply(dataOfContentType: .html, contentSize: CGSize(width: 820, height: 1000)) { _ in
            Data(html.utf8)
        }
    }
}

/// Quick Look に渡す HTML。Markdown の変換（日本語の太字の補正・表・アラート・フロントマター）はアプリと同じ
/// `Markdown.swift`、見た目はアプリのプレビューと同じ `preview.css`。
/// - Sandbox の中なので、隣の画像は読めない。ネットにもつながない（見ただけで外に通信しない）。画像は代替テキストにする。
/// - コードの色付けは、アプリと同じ highlight.js を JavaScriptCore で動かして HTML にしておく。Mermaid の図と数式は描かない（書いたまま見せる）。
enum QuickLookPage {
    /// アプリと同じく、これより大きいファイルは読まない（Quick Look は既定の表示になる）
    static let maxFileSize: Int64 = 10_000_000
    /// 描くのは先頭のこれだけ（Quick Look には時間の制限がある）
    static let maxRenderedBytes = 1_000_000
    /// コードの色付けはこれだけ（機能拡張の中の JavaScriptCore は JIT が使えず遅い）
    static let maxHighlightedBytes = 300_000

    static func html(for url: URL) throws -> String {
        let (whole, _) = try TextFile.decode(try Data(regularFileAt: url, limit: maxFileSize))
        let (text, truncated) = head(of: whole)
        let body = highlightCode(showMathSource(replaceImages(defuse(Markdown.render(text).html))))
        let css = Bundle.main.url(forResource: "preview", withExtension: "css")
            .flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "MDよみとき"
        let note = truncated
            ? "<p class=\"ql-note\">大きなファイルなので、先頭の一部だけを表示しています。すべてを見るには \(appName) で開いてください。</p>\n"
            : ""
        return """
            <!doctype html>
            <html lang="ja">
            <head>
            <meta charset="utf-8">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:">
            <style>
            \(css)
            \(extraCSS)
            </style>
            </head>
            <body><div id="content">
            \(note)\(body)
            </div></body>
            </html>
            """
    }

    private static let extraCSS = """
        /* Quick Look 用：背景を付け、余白を詰める */
        html { background: -apple-system-text-background; }
        #content { padding: 20px 28px 40px; }
        .ql-note {
          color: var(--text-secondary);
          font-size: 13px;
          border-left: 3px solid var(--separator);
          padding-left: 10px;
        }
        .ql-image {
          color: var(--text-secondary);
          font-size: 0.9em;
          border: 1px dashed var(--separator);
          border-radius: 4px;
          padding: 0 6px;
        }
        """

    /// 先頭の `maxRenderedBytes` まで（行の途中では切らない）。
    static func head(of text: String) -> (String, truncated: Bool) {
        let utf8 = text.utf8
        guard utf8.count > maxRenderedBytes else { return (text, false) }
        let limit = utf8.index(utf8.startIndex, offsetBy: maxRenderedBytes)
        let end = utf8[..<limit].lastIndex(of: UInt8(ascii: "\n")) ?? limit
        return (String(text[..<end]), true)
    }

    /// 文書の生 HTML のうち、ページの外へ働きかけるタグ（meta refresh・base・link など）を文字にする。
    /// スクリプト・外部の読み込みは Content-Security-Policy で止めている。
    static func defuse(_ html: String) -> String {
        html.replacing(/<(\/?)(meta|base|link|object|embed|form)\b/.ignoresCase()) { "&lt;\($0.1)\($0.2)" }
    }

    /// 画像は読めない（Sandbox・ネットにつながない）ので、代替テキストを枠で見せる。
    static func replaceImages(_ html: String) -> String {
        html.replacing(/<img\b[^>]*>/.ignoresCase()) { match in
            let alt = match.output.firstMatch(of: /\balt="([^"]*)"/)?.output.1 ?? ""
            return "<span class=\"ql-image\">画像\(alt.isEmpty ? "" : "：\(alt)")</span>"
        }
    }

    /// 数式（`Markdown.protectMath` が作る空の span）は描かないので、書いたままの式をコードとして見せる。
    static func showMathSource(_ html: String) -> String {
        html.replacing(/<span class="math( math-display)?" data-tex="([^"]*)"><\/span>/) { match in
            let dollars = match.output.1 == nil ? "$" : "$$"
            return "<code>\(dollars)\(match.output.2)\(dollars)</code>"
        }
    }

    /// 言語の書かれたコードブロック（`language-xxx`）だけを、アプリと同じ highlight.js で色付けする（推測はしない）。
    static func highlightCode(_ html: String) -> String {
        guard html.contains("class=\"language-"),
              let url = Bundle.main.url(forResource: "highlight.min", withExtension: "js"),
              let script = try? String(contentsOf: url, encoding: .utf8),
              let context = JSContext() else { return html }
        context.evaluateScript(script)
        guard let hljs = context.objectForKeyedSubscript("hljs"), hljs.isObject else { return html }

        var budget = maxHighlightedBytes
        return html.replacing(/(<code class="language-([^"\s]+)"[^>]*>)([\s\S]*?)(<\/code>)/) { match in
            let (_, open, language, escaped, close) = match.output
            let code = unescapeHTML(String(escaped))
            guard budget >= code.utf8.count,
                  hljs.invokeMethod("getLanguage", withArguments: [String(language)])?.isObject == true,
                  let options = JSValue(object: ["language": String(language), "ignoreIllegals": true], in: context),
                  let value = hljs.invokeMethod("highlight", withArguments: [code, options])?.forProperty("value"),
                  value.isString else { return String(match.output.0) }
            budget -= code.utf8.count
            return "\(open)\(value.toString() ?? "")\(close)"
        }
    }

    /// cmark が書き出すエスケープ（& < > "）を戻す。
    private static func unescapeHTML(_ text: String) -> String {
        text.replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
