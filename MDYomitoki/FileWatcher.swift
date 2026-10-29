import Foundation

/// 1ファイルの変更監視。アトミック保存（一時ファイル＋rename で inode が変わる）にも追従する。
///
/// - vnode の DispatchSource でファイル記述子を監視する。
/// - delete / rename を受けたら（＝別の inode に置き換わった可能性）監視を外し、同じパスを開き直す。
///   見つからない間は、最初は 0.1 秒ごと、10 回を超えたら 1 秒ごとに再試行し続ける（削除後に再生成されても拾う）。
/// - 連続したイベントは 150ms のデバウンスでまとめてから `onChange` を呼ぶ。
@MainActor
final class FileWatcher {
    private let path: String
    private let onChange: @MainActor () -> Void
    private var source: (any DispatchSourceFileSystemObject)?
    private var notifyTask: Task<Void, Never>?
    private var reopenTask: Task<Void, Never>?

    init(url: URL, onChange: @escaping @MainActor () -> Void) {
        path = url.path
        self.onChange = onChange
        _ = open()
    }

    func stop() {
        source?.cancel()
        source = nil
        notifyTask?.cancel()
        reopenTask?.cancel()
    }

    /// ファイルを開いて監視を始める。開けなければ false。
    private func open() -> Bool {
        let fd = Darwin.open(path, O_EVTONLY)
        guard fd >= 0 else { return false }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename], queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let source = self.source else { return }
                self.handle(source.data)
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        self.source = source
        return true
    }

    private func handle(_ events: DispatchSource.FileSystemEvent) {
        if events.contains(.delete) || events.contains(.rename) {
            source?.cancel()
            source = nil
            reopen()
        }
        scheduleNotify()
    }

    private func reopen() {
        reopenTask?.cancel()
        reopenTask = Task { [weak self] in
            var attempt = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(attempt < 10 ? 100 : 1000))
                guard let self, !Task.isCancelled else { return }
                if self.open() {
                    self.scheduleNotify()
                    return
                }
                attempt += 1
            }
        }
    }

    private func scheduleNotify() {
        notifyTask?.cancel()
        notifyTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard !Task.isCancelled else { return }
            self?.onChange()
        }
    }
}
