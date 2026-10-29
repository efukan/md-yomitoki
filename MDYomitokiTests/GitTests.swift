import Foundation
import Testing
@testable import MDYomitoki

struct GitTests {
    private func git(_ arguments: [String], in directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", directory.path] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    private func makeRepository() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("gittest-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try git(["init", "-q"], in: directory)
        try git(["config", "user.email", "test@example.com"], in: directory)
        try git(["config", "user.name", "test"], in: directory)
        return directory
    }

    @Test func headVersionReturnsCommittedContentEvenAfterEdits() async throws {
        let directory = try makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("文書 1.md")  // 日本語と空白を含むファイル名
        try "コミット時の内容\n".write(to: file, atomically: true, encoding: .utf8)
        try git(["add", "."], in: directory)
        try git(["commit", "-q", "-m", "init"], in: directory)
        try "編集後の内容\n".write(to: file, atomically: true, encoding: .utf8)

        let head = try await Git.headVersion(of: file)
        #expect(String(decoding: head, as: UTF8.self) == "コミット時の内容\n")
    }

    @Test func uncommittedFileFails() async throws {
        let directory = try makeRepository()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("new.md")
        try "未コミット\n".write(to: file, atomically: true, encoding: .utf8)
        await #expect(throws: Git.Failure.self) { try await Git.headVersion(of: file) }
    }

    @Test func fileOutsideRepositoryFails() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("nogit-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("a.md")
        try "x".write(to: file, atomically: true, encoding: .utf8)
        await #expect(throws: Git.Failure.self) { try await Git.headVersion(of: file) }
    }
}
