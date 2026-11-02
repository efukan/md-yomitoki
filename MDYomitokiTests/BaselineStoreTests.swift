import Foundation
import Testing
@testable import MDYomitoki

struct BaselineStoreTests {
    private let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    private var store: BaselineStore { BaselineStore(directory: directory) }

    private func files(in store: BaselineStore) -> [String] {
        store.waitUntilFinished()
        return (try? FileManager.default.contentsOfDirectory(atPath: store.directory.path)) ?? []
    }

    @Test func savedTextIsLoadedPerPath() async {
        let store = store
        defer { try? FileManager.default.removeItem(at: directory) }
        store.save("# 見出し\n本文\n", for: "/a/README.md")
        store.save("別の文書\n", for: "/b/README.md")
        #expect(await store.load(for: "/a/README.md") == "# 見出し\n本文\n")
        #expect(await store.load(for: "/b/README.md") == "別の文書\n")
    }

    @Test func nothingIsLoadedWhenNeverSaved() async {
        #expect(await store.load(for: "/a.md") == nil)
    }

    @Test func emptyTextIsKeptAsABaseline() async {
        let store = store
        defer { try? FileManager.default.removeItem(at: directory) }
        store.save("", for: "/a.md")
        #expect(await store.load(for: "/a.md") == "")
    }

    @Test func savingReplacesTheText() async {
        let store = store
        defer { try? FileManager.default.removeItem(at: directory) }
        store.save("前\n", for: "/a.md")
        store.save("後\n", for: "/a.md")
        #expect(await store.load(for: "/a.md") == "後\n")
        #expect(files(in: store).count == 1)
    }

    @Test func removeAllKeepsOnlyTheGivenPaths() async {
        let store = store
        defer { try? FileManager.default.removeItem(at: directory) }
        store.save("a", for: "/a.md")
        store.save("b", for: "/b.md")
        store.save("c", for: "/c.md")
        store.removeAll(except: ["/b.md"])
        #expect(await store.load(for: "/a.md") == nil)
        #expect(await store.load(for: "/b.md") == "b")
        #expect(await store.load(for: "/c.md") == nil)
        #expect(files(in: store).count == 1)
    }

    @Test func removeAllWithNoPathsEmptiesTheFolder() {
        let store = store
        defer { try? FileManager.default.removeItem(at: directory) }
        store.save("a", for: "/a.md")
        store.removeAll(except: [String]())
        #expect(files(in: store).isEmpty)
    }

    @Test func removeAllWithoutTheFolderDoesNothing() {
        store.removeAll(except: ["/a.md"])
        #expect(files(in: store).isEmpty)
    }

    @Test func sizeLimitCountsUTF8Bytes() {
        #expect(BaselineStore.canStore(String(repeating: "a", count: BaselineStore.maxSize)))
        #expect(!BaselineStore.canStore(String(repeating: "a", count: BaselineStore.maxSize + 1)))
        // 日本語は1文字 3 バイト
        #expect(!BaselineStore.canStore(String(repeating: "あ", count: BaselineStore.maxSize / 3 + 1)))
    }

    @Test func tooLargeTextIsNotSaved() async {
        let store = store
        defer { try? FileManager.default.removeItem(at: directory) }
        store.save(String(repeating: "a", count: BaselineStore.maxSize + 1), for: "/a.md")
        #expect(await store.load(for: "/a.md") == nil)
        #expect(files(in: store).isEmpty)
    }

    // 確認済みにした時に上限を超えていたら、古い基準を残さない（次回、確認した変更がまた出てしまう）
    @Test func tooLargeTextRemovesTheEarlierCopy() async {
        let store = store
        defer { try? FileManager.default.removeItem(at: directory) }
        store.save("小さい基準\n", for: "/a.md")
        store.save(String(repeating: "a", count: BaselineStore.maxSize + 1), for: "/a.md")
        #expect(await store.load(for: "/a.md") == nil)
    }

    @Test func brokenCopyIsTreatedAsMissing() async throws {
        let store = store
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data([0xFF, 0xFE, 0x80]).write(to: store.fileURL(for: "/a.md"))
        #expect(await store.load(for: "/a.md") == nil)
    }

    @Test func longPathFitsInAFileName() async {
        let store = store
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = "/" + String(repeating: "長いフォルダ名/", count: 100) + "a.md"
        store.save("本文", for: path)
        #expect(await store.load(for: path) == "本文")
    }

    @Test func sessionPathsAreEveryTabOfEveryWindow() {
        let session = OpenFilesSession(windows: [
            .init(paths: ["/a.md", "/b.md"], selected: "/b.md"),
            .init(paths: ["/c.md"], selected: "/c.md"),
        ])
        #expect(session.paths == ["/a.md", "/b.md", "/c.md"])
    }
}
