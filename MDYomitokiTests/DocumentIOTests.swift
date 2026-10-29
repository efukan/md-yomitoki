import AppKit
import Foundation
import Testing
@testable import MDYomitoki

struct DocumentIOTests {
    private func roundTrip(_ data: Data) throws -> (String, FileFormat, Data) {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".md")
        defer { try? FileManager.default.removeItem(at: url) }
        try data.write(to: url)
        let (text, format) = try DocumentModel.readText(at: url)
        return (text, format, try format.encode(text))
    }

    @Test func crlfAndBomArePreservedOnSave() throws {
        let original = Data("\u{FEFF}# 見出し\r\n本文\r\n".utf8)
        let (text, format, saved) = try roundTrip(original)
        #expect(text == "# 見出し\n本文\n")
        #expect(format.hasBOM && format.lineEnding == "\r\n")
        #expect(saved == original)
    }

    @Test func shiftJISIsReadAndWrittenBack() throws {
        let original = "日本語のテキスト\n".data(using: .shiftJIS)!
        let (text, format, saved) = try roundTrip(original)
        #expect(text == "日本語のテキスト\n")
        #expect(format.encoding == .shiftJIS)
        #expect(saved == original)
    }

    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + name)
    }

    @Test func regularFileWithinLimitIsRead() throws {
        let url = temporaryURL(".md")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("12345".utf8).write(to: url)
        #expect(try Data(regularFileAt: url, limit: 5) == Data("12345".utf8))
        #expect(throws: FileReadRefusal.tooLarge(size: 5, limit: 4)) { try Data(regularFileAt: url, limit: 4) }
    }

    /// FIFO は書き手が現れるまで open() で固まるので、開かずに断る。
    @Test func fifoIsRejectedWithoutBlocking() throws {
        let url = temporaryURL(".md")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(mkfifo(url.path, 0o600) == 0)
        #expect(throws: FileReadRefusal.notRegularFile) { try Data(regularFileAt: url, limit: 1 << 20) }
    }

    @Test func symlinkToDeviceIsRejected() throws {
        let url = temporaryURL(".png")
        defer { try? FileManager.default.removeItem(at: url) }
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: "/dev/zero")
        #expect(throws: FileReadRefusal.notRegularFile) { try Data(regularFileAt: url, limit: 1 << 20) }
    }

    @Test func missingFileIsReportedAsNoSuchFile() {
        let error = #expect(throws: CocoaError.self) {
            try Data(regularFileAt: temporaryURL(".md"), limit: 1 << 20)
        }
        #expect(error?.code == .fileReadNoSuchFile)
    }
}

@MainActor
struct MarkdownStylerTests {
    private func styled(_ text: String) -> NSTextStorage {
        let storage = NSTextStorage(string: text, attributes: EditorStyle.base)
        MarkdownStyler.style(storage, in: NSRange(location: 0, length: storage.length))
        return storage
    }

    private func font(_ storage: NSTextStorage, at index: Int) -> NSFont? {
        storage.attribute(.font, at: index, effectiveRange: nil) as? NSFont
    }

    @Test func headingIsEnlargedIncludingFullwidthSpaceVariant() {
        let storage = styled("# 見出し\n#　全角\n本文")
        #expect(font(storage, at: 2)?.pointSize == EditorStyle.headingFont(level: 1).pointSize)
        #expect(font(storage, at: 8)?.pointSize == EditorStyle.headingFont(level: 1).pointSize)
        #expect(font(storage, at: 12)?.pointSize == EditorStyle.fontSize)
    }

    @Test func fencedCodeAndTableRowsAreMonospaced() {
        let storage = styled("```\n**not bold**\n```\n| a | b |\n本文")
        let codeFont = font(storage, at: 6)
        #expect(codeFont?.isFixedPitch == true)
        #expect(font(storage, at: 22)?.isFixedPitch == true)
        #expect(font(storage, at: storage.length - 1)?.isFixedPitch == false)
    }

    @Test func styleOfLaterRangeKnowsItIsInsideFence() {
        // 日本語は NSTextStorage がフォールバックフォントに差し替えるので、判定は英字で行う
        let storage = NSTextStorage(string: "```\ncode\n```", attributes: EditorStyle.base)
        MarkdownStyler.style(storage, in: NSRange(location: 5, length: 1))
        #expect(font(storage, at: 5)?.isFixedPitch == true)
    }
}

struct UpdateTimeTests {
    private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    @Test func recentUpdatesAreRelative() {
        #expect(UpdateTime.label(now, now: now) == "たった今")
        #expect(UpdateTime.label(now.addingTimeInterval(-59), now: now) == "たった今")
        #expect(UpdateTime.label(now.addingTimeInterval(-60), now: now) == "1分前")
        #expect(UpdateTime.label(now.addingTimeInterval(-59 * 60), now: now) == "59分前")
        // 時計のずれで未来の日時でも「たった今」
        #expect(UpdateTime.label(now.addingTimeInterval(30), now: now) == "たった今")
    }

    @Test func updatesAnHourOrMoreAgoShowTheDate() {
        for seconds: TimeInterval in [3600, 23 * 3600, 3 * 86400] {
            let label = UpdateTime.label(now.addingTimeInterval(-seconds), now: now)
            #expect(label.contains("月") && label.contains("日") && label.contains(":"), "\(label)")
        }
    }
}
