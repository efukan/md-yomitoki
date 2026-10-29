import Foundation

/// 表記ゆれを吸収する日本語あいまい検索。
///
/// 書記素（Character）ごとに「NFKC（全角／半角の統一・濁点の合成）→ ひらがなをカタカナへ → 小文字化」を行い、
/// 正規化後の UTF-16 位置から元の UTF-16 位置への対応表を作る。照合は正規化後の文字列で行い、結果を元の範囲（NSRange）で返す。
/// NSTextView（NSString）も JS（String）も UTF-16 で位置を数えるので、どちらにもそのまま使える。
/// 作った後は変更しない（NSString も不変）ので、メインスレッドの外で作って渡してよい。
struct NormalizedText: @unchecked Sendable {
    let source: String
    private let normalized: NSString
    /// 正規化後の各 UTF-16 単位が、元のどの範囲（書記素）から来たか
    private let starts: [Int]
    private let ends: [Int]

    init(_ source: String) {
        self.source = source
        var pieces: [(text: String, start: Int, end: Int)] = []
        var offset = 0
        for character in source {
            let length = character.utf16.count
            let piece = Self.normalize(character)
            // 半角カナの濁点（ｶﾞ）は別の書記素になり、NFKC 後に結合文字だけが残る。直前の文字と合成する。
            if let last = pieces.last, piece == "\u{3099}" || piece == "\u{309A}" {
                let composed = (last.text + piece).precomposedStringWithCanonicalMapping
                if composed.unicodeScalars.count == last.text.unicodeScalars.count {
                    pieces[pieces.count - 1] = (composed, last.start, offset + length)
                    offset += length
                    continue
                }
            }
            pieces.append((piece, offset, offset + length))
            offset += length
        }

        var text = ""
        var starts: [Int] = []
        var ends: [Int] = []
        for piece in pieces {
            text += piece.text
            let count = piece.text.utf16.count
            starts.append(contentsOf: repeatElement(piece.start, count: count))
            ends.append(contentsOf: repeatElement(piece.end, count: count))
        }
        normalized = text as NSString
        self.starts = starts
        self.ends = ends
    }

    /// query に一致する元テキスト上の範囲（重ならないように先頭から順に）。
    func ranges(of query: String) -> [NSRange] {
        let needle = Self.normalizeQuery(query)
        guard !needle.isEmpty, normalized.length > 0 else { return [] }
        var result: [NSRange] = []
        var search = NSRange(location: 0, length: normalized.length)
        while true {
            let found = normalized.range(of: needle, options: .literal, range: search)
            guard found.location != NSNotFound, found.length > 0 else { break }
            let start = starts[found.location]
            let end = ends[NSMaxRange(found) - 1]
            if let last = result.last, start < NSMaxRange(last) {
                // 1つの書記素が複数文字に展開された場合などで重なったら、つなげる
                result[result.count - 1] = NSRange(location: last.location, length: max(NSMaxRange(last), end) - last.location)
            } else {
                result.append(NSRange(location: start, length: end - start))
            }
            search = NSRange(location: NSMaxRange(found), length: normalized.length - NSMaxRange(found))
        }
        return result
    }

    static func normalizeQuery(_ query: String) -> String {
        NormalizedText(query).normalized as String
    }

    private static func normalize(_ character: Character) -> String {
        if character.isASCII {
            return String(character).lowercased()
        }
        let scalars = character.unicodeScalars
        // よく出る文字（単独のかな・漢字）は NFKC で変わらないので、Foundation を呼ばずに済ませる
        if scalars.count == 1, let scalar = scalars.first, isNFKCStableKanaOrKanji(scalar.value) {
            return String(hiraganaToKatakana(scalar))
        }
        // Foundation の NFKC は ｶﾞ を「カ＋結合濁点」のまま返すので、NFC をもう一度かけて合成する
        let nfkc = String(character).precomposedStringWithCompatibilityMapping.precomposedStringWithCanonicalMapping.lowercased()
        var output = String.UnicodeScalarView()
        for scalar in nfkc.unicodeScalars { output.append(hiraganaToKatakana(scalar)) }
        return String(output)
    }

    /// ひらがな（ぁ〜ゖ）・カタカナ（ァ〜ヺ）・長音（ー）・CJK 統合漢字。濁点記号（゛゜）や ヿ などは NFKC で変わるので含めない。
    private static func isNFKCStableKanaOrKanji(_ value: UInt32) -> Bool {
        (0x3041...0x3096).contains(value) || (0x30A1...0x30FA).contains(value) || value == 0x30FC
            || (0x4E00...0x9FFF).contains(value)
    }

    /// ぁ〜ゖ・ゝゞ をカタカナへ（コードポイントが 0x60 ずれている）
    private static func hiraganaToKatakana(_ scalar: Unicode.Scalar) -> Unicode.Scalar {
        switch scalar.value {
        case 0x3041...0x3096, 0x309D...0x309E: return Unicode.Scalar(scalar.value + 0x60) ?? scalar
        default: return scalar
        }
    }
}

/// エディタの置換。範囲は検索で一致した範囲（UTF-16・文書順・重ならない）。
enum SearchReplace {
    /// 1つの一致を置き換える。置き換えた文字を選んだ状態にする。
    static func replace(_ range: NSRange, with replacement: String) -> TextEdit {
        TextEdit(range: range, replacement: replacement,
                 selection: NSRange(location: range.location, length: (replacement as NSString).length))
    }

    /// すべての一致を置き換える。最初の一致から最後の一致までを1回の置き換えにまとめる（⌘Z の1回で戻せるように）。
    /// カーソルは最初の一致の位置に置く。一致が無ければ nil。
    static func replaceAll(_ ranges: [NSRange], with replacement: String, in text: String) -> TextEdit? {
        guard let first = ranges.first, let last = ranges.last else { return nil }
        let string = text as NSString
        var result = ""
        var location = first.location
        for range in ranges {
            result += string.substring(with: NSRange(location: location, length: range.location - location))
            result += replacement
            location = NSMaxRange(range)
        }
        return TextEdit(range: NSRange(location: first.location, length: NSMaxRange(last) - first.location),
                        replacement: result, selection: NSRange(location: first.location, length: 0))
    }
}
