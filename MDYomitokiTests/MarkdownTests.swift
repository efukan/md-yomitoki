import Testing
@testable import MDYomitoki

struct JapaneseBoldTests {
    @Test func closingBeforeKanaIsFixed() {
        #expect(Markdown.fixJapaneseBold("**「重要」**な点") == "<strong>「重要」</strong>な点")
    }

    @Test func openingAfterKanaIsFixed() {
        #expect(Markdown.fixJapaneseBold("これは**「重要」**です") == "これは<strong>「重要」</strong>です")
    }

    @Test func pairsCmarkHandlesAreUntouched() {
        #expect(Markdown.fixJapaneseBold("あ**いう**えお") == "あ**いう**えお")
        #expect(Markdown.fixJapaneseBold("**太字** と **太字**") == "**太字** と **太字**")
    }

    @Test func codeSpansAndEscapesAreSkipped() {
        #expect(Markdown.fixJapaneseBold("`**「a」**x`") == "`**「a」**x`")
        #expect(Markdown.fixJapaneseBold("\\**「a」**x") == "\\**「a」**x")
    }

    @Test func oddOrCrossCellPairsAreSkipped() {
        #expect(Markdown.fixJapaneseBold("2**3 と **「a」**x") == "2**3 と **「a」**x")
        #expect(Markdown.fixJapaneseBold("| **「a」 | b」**x |") == "| **「a」 | b」**x |")
    }

    @Test func fencedCodeIsSkipped() {
        let source = "```\n**「a」**x\n```\n**「a」**x"
        #expect(Markdown.preprocess(source) == "```\n**「a」**x\n```\n<strong>「a」</strong>x")
    }

    @Test func mixedLineFromSample() {
        let html = Markdown.render("AIが書きがちな**「重要」**な点や、あ**いう**えお のような太字").html
        #expect(html.contains("<strong>「重要」</strong>"))
        #expect(html.contains("あ<strong>いう</strong>えお"), "\(html)")
    }

    @Test func renderedAsStrong() {
        let html = Markdown.render("本文**「重要」**です。と、あ**いう**えお").html
        #expect(html.contains("<strong>「重要」</strong>"))
        #expect(html.contains("<strong>いう</strong>"))
    }
}

struct FullwidthMarkerTests {
    @Test func headingAndListMarkersAreRescued() {
        #expect(Markdown.rescueFullwidthMarker("#　見出し") == "# 見出し")
        #expect(Markdown.rescueFullwidthMarker("-　項目") == "- 項目")
        #expect(Markdown.rescueFullwidthMarker("  1.　項目") == "  1. 項目")
        #expect(Markdown.rescueFullwidthMarker("本文　です") == "本文　です")
    }

    @Test func rescuedHeadingAppearsInOutline() {
        let outline = Markdown.render("#　見出し\n\n本文").outline
        #expect(outline == [OutlineItem(level: 1, title: "見出し", line: 1)])
    }
}

struct RenderTests {
    @Test func outlineHasLevelsAndLines() {
        let outline = Markdown.render("# A\n\n本文\n\n## B `code`\n\n### C").outline
        #expect(outline.map(\.title) == ["A", "B code", "C"])
        #expect(outline.map(\.level) == [1, 2, 3])
        #expect(outline.map(\.line) == [1, 5, 7])
    }

    @Test func charCountExcludesMarkupUrlsAndCodeBlocks() {
        let source = """
        # 見出し

        本文**「重要」**です。[リンク](https://example.com) ![画像](a.png)

        ```
        code block
        ```

        | 列A | 列B |
        |---|---|
        | 値 | `x` |
        """
        // 見出し(3) + 本文「重要」です。(9) + リンク(3) + 列A列B(4) + 値(1) + x(1)
        #expect(Markdown.render(source).charCount == 21)
    }

    @Test func tablesAreWrappedAndHaveSourcePositions() {
        let html = Markdown.render("| a | b |\n|---|---|\n| 1 | 2 |").html
        #expect(html.contains("<div class=\"table-wrap\"><table"))
        #expect(html.contains("</table></div>"))
        #expect(html.contains("data-sourcepos=\"1:1"))
    }

    @Test func dangerousTagsAreFiltered() {
        #expect(!Markdown.render("<script>alert(1)</script>").html.contains("<script>"))
    }

    @Test func countCharsIgnoresWhitespace() {
        #expect(Markdown.countChars("あ い\u{3000}う\nえ") == 4)
    }
}

struct FrontMatterTests {
    private let source = "---\nname: review\ndescription: |\n  変更を確認する\n  ２行目\ntools:\n  - Read\n---\n# 見出し\n\n本文"

    @Test func detectsFrontMatter() {
        #expect(Markdown.frontMatterLineCount(source) == 8)
        #expect(Markdown.frontMatterLineCount("---\ntitle: \"x\"\n...\n本文") == 3)
        #expect(Markdown.frontMatterLineCount("--- \n\ntitle: x\n---") == 4)
    }

    @Test func horizontalRulesAreNotFrontMatter() {
        #expect(Markdown.frontMatterLineCount("---\n# 見出し\n\n---\n") == nil)
        #expect(Markdown.frontMatterLineCount("---\n\n---\n") == nil)
        #expect(Markdown.frontMatterLineCount("---\ntitle: x\n本文") == nil)  // 閉じていない
        #expect(Markdown.frontMatterLineCount("本文\n---\ntitle: x\n---") == nil)
        #expect(Markdown.frontMatterLineCount("----\ntitle: x\n---") == nil)
    }

    @Test func fieldsJoinContinuationLines() {
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)[1..<7]
        let fields = Markdown.frontMatterFields(Array(lines))
        #expect(fields.map(\.key) == ["name", "description", "tools"])
        #expect(fields.map(\.value) == ["review", "変更を確認する\n２行目", "- Read"])
        #expect(Markdown.frontMatterFields(["title: \"引用 <符>\"", "time: 12:30"]).map(\.value) == ["引用 <符>", "12:30"])
    }

    @Test func renderedAsDetailsKeepingLineNumbers() {
        let rendered = Markdown.render(source)
        #expect(rendered.outline == [OutlineItem(level: 1, title: "見出し", line: 9)])
        #expect(rendered.charCount == 5)  // 見出し + 本文。フロントマターは数えない
        #expect(rendered.html.hasPrefix("<details class=\"front-matter\" data-sourcepos=\"1:1-8:3\">"))
        #expect(rendered.html.contains("<dt>description</dt><dd>変更を確認する\n２行目</dd>"))
        #expect(!rendered.html.contains("<hr"))
        #expect(Markdown.preprocess(source).split(separator: "\n", omittingEmptySubsequences: false).count == 11)
    }

    @Test func valuesAreEscaped() {
        let html = Markdown.render("---\ntitle: <script>alert(1)</script>\n---\n").html
        #expect(html.contains("&lt;script&gt;"))
        #expect(!html.contains("<script>"))
    }
}

struct HeadingAnchorTests {
    @Test func slugsFollowGitHub() {
        #expect(Slugger.slug("Hello World!") == "hello-world")
        #expect(Slugger.slug("概要（はじめに）") == "概要はじめに")
        #expect(Slugger.slug("Phase 2：ファイル監視") == "phase-2ファイル監視")
        #expect(Slugger.slug("snake_case と kebab-case") == "snake_case-と-kebab-case")
        #expect(Slugger.slug("🚀 Launch") == "-launch")
    }

    @Test func duplicatesGetSuffixes() {
        var slugger = Slugger()
        #expect(["a", "a", "a-1", "A"].map { slugger.slug($0) } == ["a", "a-1", "a-1-1", "a-2"])
    }

    @Test func headingsGetPrefixedIds() {
        let html = Markdown.render("# 概要\n\n## B `code`\n\n> ## 概要").html
        #expect(html.contains("<h1 id=\"user-content-概要\" data-sourcepos=\"1:1"))
        #expect(html.contains("<h2 id=\"user-content-b-code\" data-sourcepos=\"3:1"))
        #expect(html.contains("<h2 id=\"user-content-概要-1\" data-sourcepos=\"5:3"))
    }

    @Test func fragmentsFindHeadingLines() {
        let anchors = Markdown.render("# 概要\n\n## Hello World\n\n## 概要").anchors
        #expect(anchors == ["概要": 1, "hello-world": 3, "概要-1": 5])
        #expect(Markdown.headingLine(forFragment: "概要-1", anchors: anchors) == 5)
        #expect(Markdown.headingLine(forFragment: "user-content-hello-world", anchors: anchors) == 3)
        // 見出しの文字をそのまま書いたリンク
        #expect(Markdown.headingLine(forFragment: "Hello World", anchors: anchors) == 3)
        #expect(Markdown.headingLine(forFragment: "まとめ", anchors: anchors) == nil)
    }
}

struct GitHubAlertTests {
    @Test func markerLineBecomesTitle() {
        let html = Markdown.render("> [!NOTE]\n> 本文です。").html
        #expect(html.contains("<blockquote class=\"alert alert-note\" data-sourcepos=\"1:1"))
        #expect(html.contains("<p class=\"alert-title\">メモ</p>"))
        #expect(html.contains("本文です。"))
        #expect(!html.contains("[!NOTE]"))
    }

    @Test func markerAloneInParagraphIsDropped() {
        let html = Markdown.render("> [!warning]\n>\n> 気をつける").html
        #expect(html.contains("alert alert-warning"))
        #expect(html.contains("<p class=\"alert-title\">警告</p>"))
        #expect(!html.contains("[!warning]"))
        #expect(html.contains("気をつける"))
    }

    @Test func ordinaryQuotesAndInlineMarkersAreUntouched() {
        #expect(!Markdown.render("> 普通の引用").html.contains("alert"))
        // 記号の後に同じ行で本文が続くものは GitHub でもアラートにならない
        #expect(!Markdown.render("> [!TIP] 同じ行の本文").html.contains("alert"))
        #expect(!Markdown.render("> [!UNKNOWN]\n> 本文").html.contains("alert"))
    }
}

struct CodeBlockTests {
    @Test func fencedCodeKeepsLanguageClassForHighlighting() {
        let html = Markdown.render("```swift\nlet a = 1\n```").html
        #expect(html.contains("<pre data-sourcepos=\"1:1-3:3\"><code class=\"language-swift\">"))
    }
}

struct MathTests {
    private func span(_ tex: String, display: Bool = false) -> String {
        "<span class=\"\(display ? "math math-display" : "math")\" data-tex=\"\(tex)\"></span>"
    }

    @Test func inlineMathBecomesSpanWithTexInAttribute() {
        #expect(Markdown.protectMath("面積は $a_1 \\times b_1$ です") == "面積は \(span("a_1 \\times b_1")) です")
        #expect(Markdown.protectMath("$$E = mc^2$$") == span("E = mc^2", display: true))
        #expect(Markdown.protectMath("$`x$y`$") == span("x$y"))
    }

    @Test func pricesEscapesAndCodeAreNotMath() {
        #expect(Markdown.protectMath("$5 と $10") == "$5 と $10")
        #expect(Markdown.protectMath("$100〜$200") == "$100〜$200")
        #expect(Markdown.protectMath("\\$x$ と `$y$`") == "\\$x$ と `$y$`")
        #expect(Markdown.protectMath("$ x$") == "$ x$")
        // 閉じ側を探すのはインラインコードの手前まで
        #expect(Markdown.protectMath("$5 と `$x$`") == "$5 と `$x$`")
    }

    @Test func markdownSymbolsInsideMathAreEscaped() {
        // 表のセルの区切り・太字の補正・インラインコードに読まれない
        #expect(Markdown.protectMath("$|x| * y$") == span("&#124;x&#124; &#42; y"))
        #expect(Markdown.protectMath("$``a`b``$") == span("a&#96;b"))
        let html = Markdown.render("| a |\n|---|\n| $|x|$ |").html
        #expect(html.contains("data-tex=\"&#124;x&#124;\""))
        #expect(!Markdown.render("$a_1 + b_1$ と $c_1$").html.contains("<em>"))
    }

    @Test func dollarBlockBecomesMathFenceWithSameLineCount() {
        let source = "前\n$$\n\\frac{a}{b}\n$$\n後"
        let processed = Markdown.preprocess(source)
        #expect(processed == "前\n```math\n\\frac{a}{b}\n```\n後")
        #expect(Markdown.render(source).html.contains("<code class=\"language-math\">\\frac{a}{b}\n</code>"))
        // 閉じる `$$` が無ければそのまま
        #expect(Markdown.preprocess("$$\nx") == "$$\nx")
        // コードブロックの中は数式にしない
        #expect(Markdown.preprocess("```\n$x$\n$$\n```") == "```\n$x$\n$$\n```")
    }
}
