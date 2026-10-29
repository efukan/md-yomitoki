import Foundation
import Testing
@testable import MDYomitoki

struct RecentFilesTests {
    private func item(_ path: String, project: String = "p", pinned: Bool = false, age: TimeInterval) -> RecentFile {
        RecentFile(path: path, project: project, pinned: pinned, openedAt: Date(timeIntervalSince1970: 1_000_000 - age))
    }

    @Test func projectIsTheFolderContainingGit() {
        let url = URL(fileURLWithPath: "/Users/me/dev/md-yomitoki/docs/spec/SPEC.md")
        let name = ProjectRoot.name(for: url) { $0.path == "/Users/me/dev/md-yomitoki/.git" }
        #expect(name == "md-yomitoki")
    }

    @Test func projectFallsBackToParentFolder() {
        let url = URL(fileURLWithPath: "/Users/me/notes/memo/README.md")
        #expect(ProjectRoot.name(for: url) { _ in false } == "memo")
    }

    @Test func pinnedComeFirstAndOthersAreLimited() {
        var items = (0..<40).map { item("/f\($0).md", age: TimeInterval($0)) }
        items.append(item("/pinned-old.md", pinned: true, age: 1000))
        let arranged = RecentFiles.arranged(items)
        #expect(arranged.first?.path == "/pinned-old.md")
        #expect(arranged.count == 1 + RecentFiles.limit)
        #expect(arranged[1].path == "/f0.md")  // ピン留め以外は最近開いた順
        #expect(!arranged.contains { $0.path == "/f39.md" })  // 古いものから落ちる
    }

    @Test func queryMatchesNameProjectAndPathWithAllWords() {
        let file = item("/Users/me/dev/md-yomitoki/CLAUDE.md", project: "md-yomitoki", age: 0)
        #expect(file.matches(""))
        #expect(file.matches("claude"))
        #expect(file.matches("CLAUDE yomitoki"))
        #expect(file.matches("ｃｌａｕｄｅ"))  // 全角でも一致する
        #expect(!file.matches("claude other"))
    }
}

struct OpenFilesSessionTests {
    private let session = OpenFilesSession(
        windows: [
            .init(paths: ["/a.md", "/b.md", "/c.md"], selected: "/b.md", frame: "{{0, 0}, {800, 600}}"),
            .init(paths: ["/d.md"], selected: "/d.md", frame: nil),
        ],
        front: "/d.md"
    )

    @Test func keepsEverythingWhenAllFilesExist() {
        #expect(session.restorable(fileExists: { _ in true }) == session)
    }

    @Test func dropsMissingFilesAndFixesSelection() {
        let restored = session.restorable(fileExists: { $0 != "/b.md" && $0 != "/d.md" })
        #expect(restored.windows.count == 1)  // タブが残らないウィンドウは除く
        #expect(restored.windows[0].paths == ["/a.md", "/c.md"])
        #expect(restored.windows[0].selected == "/a.md")  // 選んでいたタブが消えたら先頭
        #expect(restored.windows[0].frame == "{{0, 0}, {800, 600}}")
        #expect(restored.front == "/a.md")  // 一番手前のファイルが消えたら、最初のウィンドウの選んでいたタブ
    }

    @Test func nothingToRestoreWhenAllFilesAreGone() {
        let restored = session.restorable(fileExists: { _ in false })
        #expect(restored.windows.isEmpty)
        #expect(restored.front == nil)
    }
}
