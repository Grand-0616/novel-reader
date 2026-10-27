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

    @State private var diskUsage: Int64 = 0
    @State private var bookCount = 0
    @State private var showResetAlert = false
    @State private var message: String?

    var body: some View {
        @Bindable var appState = appState

        NavigationStack {
            List {
                // MARK: 排版
                Section("阅读外观") {
                    NavigationLink {
                        ReaderSettingsPanel(asSheet: false)
                    } label: {
                        Label("排版设置", systemImage: "textformat.size")
                    }
                    TypographyPreviewCard()
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(Color.clear)
                }

                // MARK: 存储
                Section("存储") {
                    HStack {
                        Label("已占用空间", systemImage: "internaldrive")
                        Spacer()
                        Text(ByteCountFormatter.string(fromByteCount: diskUsage, countStyle: .file))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    HStack {
                        Label("书籍数量", systemImage: "books.vertical")
                        Spacer()
                        Text("\(bookCount) 本").foregroundStyle(.secondary)
                    }
                    NavigationLink {
                        StorageDetailView(onChange: refresh)
                    } label: {
                        Label("清理缓存", systemImage: "trash")
                    }
                }

                // MARK: 文件
                Section {
                    HStack {
                        Label("文件收纳箱", systemImage: "tray.and.arrow.down")
                        Spacer()
                        Text("Inbox").foregroundStyle(.secondary).font(.caption)
                    }
                    Text("把 TXT / EPUB 拖进「文件」App → 我的 iPhone → 书虫 → Inbox，回到书架下拉即可自动导入。也可以在「文件」里长按文件 → 共享 → 书虫。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: { Text("导入方式") }

                // MARK: 书源
                Section("书源") {
                    HStack {
                        Label("书源数量", systemImage: "network")
                        Spacer()
                        Text("\(registry.sources.count)").foregroundStyle(.secondary)
                    }
                    Button {
                        UIPasteboard.general.string = registry.exportJSON()
                        message = "书源配置已复制"
                    } label: {
                        Label("复制书源配置 JSON", systemImage: "doc.on.doc")
                    }
                }

                // MARK: 关于
                Section("关于") {
                    HStack {
                        Text("版本")
                        Spacer()
                        Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
                            .foregroundStyle(.secondary)
                    }
                    NavigationLink {
                        AboutView()
                    } label: {
                        Label("关于与自签说明", systemImage: "info.circle")
                    }
                }

                Section {
                    Button("重置所有缓存", role: .destructive) {
                        showResetAlert = true
                    }
                }
            }
            .navigationTitle("我的")
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
    @Query(sort: \Book.createdAt, order: .reverse) private var books: [Book]
    var onChange: () -> Void

    var body: some View {
        List {
            Section {
                ForEach(books) { book in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(book.title).font(.subheadline).lineLimit(1)
                            Text("\(book.cachedChapterCount)/\(book.chapterCount) 章已缓存")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(ByteCountFormatter.string(
                            fromByteCount: cacheSize(for: book), countStyle: .file))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
        .navigationTitle("存储")
        .navigationBarTitleDisplayMode(.inline)
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
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("书虫").font(.largeTitle.bold())
                    Text("本地优先的小说阅读器 · 支持 NAS 书库")
                        .font(.subheadline).foregroundStyle(.secondary)
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
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 20)
            }
            .padding(20)
        }
        .navigationTitle("关于")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func group(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            content()
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text("•").foregroundStyle(.secondary)
            Text(text).font(.footnote).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
