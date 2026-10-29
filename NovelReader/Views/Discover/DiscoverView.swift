//
//  DiscoverView.swift
//  NovelReader
//
//  发现：浏览 NAS 书库目录 / 在线书源搜索 / 一键加入书架并下载
//
//  本轮改动：
//   - 服务器列表里已下载过的书显示"已在书架"标记，避免重复下载
//   - 导入/下载过程显示真实进度条（章节维度 + 字节维度）
//   - 修掉 .alert(isPresented: .constant(...)) 关不掉的弹窗
//

import SwiftUI
import SwiftData

struct DiscoverView: View {
    @Environment(AppState.self) private var appState
    @Environment(SourceRegistry.self) private var registry
    @Environment(\.modelContext) private var modelContext
    @Environment(\.omniSkin) private var skin

    @State private var selectedSourceID: UUID?
    @State private var entries: [SourceEntry] = []
    @State private var path: [String] = []
    @State private var currentURL: String?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var searchResults: [RemoteBookCandidate] = []
    @State private var isSearching = false
    @State private var importProgress: ImportProgress?
    @State private var importMessage: String?
    @State private var showSearch = false
    @State private var showSources = false
    /// 书库里已有书的索引：用于给服务器列表打"已下载"标记
    @State private var libraryIndex = LibraryIndex()

    private var enabledSources: [RemoteSource] { registry.sources.filter(\.isEnabled) }

    private var selectedSource: RemoteSource? {
        registry.source(id: selectedSourceID) ?? enabledSources.first
    }

    private var isRuleSource: Bool {
        selectedSource?.kind == .rules || selectedSource?.kind == .jsonAPI
    }

    var body: some View {
        NavigationStack {
            decoratedContent
        }
    }

    /// 修饰符链拆成多段：单个表达式太长时 Swift 类型检查会超时
    /// （error: the compiler is unable to type-check this expression in reasonable time）。
    private var decoratedContent: some View {
        searchableContent
            .overlay(alignment: .top) { importBanner }
            .alert("出错了", isPresented: errorPresented) {
                Button("好") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .task { await initialLoad() }
            .onChange(of: importMessage) { _, newValue in
                // 导入结束（成功或失败）后刷新已下载标记
                if newValue == nil { Task { await refreshLibraryIndex() } }
            }
    }

    private var searchableContent: some View {
        titledContent
            .searchable(text: $searchText, isPresented: $showSearch, prompt: "搜索书名 / 作者")
            .onSubmit(of: .search) {
                Task { await performSearch() }
            }
    }

    private var titledContent: some View {
        mainContent
            .background(skin.background)
            .navigationTitle(selectedSource?.name ?? "发现")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(skin.surface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
        .sheet(isPresented: $showSources) {
            NavigationStack { LegadoSourcesView() }
        }
            .toolbar { mainToolbar }
    }

    @ViewBuilder
    private var importBanner: some View {
        if let importMessage {
            ImportBanner(message: importMessage, progress: importProgress)
                .padding(.top, 6)
        }
    }

    @MainActor
    private func initialLoad() async {
        if selectedSourceID == nil {
            selectedSourceID = enabledSources.first?.id
        }
        await refreshLibraryIndex()
        if isRuleSource {
            showSearch = true
        } else if entries.isEmpty {
            await browse(nil)
        }
    }

    /// 主体内容：拆出来单独声明，避免 body 里三元 + 修饰符链过长导致
    /// Swift 类型检查超时（error: unable to type-check in reasonable time）。
    @ViewBuilder
    private var mainContent: some View {
        if enabledSources.isEmpty {
            emptySources
        } else if isRuleSource && showSearch {
            searchResultsView
        } else {
            browserView
        }
    }

    private var errorPresented: Binding<Bool> {
        Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )
    }

    @ToolbarContentBuilder
    private var mainToolbar: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) { sourceMenu }
        ToolbarItem(placement: .topBarTrailing) { trailingToolbarButton }
    }

    private var sourceMenu: some View {
        Menu {
            ForEach(enabledSources) { s in
                Button {
                    selectedSourceID = s.id
                    path = []
                    currentURL = nil
                    showSearch = s.kind == .rules || s.kind == .jsonAPI
                    if !showSearch { Task { await browse(nil) } }
                } label: {
                    Label(s.name, systemImage: s.kind.symbolName)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: selectedSource?.kind.symbolName ?? "network")
                Text(selectedSource?.name ?? "选择").font(.subheadline)
            }
        }
    }

    @ViewBuilder
    private var trailingToolbarButton: some View {
        if isRuleSource {
            Button {
                withAnimation { showSearch.toggle() }
            } label: {
                Image(systemName: showSearch ? "folder" : "magnifyingglass")
            }
        } else if let url = currentURL, path.count > 0 {
            Button {
                Task { await browse(url) }
            } label: {
                Image(systemName: "arrow.clockwise")
            }
        }
    }

    // MARK: - 目录浏览

    private var browserView: some View {
        Group {
            if isLoading {
                ProgressView("加载中…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty {
                ContentUnavailableView {
                    Label("这里没有内容", systemImage: "tray")
                } description: {
                    Text(selectedSource?.lastCheckMessage.isEmpty == false
                         ? (selectedSource?.lastCheckMessage ?? "")
                         : "检查地址是否正确，或刷新重试")
                } actions: {
                    Button("刷新") { Task { await browse(currentURL) } }
                }
            } else {
                List {
                    if !path.isEmpty {
                        Button {
                            goUp()
                        } label: {
                            Label("返回上级", systemImage: "arrow.up.left")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    ForEach(entries) { entry in
                        Button {
                            handleEntryTap(entry)
                        } label: {
                            entryRow(entry)
                        }
                        .buttonStyle(.plain)
                        .swipeActions(edge: .trailing) {
                            if entry.kind != .directory, !isDownloaded(entry) {
                                Button {
                                    if let source = selectedSource {
                                        Task { await importEntry(entry, source: source) }
                                    }
                                } label: {
                                    Label("下载", systemImage: "arrow.down.circle")
                                }
                                .tint(.accentColor)
                            }
                        }
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private func entryRow(_ entry: SourceEntry) -> some View {
        let downloaded = entry.kind != .directory && isDownloaded(entry)
        let active = entry.kind != .directory ? DownloadManager.shared.task(forRemote: entry.href) : nil
        return HStack(spacing: 12) {
            Image(systemName: entry.kind == .directory ? "folder.fill" : "book.closed.fill")
                .foregroundStyle(entry.kind == .directory ? Color.accentColor : Color.secondary)
                .frame(width: 24)

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.title)
                    .font(.subheadline)
                    .lineLimit(2)
                if let author = entry.author, !author.isEmpty {
                    Text(author).font(.caption).foregroundStyle(.secondary)
                } else if let summary = entry.summary, !summary.isEmpty, entry.kind == .book {
                    Text(summary).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                // 正在下载：显示进度条，避免用户以为没反应又点一次
                if let active, active.state.isRunning {
                    ProgressView(value: active.fraction)
                        .progressViewStyle(.linear)
                        .frame(height: 2)
                    Text(active.statusText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()

            if entry.kind != .directory {
                if downloaded {
                    // 已在书架：明确标记，避免重复下载
                    Label("已在书架", systemImage: "checkmark.circle.fill")
                        .labelStyle(.iconOnly)
                        .font(.callout)
                        .foregroundStyle(.green)
                } else if let active, active.state.isActive {
                    Image(systemName: "arrow.down.circle.dotted")
                        .foregroundStyle(Color.accentColor)
                } else {
                    Image(systemName: "arrow.down.circle")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }

    // MARK: - 搜索结果

    private var searchResultsView: some View {
        Group {
            if isSearching {
                ProgressView("搜索中…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if searchResults.isEmpty {
                ContentUnavailableView {
                    Label("输入关键词搜索", systemImage: "magnifyingglass")
                } description: {
                    Text("支持搜索书名、作者")
                }
            } else {
                List(searchResults) { candidate in
                    Button {
                        Task { await importCandidate(candidate) }
                    } label: {
                        HStack(spacing: 12) {
                            AsyncCover(url: candidate.coverURL, source: selectedSource)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(candidate.title).font(.subheadline).lineLimit(2)
                                if !candidate.author.isEmpty {
                                    Text(candidate.author).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if isDownloadedURL(candidate.detailURL) {
                                Label("已在书架", systemImage: "checkmark.circle.fill")
                                    .labelStyle(.iconOnly)
                                    .foregroundStyle(.green)
                            } else {
                                Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
                .listStyle(.plain)
            }
        }
    }

    // MARK: - 已下载判定

    /// 服务器条目是否已经在书架里
    private func isDownloaded(_ entry: SourceEntry) -> Bool {
        libraryIndex.contains(sourceID: selectedSource?.id, remoteURL: entry.href,
                              title: entry.title, bookID: nil)
    }

    private func isDownloadedURL(_ url: String?) -> Bool {
        guard let url else { return false }
        return libraryIndex.contains(sourceID: selectedSource?.id, remoteURL: url,
                                     title: nil, bookID: nil)
    }

    private func refreshLibraryIndex() async {
        let books: [Book] = (try? modelContext.fetch(FetchDescriptor<Book>())) ?? []
        var idx = LibraryIndex()
        for b in books {
            idx.add(sourceID: b.sourceID.flatMap(UUID.init(uuidString:)),
                    remoteURL: b.remoteURL,
                    title: b.title)
        }
        await MainActor.run { libraryIndex = idx }
    }

    // MARK: - 交互

    private func handleEntryTap(_ entry: SourceEntry) {
        if entry.kind == .directory {
            Task { await browse(entry.href) }
            return
        }
        guard let source = selectedSource else { return }
        // 已经在书架：直接提示，不重复下载
        if isDownloaded(entry) {
            errorMessage = "《\(entry.title)》已经在书架里了，不需要重复下载。"
            return
        }
        // 已在下载中：只提示
        if let t = DownloadManager.shared.task(forRemote: entry.href), t.state.isActive {
            errorMessage = "《\(entry.title)》正在下载中：\(t.statusText)"
            return
        }
        Task { await importEntry(entry, source: source) }
    }

    private func browse(_ url: String?) async {
        guard let source = selectedSource else { return }
        isLoading = true
        errorMessage = nil
        do {
            let list = try await OPDSSource.browse(source: source, url: url)
            await MainActor.run {
                entries = list
                currentURL = url ?? source.baseURL
                if let url, !path.contains(url) { path.append(url) }
                else if url == nil { path = [] }
                isLoading = false
            }
            registry.markCheck(source.id, ok: true, message: "\(list.count) 项")
        } catch {
            await MainActor.run {
                isLoading = false
                entries = []
                errorMessage = error.localizedDescription
            }
            registry.markCheck(source.id, ok: false, message: error.localizedDescription)
        }
    }

    private func goUp() {
        guard !path.isEmpty else { return }
        path.removeLast()
        let parent = path.last
        Task { await browse(parent) }
    }

    private func performSearch() async {
        guard let source = selectedSource, !searchText.isEmpty else { return }
        isSearching = true
        do {
            let results = try await WebBookSource.search(source: source, keyword: searchText)
            await MainActor.run {
                searchResults = results
                isSearching = false
            }
        } catch {
            await MainActor.run {
                isSearching = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func importEntry(_ entry: SourceEntry, source: RemoteSource) async {
        let store = appState.store ?? Store(context: modelContext)
        await MainActor.run {
            importMessage = "准备下载《\(entry.title)》"
            importProgress = ImportProgress(phase: "准备", fraction: 0, detail: entry.title)
        }
        do {
            let book: Book
            if source.kind == .rules || source.kind == .jsonAPI {
                book = try await ImportService.shared.importWebBook(
                    detailURL: entry.href, source: source, store: store
                ) { p in
                    Task { @MainActor in
                        importProgress = p
                        importMessage = "\(p.phase) \(p.detail)"
                    }
                }
            } else if entry.kind == .chapter || entry.mimeType?.contains("html") == true {
                book = try await ImportService.shared.importChaptersFromPage(
                    entryURL: entry.href, source: source, store: store
                ) { p in
                    Task { @MainActor in
                        importProgress = p
                        importMessage = "\(p.phase) \(p.detail)"
                    }
                }
            } else {
                book = try await ImportService.shared.importRemoteFile(
                    url: entry.href, source: source, store: store,
                    origin: source.kind == .opds ? .opds : .directURL
                ) { p in
                    Task { @MainActor in
                        importProgress = p
                        importMessage = "\(p.phase) \(p.detail)"
                    }
                }
            }
            await MainActor.run {
                importMessage = "《\(book.title)》已加入书架"
                importProgress = ImportProgress(phase: "完成", fraction: 1, detail: book.title)
            }
            await refreshLibraryIndex()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run {
                importMessage = nil
                importProgress = nil
            }
        } catch {
            await MainActor.run {
                importMessage = nil
                importProgress = nil
                errorMessage = "\(entry.title)：\(error.localizedDescription)"
            }
        }
    }

    private func importCandidate(_ candidate: RemoteBookCandidate) async {
        guard let source = selectedSource else { return }
        let store = appState.store ?? Store(context: modelContext)
        if isDownloadedURL(candidate.detailURL) {
            errorMessage = "《\(candidate.title)》已经在书架里了。"
            return
        }
        await MainActor.run {
            importMessage = "获取《\(candidate.title)》目录"
            importProgress = ImportProgress(phase: "获取目录", fraction: 0, detail: candidate.title)
        }
        do {
            let book = try await ImportService.shared.importWebBook(
                detailURL: candidate.detailURL, source: source, store: store
            ) { p in
                Task { @MainActor in
                    importProgress = p
                    importMessage = "\(p.phase) \(p.detail)"
                }
            }
            await MainActor.run {
                importMessage = "《\(book.title)》已加入书架"
                importProgress = ImportProgress(phase: "完成", fraction: 1, detail: book.title)
            }
            await refreshLibraryIndex()
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run {
                importMessage = nil
                importProgress = nil
            }
        } catch {
            await MainActor.run {
                importMessage = nil
                importProgress = nil
                errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - 空状态

    private var emptySources: some View {
        ContentUnavailableView {
            Label("还没有启用书源", systemImage: "network.slash")
        } description: {
            Text("去「书源」页添加 NAS 书库或在线书源，就能在这里浏览和搜索。")
        } actions: {
            Button("管理书源") { showSources = true }
                .buttonStyle(.borderedProminent)
        }
    }
}

// MARK: - 书库索引（判断"已下载"）

/// 用 (sourceID, remoteURL) 和 (title) 两套索引进快速判断服务器条目是否已入库。
struct LibraryIndex {
    private var byURL: Set<String> = []
    private var byTitle: Set<String> = []

    private static func urlKey(_ sourceID: UUID?, _ url: String) -> String {
        let sid = sourceID?.uuidString ?? "-"
        return sid + "|" + url.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func titleKey(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    mutating func add(sourceID: UUID?, remoteURL: String?, title: String?) {
        if let remoteURL, !remoteURL.isEmpty {
            byURL.insert(Self.urlKey(sourceID, remoteURL))
        }
        if let title, !title.isEmpty {
            byTitle.insert(Self.titleKey(title))
        }
    }

    func contains(sourceID: UUID?, remoteURL: String?, title: String?, bookID: UUID?) -> Bool {
        if let remoteURL, !remoteURL.isEmpty, byURL.contains(Self.urlKey(sourceID, remoteURL)) {
            return true
        }
        if let title, !title.isEmpty, byTitle.contains(Self.titleKey(title)) {
            return true
        }
        return false
    }

    var isEmpty: Bool { byURL.isEmpty && byTitle.isEmpty }
}

// MARK: - 远程封面

struct AsyncCover: View {
    let url: String?
    let source: RemoteSource?
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 4)
                    .fill(Color.secondary.opacity(0.12))
                    .overlay { Image(systemName: "book.closed").font(.caption).foregroundStyle(.tertiary) }
            }
        }
        .frame(width: 34, height: 48)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .task(id: url) {
            guard let url, image == nil else { return }
            if let data = await CoverLoader.load(url: url, source: source) {
                image = UIImage(data: data)
            }
        }
    }
}
