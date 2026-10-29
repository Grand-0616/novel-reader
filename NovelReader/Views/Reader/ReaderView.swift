//
//  ReaderView.swift
//  NovelReader
//
//  阅读器：分页显示、点击左右翻页、滑动翻页、连续滚动、进度保存、章节跳转、设置面板
//
//  性能约定（滑动卡顿修复后的规则）：
//   1. 整章只建一次 CTFramesetter，存在 @State 里跟着章走，
//      body 求值时不再重建 attributed string。
//   2. 分页放到后台线程（Paginator.paginateAsync），翻章不阻塞主线程。
//   3. 正文视图不再用 .id(...) 强制重建；翻页只是改 range，
//      CoreTextPageView 内部按 (range, bounds) 缓存 CTFrame。
//   4. 上下滑动模式用整章连续排版 + UIScrollView 滚动，滚动本身不触发排版。
//

import SwiftUI
import SwiftData
import CoreText

// MARK: - 阅读器布局度量
//
// 分页时用的尺寸和实际绘制区域必须是同一个，否则会出现
// "页底空一截"或"最后一行被裁掉"。所有边距/安全区计算集中在这里。
struct ReaderLayout: Equatable {
    /// 整个可用区域（含安全区）
    let size: CGSize
    let insets: EdgeInsets
    /// 左右页边距（百分比 * 宽度）
    let marginH: CGFloat
    /// 上下页边距（百分比 * 高度）
    let marginV: CGFloat
    /// 是否显示页脚（关闭时腾出的高度给正文）
    let showsFooter: Bool

    /// 页码行高度
    static let footerHeight: CGFloat = 22

    init(size: CGSize, insets: EdgeInsets, marginH ratioH: Double, marginV ratioV: Double,
         showsFooter: Bool = true) {
        self.size = size
        self.insets = insets
        self.marginH = size.width * CGFloat(ratioH)
        self.marginV = size.height * CGFloat(ratioV)
        self.showsFooter = showsFooter
    }

    /// 顶部起排位置：安全区 + 上下边距
    var topInset: CGFloat { max(insets.top, 20) + marginV }
    /// 底部收排位置：安全区 + 上下边距 + 页码行
    var bottomInset: CGFloat {
        max(insets.bottom, 16) + marginV + (showsFooter ? Self.footerHeight : 0)
    }

    /// 正文可排版区域
    var textSize: CGSize {
        CGSize(
            width: max(size.width - marginH * 2, 80),
            height: max(size.height - topInset - bottomInset, 80)
        )
    }

    var textOrigin: CGPoint {
        CGPoint(x: marginH, y: topInset)
    }
}

struct ReaderView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var appState
    @Environment(\.colorScheme) private var systemScheme
    @Environment(\.omniSkin) private var skin

    let book: Book

    @State private var chapterIndex: Int = 0
    @State private var pages: [NSRange] = []
    @State private var pageIndex: Int = 0
    @State private var chapterText: String = ""
    @State private var pendingOffset: Int = 0
    @State private var showChrome = false
    @State private var showSettings = false
    @State private var showChapterList = false
    @State private var paginationSize: CGSize = .zero
    /// 当前生效的布局度量，供边距变化时重算尺寸
    @State private var currentLayout: ReaderLayout?
    @State private var isLoading = true
    @State private var loadError: String?


    // MARK: 性能相关缓存
    /// 整章的 attributed string 与 framesetter，随章节/排版参数变化重建一次
    @State private var framesetter: CTFramesetter?
    /// 当前章字符总数（滚动模式传给 ContinuousTextView）
    @State private var chapterLength: Int = 0
    /// 滚动模式下当前滚动位置对应的字符偏移
    @State private var scrollCharOffset: Int = 0
    /// 防止重排任务乱序落地（连点字号时只认最后一次）
    @State private var repaginateToken: Int = 0

    @Environment(\.modelContext) private var modelContext
    @Environment(SourceRegistry.self) private var registry

    /// 优先用 AppState 里的 Store，没有就现场建一个（避免强制解包崩溃）
    private var store: Store {
        appState.store ?? Store(context: modelContext)
    }

    private var theme: ReaderTheme { appState.theme }

    private var chapters: [Chapter] {
        book.chapters.sorted { $0.index < $1.index }
    }

    private var currentChapter: Chapter? {
        chapters.first { $0.index == chapterIndex }
    }

    private var font: UIFont {
        UIFont.systemFont(ofSize: appState.fontSize, weight: .regular)
    }

    private var isScrollMode: Bool { appState.pageTurnStyle.isScrollMode }

    var body: some View {
        GeometryReader { geo in
            let layout = ReaderLayout(size: geo.size,
                                      insets: geo.safeAreaInsets,
                                      marginH: appState.marginHorizontal,
                                      marginV: appState.marginVertical,
                                      showsFooter: appState.showFooter)

            ZStack(alignment: .topLeading) {
                theme.backgroundColor.ignoresSafeArea()

                if isScrollMode {
                    // 上下滑动：整章连续排版，交给 UIScrollView 滚
                    scrollContent(layout: layout)
                        .frame(width: layout.textSize.width, height: layout.textSize.height)
                        .offset(x: layout.textOrigin.x, y: layout.textOrigin.y)
                } else {
                    // 分页：尺寸与分页时使用的尺寸完全一致，避免裁字或页底留白
                    content(textSize: layout.textSize)
                        .frame(width: layout.textSize.width,
                               height: layout.textSize.height,
                               alignment: .topLeading)
                        .offset(x: layout.textOrigin.x, y: layout.textOrigin.y)
                }

                if appState.showFooter {
                    footer(layout: layout)
                }
            }
            .contentShape(Rectangle())
            // 滚动模式下不能抢手势，点击检测交给 overlay 层
            .onTapGesture { location in
                handleTap(location: location, size: geo.size)
            }
            .gesture(isScrollMode ? nil : swipeGesture(width: geo.size.width))
            .onAppear {
                applyLayout(layout)
                loadInitial()
            }
            .onChange(of: layout) { _, newLayout in
                // 旋转 / 分屏 / 安全区变化：重排并回到原来的字符位置
                applyLayout(newLayout)
                repaginate(keepingOffset: currentOffsetInPage)
            }
        }
        .statusBarHidden(!showChrome)
        .persistentSystemOverlays(showChrome ? .automatic : .hidden)
        .overlay(alignment: .top) { if showChrome { topBar } }
        .overlay(alignment: .bottom) { if showChrome { bottomBar } }
        .sheet(isPresented: $showSettings) {
            ReaderSettingsPanel()
        }
        .sheet(isPresented: $showChapterList) {
            ChapterListView(book: book) { idx in
                showChapterList = false
                goToChapter(idx, offset: 0)
            }
        }
        .onDisappear {
            saveProgress()
        }
        // 排版参数变化后必须重排：字号/行距/边距都会改变每页容量。
        // 用当前页的起始字符偏移作为锚点，重排后仍停在原来的位置。
        .onChange(of: appState.fontSize) { _, _ in
            repaginate(keepingOffset: currentOffsetInPage)
        }
        .onChange(of: appState.lineSpacing) { _, _ in
            repaginate(keepingOffset: currentOffsetInPage)
        }
        .onChange(of: appState.marginHorizontal) { _, _ in
            // 边距变化会改变可用宽度，需要先更新 paginationSize 再重排
            repaginateAfterLayoutChange()
        }
        .onChange(of: appState.marginVertical) { _, _ in
            repaginateAfterLayoutChange()
        }
        .onChange(of: appState.showFooter) { _, _ in
            repaginateAfterLayoutChange()
        }
        .onChange(of: appState.pageTurnStyle) { _, _ in
            // 分页 ↔ 滚动切换时，用当前字符位置对齐
            repaginate(keepingOffset: currentOffsetInPage)
        }
        .onChange(of: appState.theme) { _, _ in
            rebuildFramesetterOnly()
        }
    }

    /// 边距类改动会同时影响可用尺寸，需要重新取一次布局度量
    private func repaginateAfterLayoutChange() {
        guard let layout = currentLayout else { return }
        paginationSize = layout.textSize
        repaginate(keepingOffset: currentOffsetInPage)
    }

    private func applyLayout(_ layout: ReaderLayout) {
        currentLayout = layout
        if layout.textSize != paginationSize {
            paginationSize = layout.textSize
        }
    }

    // MARK: - 正文（分页模式）

    @ViewBuilder
    private func content(textSize: CGSize) -> some View {
        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError {
            errorView(loadError)
        } else if pageIndex < pages.count, let framesetter {
            // 注意：这里不再重建 attributed，也不再挂 .id(...)，
            // 翻页只是把新的 range 交给同一个 CoreTextPageView。
            CoreTextPage(framesetter: framesetter, range: pages[pageIndex])
                .equatable()
                .frame(width: textSize.width, height: textSize.height)
        } else {
            Color.clear
        }
    }

    // MARK: - 正文（上下滑动模式）

    @ViewBuilder
    private func scrollContent(layout: ReaderLayout) -> some View {
        if isLoading {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let loadError {
            errorView(loadError)
        } else if let framesetter, chapterLength > 0 {
            ContinuousText(framesetter: framesetter,
                           length: chapterLength,
                           contentWidth: layout.textSize.width,
                           initialOffset: pendingOffset,
                           onOffsetChange: { offset in
                               scrollCharOffset = offset
                           },
                           onReachBottom: {
                               if chapterIndex + 1 < chapters.count {
                                   goToChapter(chapterIndex + 1, offset: 0)
                               }
                           },
                           onTap: { location in
                               handleTap(location: location, size: layout.size)
                           })
                .frame(width: layout.textSize.width, height: layout.textSize.height)
        } else {
            Color.clear
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.secondary)
            Text(message)
                .font(.footnote)
                .foregroundStyle(theme.secondaryTextColor)
                .multilineTextAlignment(.center)
            Button("重试") { loadChapter(chapterIndex: chapterIndex, offset: pendingOffset) }
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - 页脚

    private func footer(layout: ReaderLayout) -> some View {
        VStack {
            Spacer()
            HStack {
                Text(currentChapter?.title ?? "")
                    .lineLimit(1)
                Spacer()
                if isScrollMode {
                    Text("\(Int(book.readingProgress * 100))%")
                        .monospacedDigit()
                } else {
                    Text("\(pageIndex + 1)/\(max(pages.count, 1))")
                        .monospacedDigit()
                    Spacer()
                    Text("\(Int(book.readingProgress * 100))%")
                        .monospacedDigit()
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(theme.secondaryTextColor)
            .padding(.horizontal, layout.marginH)
            .padding(.bottom, max(layout.insets.bottom, 8) + 4)
        }
        .allowsHitTesting(false)
    }

    // MARK: - 顶栏

    private var topBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 12) {
                Button {
                    saveProgress()
                    dismiss()
                } label: {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(skin.accent)
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                VStack(alignment: .leading, spacing: 2) {
                    Text(book.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(skin.textPrimary)
                        .lineLimit(1)
                    Text(currentChapter?.title ?? "")
                        .font(.caption2)
                        .foregroundStyle(skin.textSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Menu {
                    Button { showChapterList = true } label: { Label("目录", systemImage: "list.bullet") }
                    Button { showSettings = true } label: { Label("排版", systemImage: "textformat.size") }
                    if let ch = currentChapter, !ch.isCached, ch.remoteURL != nil {
                        Button {
                            DownloadManager.shared.downloadAll(book: book, store: store)
                        } label: { Label("下载整本", systemImage: "arrow.down.circle") }
                    }
                } label: {
                    Image(systemName: "ellipsis")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(skin.accent)
                        .frame(width: 34, height: 34)
                        .contentShape(Rectangle())
                }
            }

            // 「下载整本」的实时进度：直接观察 DownloadManager 里这本书的任务，
            // 章节维度 + 当前章字节维度合成 fraction，完成后自动消失。
            if let task = DownloadManager.shared.task(for: book.id), task.state.isActive {
                HStack(spacing: 8) {
                    ProgressView(value: task.fraction)
                        .progressViewStyle(.linear)
                        .tint(skin.accent)
                    Text(task.statusText)
                        .font(.caption2)
                        .foregroundStyle(skin.textSecondary)
                        .lineLimit(1)
                        .monospacedDigit()
                    Button {
                        DownloadManager.shared.cancel(bookID: book.id)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(skin.textSecondary)
                    }
                    .buttonStyle(.plain)
                }
                .transition(.opacity)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .background {
            skin.surface
                .overlay(alignment: .bottom) {
                    Rectangle().fill(skin.separator).frame(height: 0.5)
                }
                .ignoresSafeArea(edges: .top)
        }
    }

    // MARK: - 底栏

    private var bottomBar: some View {
        VStack(spacing: 14) {
            // 整本书进度：拖动可快速跳到任意章节
            HStack(spacing: 10) {
                Text("\(chapterIndex + 1)")
                    .font(.caption2)
                    .foregroundStyle(skin.textSecondary)
                    .monospacedDigit()
                Slider(value: Binding(
                    get: { Double(chapterIndex) },
                    set: { newValue in
                        let target = Int(newValue.rounded())
                        guard target != chapterIndex, target >= 0, target < chapters.count else { return }
                        goToChapter(target, offset: 0)
                    }
                ), in: 0...Double(max(chapters.count - 1, 1)))
                .tint(skin.accent)
                Text("\(chapters.count)")
                    .font(.caption2)
                    .foregroundStyle(skin.textSecondary)
                    .monospacedDigit()
            }

            HStack(spacing: 0) {
                chromeButton("上一章", "chevron.up", enabled: chapterIndex > 0) {
                    goToChapter(max(chapterIndex - 1, 0), offset: 0)
                }
                chromeButton("目录", "list.bullet", enabled: true) {
                    showChapterList = true
                }
                chromeButton("排版", "textformat.size", enabled: true) {
                    showSettings = true
                }
                chromeButton("下一章", "chevron.down", enabled: chapterIndex < chapters.count - 1) {
                    goToChapter(min(chapterIndex + 1, max(chapters.count - 1, 0)), offset: 0)
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.top, 14)
        .padding(.bottom, 6)
        .background {
            skin.surface
                .overlay(alignment: .top) {
                    Rectangle().fill(skin.separator).frame(height: 0.5)
                }
                .ignoresSafeArea(edges: .bottom)
        }
    }

    /// 阅读器底栏工具按钮：图标在上、文字在下，禁用态压暗
    private func chromeButton(_ title: String,
                              _ symbol: String,
                              enabled: Bool,
                              action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: symbol)
                    .font(.system(size: 17, weight: .medium))
                Text(title)
                    .font(.system(size: 10))
            }
            .foregroundStyle(enabled ? skin.accent : skin.textSecondary.opacity(0.35))
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    // MARK: - 手势

    private func handleTap(location: CGPoint, size: CGSize) {
        let leftZone = size.width * 0.3
        let rightZone = size.width * 0.7
        let middleV = size.height * 0.15...size.height * 0.85

        if showChrome {
            showChrome = false
            return
        }
        // 滚动模式没有"翻页"，左右区域改成上一章/下一章
        if isScrollMode {
            if location.y >= middleV.lowerBound, location.y <= middleV.upperBound {
                if location.x < leftZone {
                    goToChapter(max(chapterIndex - 1, 0), offset: 0)
                    return
                } else if location.x > rightZone {
                    if chapterIndex + 1 < chapters.count {
                        goToChapter(chapterIndex + 1, offset: 0)
                    }
                    return
                }
            }
            withAnimation(.easeInOut(duration: 0.15)) { showChrome.toggle() }
            return
        }

        if location.y >= middleV.lowerBound, location.y <= middleV.upperBound {
            if location.x < leftZone {
                previousPage()
                return
            } else if location.x > rightZone {
                nextPage()
                return
            }
        }
        withAnimation(.easeInOut(duration: 0.15)) { showChrome.toggle() }
    }

    /// 手势只做判定，不做跟手位移：拖动期间任何 @State 变化都会让整个
    /// ReaderView 重新求值（含 SwiftData 关系访问与 Core Text 视图重建），
    /// 那才是翻页卡顿的真正来源。
    private func swipeGesture(width: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: 24)
            .onEnded { value in
                let threshold: CGFloat = 50
                let dx = value.translation.width
                let dy = value.translation.height
                // 明显是纵向拖动就交给系统，不当作翻页
                guard abs(dx) > abs(dy) else { return }
                if dx < -threshold {
                    nextPage()
                } else if dx > threshold {
                    previousPage()
                }
            }
    }

    // MARK: - 翻页逻辑

    private var currentOffsetInPage: Int {
        if isScrollMode { return scrollCharOffset }
        guard pageIndex < pages.count else { return pendingOffset }
        return pages[pageIndex].location
    }

    /// 翻页不加动画：CoreTextPage 是 UIViewRepresentable，包在 withAnimation
    /// 里会被要求逐帧刷新，等于每帧重排整页文字。
    private func nextPage() {
        if pageIndex + 1 < pages.count {
            pageIndex += 1
            saveProgress()
        } else if chapterIndex + 1 < chapters.count {
            goToChapter(chapterIndex + 1, offset: 0)
        }
    }

    private func previousPage() {
        if pageIndex > 0 {
            pageIndex -= 1
            saveProgress()
        } else if chapterIndex > 0 {
            // 跳到上一章最后一页
            let prev = chapterIndex - 1
            loadChapter(chapterIndex: prev, offset: Int.max, preferLastPage: true)
        }
    }

    // MARK: - 章节加载

    private func loadInitial() {
        chapterIndex = min(max(book.positionChapterIndex, 0), max(chapters.count - 1, 0))
        pendingOffset = book.positionCharOffset
        loadChapter(chapterIndex: chapterIndex, offset: pendingOffset)
    }

    private func loadChapter(chapterIndex idx: Int, offset: Int, preferLastPage: Bool = false) {
        guard idx >= 0, idx < chapters.count else { return }
        chapterIndex = idx
        isLoading = true
        loadError = nil
        let chapter = chapters[idx]
        let bookRef = book
        let storeRef: Store? = store

        Task {
            var text = ""
            // 1. 本地缓存
            if let url = chapter.cacheFileURL,
               FileManager.default.fileExists(atPath: url.path) {
                text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
            }
            // 2. 远程抓取
            if text.isEmpty, let remote = chapter.remoteURL {
                let source = SourceRegistry.shared.source(id: UUID(uuidString: bookRef.sourceID ?? ""))
                do {
                    if let src = source, src.kind == .rules || src.kind == .jsonAPI {
                        text = try await WebBookSource.content(source: src, chapterURL: remote)
                    } else {
                        let resp = try await HTTPClient.shared.fetchText(remote, source: source)
                        text = TextSanitizer.normalizeBody(HTMLParser.htmlToPlainText(resp.text))
                    }
                    if !text.isEmpty, let storeRef {
                        try? await MainActor.run {
                            try storeRef.writeChapterCache(book: bookRef, chapter: chapter, text: text)
                        }
                    }
                } catch {
                    await MainActor.run {
                        self.loadError = "本章加载失败：\(error.localizedDescription)"
                        self.isLoading = false
                    }
                    return
                }
            }

            if text.isEmpty {
                text = "（本章内容为空）"
            }

            await MainActor.run {
                self.chapterText = text
                // 新章：先建 framesetter，再按需分页
                self.framesetter = nil
                self.rebuildFramesetter()
                self.isLoading = false
                if !self.isScrollMode {
                    self.repaginate(toOffset: preferLastPage ? Int.max : offset)
                } else {
                    self.scrollCharOffset = offset
                }
            }
        }
    }

    // MARK: - 排版缓存

    /// 只重建 attributed/framesetter（换主题改颜色时走这里，不需要重新分页）
    private func rebuildFramesetterOnly() {
        rebuildFramesetter()
    }

    /// 用当前参数建一次整章 framesetter。分页与滚动两种模式共用。
    private func rebuildFramesetter() {
        guard !chapterText.isEmpty else {
            framesetter = nil
            chapterLength = 0
            return
        }
        let attributed = Paginator.makeAttributedString(
            text: chapterText,
            font: font,
            lineSpacing: appState.lineSpacing,
            color: UIColor(theme.textColor))
        chapterLength = attributed.length
        framesetter = CTFramesetterCreateWithAttributedString(attributed)
    }

    // MARK: - 分页

    private func repaginate(keepingOffset offset: Int? = nil) {
        let target = offset ?? currentOffsetInPage
        repaginate(toOffset: target)
    }

    private func repaginate(toOffset offset: Int) {
        guard !chapterText.isEmpty, paginationSize.width > 0, paginationSize.height > 0 else {
            pages = [NSRange(location: 0, length: (chapterText as NSString).length)]
            pageIndex = 0
            return
        }
        // 滚动模式不需要分页
        if isScrollMode {
            scrollCharOffset = min(offset, max(chapterLength - 1, 0))
            return
        }

        repaginateToken += 1
        let token = repaginateToken
        let text = chapterText
        let size = paginationSize
        let f = font
        let ls = appState.lineSpacing

        // 后台分页，主线程不阻塞；回到主线程后再校验 token，丢弃过期结果
        Task.detached(priority: .userInitiated) {
            let newPages = Paginator.paginate(text: text, size: size, font: f,
                                              lineSpacing: ls, color: .black)
            await MainActor.run {
                guard token == self.repaginateToken else { return }
                self.pages = newPages
                if offset == Int.max {
                    self.pageIndex = max(newPages.count - 1, 0)
                } else {
                    self.pageIndex = newPages.firstIndex {
                        offset >= $0.location && offset < $0.location + $0.length
                    } ?? 0
                }
            }
        }
    }

    private func goToChapter(_ idx: Int, offset: Int) {
        guard idx >= 0, idx < chapters.count else { return }
        pendingOffset = offset
        pages = []
        pageIndex = 0
        scrollCharOffset = offset
        loadChapter(chapterIndex: idx, offset: offset)
    }

    // MARK: - 进度保存

    private func saveProgress() {
        let s = store
        let offset = currentOffsetInPage
        s.saveProgress(book: book, chapterIndex: chapterIndex, charOffset: offset)
        // 预取后续章节
        if let current = currentChapter {
            let next = chapters.filter { $0.index > current.index }
            DownloadManager.shared.prefetch(book: book, fromChapters: Array(next.prefix(3)), store: s)
        }
    }
}

// MARK: - 设置面板

struct ReaderSettingsPanel: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    @Environment(\.omniSkin) private var skin

    /// true = 作为 sheet 弹出（自带导航栏与"完成"按钮）
    /// false = 嵌在其它导航栈里（如"我的 → 排版设置"），不再套一层 NavigationStack
    var asSheet: Bool = true

    var body: some View {
        if asSheet {
            NavigationStack {
                form
                    .navigationTitle("排版设置")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("完成") { dismiss() }
                        }
                    }
            }
            .presentationDetents([.medium, .large])
        } else {
            form
                .navigationTitle("排版设置")
                .navigationBarTitleDisplayMode(.inline)
        }
    }

    @ViewBuilder
    private var form: some View {
        @Bindable var appState = appState

        ScrollView {
            VStack(spacing: 12) {
                themeCard
                fontSizeCard
                sliderCard(title: "行距", value: $appState.lineSpacing, range: 0...20, step: 1)
                sliderCard(title: "段距", value: $appState.paragraphSpacing, range: 0...24, step: 2)
                marginCard
                pageTurnCard
                footerCard
                resetCard
            }
            .padding(.horizontal, 16)
            .padding(.top, 10)
            .padding(.bottom, 30)
        }
        .background(skin.background)
    }

    // MARK: 卡片

    private func settingsCard<Content: View>(
        _ title: String,
        trailing: String? = nil,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(skin.textPrimary)
                Spacer(minLength: 8)
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(skin.accent)
                        .monospacedDigit()
                }
            }
            content()
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(skin.surface)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(skin.separator, lineWidth: 0.5)
        }
    }

    private var themeCard: some View {
        settingsCard("阅读主题", trailing: appState.theme.displayName) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(ReaderTheme.allCases) { item in
                        Button {
                            appState.theme = item
                        } label: {
                            VStack(spacing: 6) {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(item.backgroundColor)
                                    .frame(width: 52, height: 52)
                                    .overlay {
                                        Text("Aa")
                                            .font(.system(size: 16, weight: .medium, design: .serif))
                                            .foregroundStyle(item.textColor)
                                    }
                                    .overlay {
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .strokeBorder(appState.theme == item ? skin.accent : skin.separator,
                                                          lineWidth: appState.theme == item ? 2 : 1)
                                    }
                                Text(item.displayName)
                                    .font(.system(size: 10))
                                    .foregroundStyle(appState.theme == item ? skin.accent : skin.textSecondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var fontSizeCard: some View {
        @Bindable var appState = appState
        return settingsCard("字号", trailing: "\(Int(appState.fontSize))") {
            HStack(spacing: 14) {
                fontSizeButton("A", size: 13, enabled: appState.fontSize > 12) {
                    appState.fontSize = max(12, appState.fontSize - 1)
                }
                Slider(value: $appState.fontSize, in: 12...32, step: 1)
                    .tint(skin.accent)
                fontSizeButton("A", size: 21, enabled: appState.fontSize < 32) {
                    appState.fontSize = min(32, appState.fontSize + 1)
                }
            }
        }
    }

    private func fontSizeButton(_ label: String, size: CGFloat, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.system(size: size, weight: .semibold, design: .serif))
                .foregroundStyle(enabled ? skin.textPrimary : skin.textSecondary.opacity(0.4))
                .frame(width: 38, height: 38)
                .background {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(skin.surfaceAlt)
                }
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func sliderCard(
        title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        settingsCard(title, trailing: "\(Int(value.wrappedValue))") {
            Slider(value: value, in: range, step: step)
                .tint(skin.accent)
        }
    }

    private var marginCard: some View {
        @Bindable var appState = appState
        return settingsCard("页边距") {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Text("左右")
                        .font(.system(size: 12))
                        .foregroundStyle(skin.textSecondary)
                        .frame(width: 34, alignment: .leading)
                    Slider(value: $appState.marginHorizontal, in: 0.02...0.15, step: 0.005)
                        .tint(skin.accent)
                    Text("\(Int(appState.marginHorizontal * 100))%")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(skin.accent)
                        .monospacedDigit()
                        .frame(width: 38, alignment: .trailing)
                }
                HStack(spacing: 10) {
                    Text("上下")
                        .font(.system(size: 12))
                        .foregroundStyle(skin.textSecondary)
                        .frame(width: 34, alignment: .leading)
                    Slider(value: $appState.marginVertical, in: 0.01...0.10, step: 0.005)
                        .tint(skin.accent)
                    Text("\(Int(appState.marginVertical * 100))%")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(skin.accent)
                        .monospacedDigit()
                        .frame(width: 38, alignment: .trailing)
                }
            }
        }
    }

    private var pageTurnCard: some View {
        @Bindable var appState = appState
        return settingsCard("翻页方式") {
            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    ForEach(PageTurnStyle.allCases) { style in
                        Button {
                            appState.pageTurnStyle = style
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: style.isScrollMode ? "arrow.up.and.down" : "arrow.left.and.right")
                                    .font(.system(size: 16, weight: .medium))
                                Text(style.displayName)
                                    .font(.system(size: 10))
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 11)
                            .foregroundStyle(appState.pageTurnStyle == style ? skin.accent : skin.textSecondary)
                            .background {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .fill(appState.pageTurnStyle == style ? skin.accent.opacity(0.16) : skin.surfaceAlt)
                            }
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .strokeBorder(appState.pageTurnStyle == style ? skin.accent : .clear, lineWidth: 1)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text(appState.pageTurnStyle.isScrollMode
                     ? "整章连续滚动，适合长章节。点击屏幕左右可切换上一章/下一章。"
                     : "左右滑动翻页，点击屏幕左右三分之一区域也能翻。")
                    .font(.system(size: 11))
                    .foregroundStyle(skin.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var footerCard: some View {
        @Bindable var appState = appState
        return settingsCard("页脚") {
            Toggle(isOn: $appState.showFooter) {
                Text("显示章节名与进度")
                    .font(.system(size: 13))
                    .foregroundStyle(skin.textPrimary)
            }
            .tint(skin.accent)
        }
    }

    private var resetCard: some View {
        Button {
            appState.resetReaderDefaults()
        } label: {
            Text("恢复默认排版")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(skin.accent)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(skin.surface)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(skin.separator, lineWidth: 0.5)
                }
        }
        .buttonStyle(.plain)
    }
}