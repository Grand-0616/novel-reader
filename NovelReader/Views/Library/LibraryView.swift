//
//  LibraryView.swift
//  NovelReader
//
//  书架：网格/列表、搜索、排序、导入（文件选择器 / Inbox / 分享）
//

import SwiftUI
import SwiftData
import UniformTypeIdentifiers

struct LibraryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    @Environment(\.omniSkin) private var skin
    @Query(sort: [SortDescriptor(\Book.lastOpenedAt, order: .reverse),
                  SortDescriptor(\Book.createdAt, order: .reverse)])
    private var books: [Book]

    @State private var searchText = ""
    @State private var showImporter = false
    @State private var showURLSheet = false
    @State private var sortMode: SortMode = .recent
    @State private var isImporting = false
    @State private var importMessage: String?
    @State private var errorMessage: String?
    @State private var selectedBook: Book?
    @State private var showSettings = false
    @State private var groupFilter: ShelfGroup = .all

    enum SortMode: String, CaseIterable, Identifiable {
        case recent = "最近阅读"
        case added = "添加时间"
        case title = "书名"
        case author = "作者"
        var id: String { rawValue }
    }

    /// 书架分组，对齐云书阁的书架分组条
    enum ShelfGroup: String, CaseIterable, Identifiable {
        case all = "全部"
        case reading = "在读"
        case favorites = "收藏"
        case finished = "已读完"
        var id: String { rawValue }
    }

    private var filteredBooks: [Book] {
        var list = books
        if !searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            let q = searchText.lowercased()
            list = list.filter {
                $0.title.lowercased().contains(q) || $0.author.lowercased().contains(q)
            }
        }
        switch groupFilter {
        case .all:
            break
        case .reading:
            list = list.filter { $0.readingProgress > 0.001 && $0.readingProgress < 0.999 }
        case .favorites:
            list = list.filter(\.isPinned)
        case .finished:
            list = list.filter { $0.readingProgress >= 0.999 }
        }
        switch sortMode {
        case .recent:
            list.sort { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }
        case .added:
            list.sort { $0.createdAt > $1.createdAt }
        case .title:
            list.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .author:
            list.sort { $0.author.localizedStandardCompare($1.author) == .orderedAscending }
        }
        // 置顶优先（稳定排序：先按置顶分组，组内保持上面的排序）
        let pinned = list.filter(\.isPinned)
        let normal = list.filter { !$0.isPinned }
        return pinned + normal
    }

    var body: some View {
        NavigationStack {
            Group {
                if books.isEmpty {
                    emptyState
                } else {
                    bookGrid
                }
            }
            .background(skin.background)
            .navigationTitle("书架")
            .toolbarBackground(skin.surface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .searchable(text: $searchText, prompt: "搜索书名或作者")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("排序", selection: $sortMode) {
                            ForEach(SortMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "person.crop.circle")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            showImporter = true
                        } label: {
                            Label("从「文件」导入", systemImage: "folder.badge.plus")
                        }
                        Button {
                            showURLSheet = true
                        } label: {
                            Label("从链接导入", systemImage: "link")
                        }
                        Button {
                            Task { await importFromInbox() }
                        } label: {
                            Label("扫描 Inbox 目录", systemImage: "tray.and.arrow.down")
                        }
                        Divider()
                        Button {
                            selectedBook = nil
                            appState.selectedTab = .discover
                        } label: {
                            Label("去书源找书", systemImage: "magnifyingglass")
                        }
                    } label: {
                        Image(systemName: "plus.circle.fill")
                    }
                }
            }
            .fileImporter(
                isPresented: $showImporter,
                allowedContentTypes: Self.importTypes,
                allowsMultipleSelection: true
            ) { result in
                handleImport(result)
            }
            .sheet(isPresented: $showURLSheet) {
                URLImportSheet()
            }
            .sheet(item: $selectedBook) { book in
                BookDetailView(book: book)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView()
            }
            .overlay(alignment: .top) {
                if let importMessage {
                    ImportBanner(message: importMessage)
                        .padding(.top, 8)
                        .transition(.move(edge: .top).combined(with: .opacity))
                }
            }
            .animation(.easeInOut(duration: 0.2), value: importMessage)
            .alert("出错了", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("好") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
            .task {
                await importInboxOnFirstLaunchIfNeeded()
            }
        }
    }

    static var importTypes: [UTType] {
        var types: [UTType] = [.plainText, .html]
        if let epub = UTType(filenameExtension: "epub") { types.append(epub) }
        types.append(.text)
        types.append(.data)
        return types
    }

    // MARK: - 网格

    private var bookGrid: some View {
        ScrollView {
            VStack(spacing: 18) {
                continueSection
                groupBar

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104, maximum: 140), spacing: 16)],
                          spacing: 20) {
                    ForEach(filteredBooks) { book in
                        Button {
                            selectedBook = book
                        } label: {
                            OmniBookCard(
                                title: book.title,
                                author: book.displayAuthor,
                                coverData: book.coverData,
                                progress: book.readingProgress,
                                isPinned: book.isPinned
                            )
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button {
                                book.isPinned.toggle()
                                try? modelContext.save()
                            } label: {
                                Label(book.isPinned ? "取消置顶" : "置顶", systemImage: "pin")
                            }
                            if let store = appState.store {
                                Button {
                                    store.delete(book: book)
                                } label: {
                                    Label("删除", systemImage: "trash")
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .background(skin.background)
    }

    // MARK: - 继续阅读

    /// 最近在读的横向卡片，只在「全部」分组且未搜索时出现，
    /// 对应云书阁书架顶部那块继续阅读区。
    @ViewBuilder
    private var continueSection: some View {
        let items = Array(
            books
                .filter { $0.readingProgress > 0.001 && $0.readingProgress < 0.999 }
                .sorted { ($0.lastOpenedAt ?? .distantPast) > ($1.lastOpenedAt ?? .distantPast) }
                .prefix(6)
        )
        if !items.isEmpty,
           groupFilter == .all,
           searchText.trimmingCharacters(in: .whitespaces).isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("继续阅读")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(skin.textPrimary)
                    .padding(.horizontal, 16)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(items) { book in
                            Button {
                                selectedBook = book
                            } label: {
                                continueCard(book)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }

    private func continueCard(_ book: Book) -> some View {
        HStack(spacing: 11) {
            coverThumb(book, width: 44, height: 60)
            VStack(alignment: .leading, spacing: 5) {
                Text(book.title)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(skin.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text("\(Int(book.readingProgress * 100))%  ·  \(book.displayAuthor)")
                    .font(.system(size: 10))
                    .foregroundStyle(skin.textSecondary)
                    .lineLimit(1)
                ProgressView(value: min(max(book.readingProgress, 0), 1))
                    .tint(skin.accent)
                    .scaleEffect(x: 1, y: 0.65, anchor: .center)
            }
            .frame(width: 132, alignment: .leading)
        }
        .padding(10)
        .frame(width: 212)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(skin.surface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(skin.separator, lineWidth: 0.5)
        }
    }

    @ViewBuilder
    private func coverThumb(_ book: Book, width: CGFloat, height: CGFloat) -> some View {
        Group {
            if let data = book.coverData, let image = UIImage(data: data) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(
                        colors: [skin.accent.opacity(0.32), skin.accent.opacity(0.10)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing)
                    Text(String(book.title.prefix(1)))
                        .font(.system(size: height * 0.34, weight: .semibold, design: .serif))
                        .foregroundStyle(skin.accent)
                }
            }
        }
        .frame(width: width, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    /// 分组条：横向滚动的胶囊，选中态用主题主色
    private var groupBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(ShelfGroup.allCases) { group in
                    OmniChip(
                        title: group.rawValue,
                        count: count(for: group),
                        isSelected: groupFilter == group
                    ) {
                        groupFilter = group
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func count(for group: ShelfGroup) -> Int? {
        switch group {
        case .all:
            return books.count
        case .reading:
            return books.filter { $0.readingProgress > 0.001 && $0.readingProgress < 0.999 }.count
        case .favorites:
            return books.filter(\.isPinned).count
        case .finished:
            return books.filter { $0.readingProgress >= 0.999 }.count
        }
    }

    // MARK: - 空状态

    private var emptyState: some View {
        ScrollView {
            VStack(spacing: 20) {
                Spacer(minLength: 60)
                Image(systemName: "books.vertical")
                    .font(.system(size: 64, weight: .thin))
                    .foregroundStyle(skin.accent.opacity(0.75))
                Text("书架还是空的")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(skin.textPrimary)
                Text("导入本地 TXT / EPUB，或到「书源」添加站点后搜索")
                    .font(.subheadline)
                    .foregroundStyle(skin.textSecondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)

                VStack(spacing: 12) {
                    Button {
                        showImporter = true
                    } label: {
                        Label("从「文件」导入", systemImage: "folder.badge.plus")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .foregroundStyle(skin.background)
                            .padding(.vertical, 12)
                            .background(Capsule().fill(skin.accent))
                    }
                    .buttonStyle(.plain)

                    Button {
                        appState.selectedTab = .sources
                    } label: {
                        Label("添加书源", systemImage: "network")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .foregroundStyle(skin.accent)
                            .padding(.vertical, 12)
                            .background(Capsule().strokeBorder(skin.accent, lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 40)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        }
        .background(skin.background)
    }

    // MARK: - 导入

    private func handleImport(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard !urls.isEmpty else {
                errorMessage = "没有选择文件"
                return
            }
            // 不再依赖 appState.store —— 它可能是 nil（onAppear 未触发），
            // 那样会静默 return，用户看到的只是"没反应"。
            // 这里直接用 modelContext 兜底创建 Store。
            let store = appState.store ?? Store(context: modelContext)
            appState.store = store

            Task {
                isImporting = true
                importMessage = "准备导入 \(urls.count) 个文件"
                var count = 0
                var errors: [String] = []

                for url in urls {
                    do {
                        _ = try await ImportService.shared.importLocalFile(at: url, store: store) { p in
                            Task { @MainActor in
                                importMessage = "\(p.phase)…"
                            }
                        }
                        count += 1
                    } catch {
                        errors.append("\(url.lastPathComponent)：\(error.localizedDescription)")
                    }
                }

                isImporting = false
                if !errors.isEmpty {
                    errorMessage = errors.joined(separator: "\n\n")
                }
                if count > 0 {
                    importMessage = "已导入 \(count) 本"
                    try? await Task.sleep(nanoseconds: 1_800_000_000)
                }
                importMessage = nil
            }
        case .failure(let error):
            errorMessage = "选择文件失败：\(error.localizedDescription)"
        }
    }

    private func importFromInbox() async {
        guard let store = appState.store else { return }
        isImporting = true
        defer { isImporting = false }
        do {
            let books = try await ImportService.shared.importFromInbox(store: store) { p in
                Task { @MainActor in
                    importMessage = "\(p.phase)"
                }
            }
            importMessage = books.isEmpty ? "Inbox 里没有可导入的文件" : "已导入 \(books.count) 本"
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            importMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func importInboxOnFirstLaunchIfNeeded() async {
        guard books.isEmpty else { return }
        guard appState.store != nil else { return }
        await importFromInbox()
    }
}

// MARK: - 书格

struct BookCell: View {
    let book: Book

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                cover
                    .frame(height: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .shadow(color: .black.opacity(0.12), radius: 4, x: 0, y: 2)

                if book.isPinned {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .padding(4)
                        .background(.ultraThinMaterial, in: Circle())
                        .padding(5)
                }
            }
            Text(book.title)
                .font(.caption.weight(.medium))
                .lineLimit(2)
                .foregroundStyle(.primary)
            if book.readingProgress > 0.001 {
                ProgressView(value: min(book.readingProgress, 1))
                    .progressViewStyle(.linear)
                    .tint(.accentColor)
                    .scaleEffect(x: 1, y: 0.6, anchor: .center)
            } else {
                Text(book.displayAuthor)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }

    @ViewBuilder
    private var cover: some View {
        if let data = book.coverData, let img = UIImage(data: data) {
            Image(uiImage: img)
                .resizable()
                .aspectRatio(contentMode: .fill)
        } else {
            ZStack {
                LinearGradient(colors: gradientColors, startPoint: .topLeading, endPoint: .bottomTrailing)
                VStack {
                    Text(book.title)
                        .font(.system(size: 13, weight: .semibold, design: .serif))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(4)
                        .padding(.horizontal, 8)
                }
                .padding(6)
            }
        }
    }

    private var gradientColors: [Color] {
        let palette: [[Color]] = [
            [Color(red: 0.35, green: 0.42, blue: 0.62), Color(red: 0.20, green: 0.26, blue: 0.42)],
            [Color(red: 0.62, green: 0.38, blue: 0.33), Color(red: 0.42, green: 0.22, blue: 0.20)],
            [Color(red: 0.30, green: 0.50, blue: 0.45), Color(red: 0.16, green: 0.34, blue: 0.30)],
            [Color(red: 0.52, green: 0.45, blue: 0.30), Color(red: 0.34, green: 0.28, blue: 0.18)],
            [Color(red: 0.45, green: 0.35, blue: 0.52), Color(red: 0.28, green: 0.20, blue: 0.34)]
        ]
        let idx = abs(book.title.hashValue) % palette.count
        return palette[idx]
    }
}

// MARK: - 导入 Banner

struct ImportBanner: View {
    let message: String
    /// 有确定进度时显示线性进度条（下载/解析导入），否则显示转圈
    var progress: ImportProgress? = nil

    var body: some View {
        HStack(spacing: 10) {
            if progress == nil {
                ProgressView().scaleEffect(0.8)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(message).font(.footnote).lineLimit(2)
                if let p = progress {
                    ProgressView(value: min(max(p.fraction, 0), 1))
                        .progressViewStyle(.linear)
                        .frame(minWidth: 180)
                    if !p.phase.isEmpty || !p.detail.isEmpty {
                        Text(p.phase.isEmpty ? p.detail : p.phase)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .shadow(radius: 3)
    }
}

// MARK: - URL 导入

struct URLImportSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @Environment(SourceRegistry.self) private var registry

    @State private var urlText = ""
    @State private var useSourceID: UUID?
    @State private var isWorking = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section("文件链接") {
                    TextField("https://example.com/book.txt", text: $urlText, axis: .vertical)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .lineLimit(1...3)
                }
                Section("使用书源凭证") {
                    Picker("书源", selection: $useSourceID) {
                        Text("无").tag(UUID?.none)
                        ForEach(registry.sources) { s in
                            Text(s.name).tag(Optional(s.id))
                        }
                    }
                }
                Section {
                    Text("支持直链 TXT / EPUB，也支持指向 HTML 目录页的链接（会自动抓章节）。NAS 需要登录时请在此选择对应书源以带上账号。")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("从链接导入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("导入") { startImport() }
                        .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty || isWorking)
                }
            }
            .overlay {
                if isWorking {
                    ProgressView("正在导入…")
                        .padding(24)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
                }
            }
            .alert("导入失败", isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } }
            )) {
                Button("好") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    private func startImport() {
        guard let store = appState.store else { return }
        let source = registry.source(id: useSourceID)
        let url = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        isWorking = true
        Task {
            do {
                _ = try await ImportService.shared.importRemoteFile(
                    url: url, source: source, store: store,
                    origin: source == nil ? .directURL : (source!.kind == .opds ? .opds : .web)
                ) { _ in }
                isWorking = false
                dismiss()
            } catch {
                isWorking = false
                errorMessage = error.localizedDescription
            }
        }
    }
}
