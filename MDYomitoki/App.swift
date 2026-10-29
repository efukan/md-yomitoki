import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
struct MDYomitokiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // ドキュメントウィンドウは AppDelegate が AppKit で管理する。SwiftUI はメニューと設定ウィンドウ（⌘,）を担当する。
        Settings { SettingsView() }
            .commands {
                CommandGroup(replacing: .appInfo) {
                    Button("\(AppDelegate.appName) について") { appDelegate.showAboutPanel() }
                    Button("アップデートを確認…") { Updater.shared.checkForUpdates() }
                        .disabled(!Updater.shared.isEnabled)
                }
                CommandGroup(replacing: .newItem) {
                    Button("開く…") { appDelegate.showOpenPanel() }
                        .keyboardShortcut("o")
                    Button("最近使ったファイルを開く…") { RecentFilesPanel.shared.show() }
                        .keyboardShortcut("o", modifiers: [.command, .shift])
                    RecentFilesMenu()
                }
                // 標準の「検索」は NSTextView の検索パネルになり表記ゆれを吸収できないので、自前の検索に置き換える
                CommandGroup(replacing: .textEditing) {
                    Button("検索…") { appDelegate.activeModel?.showSearch() }
                        .keyboardShortcut("f")
                    Button("置換…") { appDelegate.activeModel?.showSearch(replacing: true) }
                        .keyboardShortcut("f", modifiers: [.command, .option])
                    Button("次を検索") { appDelegate.activeModel?.findNext() }
                        .keyboardShortcut("g")
                    Button("前を検索") { appDelegate.activeModel?.findNext(forward: false) }
                        .keyboardShortcut("g", modifiers: [.command, .shift])
                }
                // 標準の「閉じる」はこの欄に入っているので、置き換える時に自分で用意する
                CommandGroup(replacing: .saveItem) {
                    Button("閉じる") { NSApp.keyWindow?.performClose(nil) }
                        .keyboardShortcut("w")
                    Button("ウインドウを閉じる") { appDelegate.closeFrontWindowAndTabs() }
                        .keyboardShortcut("w", modifiers: [.command, .shift])
                    Button("閉じたタブを開き直す") { appDelegate.reopenClosedTab() }
                        .keyboardShortcut("t", modifiers: [.command, .shift])
                    Divider()
                    Button("保存") { appDelegate.activeModel?.save() }
                        .keyboardShortcut("s")
                }
                // 印刷も PDF も、表示中のモードにかかわらずプレビュー（描画した本文）を使う
                CommandGroup(replacing: .printItem) {
                    Button("PDF として書き出す…") { appDelegate.activeModel?.exportPDF() }
                    Button("プリント…") { appDelegate.activeModel?.printDocument() }
                        .keyboardShortcut("p")
                }
                CommandGroup(before: .toolbar) {
                    Button("プレビュー／エディタを切り替え") { appDelegate.activeModel?.toggleMode() }
                        .keyboardShortcut("e")
                    Button("戻る") { appDelegate.activeModel?.goBack() }
                        .keyboardShortcut("[")
                    Button("進む") { appDelegate.activeModel?.goForward() }
                        .keyboardShortcut("]")
                    Button("見出し一覧を表示／隠す") {
                        guard let model = appDelegate.activeModel else { return }
                        withAnimation { model.sidebarVisible.toggle() }
                    }
                    .keyboardShortcut("s", modifiers: [.control, .command])
                    Button("付箋を付ける／外す") { appDelegate.activeModel?.toggleBookmarkAtCurrentPosition() }
                        .keyboardShortcut("d")
                    RemoteImagesToggle()
                    Divider()
                    TextSizeCommands()
                    Divider()
                }
                CommandMenu("書式") {
                    ForEach(Array(MarkdownFormat.menuLayout.enumerated()), id: \.offset) { _, format in
                        if let format {
                            let button = Button(format.title, systemImage: format.symbol) {
                                appDelegate.activeModel?.applyFormat(format)
                            }
                            if let shortcut = format.shortcut {
                                button.keyboardShortcut(shortcut)
                            } else {
                                button
                            }
                        } else {
                            Divider()
                        }
                    }
                }
                // ショートカットはメニューに置く（ツールバーのボタンに付けても AppKit のウィンドウでは効かない）。
                CommandMenu("変更") {
                    Button("次の変更箇所へ移動") { appDelegate.activeModel?.jumpToNextChange() }
                        .keyboardShortcut("j")
                    Button("前の変更箇所へ移動") { appDelegate.activeModel?.jumpToPreviousChange() }
                        .keyboardShortcut("j", modifiers: [.command, .shift])
                    Button("確認済みにする") { appDelegate.activeModel?.markAsReviewed() }
                    Divider()
                    Button("git HEAD と比較／比較をやめる") { appDelegate.activeModel?.toggleGitBaseline() }
                }
                // 標準の「MDよみとき ヘルプ」はヘルプブックが無いと「ヘルプはありません」と出るだけなので、GitHub へのリンクに置き換える
                CommandGroup(replacing: .help) {
                    Button("使い方（README）") { NSWorkspace.shared.open(ProjectLinks.readme) }
                    Button("不具合の報告・要望（メール）…") { NSWorkspace.shared.open(ProjectLinks.reportMail) }
                    Button("不具合の報告・要望（GitHub）…") { NSWorkspace.shared.open(ProjectLinks.newIssue) }
                    Button("更新履歴") { NSWorkspace.shared.open(ProjectLinks.releases) }
                }
            }
    }
}

extension MarkdownFormat {
    /// 「書式」メニューのショートカット
    var shortcut: KeyboardShortcut? {
        switch self {
        case .heading1: KeyboardShortcut("1")
        case .heading2: KeyboardShortcut("2")
        case .heading3: KeyboardShortcut("3")
        case .body: KeyboardShortcut("0", modifiers: [.command, .option])  // ⌘0 は「実際のサイズ」（macOS の標準）
        case .bold: KeyboardShortcut("b")
        case .italic: KeyboardShortcut("i")
        case .strikethrough: KeyboardShortcut("x", modifiers: [.command, .shift])
        case .link: KeyboardShortcut("k")
        default: nil
        }
    }
}

/// 設定ウィンドウ（⌘,）。アプリ全体の設定（`AppSettings`）をまとめて見られるようにする。
/// どれもメニューやツールバーからも変えられ、変えるとすぐ全ウィンドウに反映される。
private struct SettingsView: View {
    @Bindable private var settings = AppSettings.shared
    @Bindable private var updater = Updater.shared

    var body: some View {
        Form {
            Section("表示") {
                Picker("外観", selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("文字の大きさ", selection: $settings.textScale) {
                    ForEach(AppSettings.textScales, id: \.self) { scale in
                        Text("\(Int((scale * 100).rounded()))%").tag(scale)
                    }
                }
                Picker("本文の幅", selection: $settings.contentWidth) {
                    ForEach(ContentWidth.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Toggle(isOn: $settings.loadRemoteImages) {
                    Text("リモート画像を読み込む")
                    Text("オフにすると、http・https の画像やスタイルなどを読み込みません。")
                }
            }
            DefaultAppSection()
            Section {
                Toggle(isOn: $settings.restoreOpenFiles) {
                    Text("前回開いていたファイルを開く")
                    Text("起動した時と、ウインドウを全部閉じてから Dock のアイコンをクリックした時に、最後に開いていたウインドウとタブの並びで開き直します。オフのときや開けるファイルが無いときは、最近使ったファイルの一覧を出します。")
                }
            } header: {
                Text("起動")
            }
            Section {
                Picker("新しく開いたファイルの基準", selection: $settings.compareWithGitHead) {
                    Text("開いた時点・確認済みの時点").tag(false)
                    Text("git HEAD（最後のコミット）").tag(true)
                }
            } header: {
                Text("変更の比較")
            } footer: {
                Text("ツールバーで基準を切り替えると、ここも変わります。git 管理外のファイルは開いた時点になります。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Section {
                Toggle("アップデートを自動で確認する", isOn: $updater.automaticallyChecks)
                Toggle(isOn: $updater.automaticallyDownloads) {
                    Text("自動でダウンロードしてインストールする")
                    Text("オフのときは、新しい版があればお知らせして、入れるかどうかを選べます。オンのときは、次に終了した時に新しい版に入れ替わります。")
                }
                .disabled(!updater.automaticallyChecks)
            } header: {
                Text("アップデート")
            }
            .disabled(!updater.isEnabled)
        }
        .formStyle(.grouped)
        .frame(width: 480)
        .fixedSize()
    }
}

/// 設定ウィンドウの「Markdown ファイル」：.md を開く既定のアプリを MDよみとき にする。
/// Info.plist の LSHandlerRank は Alternate（ほかのアプリが既定なら勝手に奪わない）なので、利用者がここで選ぶ。
/// 同じ Bundle ID の別のコピー（開発中のビルドと /Applications の公開版など）が既定なら、もう MDよみとき とみなす。
private struct DefaultAppSection: View {
    @State private var current: URL?
    @State private var failed = false

    private var isDefault: Bool {
        current.flatMap { Bundle(url: $0)?.bundleIdentifier } == Bundle.main.bundleIdentifier
    }

    var body: some View {
        Section {
            if isDefault {
                Label("Finder でダブルクリックすると、\(AppDelegate.appName) で開きます。", systemImage: "checkmark.circle.fill")
            } else {
                LabeledContent {
                    Button("\(AppDelegate.appName) にする") { makeDefault() }
                } label: {
                    Text("ダブルクリックで開くアプリ")
                    Text(current.map { "今は「\(Self.name(of: $0))」で開きます。" } ?? "まだ決まっていません。")
                }
            }
            if failed {
                Text("変更できませんでした。Finder でファイルを選び、「情報を見る」の「このアプリケーションで開く」で選んでから「すべてを変更」を押してください。")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Markdown ファイル")
        }
        .onAppear(perform: refresh)
    }

    private func refresh() {
        current = NSWorkspace.shared.urlForApplication(toOpen: .markdown)
    }

    /// Finder と同じ表示名（拡張子を表示する設定でも .app は付けない）
    private static func name(of app: URL) -> String {
        let name = FileManager.default.displayName(atPath: app.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    private func makeDefault() {
        Task {
            do {
                try await NSWorkspace.shared.setDefaultApplication(at: Bundle.main.bundleURL, toOpen: .markdown)
                failed = false
            } catch {
                failed = true
            }
            refresh()
        }
    }
}

/// 「ヘルプ」メニューから開く GitHub のページ。リポジトリは xcconfig の GITHUB_REPOSITORY（Info.plist の MDYGitHubRepository）。
@MainActor
enum ProjectLinks {
    static var repository: URL {
        let name = Bundle.main.object(forInfoDictionaryKey: "MDYGitHubRepository") as? String ?? "efukan/md-yomitoki"
        return URL(string: "https://github.com/\(name)")!
    }

    static var readme: URL { URL(string: repository.absoluteString + "#readme")! }
    static var releases: URL { repository.appending(path: "releases") }

    /// 新しい Issue の画面（GitHub のアカウントが要る）。
    static var newIssue: URL {
        var components = URLComponents(url: repository.appending(path: "issues/new"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "body", value: reportBody)]
        return components.url!
    }

    /// 不具合の報告・要望のメール（アカウントが無くても送れる窓口）。宛先は xcconfig の SUPPORT_EMAIL（Info.plist の MDYSupportEmail）。
    static var reportMail: URL {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = Bundle.main.object(forInfoDictionaryKey: "MDYSupportEmail") as? String ?? ""
        components.queryItems = [
            URLQueryItem(name: "subject", value: "\(AppDelegate.appName) \(version) について"),
            URLQueryItem(name: "body", value: reportBody),
        ]
        return components.url!
    }

    private static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    /// 報告の本文のひな形。調べるのに要るアプリと macOS の版を入れておく（送る前に利用者が見て直せる）。
    private static var reportBody: String {
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
        let os = ProcessInfo.processInfo.operatingSystemVersion
        #if arch(arm64)
        let cpu = "Apple シリコン"
        #else
        let cpu = "Intel"
        #endif
        return """
            （起きたこと・してほしいことを書いてください。不具合なら、どうすると起きるかも書いてもらえると助かります）



            ---
            \(AppDelegate.appName) \(version)（ビルド \(build)）
            macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)（\(cpu)）
            """
    }
}

/// 「表示」メニューの文字の大きさ（拡大・縮小・実際のサイズ）と本文の幅。全ウィンドウ共通。
private struct TextSizeCommands: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        Button("拡大") { settings.zoomIn() }
            .keyboardShortcut("+")
            .disabled(!settings.canZoomIn)
        Button("縮小") { settings.zoomOut() }
            .keyboardShortcut("-")
            .disabled(!settings.canZoomOut)
        Button("実際のサイズ") { settings.textScale = 1 }
            .keyboardShortcut("0")
            .disabled(settings.textScale == 1)
        Picker("本文の幅", selection: $settings.contentWidth) {
            ForEach(ContentWidth.allCases, id: \.self) { Text($0.title).tag($0) }
        }
    }
}

/// 「表示」メニューの「リモート画像を読み込む」（チェック付き）。
private struct RemoteImagesToggle: View {
    @Bindable private var settings = AppSettings.shared

    var body: some View {
        Toggle("リモート画像を読み込む", isOn: $settings.loadRemoteImages)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// SwiftUI のアダプタ経由だと `NSApp.delegate` が自分にならないため、静的参照を持つ。
    private(set) static weak var shared: AppDelegate?
    private var controllers: [DocumentWindowController] = []

    override init() {
        super.init()
        Self.shared = self
    }

    /// Finder・Dock と同じ表示名（InfoPlist.strings で xcconfig の APP_DISPLAY_NAME になる）
    static var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? ProcessInfo.processInfo.processName
    }

    /// 「このアプリについて」。同梱するライブラリのライセンス（Credits.html）を、文字色の指定を外してから渡す。
    /// HTML のままだとリンクが固定の青になり（OS の版によっては本文も黒になり）、ダークモードで読みにくいため。
    func showAboutPanel() {
        // 既定のアイコン（NSApp.applicationIconImage）だと Icon Composer のアイコンが白紙の汎用アイコンになることがあるので、
        // Finder と同じアイコンを渡す。
        let icon = NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        icon.size = NSSize(width: 64, height: 64)
        var options: [NSApplication.AboutPanelOptionKey: Any] = [.applicationIcon: icon]
        if let url = Bundle.main.url(forResource: "Credits", withExtension: "html"),
           let credits = try? NSMutableAttributedString(
               url: url,
               options: [.documentType: NSAttributedString.DocumentType.html, .characterEncoding: String.Encoding.utf8.rawValue],
               documentAttributes: nil) {
            credits.removeAttribute(.foregroundColor, range: NSRange(location: 0, length: credits.length))
            options[.credits] = credits
        }
        NSApp.orderFrontStandardAboutPanel(options: options)
        NSApp.activate()
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = true
        AppSettings.shared.applyAppearance()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        open(urls)
    }

    // ファイルを開いていないときは、最近使ったファイルの一覧（「開く…」ボタン付き）を出す。
    // SwiftUI のアプリでは applicationOpenUntitledFile が呼ばれないため、起動完了時と Dock のクリックで自分で判断する。
    func applicationDidFinishLaunching(_ notification: Notification) {
        installNavigationGestures()
        if !isRunningTests { Updater.shared.start() }
        // Finder から開いて起動した場合のファイル（application(_:open:)）を待ってから判断する。
        // それが無ければ前回開いていたファイルを開き直し、それも無ければ最近使ったファイルの一覧を出す。
        DispatchQueue.main.async { [self] in
            guard !isRunningTests && controllers.isEmpty else { return }
            if AppSettings.shared.restoreOpenFiles { restoreSession() }
            if controllers.isEmpty { RecentFilesPanel.shared.show() }
        }
    }

    /// 終了する時に開いているウィンドウとタブの並びを記録する。全部閉じてから終了した時は、
    /// 全部閉じる直前の記録をそのまま使う。
    func applicationWillTerminate(_ notification: Notification) {
        recordSessionIfAnyOpen()
    }

    private func recordSessionIfAnyOpen() {
        guard !isRunningTests, !controllers.isEmpty else { return }
        currentSession().save()
    }

    /// 開いているファイルを、ウィンドウごと（タブの並び順）にまとめる。
    private func currentSession() -> OpenFilesSession {
        var session = OpenFilesSession()
        var seen = Set<ObjectIdentifier>()
        func path(of window: NSWindow?) -> String? {
            controllers.first { $0.window === window }?.model.url.path
        }
        for controller in controllers {
            guard let window = controller.window, !seen.contains(ObjectIdentifier(window)) else { continue }
            let tabs = window.tabGroup?.windows ?? [window]
            tabs.forEach { seen.insert(ObjectIdentifier($0)) }
            session.windows.append(OpenFilesSession.Window(
                paths: tabs.compactMap(path(of:)),
                selected: path(of: window.tabGroup?.selectedWindow ?? window),
                frame: NSStringFromRect(window.frame)
            ))
        }
        // アプリが前面に無い時は手前のウィンドウがわからないので記録せず、各ウィンドウで選んでいたタブに任せる
        session.front = [NSApp.keyWindow, NSApp.mainWindow].lazy.compactMap(path(of:)).first
        return session
    }

    /// 前回のウィンドウとタブを同じ並びで開き直す（消えたファイルは黙って飛ばす）。
    private func restoreSession() {
        guard let session = OpenFilesSession.load()?.restorable(fileExists: { FileManager.default.fileExists(atPath: $0) })
        else { return }
        isRestoringSession = true
        defer {
            isRestoringSession = false
            currentSession().save()
        }
        for saved in session.windows {
            for (index, path) in saved.paths.enumerated() {
                open(URL(fileURLWithPath: path), inNewWindow: index == 0)
            }
            let first = controllers.first { $0.model.url.path == saved.paths.first }
            if let frame = saved.frame, let window = first?.window {
                window.setFrame(NSRectFromString(frame), display: false)
            }
            controllers.first { $0.model.url.path == saved.selected }?.window?.makeKeyAndOrderFront(nil)
        }
        controllers.first { $0.model.url.path == session.front }?.window?.makeKeyAndOrderFront(nil)
    }

    /// ウィンドウを全部閉じてから Dock のアイコンをクリックした時も、最後に開いていたファイルを開き直す。
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        if controllers.isEmpty && AppSettings.shared.restoreOpenFiles { restoreSession() }
        if controllers.isEmpty { RecentFilesPanel.shared.show() }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        for controller in controllers where controller.model.isDirty {
            if !controller.confirmClose() { return .terminateCancel }
        }
        return .terminateNow
    }

    var hasDocuments: Bool { !controllers.isEmpty }

    /// 前面にある文書ウィンドウのモデル。メニューコマンドの送り先。
    /// アプリが前面に無い時（アクセシビリティ経由でメニューを押された時など）は、一番手前の文書ウィンドウ。
    var activeModel: DocumentModel? {
        let windows = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 } + NSApp.orderedWindows
        return windows.lazy.compactMap { window in self.controllers.first { $0.window === window }?.model }.first
    }

    func showOpenPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType("net.daringfireball.markdown"), .plainText].compactMap { $0 }
        panel.allowsMultipleSelection = true
        if panel.runModal() == .OK {
            open(panel.urls)
        }
    }

    func open(_ urls: [URL]) {
        for url in urls where url.isFileURL {
            open(url.standardizedFileURL.resolvingSymlinksInPath())
        }
    }

    /// ほかの文書のリンク（`other.md#見出し`）：開いて（開いていれば前面に出して）、その見出しへ移動する。
    func open(_ url: URL, fragment: String?) {
        open([url])
        guard let fragment, !fragment.isEmpty else { return }
        let target = url.standardizedFileURL.resolvingSymlinksInPath()
        controllers.first { $0.model.url == target }?.model.reveal(fragment: fragment)
    }

    /// inNewWindow なら、今あるウィンドウのタブにせず新しいウィンドウで開く（前回のウィンドウの復元用）。
    private func open(_ url: URL, inNewWindow: Bool = false) {
        if let existing = controllers.first(where: { $0.model.url == url }) {
            existing.window?.makeKeyAndOrderFront(nil)
            RecentFiles.shared.noteOpened(url)
            return
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            let alert = NSAlert()
            alert.messageText = "「\(url.lastPathComponent)」が見つかりません"
            alert.informativeText = "移動または削除された可能性があります。"
            alert.addButton(withTitle: "履歴から削除")
            alert.addButton(withTitle: "キャンセル")
            if alert.runModal() == .alertFirstButtonReturn {
                RecentFiles.shared.remove(paths: [url.path])
            }
            return
        }
        let controller = DocumentWindowController(url: url)
        controller.onClose = { [weak self, weak controller] in
            // ⇧⌘T で開き直せるように覚えておく
            self?.closedFiles.removeAll { $0 == url }
            self?.closedFiles.append(url)
            self?.controllers.removeAll { $0 === controller }
            self?.updateTabTitles()
            self?.updateDockBadge()
            // 閉じるボタンはタブをまとめて閉じるので、閉じ終わってから記録し直す。まだ開いているものがあれば
            // 今の並びにし（閉じたタブは次に開き直さない）、全部閉じた時は閉じる前の記録を残す。
            DispatchQueue.main.async { self?.recordSessionIfAnyOpen() }
        }
        controller.onUnseenUpdateChange = { [weak self] in self?.updateDockBadge() }
        guard let window = controller.window else { return }
        if !inNewWindow, let front = controllers.compactMap(\.window).first(where: \.isMainWindow) ?? controllers.last?.window {
            front.addTabbedWindow(window, ordered: .above)
        } else {
            window.center()
        }
        controllers.append(controller)
        controller.showWindow(nil)
        RecentFiles.shared.noteOpened(url)
        // 開くたびに今の並びを記録する（全部閉じた後の Dock のクリックや次の起動で開き直せるように）
        if !isRestoringSession { recordSessionIfAnyOpen() }
        // プロジェクト名は親フォルダを遡って .git を探すので、メインスレッドの外で調べる
        Task {
            let project = await Task.detached { ProjectRoot.name(for: url) }.value
            controller.project = project
            RecentFiles.shared.setProject(project, for: url)
            updateTabTitles()
        }
    }

    // MARK: トラックパッド・マウスでの戻る／進む

    private var gestureMonitor: Any?

    /// マウスの戻る／進むボタン（4・5 番目のボタン）と、トラックパッドの「ページ間をスワイプ」を ⌘[ / ⌘] と同じにする。
    /// スワイプは設定により、2本指なら scrollWheel を自分で数え、3本指なら swipe のイベントで届く。
    private func installNavigationGestures() {
        gestureMonitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseDown, .swipe, .scrollWheel]) { [weak self] event in
            let handled = MainActor.assumeIsolated { self?.handleNavigationGesture(event) ?? false }
            return handled ? nil : event
        }
    }

    private func handleNavigationGesture(_ event: NSEvent) -> Bool {
        guard let window = event.window, let model = controllers.first(where: { $0.window === window })?.model else { return false }
        let view = window.contentView?.hitTest(event.locationInWindow)
        switch event.type {
        case .otherMouseDown:
            switch event.buttonNumber {
            case 3: model.goBack()
            case 4: model.goForward()
            default: return false
            }
            return true
        case .swipe:
            guard model.isContent(view), event.deltaX != 0 else { return false }
            event.deltaX > 0 ? model.goBack() : model.goForward()
            return true
        case .scrollWheel:
            return model.isContent(view) && model.handleSwipeScroll(event)
        default:
            return false
        }
    }

    /// 同じ名前のファイルを複数開いているときだけ、タブの見出しにプロジェクト名を付けて見分けられるようにする。
    private func updateTabTitles() {
        let counts = Dictionary(grouping: controllers, by: { $0.model.url.lastPathComponent }).mapValues(\.count)
        for controller in controllers {
            let name = controller.model.url.lastPathComponent
            let duplicated = counts[name, default: 0] > 1
            controller.window?.tab.title = duplicated ? "\(name) — \(controller.project ?? "")" : nil
        }
    }

    /// 見ていない間に更新された文書の数を Dock のアイコンに出す（AI の書き換えに気づけるように）。
    private func updateDockBadge() {
        let count = controllers.filter(\.hasUnseenUpdate).count
        NSApp.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }

    // MARK: 閉じる・閉じたタブを開き直す

    /// 閉じたファイル（最後に閉じたものが末尾）。⇧⌘T で新しい順に開き直す。アプリを終了すると忘れる。
    private var closedFiles: [URL] = []

    /// ⇧⌘W：前面のウィンドウを、タブごとまとめて閉じる（未保存のものは1つずつ確認し、キャンセルしたものは残る）。
    func closeFrontWindowAndTabs() {
        guard let window = NSApp.keyWindow else { return }
        for tab in window.tabGroup?.windows ?? [window] {
            tab.performClose(nil)
        }
    }

    /// ⇧⌘T：最後に閉じたファイルを開き直す（今開いているもの・消えたものは飛ばす）。
    func reopenClosedTab() {
        while let url = closedFiles.popLast() {
            guard !controllers.contains(where: { $0.model.url == url }),
                  FileManager.default.fileExists(atPath: url.path) else { continue }
            open(url)
            return
        }
        NSSound.beep()
    }

    /// 前回のファイルを開き直している間（1つ開くたびに記録し直さない）
    private var isRestoringSession = false

    private var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

@MainActor
final class DocumentWindowController: NSWindowController, NSWindowDelegate {
    let model: DocumentModel
    var onClose: (() -> Void)?
    /// プロジェクト名。ウィンドウのサブタイトルに出す（同じ名前のファイルを見分けるため）。
    var project: String? {
        didSet { window?.subtitle = project ?? "" }
    }
    /// 見えていない間（裏のタブ・隠れたウィンドウ・しまったウィンドウ）に外部で更新された。
    /// タブにオレンジの点を出し、Dock のバッジに数える。見えるようになったら消す。
    private(set) var hasUnseenUpdate = false {
        didSet {
            guard hasUnseenUpdate != oldValue else { return }
            window?.tab.accessoryView = hasUnseenUpdate ? Self.updateDot() : nil
            onUnseenUpdateChange?()
        }
    }
    var onUnseenUpdateChange: (() -> Void)?

    init(url: URL) {
        model = DocumentModel(url: url)
        let host = NSHostingController(rootView: ContentView(model: model))
        host.sceneBridgingOptions = [.toolbars]
        host.sizingOptions = [.minSize]

        let window = NSWindow(contentViewController: host)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.setContentSize(NSSize(width: 1000, height: 720))
        window.title = url.lastPathComponent
        window.representedURL = url
        window.tabbingMode = .preferred
        window.tabbingIdentifier = "MDYomitokiDocument"
        super.init(window: window)
        window.delegate = self
        // プレビューのチェックボックスの切り替えを、ウィンドウ（エディタの NSTextView も使う）の取り消しの履歴に積む
        model.undoManager = window.undoManager
        model.onDirtyChange = { [weak window] dirty in window?.isDocumentEdited = dirty }
        model.onExternalUpdate = { [weak self] in
            guard let self, !isVisibleToUser else { return }
            hasUnseenUpdate = true
        }
        model.load()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        confirmClose()
    }

    /// 未保存の編集があれば保存するか確認する。閉じてよければ true。
    func confirmClose() -> Bool {
        guard model.isDirty else { return true }
        window?.makeKeyAndOrderFront(nil)
        let alert = NSAlert()
        alert.messageText = "「\(model.url.lastPathComponent)」の変更を保存しますか？"
        alert.informativeText = "保存しないと、変更内容は失われます。"
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "キャンセル")
        alert.addButton(withTitle: "保存しない")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            model.save()
            return !model.isDirty
        case .alertThirdButtonReturn:
            return true
        default:
            return false
        }
    }

    /// 画面に少しでも見えていて、タブなら選ばれているか。横に並べて見ている時は印を付けない。
    private var isVisibleToUser: Bool {
        guard let window, window.isVisible, !window.isMiniaturized, window.occlusionState.contains(.visible) else { return false }
        return (window.tabGroup?.selectedWindow ?? window) === window
    }

    func windowDidBecomeKey(_ notification: Notification) {
        hasUnseenUpdate = false
    }

    func windowDidChangeOcclusionState(_ notification: Notification) {
        if isVisibleToUser { hasUnseenUpdate = false }
    }

    /// 見出し一覧の「変更のある節」と同じオレンジの点。タブバーはテンプレート画像を灰色で描くので、色を画像に焼き込む。
    private static func updateDot() -> NSView {
        let configuration = NSImage.SymbolConfiguration(pointSize: 7, weight: .regular)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.systemOrange]))
        let image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: "更新あり")?
            .withSymbolConfiguration(configuration)
        let view = NSImageView(image: image ?? NSImage())
        view.toolTip = "見ていない間に外部で更新されました"
        return view
    }

    func windowWillClose(_ notification: Notification) {
        model.close()
        onClose?()
    }

    /// タブバーの「＋」ボタン。
    override func newWindowForTab(_ sender: Any?) {
        RecentFilesPanel.shared.show()
    }
}
