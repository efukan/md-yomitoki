import Foundation
import Observation
import Sparkle

/// Sparkle による自動アップデート。更新情報（appcast.xml）は GitHub の最新の Release に添付したものを見る
/// （Info.plist の `SUFeedURL`。更新の dmg は Info.plist の `SUPublicEDKey` に対応する鍵で署名してある）。
/// 1日1回確かめて、新しい版があれば知らせる（`SUEnableAutomaticChecks`）。ダウンロードとインストールまで
/// 自動にするかは設定ウィンドウで選ぶ。どちらの設定も Sparkle が UserDefaults に持つ。
@MainActor @Observable
final class Updater {
    static let shared = Updater()

    @ObservationIgnored private let controller = SPUStandardUpdaterController(
        startingUpdater: false, updaterDelegate: nil, userDriverDelegate: nil)
    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    private init() {
        // 更新の画面の「今後は自動的に…」など、Sparkle 側で変わった時も設定ウィンドウに映す（SPUUpdater は KVO で知らせる）。
        let updater = controller.updater
        observations = [
            updater.observe(\.automaticallyChecksForUpdates) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.withMutation(keyPath: \.automaticallyChecks) {} }
            },
            updater.observe(\.automaticallyDownloadsUpdates) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.withMutation(keyPath: \.automaticallyDownloads) {} }
            },
        ]
    }

    /// Debug ビルドでは確かめない（開発中のアプリが公開版に置き換わらないように）。
    let isEnabled: Bool = {
        #if DEBUG
        false
        #else
        true
        #endif
    }()

    func start() {
        guard isEnabled else { return }
        controller.startUpdater()
    }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    var automaticallyChecks: Bool {
        get {
            access(keyPath: \.automaticallyChecks)
            return controller.updater.automaticallyChecksForUpdates
        }
        set { controller.updater.automaticallyChecksForUpdates = newValue }
    }

    var automaticallyDownloads: Bool {
        get {
            access(keyPath: \.automaticallyDownloads)
            return controller.updater.automaticallyDownloadsUpdates
        }
        set { controller.updater.automaticallyDownloadsUpdates = newValue }
    }
}
