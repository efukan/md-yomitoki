import AppKit
import OSLog
import SwiftUI
import UniformTypeIdentifiers
import WebKit

private let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "MDYomitoki", category: "preview")

struct PreviewView: NSViewRepresentable {
    let model: DocumentModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> WKWebView {
        context.coordinator.webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        webView.isHidden = model.mode != .preview
        context.coordinator.setRemoteImages(AppSettings.shared.loadRemoteImages)
        context.coordinator.setLayout(scale: AppSettings.shared.textScale, width: AppSettings.shared.contentWidth.css)
        // 開いた直後、描画ができるまでは何も渡さない（空の文書を描いて位置の復元を済ませてしまわないように）
        if model.hasRendered { context.coordinator.update(html: model.rendered.html, marks: model.marks) }
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.tearDown()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
        let webView: DocumentWebView
        private let model: DocumentModel
        private let baseURL: String
        private var html: String?
        private var marks = PreviewMarks()
        private var isReady = false
        /// 外枠を読み込んだ直後の描画では、前回のスクロール位置を復元する。
        private var needsScrollRestore = true
        private var allowRemoteImages = AppSettings.shared.loadRemoteImages
        /// リモートの読み込みを止めるコンテンツブロッカーを入れているか
        private var blockingRemote = false
        /// 外枠の読み込みを自分で始めたところか。文書の `<meta http-equiv="refresh">` などによる外枠の再読み込みは
        /// 許可しない（ready のたびに描画し直すので、止めないと再読み込みが延々と続く）。
        private var shellLoadPending = false
        /// 本文の列の最大幅（CSS の値）
        private var contentWidth = AppSettings.shared.contentWidth.css
        private var appearanceBeforePrinting: NSAppearance?

        init(model: DocumentModel) {
            self.model = model
            baseURL = LocalSchemeHandler.baseURL(forDirectory: model.url.deletingLastPathComponent()).absoluteString

            let config = WKWebViewConfiguration()
            config.setURLSchemeHandler(LocalSchemeHandler(), forURLScheme: LocalSchemeHandler.scheme)
            let proxy = WeakScriptMessageHandler()
            config.userContentController.add(proxy, name: "bridge")
            webView = DocumentWebView(frame: .zero, configuration: config)
            super.init()

            proxy.target = self
            webView.navigationDelegate = self
            webView.setValue(false, forKey: "drawsBackground")
            #if DEBUG
            webView.isInspectable = true  // Safari の Web インスペクタで調べられるようにする
            #endif
            webView.alphaValue = 0  // 外枠の準備ができるまで隠しておき、初回表示のチラつきを防ぐ
            webView.pageZoom = AppSettings.shared.textScale
            loadShell()
            model.preview = self
        }

        func setRemoteImages(_ allow: Bool) {
            guard allow != allowRemoteImages else { return }
            allowRemoteImages = allow
            guard isReady else { return }
            Task {
                await syncRemoteBlocker()
                callJS("setRemoteImages(allow)", ["allow": allowRemoteImages])
            }
        }

        /// 文字の大きさはページ全体の拡大率で、本文の幅は CSS 変数で変える。
        /// どちらも本文の高さが変わるので、JS 側で見ていた位置を保つ（resize・ResizeObserver）。
        func setLayout(scale: Double, width: String) {
            if webView.pageZoom != scale { webView.pageZoom = scale }
            guard width != contentWidth else { return }
            contentWidth = width
            guard isReady else { return }
            callJS("setContentWidth(width)", ["width": width])
        }

        /// JS の src の退避だけでは srcset・CSS の背景・SVG の image などを止めきれないので、
        /// オフの間はコンテンツブロッカーで http/https の読み込みそのものを止める。
        private func syncRemoteBlocker() async {
            await RemoteContentBlocker.prepare()
            let shouldBlock = !allowRemoteImages
            guard shouldBlock != blockingRemote, let ruleList = RemoteContentBlocker.ruleList else { return }
            let controller = webView.configuration.userContentController
            if shouldBlock {
                controller.add(ruleList)
            } else {
                controller.remove(ruleList)
            }
            blockingRemote = shouldBlock
        }

        private func loadShell() {
            shellLoadPending = true
            webView.load(URLRequest(url: LocalSchemeHandler.shellURL))
        }

        func update(html: String, marks: PreviewMarks) {
            let htmlChanged = html != self.html
            let marksChanged = marks != self.marks
            self.html = html
            self.marks = marks
            guard isReady else { return }
            if htmlChanged {
                sendRender()
            } else if marksChanged {
                callJS("setMarks(marks)", ["marks": marks.jsValue])
            }
        }

        func scroll(toLine line: Int) {
            guard isReady else { return }
            callJS("scrollToLine(line)", ["line": line])
        }

        func jump(toLine line: Int) {
            guard isReady else { return }
            callJS("jumpToLine(line)", ["line": line])
        }

        /// マウスの下に横にスクロールできる表・コードがあるか（その上では横スワイプを戻る／進むにしない）。
        private(set) var isOverHorizontalScroll = false

        /// 文書を描き終えている（最初の描画で位置を復元し終えた）。
        var hasShownDocument: Bool { isReady && !needsScrollRestore }

        /// 印刷（toPDF が nil）か、印刷と同じページ割りで PDF に書き出す。
        /// ダークモードのまま印刷すると白い紙に明るい文字になるので、印刷の間だけライトの見た目にする（終わったら戻す）。
        func printDocument(toPDF destination: URL?) {
            guard isReady, let window = webView.window else {
                NSSound.beep()
                return
            }
            let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo()
            info.horizontalPagination = .fit
            info.verticalPagination = .automatic
            info.isHorizontallyCentered = false
            info.isVerticallyCentered = false
            info.topMargin = 40
            info.bottomMargin = 40
            info.leftMargin = 40
            info.rightMargin = 40
            if let destination {
                info.jobDisposition = .save
                info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = destination
            }
            appearanceBeforePrinting = webView.appearance
            webView.appearance = NSAppearance(named: .aqua)
            // Mermaid の図もライトの配色で描き直してから印刷する
            webView.callAsyncJavaScript("await refreshMermaid()", arguments: [:], in: nil, in: .page) { [weak self] _ in
                guard let self else { return }
                let operation = self.webView.printOperation(with: info)
                operation.jobTitle = self.model.url.deletingPathExtension().lastPathComponent
                operation.showsPrintPanel = destination == nil
                operation.showsProgressPanel = true
                operation.view?.frame = self.webView.bounds  // 枠が空のままだと白紙になることがある
                operation.runModal(
                    for: window, delegate: self, didRun: #selector(self.printOperationDidRun(_:success:contextInfo:)), contextInfo: nil
                )
            }
        }

        @objc private func printOperationDidRun(_ operation: NSPrintOperation, success: Bool, contextInfo: UnsafeMutableRawPointer?) {
            webView.appearance = appearanceBeforePrinting
        }

        /// 戻る・進む：保存しておいた位置（行の範囲と割合）を画面上部に出す。
        func show(_ position: ScrollPosition) {
            guard isReady else { return }
            callJS("scrollToLine(line, ratio, last)", ["line": position.line, "ratio": position.ratio, "last": position.endLine])
        }

        // MARK: 検索（照合は Swift、ハイライトは JS の CSS Custom Highlight API。DOM は書き換えない）

        /// 本文のテキストノードをつなげた文字列。JS 側でノードと位置の対応を覚えておく。
        func searchText() async -> String? {
            guard isReady else { return nil }
            return try? await webView.callAsyncJavaScript("return collectText()", contentWorld: .page) as? String
        }

        /// 一致範囲（UTF-16）をハイライトし、current 番目へスクロールする。current が nil なら画面内の最初の一致を選ぶ。
        /// 選んだ番号を返す。
        @discardableResult
        func highlightSearch(_ ranges: [NSRange], current: Int?) async -> Int {
            guard isReady else { return 0 }
            let arguments: [String: Any] = [
                "ranges": ranges.map { [$0.location, $0.length] },
                "current": current ?? -1,
            ]
            let result = try? await webView.callAsyncJavaScript(
                "return highlightSearch(ranges, current)", arguments: arguments, contentWorld: .page
            )
            return (result as? Int) ?? 0
        }

        func clearSearch() {
            guard isReady else { return }
            callJS("clearSearch()", [:])
        }

        /// エディタから切り替わったとき。最新の内容を描画してから、エディタで見ていた行へスクロールする。
        func activate(at position: ScrollPosition) {
            webView.window?.makeFirstResponder(webView)
            if model.hasRendered { update(html: model.rendered.html, marks: model.marks) }
            guard isReady else { return }
            callJS("scrollToLine(line, ratio, last)", ["line": position.line, "ratio": position.ratio, "last": position.endLine])
        }

        func tearDown() {
            webView.configuration.userContentController.removeScriptMessageHandler(forName: "bridge")
            webView.stopLoading()
            model.preview = nil
        }

        /// ブロッカーの状態が設定と合っていない時（オフにした直後や最初の描画）だけ、入れ終えるのを待ってから描画する。
        /// 普段は待たずに描く（直後の scrollToLine などが描画より先に走らないように）。
        private func sendRender() {
            guard isReady else { return }
            if blockingRemote == !allowRemoteImages || RemoteContentBlocker.failed {
                renderNow()
            } else {
                Task {
                    await syncRemoteBlocker()
                    renderNow()
                }
            }
        }

        private func renderNow() {
            guard isReady, let html else { return }
            var body = "allowRemoteImages = allow; setContentWidth(width); render(html, base, marks)"
            var arguments: [String: Any] = [
                "html": html, "base": baseURL, "marks": marks.jsValue, "allow": allowRemoteImages, "width": contentWidth,
            ]
            if needsScrollRestore {
                needsScrollRestore = false
                let position = model.scrollPosition
                if position.line > 1 || position.ratio > 0 {
                    body += "; scrollToLine(line, ratio, last)"
                    arguments["line"] = position.line
                    arguments["ratio"] = position.ratio
                    arguments["last"] = position.endLine
                }
            }
            // 復元のスクロールまで済ませてから表示するので、一番上が一瞬見えることもない。
            callJS(body, arguments) { [weak self] in
                self?.webView.alphaValue = 1
            }
        }

        /// 引数はバインドして渡すので、HTML 文字列のエスケープ事故が起きない。
        private func callJS(_ body: String, _ arguments: [String: Any], completion: (() -> Void)? = nil) {
            webView.callAsyncJavaScript(body, arguments: arguments, in: nil, in: .page) { result in
                if case .failure(let error) = result {
                    log.error("\(body, privacy: .public) failed: \(error, privacy: .public)")
                }
                completion?()
            }
        }

        // MARK: WKScriptMessageHandler

        func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any], let type = body["type"] as? String else { return }
            switch type {
            case "ready":
                isReady = true
                needsScrollRestore = true
                if html == nil { webView.alphaValue = 1 }
                sendRender()
            case "horizontalScroll":
                isOverHorizontalScroll = body["over"] as? Bool ?? false
            case "willJump":
                // 文書内リンク・ルーラーで移動する前（「戻る」の履歴に積む）
                model.recordJump()
            case "toggleTask":
                guard let line = body["line"] as? Int else { return }
                model.toggleTask(line: line)
            case "toggleBookmark":
                guard let lines = body["lines"] as? [Int], !lines.isEmpty else { return }
                model.toggleBookmark(lines: lines)
            case "selection":
                model.selectionCount = Markdown.countChars(body["text"] as? String ?? "")
            case "copy":
                // コードブロックのコピーボタン。WebKit のクリップボード API は独自スキームのページでは使えないことがあるので、こちらで書く。
                guard let text = body["text"] as? String else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            case "scroll":
                guard let line = body["line"] as? Int else { return }
                model.updateScrollPosition(ScrollPosition(
                    line: line, endLine: body["endLine"] as? Int ?? line, ratio: body["ratio"] as? Double ?? 0
                ), from: .preview)
            default:
                break
            }
        }

        // MARK: WKNavigationDelegate

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            guard let url = action.request.url else { return .cancel }
            if url == LocalSchemeHandler.shellURL, shellLoadPending {
                shellLoadPending = false
                return .allow
            }
            if action.navigationType == .linkActivated {
                openLink(url)
            }
            return .cancel
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            isReady = false
            loadShell()
        }

        private func openLink(_ url: URL) {
            if url.scheme == LocalSchemeHandler.scheme, url.host == "file" {
                let fileURL = URL(fileURLWithPath: url.path)
                if UTType(filenameExtension: fileURL.pathExtension)?.conforms(to: .markdown) == true {
                    AppDelegate.shared?.open(fileURL, fragment: url.fragment(percentEncoded: false))
                } else {
                    // 開くと .app や .command がそのまま起動してしまう（git clone したファイルには quarantine が無く、
                    // Gatekeeper の確認も出ない）。文書のリンクからは Finder で場所を示すだけにする。
                    NSWorkspace.shared.activateFileViewerSelecting([fileURL])
                }
            } else if ["http", "https", "mailto"].contains(url.scheme) {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

/// JS とエディタに渡す変更ハイライトと付箋。
struct PreviewMarks: Equatable {
    var changes = LineChanges()
    var latest = LineChanges()
    var bookmarks: [Int] = []

    var jsValue: [String: Any] {
        [
            "changed": changes.changed.map { [$0.lowerBound, $0.upperBound] },
            "latest": latest.changed.map { [$0.lowerBound, $0.upperBound] },
            "deleted": changes.deletedBefore,
            "removed": changes.removed.sorted { $0.key < $1.key }.map { [$0.key, $0.value.lineCount, $0.value.text] as [Any] },
            "bookmarks": bookmarks,
        ]
    }
}

extension UTType {
    static let markdown = UTType(importedAs: "net.daringfireball.markdown")
}

/// リモート画像を読み込まない設定のときに入れるコンテンツブロッカー。最初に使う時に一度だけコンパイルする。
/// コンパイルに失敗した場合は JS の src の退避だけになる。
@MainActor
enum RemoteContentBlocker {
    private(set) static var ruleList: WKContentRuleList?
    private(set) static var failed = false
    private static var loading: Task<Void, Never>?
    /// 遷移（document）は decidePolicyFor でキャンセルするので対象にしない。
    private static let rules = """
        [{"trigger": {"url-filter": "^https?://", "resource-type": ["image", "style-sheet", "script", "font", "raw", "svg-document", "media", "ping"]},
          "action": {"type": "block"}}]
        """

    static func prepare() async {
        if loading == nil {
            loading = Task {
                do {
                    ruleList = try await WKContentRuleListStore.default().compileContentRuleList(
                        forIdentifier: "RemoteContent", encodedContentRuleList: rules
                    )
                } catch {
                    log.error("content rule list failed: \(error, privacy: .public)")
                }
                failed = ruleList == nil
            }
        }
        await loading?.value
    }
}

/// Finder からのファイルドロップを WebKit に渡さず、アプリの「開く」に回す。
final class DocumentWebView: WKWebView {
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        evaluateJavaScript("hideBookmarkHover()")
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        fileURLs(sender).isEmpty ? super.draggingEntered(sender) : .copy
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        fileURLs(sender).isEmpty ? super.draggingUpdated(sender) : .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = fileURLs(sender)
        guard !urls.isEmpty else { return super.performDragOperation(sender) }
        AppDelegate.shared?.open(urls)
        return true
    }

    private func fileURLs(_ info: any NSDraggingInfo) -> [URL] {
        info.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
    }
}

/// WKUserContentController はハンドラを強参照するので、弱参照で中継して循環参照を防ぐ。
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: (any WKScriptMessageHandler)?

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(controller, didReceive: message)
    }
}

/// `yomitoki://app/<name>` は同梱リソース、`yomitoki://file/<絶対パス>` はディスク上の画像を返す。
/// 一時ファイルを作らずに、相対パスの画像を表示するための仕組み。
final class LocalSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "yomitoki"
    static let shellURL = URL(string: "\(scheme)://app/preview.html")!
    private nonisolated static let appResources: Set<String> = [
        "preview.html", "preview.css", "preview.js", "highlight.min.js", "mermaid.min.js",
    ]
    private nonisolated static let maxImageSize: Int64 = 100_000_000

    static func baseURL(forDirectory directory: URL) -> URL {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "file"
        components.path = directory.path.hasSuffix("/") ? directory.path : directory.path + "/"
        return components.url!
    }

    /// 読み込み中のタスク。`stop` されたものは取り除き、完了を通知しない（停止済みタスクへの通知は例外になる）。
    private var tasks: [ObjectIdentifier: any WKURLSchemeTask] = [:]

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        guard let url = task.request.url else { return }
        let id = ObjectIdentifier(task)
        tasks[id] = task
        // ~/Documents などの画像は、初回はプライバシー保護（TCC）の許可待ちで open() がブロックされる。
        // メインスレッドで読むとアプリ全体が固まるので、必ずバックグラウンドで読む。
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = Result { try Self.load(url) }
            await self?.finish(id, url: url, result: result)
        }
    }

    func webView(_ webView: WKWebView, stop task: any WKURLSchemeTask) {
        tasks[ObjectIdentifier(task)] = nil
    }

    private func finish(_ id: ObjectIdentifier, url: URL, result: Result<(Data, String), any Error>) {
        guard let task = tasks.removeValue(forKey: id) else { return }
        switch result {
        case .success(let (data, mimeType)):
            let headers = ["Content-Type": mimeType, "Cache-Control": "no-store"]
            task.didReceive(HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: headers)!)
            task.didReceive(data)
            task.didFinish()
        case .failure(let error):
            log.error("scheme load failed: \(url.absoluteString, privacy: .private) \(error, privacy: .public)")
            task.didFailWithError(error)
        }
    }

    private nonisolated static func load(_ url: URL) throws -> (Data, String) {
        switch url.host {
        case "app":
            let name = url.lastPathComponent
            guard Self.appResources.contains(name),
                  let file = Bundle.main.url(forResource: name, withExtension: nil) else {
                throw URLError(.fileDoesNotExist)
            }
            let mime = UTType(filenameExtension: file.pathExtension)?.preferredMIMEType ?? "text/plain"
            return (try Data(contentsOf: file), mime + "; charset=utf-8")
        case "file":
            // 画像の名前のシンボリックリンクで別のファイルを読ませないよう、リンク先の名前も画像であることを確かめる
            let file = URL(fileURLWithPath: url.path).resolvingSymlinksInPath()
            guard let requested = UTType(filenameExtension: url.pathExtension), requested.conforms(to: .image),
                  let type = UTType(filenameExtension: file.pathExtension), type.conforms(to: .image) else {
                throw URLError(.noPermissionsToReadFile)
            }
            return (try Data(regularFileAt: file, limit: maxImageSize), type.preferredMIMEType ?? "application/octet-stream")
        default:
            throw URLError(.unsupportedURL)
        }
    }
}
