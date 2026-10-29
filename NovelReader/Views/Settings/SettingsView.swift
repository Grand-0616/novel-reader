//
//  SettingsView.swift
//  NovelReader
//
//  "我的"：排版默认值、存储管理、文件收纳箱、关于、自签说明
//

import SwiftUI
import SwiftData
import UIKit

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @Environment(SourceRegistry.self) private var registry
    @Environment(\.modelContext) private var modelContext
    @Environment(\.omniSkin) private var skin
    @Environment(LegadoStore.self) private var legadoStore

    @Query(sort: \Book.createdAt, order: .reverse) private var books: [Book]

    @State private var diskUsage: Int64 = 0
    @State private var bookCount = 0
    @State private var showResetAlert = false
    @State private var message: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 16) {
                    NavigationLink {
                        ReadingStatsView()
                    } label: {
                        overviewCard
                    }
                    .buttonStyle(.plain)
                    mainGroup
                    groupTitle("数据与存储")
                    dataGroup
                    groupTitle("关于与帮助")
                    aboutGroup
                    resetRow
                }
                .padding(.top, 8)
                .padding(.bottom, 30)
            }
            .background(skin.background)
            .navigationTitle("我的")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(skin.surface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .task { refresh() }
            .onAppear { refresh() }
            .overlay(alignment: .top) {
                if let message { ImportBanner(message: message).padding(.top, 6) }
            }
            .alert("确认清理？", isPresented: $showResetAlert) {
                Button("取消", role: .cancel) {}
                Button("清理", role: .destructive) {
                    let store = appState.store ?? Store(context: modelContext)
                    store.clearAllCaches()
                    refresh()
                    message = "缓存已清理，下次阅读会自动重新下载"
                }
            } message: {
                Text("会删除所有已缓存的章节正文（书籍条目和原始文件保留）。")
            }
        }
    }

    // MARK: - 阅读概览

    private var readingCount: Int {
        books.filter { $0.readingProgress > 0.001 && $0.readingProgress < 0.999 }.count
    }

    private var finishedCount: Int {
        books.filter { $0.readingProgress >= 0.999 }.count
    }

    private var overviewCard: some View {
        VStack(spacing: 14) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("阅读概览")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(skin.textPrimary)
                    Text("含阅读与收听的时长")
                        .font(.system(size: 12))
                        .foregroundStyle(skin.textSecondary)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 3) {
                    Text(ReadingStats.text(minutes: ReadingStats.totalMinutes))
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(skin.textPrimary)
                        .lineLimit(1)
                    Text("累计阅读")
                        .font(.system(size: 11))
                        .foregroundStyle(skin.textSecondary)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(skin.textSecondary.opacity(0.45))
                    .padding(.top, 3)
            }

            Rectangle()
                .fill(skin.separator)
                .frame(height: 0.5)

            HStack(spacing: 0) {
                statItem(symbol: "clock.fill", tint: skin.accent,
                         value: ReadingStats.text(minutes: ReadingStats.monthMinutes),
                         label: "本月时长")
                statItem(symbol: "book.fill", tint: skin.accent,
                         value: "\(readingCount)", label: "在读")
                statItem(symbol: "checkmark.circle.fill", tint: skin.accent,
                         value: "\(finishedCount)", label: "已读完")
            }

            HStack(spacing: 6) {
                Image(systemName: "leaf.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color(hex: 0x34C759))
                Text("连续阅读 \(ReadingStats.streak) 天 · 今日阅读 \(ReadingStats.text(minutes: ReadingStats.todayMinutes))")
                    .font(.system(size: 12))
                    .foregroundStyle(skin.textSecondary)
                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous).fill(skin.surface)
        }
        .padding(.horizontal, 16)
    }

    private func statItem(symbol: String, tint: Color, value: String, label: String) -> some View {
        VStack(spacing: 5) {
            ZStack {
                Circle().fill(tint.opacity(0.16))
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(tint)
            }
            .frame(width: 24, height: 24)

            Text(value)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(skin.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.65)

            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(skin.textSecondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - 分组卡片

    private func groupTitle(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(skin.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.top, 2)
    }

    private func groupCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 0) { content() }
            .background {
                RoundedRectangle(cornerRadius: 14, style: .continuous).fill(skin.surface)
            }
            .padding(.horizontal, 16)
    }

    private func settingsRow(_ title: String,
                             icon: String,
                             tint: Color,
                             value: String? = nil) -> some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(tint)
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 28, height: 28)

            Text(title)
                .font(.system(size: 15))
                .foregroundStyle(skin.textPrimary)

            Spacer(minLength: 8)

            if let value {
                Text(value)
                    .font(.system(size: 13))
                    .foregroundStyle(skin.textSecondary)
                    .lineLimit(1)
            }

            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(skin.textSecondary.opacity(0.45))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .contentShape(Rectangle())
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(skin.separator)
            .frame(height: 0.5)
            .padding(.leading, 54)
    }

    // MARK: - 主分组

    private var mainGroup: some View {
        groupCard {
            NavigationLink {
                ReaderSettingsPanel(asSheet: false)
            } label: {
                settingsRow("通用设置", icon: "gearshape.fill", tint: Color(hex: 0x8E8E93))
            }
            .buttonStyle(.plain)

            rowDivider

            NavigationLink {
                SkinAndIconView()
            } label: {
                settingsRow("外观与图标", icon: "circle.lefthalf.filled", tint: Color(hex: 0x1C1C1E))
            }
            .buttonStyle(.plain)

            rowDivider

            NavigationLink {
                AIProviderView()
            } label: {
                settingsRow("AI 提供商", icon: "sparkles", tint: Color(hex: 0x0A84FF))
            }
            .buttonStyle(.plain)

            rowDivider

            NavigationLink {
                StorageDetailView(onChange: refresh)
            } label: {
                settingsRow("藏书阁", icon: "books.vertical.fill", tint: Color(hex: 0xFF9500),
                            value: "\(bookCount) 本")
            }
            .buttonStyle(.plain)

            rowDivider

            NavigationLink {
                LegadoSourcesView()
            } label: {
                settingsRow("书源管理", icon: "square.and.arrow.down.fill", tint: Color(hex: 0x34C759),
                            value: "\(legadoStore.sources.count) 个")
            }
            .buttonStyle(.plain)

            rowDivider

            NavigationLink {
                FavoritesView()
            } label: {
                settingsRow("收藏管理", icon: "heart.fill", tint: Color(hex: 0xFF2D55),
                            value: "\(books.filter(\.isPinned).count)")
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 数据与存储

    private var dataGroup: some View {
        groupCard {
            NavigationLink {
                StorageDetailView(onChange: refresh)
            } label: {
                settingsRow("下载与缓存", icon: "arrow.down.circle.fill", tint: Color(hex: 0x34C759),
                            value: ByteCountFormatter.string(fromByteCount: diskUsage, countStyle: .file))
            }
            .buttonStyle(.plain)

            rowDivider

            NavigationLink {
                SyncBackupView()
            } label: {
                settingsRow("同步与备份", icon: "arrow.triangle.2.circlepath.circle.fill",
                            tint: Color(hex: 0x0A84FF))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - 关于

    private var aboutGroup: some View {
        groupCard {
            NavigationLink {
                AboutView()
            } label: {
                settingsRow("关于与帮助", icon: "info.circle.fill", tint: Color(hex: 0x636366),
                            value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
            }
            .buttonStyle(.plain)

            rowDivider

            HStack(spacing: 12) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(hex: 0x30D158))
                    Image(systemName: "tray.and.arrow.down.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                }
                .frame(width: 28, height: 28)

                VStack(alignment: .leading, spacing: 2) {
                    Text("文件收纳箱")
                        .font(.system(size: 15))
                        .foregroundStyle(skin.textPrimary)
                    Text("Documents/Inbox，放进去后回书架下拉自动导入")
                        .font(.system(size: 11))
                        .foregroundStyle(skin.textSecondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
        }
    }

    private var resetRow: some View {
        Button {
            showResetAlert = true
        } label: {
            Text("重置所有缓存")
                .font(.system(size: 15))
                .foregroundStyle(Color(hex: 0xE85D5D))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(skin.surface)
                }
                .padding(.horizontal, 16)
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
    }

    private func refresh() {
        let store = appState.store ?? Store(context: modelContext)
        diskUsage = store.diskUsage()
        bookCount = store.allBooks().count
    }
}

// MARK: - 存储明细

struct StorageDetailView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.modelContext) private var modelContext
    @Environment(\.omniSkin) private var skin
    @Query(sort: \Book.createdAt, order: .reverse) private var books: [Book]
    var onChange: () -> Void

    var body: some View {
        List {
            Section {
                ForEach(books) { book in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(book.title)
                                .font(.subheadline)
                                .foregroundStyle(skin.textPrimary)
                                .lineLimit(1)
                            Text("\(book.cachedChapterCount)/\(book.chapterCount) 章已缓存")
                                .font(.caption2)
                                .foregroundStyle(skin.textSecondary)
                        }
                        Spacer()
                        Text(ByteCountFormatter.string(
                            fromByteCount: cacheSize(for: book), countStyle: .file))
                            .font(.caption)
                            .foregroundStyle(skin.textSecondary)
                    }
                    .listRowBackground(skin.surface)
                    .swipeActions {
                        Button(role: .destructive) {
                            let store = appState.store ?? Store(context: modelContext)
                            ChapterCache.removeAll(bookID: book.id.uuidString)
                            for ch in book.chapters {
                                ch.isCached = false
                                ch.cacheRelativePath = nil
                            }
                            book.cachedChapterCount = 0
                            try? modelContext.save()
                            onChange()
                        } label: { Label("清缓存", systemImage: "trash") }
                    }
                }
            } header: {
                Text("每本书的缓存")
            } footer: {
                Text("本地导入的书清掉缓存后需要重新导入；网络书源的书清掉后会在阅读时重新下载。")
            }
        }
        .scrollContentBackground(.hidden)
        .background(skin.background)
        .navigationTitle("存储")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(skin.surface, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    private func cacheSize(for book: Book) -> Int64 {
        let dir = BookStorage.chapterCacheDirectory.appendingPathComponent(book.id.uuidString)
        guard let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let f as URL in en {
            let v = try? f.resourceValues(forKeys: [.fileSizeKey])
            total += Int64(v?.fileSize ?? 0)
        }
        return total
    }
}

// MARK: - 关于

struct AboutView: View {
    @Environment(\.omniSkin) private var skin

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("书虫")
                        .font(.largeTitle.bold())
                        .foregroundStyle(skin.textPrimary)
                    Text("本地优先的小说阅读器 · 支持 NAS 书库")
                        .font(.subheadline)
                        .foregroundStyle(skin.textSecondary)
                }

                group("支持的格式") {
                    bullet("TXT（自动识别 UTF-8 / GBK / GB18030 / Big5 编码，自动分章）")
                    bullet("EPUB（解析 OPF/spine/目录，含内嵌样式文本）")
                    bullet("HTML/HTM（网页正文提取）")
                    bullet("NAS 上的 TXT/EPUB 直接下载到本地离线阅读")
                }

                group("NAS 书库") {
                    bullet("OPDS 1.2：calibre-web、COPS、Komga、Kavita")
                    bullet("HTTP 目录索引：nginx autoindex、Apache、群晖")
                    bullet("WebDAV：群晖/威联通，支持 Basic 认证")
                    bullet("需要 Basic 认证时，在书源里填用户名密码即可")
                }

                group("自签安装（个人使用）") {
                    bullet("方式一：Xcode 直装 — 用 Apple ID 免费账号，选 Personal Team，真机运行。免费证书 7 天有效，到期重签一次即可。")
                    bullet("方式二：AltStore / SideStore — 电脑装 AltServer，手机自动续签（推荐长期使用）。")
                    bullet("方式三：Sideloadly / TrollStore（支持的系统版本）直接安装 ipa。")
                    bullet("打包 ipa：Xcode → Product → Archive → Distribute App → Development/Ad-Hoc 导出，或用 `xcodebuild -exportArchive`。")
                }

                group("隐私") {
                    Text("所有书源、账号、阅读记录仅保存在本机沙盒内，不上传任何服务器。本 App 没有内建任何第三方统计或广告。")
                        .font(.footnote)
                        .foregroundStyle(skin.textSecondary)
                }

                Spacer(minLength: 20)
            }
            .padding(20)
        }
        .background(skin.background)
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(skin.surface, for: .navigationBar)
        .toolbarBackground(.visible, for: .navigationBar)
    }

    private func group(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)
                .foregroundStyle(skin.textPrimary)
            content()
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•").foregroundStyle(skin.accent)
            Text(text)
                .font(.footnote)
                .foregroundStyle(skin.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
