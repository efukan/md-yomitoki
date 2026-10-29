import AppKit
import Observation

/// アプリ全体の設定（UserDefaults に保存）。
@Observable
@MainActor
final class AppSettings {
    static let shared = AppSettings()

    /// プレビューで http/https の画像を読み込むか
    var loadRemoteImages: Bool {
        didSet { UserDefaults.standard.set(loadRemoteImages, forKey: "loadRemoteImages") }
    }

    /// 新しく開いたファイルの比較の基準を git HEAD にするか（最後に選んだ基準を引き継ぐ）
    var compareWithGitHead: Bool {
        didSet { UserDefaults.standard.set(compareWithGitHead, forKey: "compareWithGitHead") }
    }

    /// 外観（端末に合わせる・ライト・ダーク）。アプリ全体（プレビューの WebView も含む）に効く。
    var appearance: AppAppearance {
        didSet {
            UserDefaults.standard.set(appearance.rawValue, forKey: "appearance")
            applyAppearance()
        }
    }

    func applyAppearance() {
        NSApp.appearance = appearance.nsAppearance
    }

    /// 起動した時に、前回終了した時に開いていたファイルを開き直すか
    var restoreOpenFiles: Bool {
        didSet { UserDefaults.standard.set(restoreOpenFiles, forKey: "restoreOpenFiles") }
    }

    /// 文字の大きさの倍率（プレビューとエディタ。全ウィンドウ共通）
    var textScale: Double {
        didSet { UserDefaults.standard.set(textScale, forKey: "textScale") }
    }

    /// プレビューの本文の列の最大幅
    var contentWidth: ContentWidth {
        didSet { UserDefaults.standard.set(contentWidth.rawValue, forKey: "contentWidth") }
    }

    /// ⌘+ / ⌘− で切り替える倍率の段階
    static let textScales: [Double] = [0.75, 0.85, 1, 1.1, 1.25, 1.4, 1.6, 1.8, 2]

    var canZoomIn: Bool { textScale < Self.textScales.last! }
    var canZoomOut: Bool { textScale > Self.textScales.first! }

    func zoomIn() {
        if let next = Self.textScales.first(where: { $0 > textScale + 0.001 }) { textScale = next }
    }

    func zoomOut() {
        if let previous = Self.textScales.last(where: { $0 < textScale - 0.001 }) { textScale = previous }
    }

    private init() {
        loadRemoteImages = UserDefaults.standard.object(forKey: "loadRemoteImages") as? Bool ?? true
        compareWithGitHead = UserDefaults.standard.bool(forKey: "compareWithGitHead")
        restoreOpenFiles = UserDefaults.standard.object(forKey: "restoreOpenFiles") as? Bool ?? true
        appearance = AppAppearance(rawValue: UserDefaults.standard.string(forKey: "appearance") ?? "") ?? .system
        let scale = UserDefaults.standard.double(forKey: "textScale")
        textScale = Self.textScales.contains(scale) ? scale : 1
        contentWidth = ContentWidth(rawValue: UserDefaults.standard.string(forKey: "contentWidth") ?? "") ?? .standard
    }
}

enum AppAppearance: String, CaseIterable {
    case system, light, dark

    var title: String {
        switch self {
        case .system: "端末に合わせる"
        case .light: "ライト"
        case .dark: "ダーク"
        }
    }

    /// nil なら端末の設定に従う
    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// プレビューの本文の列の最大幅（文字の大きさに合わせて伸び縮みするよう em で指定する）
enum ContentWidth: String, CaseIterable {
    case narrow, standard, wide, full

    var title: String {
        switch self {
        case .narrow: "狭い"
        case .standard: "標準"
        case .wide: "広い"
        case .full: "ウインドウの幅"
        }
    }

    var css: String {
        switch self {
        case .narrow: "40em"
        case .standard: "52em"
        case .wide: "68em"
        case .full: "none"
        }
    }
}
