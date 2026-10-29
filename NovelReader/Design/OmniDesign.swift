//
//  OmniDesign.swift
//  NovelReader
//
//  云书阁风格设计系统。
//
//  色板不是拍脑袋调的：深色阶梯、金色主色、米白、蓝色与状态色都来自
//  云书阁 1.3.2 主题包（com.gangz1o.OmniRead.theme）palette 里的真实色值。
//  组件形状（卡片圆角、胶囊、分组 chip）按同类阅读器的信息密度还原。
//

import SwiftUI
import SwiftData

// MARK: - 色值解析

extension Color {
    /// 0xRRGGBB 形式构造，便于直接抄主题包里的色号
    init(hex: UInt32, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

// MARK: - 色板

enum OmniPalette {
    // 深色阶梯：从最底到最高层，云书阁用它堆出「书阁」的纵深感
    static let ink0 = Color(hex: 0x10141C)
    static let ink1 = Color(hex: 0x141A24)
    static let ink2 = Color(hex: 0x171D29)
    static let ink3 = Color(hex: 0x1C2433)
    static let ink4 = Color(hex: 0x20293A)
    static let ink5 = Color(hex: 0x253044)

    // 金色主色：标题、选中态、进度、分隔装饰
    static let gold = Color(hex: 0xC9A86A)
    static let goldBright = Color(hex: 0xD6B67A)
    static let goldDeep = Color(hex: 0xA8864F)
    static let gold2 = Color(hex: 0xB99154)
    static let gold3 = Color(hex: 0xCBAA73)
    static let gold4 = Color(hex: 0x9A7843)
    static let gold5 = Color(hex: 0x81653A)
    static let goldPale = Color(hex: 0xE8D9B5)

    // 米白：浅色主题的纸面
    static let cream = Color(hex: 0xF7F4ED)
    static let cream2 = Color(hex: 0xF1ECE3)
    static let cream3 = Color(hex: 0xFAF7F2)

    // 蓝：链接、信息态
    static let blue = Color(hex: 0x5D8DFF)
    static let blueLight = Color(hex: 0x83A8FF)

    // 状态色
    static let success = Color(hex: 0x4CAF50)
    static let warning = Color(hex: 0xF5A623)
    static let danger = Color(hex: 0xE85D5D)
    static let successAlt = Color(hex: 0x3FA34D)
    static let warningAlt = Color(hex: 0xD98A1F)
    static let dangerAlt = Color(hex: 0xD64545)
}

// MARK: - 皮肤

/// 云书阁内置四套主题 + 跟随系统。
/// 每套只描述「表面/主色/文字」三层，具体组件统一从这里取色。
enum OmniSkin: String, CaseIterable, Codable, Identifiable {
    case classic      // 经典书阁（深色 + 金）
    case bilibili     // 哔哩哔哩
    case blueWhite    // 蓝白
    case shinChan     // 蜡笔小新
    case system       // 跟随系统

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .classic:  return "经典书阁"
        case .bilibili: return "哔哩哔哩"
        case .blueWhite: return "蓝白"
        case .shinChan: return "蜡笔小新"
        case .system:   return "跟随系统"
        }
    }

    var symbolName: String {
        switch self {
        case .classic:  return "books.vertical.fill"
        case .bilibili: return "play.rectangle.fill"
        case .blueWhite: return "drop.fill"
        case .shinChan: return "face.smiling.fill"
        case .system:   return "circle.lefthalf.filled"
        }
    }

    /// 是否深色底（决定状态栏与 tabbar 的明暗）
    var isDark: Bool {
        switch self {
        case .classic, .bilibili: return true
        case .blueWhite, .shinChan, .system: return false
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .classic, .bilibili: return .dark
        case .blueWhite, .shinChan: return .light
        case .system: return nil
        }
    }

    // MARK: 表面

    /// 页面底色
    var background: Color {
        switch self {
        case .classic:  return OmniPalette.ink0
        case .bilibili: return Color(hex: 0x12141A)
        case .blueWhite: return OmniPalette.cream
        case .shinChan: return Color(hex: 0xFDF3E3)
        case .system:   return Color(.systemBackground)
        }
    }

    /// 卡片 / 列表行底色
    var surface: Color {
        switch self {
        case .classic:  return OmniPalette.ink2
        case .bilibili: return Color(hex: 0x1B1E27)
        case .blueWhite: return .white
        case .shinChan: return .white
        case .system:   return Color(.secondarySystemBackground)
        }
    }

    /// 次级表面（分组条、输入框）
    var surfaceAlt: Color {
        switch self {
        case .classic:  return OmniPalette.ink3
        case .bilibili: return Color(hex: 0x242835)
        case .blueWhite: return OmniPalette.cream2
        case .shinChan: return Color(hex: 0xFBEBDA)
        case .system:   return Color(.tertiarySystemBackground)
        }
    }

    // MARK: 文字

    var textPrimary: Color {
        switch self {
        case .classic:  return OmniPalette.cream
        case .bilibili: return Color(hex: 0xF2F4F8)
        case .blueWhite: return Color(hex: 0x1C2433)
        case .shinChan: return Color(hex: 0x3A2A1A)
        case .system:   return Color(.label)
        }
    }

    var textSecondary: Color {
        textPrimary.opacity(0.55)
    }

    // MARK: 主色

    var accent: Color {
        switch self {
        case .classic:  return OmniPalette.gold
        case .bilibili: return Color(hex: 0xFB7299)
        case .blueWhite: return OmniPalette.blue
        case .shinChan: return Color(hex: 0xE85D5D)
        case .system:   return Color.accentColor
        }
    }

    /// 主色的柔化版本，用于胶囊底、进度槽
    var accentSoft: Color {
        accent.opacity(isDark ? 0.18 : 0.12)
    }

    var separator: Color {
        textPrimary.opacity(isDark ? 0.10 : 0.08)
    }
}

// MARK: - 环境注入

private struct OmniSkinKey: EnvironmentKey {
    static let defaultValue: OmniSkin = .classic
}

extension EnvironmentValues {
    var omniSkin: OmniSkin {
        get { self[OmniSkinKey.self] }
        set { self[OmniSkinKey.self] = newValue }
    }
}

// MARK: - 卡片

/// 云书阁式卡片：大圆角、细描边、无重阴影（深色底靠层级色差区分）
struct OmniCard<Content: View>: View {
    @Environment(\.omniSkin) private var skin

    var padding: CGFloat = 14
    var cornerRadius: CGFloat = 16
    var showsBorder: Bool = true

    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(skin.surface)
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(skin.separator, lineWidth: showsBorder ? 1 : 0)
            )
    }
}

// MARK: - 分组胶囊

struct OmniChip: View {
    @Environment(\.omniSkin) private var skin

    let title: String
    var count: Int? = nil
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.subheadline)
                    .fontWeight(isSelected ? .semibold : .regular)
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.caption2)
                        .monospacedDigit()
                }
            }
            .foregroundStyle(isSelected ? skin.background : skin.textSecondary)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(isSelected ? skin.accent : skin.surfaceAlt)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 分区标题

struct OmniSectionHeader: View {
    @Environment(\.omniSkin) private var skin

    let title: String
    var subtitle: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            // 金色竖条，云书阁章节标题的标志性装饰
            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                .fill(skin.accent)
                .frame(width: 3, height: 15)
            Text(title)
                .font(.headline)
                .foregroundStyle(skin.textPrimary)
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(skin.textSecondary)
            }
            Spacer(minLength: 0)
        }
    }
}

// MARK: - 书封卡片

/// 书架卡片：封面 + 书名 + 作者 + 进度。
/// 封面缺省时用「书名首字 + 主题色渐变」占位，避免灰块。
struct OmniBookCard: View {
    @Environment(\.omniSkin) private var skin

    let title: String
    let author: String
    let coverData: Data?
    var progress: Double? = nil
    var isPinned: Bool = false
    var badge: String? = nil

    private var placeholderGradient: LinearGradient {
        LinearGradient(
            colors: [skin.accent.opacity(0.85), skin.accent.opacity(0.35)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var initial: String {
        String(title.trimmingCharacters(in: .whitespaces).prefix(1))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .topTrailing) {
                cover
                    .aspectRatio(3.0 / 4.0, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(skin.separator, lineWidth: 1)
                    )

                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(skin.accent)
                        .padding(5)
                        .background(Circle().fill(skin.background.opacity(0.8)))
                        .padding(5)
                } else if let badge {
                    Text(badge)
                        .font(.caption2)
                        .foregroundStyle(skin.background)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(skin.accent))
                        .padding(5)
                }
            }

            Text(title)
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundStyle(skin.textPrimary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(height: 38, alignment: .top)

            Text(author.isEmpty ? "未知作者" : author)
                .font(.caption2)
                .foregroundStyle(skin.textSecondary)
                .lineLimit(1)

            if let progress, progress > 0 {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(skin.surfaceAlt)
                        Capsule()
                            .fill(skin.accent)
                            .frame(width: max(2, geo.size.width * min(1, progress)))
                    }
                }
                .frame(height: 3)
            }
        }
    }

    @ViewBuilder private var cover: some View {
        if let coverData, let uiImage = UIImage(data: coverData) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
        } else {
            ZStack {
                placeholderGradient
                Text(initial)
                    .font(.system(size: 34, weight: .bold, design: .serif))
                    .foregroundStyle(skin.background.opacity(0.85))
            }
        }
    }
}

// MARK: - 空态

struct OmniEmptyState: View {
    @Environment(\.omniSkin) private var skin

    let symbol: String
    let title: String
    var message: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(skin.accent.opacity(0.75))
            Text(title)
                .font(.headline)
                .foregroundStyle(skin.textPrimary)
            if let message {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(skin.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(skin.background)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(skin.accent))
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(skin.background)
    }
}

// MARK: - 底部导航栏

/// 自绘底部悬浮胶囊。系统 TabView 的 appearance 只在创建时读取一次，
/// 换肤后必须重建视图才会变色，所以这里完全用 SwiftUI 状态驱动。
/// 只保留「书架 / 设置」两页：有声、漫画、书源都收进了书架顶端的分段里，
/// 搜索交给右侧独立圆钮，避免同一条导航重复出现。
struct OmniTabBar: View {
    @Binding var selection: AppState.Tab
    let skin: OmniSkin
    var onSearch: () -> Void = {}

    private struct Item {
        let tab: AppState.Tab
        let title: String
        let symbol: String
    }

    private static let items: [Item] = [
        Item(tab: .library, title: "书架", symbol: "books.vertical.fill"),
        Item(tab: .settings, title: "设置", symbol: "gearshape.fill"),
    ]

    var body: some View {
        HStack(spacing: 10) {
            HStack(spacing: 0) {
                ForEach(Self.items, id: \.title) { item in
                    let isSelected = selection == item.tab
                    Button {
                        guard selection != item.tab else { return }
                        selection = item.tab
                    } label: {
                        VStack(spacing: 3) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 17, weight: isSelected ? .semibold : .regular))
                                .frame(height: 20)
                            Text(item.title)
                                .font(.system(size: 10, weight: isSelected ? .semibold : .regular))
                        }
                        .foregroundStyle(isSelected ? skin.accent : skin.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 52)
                        .background {
                            if isSelected {
                                Capsule(style: .continuous)
                                    .fill(skin.accent.opacity(0.14))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 5)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .frame(maxWidth: .infinity)
            .background {
                Capsule(style: .continuous)
                    .fill(skin.surface)
                    .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
                    .overlay {
                        Capsule(style: .continuous)
                            .strokeBorder(skin.separator, lineWidth: 0.5)
                    }
            }

            Button(action: onSearch) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(skin.textPrimary)
                    .frame(width: 52, height: 52)
                    .background {
                        Circle()
                            .fill(skin.surface)
                            .shadow(color: .black.opacity(0.12), radius: 12, y: 5)
                            .overlay {
                                Circle().strokeBorder(skin.separator, lineWidth: 0.5)
                            }
                    }
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }
}
