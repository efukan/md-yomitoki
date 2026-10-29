import Foundation

/// 比較の基準に使う、git の最後のコミット（HEAD）時点のファイル内容を取り出す。
enum Git {
    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// `git show HEAD:./<ファイル名>` の出力。git 管理外・未コミットのファイルならエラー。
    /// git の起動は時間がかかることがあるので、メインスレッドの外で実行する。
    static func headVersion(of url: URL) async throws -> Data {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            process.arguments = ["-C", url.deletingLastPathComponent().path, "show", "HEAD:./" + url.lastPathComponent]
            var environment = ProcessInfo.processInfo.environment
            environment["GIT_OPTIONAL_LOCKS"] = "0"  // 外部の git 操作とロックを取り合わない
            process.environment = environment
            let output = Pipe()
            let errors = Pipe()
            process.standardOutput = output
            process.standardError = errors
            do {
                try process.run()
            } catch {
                throw Failure(message: "git を起動できませんでした（\(error.localizedDescription)）")
            }
            let data = output.fileHandleForReading.readDataToEndOfFile()
            let errorText = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                if errorText.contains("not a git repository") {
                    throw Failure(message: "このファイルは git リポジトリの中にありません。")
                }
                if errorText.contains("exists on disk, but not in") || errorText.contains("does not exist in") {
                    throw Failure(message: "このファイルはまだコミットされていません。")
                }
                throw Failure(message: errorText.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return data
        }.value
    }
}
