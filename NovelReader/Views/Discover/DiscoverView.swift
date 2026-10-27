//
//  DiscoverView.swift
//  NovelReader
//
//  发现：浏览 NAS 书库目录 / 在线书源搜索 / 一键加入书架并下载
//

import SwiftUI

struct DiscoverView: View {
    @Environment(AppState.self) private var appState
    @Environment(SourceRegistry.self) private var registry

    @State private var selectedSourceID: UUID?
    @State private var entries: [SourceEntry] = []
    @State private var path: [String] = []
    @State private var currentURL: String?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var searchText = ""
    @State private var searchResults: [RemoteBookCandidate] = []
    @State private var isSearching = false
    @State private var importMessage: String?
    @State private var showSearch = false

    private var enabledSources: [RemoteSource] { registry.sources.filter(\.isEnabled) }

    private var selectedSource: RemoteSource? {
        registry.source(id: selectedSourceID) ?? enabledSources.first
    }

    private var isRuleSource: Bool {
        selectedSource?.kind == .rules || selectedSource?.kind == .jsonAPI
    }

    var body: some View {
        NavigationStack {
            Group {
                if enabledSources.isEmpty {
                    emptySources
                } else if isRuleSource && showSearch {
                    searchResultsView
                } else {
                    browserView
                }
            }
            .navigationTitle(selectedSource?.name ?? "发现")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
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
                ToolbarItem(placement: .topBarTrailing) {
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
            }
            .searchable(text: $searchText, isPresented: $showSearch, prompt: "搜索书名 / 作者")
            .onSubmit(of: .search) {
                Task { await performSearch() }
            }
            .overlay(alignment: .top) {
                if let importMessage {
                    ImportBanner(message: importMessage)
                        .padding(.top, 6)
                }
            }
            .alert("出错了", isPresented: .constant(errorMessage != nil)) {
                Button("好") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .task {
                if selectedSourceID == nil {
                    selectedSourceID = enabledSources.first?.id
                }
                if isRuleSource {
                    showSearch = true
                } else if entries.isEmpty {
                    await browse(nil)
                }
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
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    private func entryRow(_ entry: SourceEntry) -> some View {
        HStack(spacing: 12) {
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
            }
            Spacer()
            if entry.kind != .directory {
                Image(systemName: "arrow.down.circle")
                    .foregroundStyle(.secondary)
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
                    Text("在「\(selectedSource?.name ?? "")」中搜索")
                }
            } else {
                List(searchResults) { candidate in
                    HStack(spacing: 12) {
                        AsyncCover(url: candidate.coverURL, source: selectedSource)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(candidate.title).font(.subheadline).lineLimit(2)
                            Text(candidate.author.isEmpty ? "未知作者" : candidate.author)
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            Task { await importCandidate(candidate) }
                        } label: {
                            Image(systemName: "plus.circle")
                                .font(.title3)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .listStyle(.plain)
            }
        }
    }

    // MARK: - 动作

    private func handleEntryTap(_ entry: SourceEntry) {
        guard let source = selectedSource else { return }
        switch entry.kind {
        case .directory:
            Task { await browse(entry.href) }
        case .book, .chapter:
            // 下载整本并导入书架
            Task { await importEntry(entry, source: source) }
        }
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
        guard let store = appState.store else { return }
        await MainActor.run { importMessage = "准备下载《\(entry.title)》" }
        do {
            let book: Book
            if source.kind == .rules || source.kind == .jsonAPI {
                book = try await ImportService.shared.importWebBook(
                    detailURL: entry.href, source: source, store: store
                ) { p in
                    Task { @MainActor in
                        importMessage = "\(p.phase) \(p.detail)"
                    }
                }
            } else if entry.kind == .chapter || entry.mimeType?.contains("html") == true {
                book = try await ImportService.shared.importChaptersFromPage(
                    entryURL: entry.href, source: source, store: store
                ) { p in
                    Task { @MainActor in
                        importMessage = "\(p.phase) \(p.detail)"
                    }
                }
            } else {
                book = try await ImportService.shared.importRemoteFile(
                    url: entry.href, source: source, store: store,
                    origin: source.kind == .opds ? .opds : .directURL
                ) { p in
                    Task { @MainActor in
                        importMessage = "\(p.phase)"
                    }
                }
            }
            await MainActor.run {
                importMessage = "《\(book.title)》已加入书架"
            }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run { importMessage = nil }
        } catch {
            await MainActor.run {
                importMessage = nil
                errorMessage = "\(entry.title)：\(error.localizedDescription)"
            }
        }
    }

    private func importCandidate(_ candidate: RemoteBookCandidate) async {
        guard let store = appState.store, let source = selectedSource else { return }
        await MainActor.run { importMessage = "获取《\(candidate.title)》目录" }
        do {
            let book = try await ImportService.shared.importWebBook(
                detailURL: candidate.detailURL, source: source, store: store
            ) { p in
                Task { @MainActor in
                    importMessage = "\(p.phase) \(p.detail)"
                }
            }
            await MainActor.run { importMessage = "《\(book.title)》已加入书架" }
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await MainActor.run { importMessage = nil }
        } catch {
            await MainActor.run {
                importMessage = nil
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
            Button("管理书源") { appState.selectedTab = .sources }
                .buttonStyle(.borderedProminent)
        }
    }
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
