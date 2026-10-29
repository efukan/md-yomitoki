import AppKit
import Observation
import SwiftUI

/// 最近開いたファイルの1件。同じ名前のファイル（README.md・CLAUDE.md など）を見分けられるよう、プロジェクト名を持つ。
struct RecentFile: Codable, Hashable, Identifiable {
    var path: String
    /// プロジェクト名（.git のあるフォルダ名。git 管理外なら親フォルダ名）
    var project: String
    var pinned = false
    var openedAt: Date

    var id: String { path }
    var url: URL { URL(fileURLWithPath: path) }
    var name: String { url.lastPathComponent }
    /// フォルダのパス（ホームは ~ に置き換える）
    var folder: String { (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath }

    /// 空白で区切った語がすべて、ファイル名・プロジェクト名・パスのどれかに含まれるか（大文字小文字・全角半角は区別しない）
    func matches(_ query: String) -> Bool {
        let haystack = "\(name) \(project) \(path)"
        return query.split(whereSeparator: \.isWhitespace).allSatisfy {
            haystack.range(of: $0, options: [.caseInsensitive, .widthInsensitive, .diacriticInsensitive]) != nil
        }
    }
}

enum ProjectRoot {
    /// ファイルの親フォルダを遡り、.git（フォルダ。worktree・サブモジュールではファイル）のあるフォルダの名前を返す。
    /// 見つからなければ親フォルダの名前。ディスクを見るので、メインスレッドの外で呼ぶ。
    static func name(for url: URL, exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> String {
        let parent = url.deletingLastPathComponent()
        var directory = parent
        while directory.path != "/" {
            if exists(directory.appendingPathComponent(".git")) { return directory.lastPathComponent }
            directory = directory.deletingLastPathComponent()
        }
        return parent.lastPathComponent
    }
}

/// 終了した時に開いていたファイル（ウィンドウごとのタブの並び・選んでいたタブ・ウィンドウの位置と大きさ、
/// 一番手前のファイル）。次に起動した時に同じ並びで開き直す（`AppSettings.restoreOpenFiles`）。
struct OpenFilesSession: Codable, Equatable {
    struct Window: Codable, Equatable {
        var paths: [String]
        var selected: String?
        /// `NSStringFromRect` の形
        var frame: String?
    }

    var windows: [Window] = []
    /// 一番手前（キー）のウィンドウのファイル
    var front: String?

    private static let key = "openFilesSession"

    static func load() -> OpenFilesSession? {
        UserDefaults.standard.data(forKey: key).flatMap { try? JSONDecoder().decode(OpenFilesSession.self, from: $0) }
    }

    func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.key)
    }

    /// 消えたファイルを除いたもの（移動・削除されたファイルは黙って開かない）。タブが残らないウィンドウは除き、
    /// 選んでいたタブや一番手前のファイルが消えていたら、残ったものの先頭にする。
    func restorable(fileExists: (String) -> Bool) -> OpenFilesSession {
        var result = OpenFilesSession()
        for window in windows {
            let paths = window.paths.filter(fileExists)
            guard let first = paths.first else { continue }
            let selected = window.selected.flatMap { paths.contains($0) ? $0 : nil } ?? first
            result.windows.append(Window(paths: paths, selected: selected, frame: window.frame))
        }
        let all = result.windows.flatMap(\.paths)
        result.front = front.flatMap { all.contains($0) ? $0 : nil } ?? result.windows.first?.selected
        return result
    }
}

/// 最近開いたファイルの一覧（UserDefaults に保存。ピン留めしたものは数に含めず、それ以外は直近 30 件まで）。
@Observable
@MainActor
final class RecentFiles {
    static let shared = RecentFiles()
    nonisolated static let limit = 30
    private static let key = "recentFiles"

    /// ピン留め → それ以外の順。それぞれ最近開いた順。
    private(set) var items: [RecentFile]

    private init() {
        let data = UserDefaults.standard.data(forKey: Self.key)
        items = data.flatMap { try? JSONDecoder().decode([RecentFile].self, from: $0) } ?? []
    }

    /// 開いた（または前面に出した）ときに呼ぶ。プロジェクト名は後から setProject で埋める。
    func noteOpened(_ url: URL) {
        let previous = items.first { $0.path == url.path }
        let item = RecentFile(
            path: url.path,
            project: previous?.project ?? url.deletingLastPathComponent().lastPathComponent,
            pinned: previous?.pinned ?? false,
            openedAt: Date()
        )
        update { $0.removeAll { $0.path == url.path }; $0.append(item) }
        NSDocumentController.shared.noteNewRecentDocumentURL(url)
    }

    func setProject(_ project: String, for url: URL) {
        guard let index = items.firstIndex(where: { $0.path == url.path }), items[index].project != project else { return }
        update { $0[index].project = project }
    }

    func togglePin(_ item: RecentFile) {
        update { items in
            if let index = items.firstIndex(of: item) { items[index].pinned.toggle() }
        }
    }

    func remove(paths: Set<String>) {
        update { $0.removeAll { paths.contains($0.path) } }
    }

    /// ピン留めしていない履歴を消す。
    func clearUnpinned() {
        update { $0.removeAll { !$0.pinned } }
    }

    private func update(_ change: (inout [RecentFile]) -> Void) {
        var list = items
        change(&list)
        items = Self.arranged(list)
        UserDefaults.standard.set(try? JSONEncoder().encode(items), forKey: Self.key)
    }

    /// ピン留めを先頭に、それぞれ最近開いた順に並べ、ピン留め以外を limit 件に切り詰める。
    nonisolated static func arranged(_ items: [RecentFile]) -> [RecentFile] {
        let sorted = items.sorted { $0.openedAt > $1.openedAt }
        return sorted.filter(\.pinned) + sorted.filter { !$0.pinned }.prefix(limit)
    }
}

// MARK: - クイックスイッチャー（⇧⌘O）兼 起動時の画面

/// 最近開いたファイルを絞り込んで開くパネル。ファイルを開いていないときの起動画面も兼ねる。
@MainActor
final class RecentFilesPanel: NSObject, NSWindowDelegate {
    static let shared = RecentFilesPanel()
    private var panel: NSPanel?

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        // 開くたびに作り直して、絞り込みと選択を初期状態に戻す
        let current = AppDelegate.shared?.activeModel?.url.path
        panel.contentViewController = NSHostingController(rootView: RecentFilesView(currentPath: current) { [weak self] action in
            self?.perform(action)
        })
        panel.setContentSize(NSSize(width: 560, height: 440))
        panel.center()
        NSApp.activate()
        panel.makeKeyAndOrderFront(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 440),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: true
        )
        panel.title = "最近使ったファイル"
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
        return panel
    }

    private func perform(_ action: RecentFilesView.Action) {
        panel?.close()
        switch action {
        case .open(let url): AppDelegate.shared?.open([url])
        case .showOpenPanel: AppDelegate.shared?.showOpenPanel()
        case .close: break
        }
    }

    // クイックスイッチャーとして使っているときは、他をクリックしたら閉じる。
    // 文書を開いていない（起動画面の）ときは閉じない（アプリが前面に出る前に閉じてしまい、何も無い状態になるため）。
    func windowDidResignKey(_ notification: Notification) {
        guard AppDelegate.shared?.hasDocuments == true else { return }
        panel?.close()
    }
}

struct RecentFilesView: View {
    enum Action {
        case open(URL), showOpenPanel, close
    }

    let currentPath: String?
    let perform: (Action) -> Void
    @State private var recent = RecentFiles.shared
    @State private var query = ""
    @State private var selection: String?
    /// ディスク上に見つからないファイル（一覧を出したときにメインスレッドの外で調べる）
    @State private var missing: Set<String> = []
    @FocusState private var searchFocused: Bool

    private var filtered: [RecentFile] {
        recent.items.filter { $0.matches(query) }
    }

    var body: some View {
        VStack(spacing: 0) {
            TextField("ファイル名・プロジェクト名で絞り込み", text: $query)
                .textFieldStyle(.roundedBorder)
                .controlSize(.large)
                .focused($searchFocused)
                .onSubmit(openSelection)
                .onKeyPress(.downArrow) { moveSelection(1) }
                .onKeyPress(.upArrow) { moveSelection(-1) }
                .onKeyPress(.escape) {
                    perform(.close)
                    return .handled
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)  // タイトルバーの分は安全領域として自動で空く
                .padding(.bottom, 10)
            Divider()
            list
            Divider()
            footer
        }
        .frame(minWidth: 420, minHeight: 300)
        .onAppear {
            searchFocused = true
            // 今開いているファイルは飛ばして、次の候補を選んでおく（直前のファイルへすぐ戻れる）
            selection = (filtered.first { $0.path != currentPath } ?? filtered.first)?.path
        }
        .onChange(of: query) {
            selection = filtered.first?.path
        }
        .task(id: recent.items.map(\.path)) {
            let paths = recent.items.map(\.path)
            missing = await Task.detached {
                Set(paths.filter { !FileManager.default.fileExists(atPath: $0) })
            }.value
        }
    }

    @ViewBuilder
    private var list: some View {
        if filtered.isEmpty {
            ContentUnavailableView(
                recent.items.isEmpty ? "最近開いたファイルはありません" : "一致するファイルがありません",
                systemImage: "clock"
            )
            .frame(maxHeight: .infinity)
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(filtered) { item in
                            RecentFileRow(
                                item: item,
                                isSelected: item.path == selection,
                                isMissing: missing.contains(item.path),
                                isCurrent: item.path == currentPath,
                                open: { open(item) },
                                togglePin: { recent.togglePin(item) },
                                remove: { recent.remove(paths: [item.path]) }
                            )
                            .id(item.path)
                        }
                    }
                    .padding(6)
                }
                .onChange(of: selection) { _, path in
                    if let path { proxy.scrollTo(path) }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("開く…") { perform(.showOpenPanel) }
                .help("ファイルを選んで開く（⌘O）")
            Spacer()
            let missingCount = recent.items.filter { missing.contains($0.path) }.count
            if missingCount > 0 {
                Button("見つからない \(missingCount)件を削除") { recent.remove(paths: missing) }
                    .help("移動・削除されたファイルを履歴から消す")
            }
            Text("↑↓で選択・return で開く")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .controlSize(.small)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func moveSelection(_ offset: Int) -> KeyPress.Result {
        let items = filtered
        guard !items.isEmpty else { return .handled }
        let index = items.firstIndex { $0.path == selection } ?? -1
        selection = items[min(max(index + offset, 0), items.count - 1)].path
        return .handled
    }

    private func openSelection() {
        guard let item = filtered.first(where: { $0.path == selection }) ?? filtered.first else { return }
        open(item)
    }

    private func open(_ item: RecentFile) {
        guard !missing.contains(item.path) else {
            NSSound.beep()
            return
        }
        perform(.open(item.url))
    }
}

/// 1行目はファイル名とプロジェクト名のバッジ、2行目はフォルダのパス（長いときは中間を省略し、両端が見えるようにする）。
private struct RecentFileRow: View {
    let item: RecentFile
    let isSelected: Bool
    let isMissing: Bool
    let isCurrent: Bool
    let open: () -> Void
    let togglePin: () -> Void
    let remove: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: open) {
            HStack(spacing: 10) {
                Image(systemName: isMissing ? "questionmark.circle" : "doc.text")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(item.name)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                        Text(item.project)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.primary.opacity(0.08)))
                            .lineLimit(1)
                        if isCurrent {
                            Text("表示中")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if isMissing {
                            Text("見つかりません")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text(item.folder)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer(minLength: 8)
                if item.pinned || isHovering {
                    Button(item.pinned ? "ピン留めを外す" : "ピン留め", systemImage: item.pinned ? "pin.fill" : "pin", action: togglePin)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(item.pinned ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        .help(item.pinned ? "ピン留めを外す" : "一覧の上に固定する")
                }
                if isHovering {
                    Button("履歴から削除", systemImage: "xmark.circle.fill", action: remove)
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .help("履歴から削除")
                }
            }
            .opacity(isMissing ? 0.5 : 1)
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.primary.opacity(isSelected ? 0.1 : isHovering ? 0.04 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .contextMenu {
            Button(item.pinned ? "ピン留めを外す" : "ピン留め", action: togglePin)
            Button("Finder に表示") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
                .disabled(isMissing)
            Divider()
            Button("履歴から削除", action: remove)
        }
    }
}

/// 「ファイル」メニューの「最近使ったファイル」。
struct RecentFilesMenu: View {
    @State private var recent = RecentFiles.shared

    var body: some View {
        Menu("最近使ったファイル") {
            ForEach(recent.items) { item in
                Button("\(item.name) — \(item.project)") { AppDelegate.shared?.open([item.url]) }
            }
            if !recent.items.isEmpty { Divider() }
            Button("履歴を消去（ピン留めは残す）") { recent.clearUnpinned() }
                .disabled(recent.items.allSatisfy(\.pinned))
        }
    }
}
