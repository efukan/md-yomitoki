import Foundation

// ファイルの読み込み（文字コードの判別・大きさの上限）。アプリと Quick Look の機能拡張で共通に使う。

enum TextFile {
    /// UTF-8（BOM は除去）→ Shift_JIS の順に試す。改行は LF に正規化する。
    static func decode(_ fileData: Data) throws -> (String, FileFormat) {
        var data = fileData
        var format = FileFormat()
        // Foundation の UTF-8 デコードは BOM を黙って取り除くので、バイト列で判定する
        if data.starts(with: [0xEF, 0xBB, 0xBF]) {
            format.hasBOM = true
            data.removeFirst(3)
        }
        let text: String
        if let utf8 = String(data: data, encoding: .utf8) {
            text = utf8
        } else if let sjis = String(data: data, encoding: .shiftJIS) {
            text = sjis
            format.encoding = .shiftJIS
        } else {
            throw FileReadRefusal.unsupportedEncoding
        }
        if text.utf8.contains(13) { format.lineEnding = "\r\n" }
        let normalized = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        return (normalized, format)
    }
}

extension Data {
    /// 通常のファイルだけを、上限の大きさまで読む。FIFO で固まったり、/dev/zero へのシンボリックリンクや
    /// 巨大なファイルでメモリを使い果たしたりしないよう、開いた記述子で種類と大きさを確かめてから読む。
    nonisolated init(regularFileAt url: URL, limit: Int64) throws {
        // O_NONBLOCK：FIFO は open() の時点で書き手を待って固まるため（通常のファイルの読み込みには影響しない）
        let fd = open(url.path, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            let code: CocoaError.Code = switch errno {
            case ENOENT: .fileReadNoSuchFile
            case EACCES, EPERM: .fileReadNoPermission
            default: .fileReadUnknown
            }
            throw CocoaError(code, userInfo: [NSFilePathErrorKey: url.path])
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            throw CocoaError(.fileReadUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
        guard info.st_mode & S_IFMT == S_IFREG else { throw FileReadRefusal.notRegularFile }
        guard info.st_size <= limit else { throw FileReadRefusal.tooLarge(size: info.st_size, limit: limit) }
        // 読んでいる間に書き足されても上限を超えて読まない
        let data = try handle.read(upToCount: Int(limit) + 1) ?? Data()
        guard data.count <= limit else { throw FileReadRefusal.tooLarge(size: Int64(data.count), limit: limit) }
        self = data
    }
}

/// 読み込まないファイルの理由。画面にそのまま出す。
enum FileReadRefusal: LocalizedError, Equatable {
    case notRegularFile
    case tooLarge(size: Int64, limit: Int64)
    case unsupportedEncoding

    var errorDescription: String? {
        switch self {
        case .notRegularFile:
            "通常のファイルではありません（名前付きパイプやデバイスなどは開けません）。"
        case .tooLarge(let size, let limit):
            "ファイルが大きすぎます（\(Self.format(size))）。開けるのは \(Self.format(limit)) までです。"
        case .unsupportedEncoding:
            "文字コードを判別できませんでした（UTF-8 と Shift_JIS に対応しています）。"
        }
    }

    private static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// 読み込んだファイルの文字コード・改行コード・BOM。保存時に元の形式へ戻すために覚えておく。
struct FileFormat: Equatable {
    var encoding = String.Encoding.utf8
    var lineEnding = "\n"
    var hasBOM = false

    func encode(_ text: String) throws -> Data {
        var output = lineEnding == "\n" ? text : text.replacingOccurrences(of: "\n", with: lineEnding)
        if hasBOM { output = "\u{FEFF}" + output }
        guard let data = output.data(using: encoding) else {
            throw CocoaError(.fileWriteInapplicableStringEncoding)
        }
        return data
    }
}
