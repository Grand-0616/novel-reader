//
//  BookDetailView.swift
//  NovelReader
//
//  书籍详情：简介、目录、下载状态、开始阅读
//

import SwiftUI
import SwiftData

struct BookDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(AppState.self) private var appState
    @Environment(SourceRegistry.self) private var registry
    @Environment(\.omniSkin) private var skin

    let book: Book

    @State private var showReader = false
    @State private var showChapterList = false
    @State private var errorMessage: String?

    private var chapters: [Chapter] {
        book.chapters.sorted { $0.index < $1.index }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    actionRow
                    progressSection
                    summarySection
                    chapterSection
                }
                .padding(.vertical, 16)
            }
            .background(skin.background)
            .navigationTitle(book.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(skin.surface, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
            .fullScreenCover(isPresented: $showReader) {
                ReaderView(book: book)
            }
            .sheet(isPresented: $showChapterList) {
                ChapterListView(book: book) { index in
                    book.positionChapterIndex = index
                    book.positionCharOffset = 0
                    showChapterList = false
                    showReader = true
                }
            }
            .alert("出错了", isPresented: .constant(errorMessage != nil)) {
                Button("好") { errorMessage = nil }
            } message: {
                Text(errorMessage ?? "")
            }
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            ZStack {
                if let data = book.coverData, let img = UIImage(data: data) {
                    Image(uiImage: img).resizable().aspectRatio(contentMode: .fill)
                } else {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.accentColor.opacity(0.15))
                    Image(systemName: "book.closed.fill")
                        .font(.system(size: 34))
                        .foregroundStyle(Color.accentColor.opacity(0.6))
                }
            }
            .frame(width: 96, height: 132)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

            VStack(alignment: .leading, spacing: 8) {
                Text(book.title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(3)
                Text(book.displayAuthor)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                HStack(spacing: 6) {
                    Label(book.origin.displayName, systemImage: book.origin.symbolName)
                        .font(.caption2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                    Text(book.fileFormat.uppercased())
                        .font(.caption2)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }
                Text("\(book.chapterCount) 章 · \(formattedSize)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
    }

    private var formattedSize: String {
        let chars = book.totalCharacters
        if chars > 10_000 {
            return String(format: "%.1f 万字", Double(chars) / 10_000)
        }
        return "\(chars) 字"
    }

    // MARK: - 操作

    private var actionRow: some View {
        VStack(spacing: 10) {
            Button {
                showReader = true
            } label: {
                Label(book.positionChapterIndex > 0 || book.positionCharOffset > 0 ? "继续阅读" : "开始阅读",
                      systemImage: "book.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .disabled(chapters.isEmpty)

            HStack(spacing: 10) {
                Button {
                    showChapterList = true
                } label: {
                    Label("目录", systemImage: "list.bullet")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)

                if let dl = DownloadManager.shared.task(for: book.id), dl.state.isActive {
                    Button {
                        DownloadManager.shared.cancel(bookID: book.id)
                    } label: {
                        Label("取消下载", systemImage: "stop.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                } else {
                    Button {
                        DownloadManager.shared.downloadAll(book: book, store: appState.store ?? Store(context: modelContext))
                    } label: {
                        Label("下载全部", systemImage: "arrow.down.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .disabled(!chapters.contains { !$0.isCached && $0.remoteURL != nil })
                }
            }
        }
        .padding(.horizontal, 16)
    }

    // MARK: - 进度

    private var progressSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("阅读进度")
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text("\(Int(book.readingProgress * 100))%")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: book.readingProgress)
                .tint(Color.accentColor)

            HStack {
                Text("离线：\(book.cachedChapterCount)/\(max(book.chapterCount, 1)) 章")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if let dl = DownloadManager.shared.task(for: book.id) {
                    switch dl.state {
                    case .running(let done, let total, let current, _):
                        Text("下载中 \(done)/\(total) \(current)")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    case .finished(let n):
                        Text("已下载 \(n) 章")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    case .failed(let m):
                        Text("失败：\(m)").font(.caption2).foregroundStyle(.red)
                    case .queued:
                        Text("排队中…").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
    }

    // MARK: - 简介

    @ViewBuilder
    private var summarySection: some View {
        if !book.summary.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("简介").font(.subheadline.weight(.medium))
                Text(book.summary)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)
        }
    }

    // MARK: - 目录预览

    private var chapterSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("目录").font(.subheadline.weight(.medium))
                Spacer()
                Button("全部 \(chapters.count) 章") { showChapterList = true }
                    .font(.caption)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)

            Divider()

            ForEach(chapters.prefix(12)) { ch in
                Button {
                    book.positionChapterIndex = ch.index
                    book.positionCharOffset = 0
                    showReader = true
                } label: {
                    HStack {
                        Text(ch.title)
                            .font(.footnote)
                            .lineLimit(1)
                        Spacer()
                        if !ch.isCached && ch.remoteURL != nil {
                            Image(systemName: "icloud.and.arrow.down")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Divider().padding(.leading, 14)
            }
        }
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
        .padding(.bottom, 30)
    }
}

// MARK: - 章节目录

struct ChapterListView: View {
    @Environment(\.dismiss) private var dismiss
    let book: Book
    var onSelect: (Int) -> Void

    @State private var query = ""
    @State private var ascending = true

    private var chapters: [Chapter] {
        var list = book.chapters.sorted { $0.index < $1.index }
        if !ascending { list.reverse() }
        if !query.isEmpty {
            list = list.filter { $0.title.localizedCaseInsensitiveContains(query) }
        }
        return list
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List {
                    ForEach(chapters) { ch in
                        Button {
                            onSelect(ch.index)
                        } label: {
                            HStack(spacing: 8) {
                                Text(ch.title)
                                    .font(.subheadline)
                                    .foregroundStyle(ch.index == book.positionChapterIndex ? Color.accentColor : .primary)
                                    .lineLimit(2)
                                Spacer()
                                if ch.index == book.positionChapterIndex {
                                    Image(systemName: "bookmark.fill")
                                        .font(.caption)
                                        .foregroundStyle(Color.accentColor)
                                }
                                if !ch.isCached && ch.remoteURL != nil {
                                    Image(systemName: "icloud.and.arrow.down")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .id(ch.index)
                    }
                }
                .listStyle(.plain)
                .searchable(text: $query, prompt: "搜索章节")
                .onAppear {
                    proxy.scrollTo(book.positionChapterIndex, anchor: .center)
                }
            }
            .navigationTitle("目录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        ascending.toggle()
                    } label: {
                        Image(systemName: ascending ? "arrow.down" : "arrow.up")
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
