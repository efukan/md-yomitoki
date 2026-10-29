import Foundation
import Testing
@testable import MDYomitoki

struct FuzzySearchTests {
    private func matches(_ query: String, in text: String) -> [String] {
        let ns = text as NSString
        return NormalizedText(text).ranges(of: query).map { ns.substring(with: $0) }
    }

    @Test func hiraganaAndKatakanaMatchEachOther() {
        #expect(matches("りんご", in: "リンゴとりんご") == ["リンゴ", "りんご"])
    }

    @Test func fullwidthHalfwidthAndCaseAreIgnored() {
        #expect(matches("abc123", in: "ＡＢＣ１２３ と Abc123") == ["ＡＢＣ１２３", "Abc123"])
        #expect(matches("カタカナ", in: "ｶﾀｶﾅ") == ["ｶﾀｶﾅ"])
    }

    @Test func halfwidthDakutenIsComposed() {
        #expect(matches("ガイド", in: "ｶﾞｲﾄﾞを読む") == ["ｶﾞｲﾄﾞ"])
    }

    @Test func decomposedNFDTextMatchesComposedQuery() {
        let nfd = "がぎぐ".decomposedStringWithCanonicalMapping  // macOS のファイル名などにある濁点分離
        #expect(matches("ぎ", in: nfd).count == 1)
        #expect(matches("ぎ", in: nfd).first == "ぎ".decomposedStringWithCanonicalMapping)
    }

    @Test func dakutenIsNotIgnored() {
        #expect(matches("は", in: "ばびぶ").isEmpty)
    }

    @Test func rangesAreUTF16Offsets() {
        let ranges = NormalizedText("😀あいう").ranges(of: "い")
        #expect(ranges == [NSRange(location: 3, length: 1)])
    }

    @Test func emptyQueryFindsNothing() {
        #expect(NormalizedText("abc").ranges(of: "").isEmpty)
    }
}

struct SearchReplaceTests {
    @Test func replaceSelectsReplacedText() {
        let edit = SearchReplace.replace(NSRange(location: 2, length: 3), with: "ＡＢ")
        #expect(edit == TextEdit(range: NSRange(location: 2, length: 3), replacement: "ＡＢ", selection: NSRange(location: 2, length: 2)))
    }

    @Test func replaceAllMergesIntoOneEdit() {
        let text = "あいう かな カナ えお かな"
        let ranges = NormalizedText(text).ranges(of: "かな")
        #expect(ranges.count == 3)
        let edit = try! #require(SearchReplace.replaceAll(ranges, with: "仮名", in: text))
        let result = (text as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
        #expect(result == "あいう 仮名 仮名 えお 仮名")
        #expect(edit.range == NSRange(location: 4, length: 11))
        #expect(edit.selection == NSRange(location: 4, length: 0))
    }

    @Test func replaceAllHandlesEmptyReplacementAndSurrogates() {
        let text = "😀a😀b😀"
        let ranges = NormalizedText(text).ranges(of: "😀")
        let edit = try! #require(SearchReplace.replaceAll(ranges, with: "", in: text))
        #expect((text as NSString).replacingCharacters(in: edit.range, with: edit.replacement) == "ab")
        #expect(SearchReplace.replaceAll([], with: "x", in: text) == nil)
    }
}
