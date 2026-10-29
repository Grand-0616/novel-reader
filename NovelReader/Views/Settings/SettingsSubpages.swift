//
//  SettingsSubpages.swift
//  NovelReader
//
//  设置页的二级页面：外观与图标 / AI 提供商 / 收藏管理 / 同步与备份。
//

import SwiftUI
import SwiftData
import UIKit

// MARK: - 外观与图标

struct SkinAndIconView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.omniSkin) private var skin

    private var appIcon: UIImage? {
        UIImage(named: "AppIcon-1024") ?? UIImage(named: "AppIcon-60@3x")
    }

    var body: some View {
        @Bindable var appState = appState

        ScrollView {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("主题皮肤")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(skin.textSecondary)

                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 12)], spacing: 12) {
                        ForEach(OmniSkin.allCases) { item in
                            Button {
                                appState.skin = item
                            } label: {
                                VStack(spacing: 8) {
                                    ZStack {
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .fill(item.background)
                                        VStack(spacing: 3) {
                                            Capsule().fill(item.accent).frame(width: 26, height: 4)
                                            Capsule().fill(item.textSecondary.opacity(0.5)).frame(width: 34, height: 3)
                                            Capsule().fill(item.textSecondary.opacity(0.3)).frame(width: 30, height: 3)
                                        }
                                    }
                                    .frame(height: 62)
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                                            .strokeBorder(
                                                appState.skin == item ? item.accent : skin.separator,
                                                lineWidth: appState.skin == item ? 2 : 0.5)
                                    }

                                    Text(item.displayName)
                                        .font(.system(size: 12))
                                        .foregroundStyle(appState.skin == item ? item.accent : skin.textSecondary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(14)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(skin.surface)
                }
                .padding(.horizontal, 16)

                VStack(alignment: .leading, spacing: 12) {
                    Text("App 图标")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(skin.textSecondary)

                    HStack(spacing: 14) {
                        if let appIcon {
                            Image(uiImage: appIcon)
                                .resizable()
                                .frame(width: 66, height: 66)
                                .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
                        } else {
                            RoundedRectangle(cornerRadius: 15, style: .continuous)
                                .fill(skin.surfaceAlt)
                                .frame(width: 66, height: 66)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text("云书阁 · 墨金")
                                .font(.system(size: 15, weight: .medium))
                                .foregroundStyle(skin.textPrimary)
                            Text("深墨蓝底 + 金色云纹 + 摊开的书")
                                .font(.system(size: 12))
                                .foregroundStyle(skin.textSecondary)
                        }
                        Spacer()
                    }
                }
                .padding(14)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(skin.surface)
                }
                .padding(.horizontal, 16)
            }
            .padding(.vertical, 14)
        }
        .background(skin.background)
        .navigationTitle("外观与图标")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(skin.surface, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }
}

// MARK: - AI 提供商

struct AIProviderView: View {
    @Environment(\.omniSkin) private var skin

    private struct Provider: Identifiable {
        let id = UUID()
        let name: String
        let detail: String
        let symbol: String
        let tint: Color
    }

    private let providers: [Provider] = [
        .init(name: "OpenAI", detail: "GPT / TTS / 图像", symbol: "circle.hexagongrid.fill", tint: Color(hex: 0x10A37F)),
        .init(name: "Anthropic Claude", detail: "对话", symbol: "a.circle.fill", tint: Color(hex: 0xD97757)),
        .init(name: "DeepSeek", detail: "对话", symbol: "d.circle.fill", tint: Color(hex: 0x4D6BFE)),
        .init(name: "月之暗面 Kimi", detail: "对话", symbol: "k.circle.fill", tint: Color(hex: 0x1F1F1F)),
        .init(name: "硅基流动", detail: "对话 / 图像 / 语音", symbol: "square.stack.3d.up.fill", tint: Color(hex: 0x7C4DFF)),
        .init(name: "智谱 GLM", detail: "对话 / 图像 / 语音", symbol: "z.circle.fill", tint: Color(hex: 0x2F6BFF)),
    ]

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("自带密钥（BYOK）")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(skin.textPrimary)
                    Text("这里的服务商都还没接入。接入后你填自己的 API Key，费用直接结算给服务商，App 不抽成、不设额度。")
                        .font(.system(size: 13))
                        .foregroundStyle(skin.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(skin.surface)
                }
                .padding(.horizontal, 16)

                VStack(spacing: 0) {
                    ForEach(Array(providers.enumerated()), id: \.element.id) { index, item in
                        HStack(spacing: 12) {
                            ZStack {
                                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(item.tint)
                                Image(systemName: item.symbol)
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(.white)
                            }
                            .frame(width: 28, height: 28)

                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name)
                                    .font(.system(size: 15))
                                    .foregroundStyle(skin.textPrimary)
                                Text(item.detail)
                                    .font(.system(size: 11))
                                    .foregroundStyle(skin.textSecondary)
                            }
                            Spacer()
                            Text("未接入")
                                .font(.system(size: 11))
                                .foregroundStyle(skin.textSecondary)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(skin.surfaceAlt))
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 11)

                        if index < providers.count - 1 {
                            Rectangle()
                                .fill(skin.separator)
                                .frame(height: 0.5)
                                .padding(.leading, 54)
                        }
                    }
                }
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(skin.surface)
                }
                .padding(.horizontal, 16)
            }
            .padding(.vertical, 14)
        }
        .background(skin.background)
        .navigationTitle("AI 提供商")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(skin.surface, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }
}

// MARK: - 收藏管理

struct FavoritesView: View {
    @Environment(\.omniSkin) private var skin
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\Book.lastOpenedAt, order: .reverse),
                  SortDescriptor(\Book.createdAt, order: .reverse)])
    private var books: [Book]

    @State private var readingBook: Book?

    private var pinned: [Book] { books.filter(\.isPinned) }

    var body: some View {
        Group {
            if pinned.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "heart")
                        .font(.system(size: 40, weight: .light))
                        .foregroundStyle(skin.textSecondary.opacity(0.5))
                    Text("还没有收藏的书")
                        .font(.system(size: 14))
                        .foregroundStyle(skin.textSecondary)
                    Text("在书架长按书籍 → 置顶，就会出现在这里")
                        .font(.system(size: 12))
                        .foregroundStyle(skin.textSecondary.opacity(0.7))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(skin.background)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(pinned.enumerated()), id: \.element.id) { index, book in
                            Button {
                                readingBook = book
                            } label: {
                                HStack(spacing: 12) {
                                    cover(book)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(book.title)
                                            .font(.system(size: 15))
                                            .foregroundStyle(skin.textPrimary)
                                            .lineLimit(1)
                                        Text(book.displayAuthor)
                                            .font(.system(size: 12))
                                            .foregroundStyle(skin.textSecondary)
                                            .lineLimit(1)
                                    }
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(skin.textSecondary.opacity(0.5))
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 10)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                Button {
                                    book.isPinned = false
                                    try? modelContext.save()
                                } label: {
                                    Label("取消收藏", systemImage: "heart.slash")
                                }
                            }

                            if index < pinned.count - 1 {
                                Rectangle()
                                    .fill(skin.separator)
                                    .frame(height: 0.5)
                                    .padding(.leading, 66)
                            }
                        }
                    }
                    .background {
                        RoundedRectangle(cornerRadius: 14, style: .continuous).fill(skin.surface)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                }
                .background(skin.background)
            }
        }
        .navigationTitle("收藏管理")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(skin.surface, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
        .fullScreenCover(item: $readingBook) { book in
            ReaderView(book: book)
        }
    }

    @ViewBuilder
    private func cover(_ book: Book) -> some View {
        Group {
            if let data = book.coverData, let image = UIImage(data: data) {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(colors: [skin.accent.opacity(0.32), skin.accent.opacity(0.10)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Text(String(book.title.prefix(1)))
                        .font(.system(size: 16, weight: .semibold, design: .serif))
                        .foregroundStyle(skin.accent)
                }
            }
        }
        .frame(width: 40, height: 54)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }
}

// MARK: - 同步与备份

struct SyncBackupView: View {
    @Environment(\.omniSkin) private var skin

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Label("iCloud 同步", systemImage: "icloud")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(skin.textPrimary)
                    Text("书架、阅读进度、设置与书源可以同步到 iCloud，换设备后自动恢复。这个功能还没接上，目前数据只存在本机。")
                        .font(.system(size: 13))
                        .foregroundStyle(skin.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(skin.surface)
                }
                .padding(.horizontal, 16)

                VStack(alignment: .leading, spacing: 8) {
                    Label("本地备份", systemImage: "externaldrive")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(skin.textPrimary)
                    Text("把 Documents 目录整体拷出来就是完整备份：书籍、封面、章节缓存、书源配置都在里面。用「文件」App 直接复制即可。")
                        .font(.system(size: 13))
                        .foregroundStyle(skin.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(skin.surface)
                }
                .padding(.horizontal, 16)
            }
            .padding(.vertical, 14)
        }
        .background(skin.background)
        .navigationTitle("同步与备份")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(skin.surface, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }
}

// MARK: - 阅读统计

struct ReadingStatsView: View {
    @Environment(\.omniSkin) private var skin
    @Query(sort: \Book.createdAt, order: .reverse) private var books: [Book]

    private var week: [(date: Date, seconds: Double)] {
        ReadingStats.dailySeconds(daysBack: 7)
    }

    private var weekMax: Double {
        max(week.map(\.seconds).max() ?? 0, 60)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                totalCard
                weekCard
                detailCard
            }
            .padding(.top, 8)
            .padding(.bottom, 30)
        }
        .background(skin.background)
        .navigationTitle("阅读统计")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(skin.surface, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    private var totalCard: some View {
        VStack(spacing: 10) {
            Text(ReadingStats.text(minutes: ReadingStats.totalMinutes))
                .font(.system(size: 34, weight: .semibold, design: .rounded))
                .foregroundStyle(skin.textPrimary)
            Text("累计阅读时长")
                .font(.system(size: 12))
                .foregroundStyle(skin.textSecondary)

            HStack(spacing: 0) {
                miniStat("本月", ReadingStats.text(minutes: ReadingStats.monthMinutes))
                miniStat("今日", ReadingStats.text(minutes: ReadingStats.todayMinutes))
                miniStat("连续", "\(ReadingStats.streak) 天")
            }
            .padding(.top, 6)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(skin.surface)
        }
        .padding(.horizontal, 16)
    }

    private func miniStat(_ label: String, _ value: String) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(skin.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(skin.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var weekCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("最近 7 天")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(skin.textPrimary)

            HStack(alignment: .bottom, spacing: 10) {
                ForEach(Array(week.enumerated()), id: \.offset) { _, item in
                    VStack(spacing: 6) {
                        Text(shortMinutes(item.seconds))
                            .font(.system(size: 9))
                            .foregroundStyle(skin.textSecondary)
                            .lineLimit(1)

                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(item.seconds > 0 ? skin.accent : skin.surfaceAlt)
                            .frame(height: max(4, CGFloat(item.seconds / weekMax) * 92))

                        Text(weekdayLabel(item.date))
                            .font(.system(size: 10))
                            .foregroundStyle(skin.textSecondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 130, alignment: .bottom)
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(skin.surface)
        }
        .padding(.horizontal, 16)
    }

    private var detailCard: some View {
        VStack(spacing: 0) {
            detailRow("有记录的天数", "\(ReadingStats.activeDays) 天")
            Rectangle().fill(skin.separator).frame(height: 0.5)
            detailRow("在读", "\(books.filter { $0.readingProgress > 0.001 && $0.readingProgress < 0.999 }.count) 本")
            Rectangle().fill(skin.separator).frame(height: 0.5)
            detailRow("已读完", "\(books.filter { $0.readingProgress >= 0.999 }.count) 本")
            Rectangle().fill(skin.separator).frame(height: 0.5)
            detailRow("藏书总量", "\(books.count) 本")
        }
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(skin.surface)
        }
        .padding(.horizontal, 16)
    }

    private func detailRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 14))
                .foregroundStyle(skin.textPrimary)
            Spacer()
            Text(value)
                .font(.system(size: 14))
                .foregroundStyle(skin.textSecondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private func shortMinutes(_ seconds: Double) -> String {
        if seconds < 60 { return seconds > 0 ? "<1" : "0" }
        let m = Int((seconds / 60).rounded())
        if m < 60 { return "\(m)" }
        return "\(m / 60)h"
    }

    private func weekdayLabel(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "EEE"
        return f.string(from: date).replacingOccurrences(of: "周", with: "")
    }
}
