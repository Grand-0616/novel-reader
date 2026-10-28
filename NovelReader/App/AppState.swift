//
//  AppState.swift
//  NovelReader
//
//  全局状态：阅读器外观设置（持久化到 UserDefaults）、Tab 选择、分享导入队列
//

import SwiftUI
import SwiftData
import Observation

// MARK: - 主题

enum ReaderTheme: String, CaseIterable, Codable, Identifiable {
    case paper      // 米黄纸
    case white      // 纯白
    case sepia      // 棕褐
    case green      // 护眼绿
    case dark       // 夜间
    case black      // 纯黑（OLED）

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .paper: return "羊皮纸"
        case .white: return "纯白"
        case .sepia: return "棕褐"
        case .green: return "护眼绿"
        case .dark:  return "夜间"
        case .black: return "纯黑"
        }
    }

    var isDark: Bool { self == .dark || self == .black }

    var backgroundColor: Color {
        switch self {
        case .paper: return Color(red: 0.96, green: 0.93, blue: 0.86)
        case .white: return Color.white
        case .sepia: return Color(red: 0.94, green: 0.88, blue: 0.78)
        case .green: return Color(red: 0.80, green: 0.89, blue: 0.81)
        case .dark:  return Color(red: 0.10, green: 0.11, blue: 0.10)
        case .black: return Color.black
        }
    }

    var textColor: Color {
        switch self {
        case .paper, .sepia: return Color(red: 0.20, green: 0.17, blue: 0.13)
        case .white:         return Color(red: 0.10, green: 0.10, blue: 0.11)
        case .green:         return Color(red: 0.15, green: 0.21, blue: 0.16)
        case .dark:          return Color(red: 0.78, green: 0.78, blue: 0.76)
        case .black:         return Color(red: 0.72, green: 0.72, blue: 0.72)
        }
    }

    var secondaryTextColor: Color { textColor.opacity(0.55) }

    var uiColor: UIColor { UIColor(backgroundColor) }

    /// 用于 SwiftUI 整机配色
    var colorScheme: ColorScheme? {
        if isDark { return .dark }
        return .light
    }
}

enum PageTurnStyle: String, CaseIterable, Codable, Identifiable {
    /// 左右滑动翻页（横向分页）
    case slide
    /// 无动画直接切页（横向分页）
    case none
    /// 仿真覆盖（横向分页）
    case cover
    /// 上下滑动连续滚动（不分页，整章连续排版）
    case verticalScroll = "vertical"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .slide:          return "左右滑动"
        case .none:           return "无动画"
        case .cover:          return "仿真覆盖"
        case .verticalScroll: return "上下滑动"
        }
    }

    /// 该模式下正文是否连续滚动（不做分页）
    var isScrollMode: Bool {
        self == .verticalScroll
    }
}

// MARK: - AppState

@Observable
@MainActor
final class AppState {
    enum Tab: Hashable {
        case library, discover, sources, settings
    }

    var selectedTab: Tab = .library

    // ---- 阅读外观（UserDefaults 持久化） ----
    // 说明：@Observable 宏会为每个存储属性生成 _prop / prop 访问器，
    // 在 didSet 里直接读 self.prop 会撞上"正在初始化"的检查，这里统一走 persist()。
    var theme: ReaderTheme = .paper { didSet { persist() } }
    var fontSize: Double = 19 { didSet { persist() } }
    var lineSpacing: Double = 8 { didSet { persist() } }
    var paragraphSpacing: Double = 10 { didSet { persist() } }
    var pageTurnStyle: PageTurnStyle = .slide { didSet { persist() } }
    /// 页边距百分比
    var marginHorizontal: Double = 0.055 { didSet { persist() } }
    var marginVertical: Double = 0.03 { didSet { persist() } }
    /// 跟随系统深色
    var followSystemAppearance: Bool = false { didSet { persist() } }
    /// 是否显示页脚（章节名 / 页码 / 进度）
    var showFooter: Bool = true { didSet { persist() } }

    // ---- 状态 ----
    var store: Store?
    var importProgress: ImportProgress?
    var alertMessage: String?
    var pendingSharedFiles: [URL] = []

    private var loaded = false

    init() { loadSettings() }

    var appearance: ReaderTheme {
        followSystemAppearance ? .paper : theme
    }

    var themeTint: Color {
        Color.accentColor
    }

    func attach(context: ModelContext) {
        if store == nil {
            store = Store(context: context)
        }
    }

    // MARK: - URL 处理（分享 / 文件 App）

    func handleIncomingURL(_ url: URL) {
        if url.isFileURL {
            pendingSharedFiles.append(url)
            selectedTab = .library
        }
    }

    // MARK: - 持久化

    private enum Keys {
        static let theme = "reader.theme"
        static let fontSize = "reader.fontSize"
        static let lineSpacing = "reader.lineSpacing"
        static let paragraphSpacing = "reader.paragraphSpacing"
        static let pageTurn = "reader.pageTurn"
        static let marginH = "reader.marginH"
        static let marginV = "reader.marginV"
        static let followSystem = "reader.followSystem"
        static let showFooter = "reader.showFooter"
    }

    private func persist() {
        guard loaded else { return }
        let d = UserDefaults.standard
        d.set(theme.rawValue, forKey: Keys.theme)
        d.set(fontSize, forKey: Keys.fontSize)
        d.set(lineSpacing, forKey: Keys.lineSpacing)
        d.set(paragraphSpacing, forKey: Keys.paragraphSpacing)
        d.set(pageTurnStyle.rawValue, forKey: Keys.pageTurn)
        d.set(marginHorizontal, forKey: Keys.marginH)
        d.set(marginVertical, forKey: Keys.marginV)
        d.set(followSystemAppearance, forKey: Keys.followSystem)
        d.set(showFooter, forKey: Keys.showFooter)
    }

    private func loadSettings() {
        let d = UserDefaults.standard
        if let raw = d.string(forKey: Keys.theme), let t = ReaderTheme(rawValue: raw) { theme = t }
        if d.object(forKey: Keys.fontSize) != nil { fontSize = d.double(forKey: Keys.fontSize) }
        if d.object(forKey: Keys.lineSpacing) != nil { lineSpacing = d.double(forKey: Keys.lineSpacing) }
        if d.object(forKey: Keys.paragraphSpacing) != nil { paragraphSpacing = d.double(forKey: Keys.paragraphSpacing) }
        if let raw = d.string(forKey: Keys.pageTurn), let p = PageTurnStyle(rawValue: raw) { pageTurnStyle = p }
        if d.object(forKey: Keys.marginH) != nil { marginHorizontal = d.double(forKey: Keys.marginH) }
        if d.object(forKey: Keys.marginV) != nil { marginVertical = d.double(forKey: Keys.marginV) }
        followSystemAppearance = d.bool(forKey: Keys.followSystem)
        if d.object(forKey: Keys.showFooter) != nil { showFooter = d.bool(forKey: Keys.showFooter) }
        loaded = true
    }

    func resetReaderDefaults() {
        theme = .paper
        fontSize = 19
        lineSpacing = 8
        paragraphSpacing = 10
        pageTurnStyle = .slide
        marginHorizontal = 0.055
        marginVertical = 0.03
        showFooter = true
    }
}
