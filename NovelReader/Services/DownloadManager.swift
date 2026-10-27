//
//  DownloadManager.swift
//  NovelReader
//
//  离线下载管理：按章节下载、整本下载、后台继续、进度状态
//

import Foundation
import Observation

struct DownloadTask: Identifiable, Equatable {
    enum State: Equatable {
        case queued
        case running(done: Int, total: Int, current: String)
        case finished(Int)
        case failed(String)

        var isActive: Bool {
            if case .running = self { return true }
            if case .queued = self { return true }
            return false
        }
    }

    var id: UUID
    var bookID: UUID
    var bookTitle: String
    var state: State
}

@Observable
@MainActor
final class DownloadManager {
    static let shared = DownloadManager()

    private(set) var tasks: [DownloadTask] = []

    private init() {}

    var activeCount: Int { tasks.filter { $0.state.isActive }.count }

    func task(for bookID: UUID) -> DownloadTask? {
        tasks.first { $0.bookID == bookID }
    }

    func cancel(bookID: UUID) {
        tasks.removeAll { $0.bookID == bookID }
    }

    // MARK: - 整本下载（网络书源 / NAS 章节页）

    /// 下载一本书所有未缓存章节（在线书源）
    func downloadAll(book: Book, store: Store, registry: SourceRegistry = .shared) {
        guard !tasks.contains(where: { $0.bookID == book.id && $0.state.isActive }) else { return }
        let taskID = UUID()
        tasks.append(DownloadTask(id: taskID, bookID: book.id, bookTitle: book.title, state: .queued))

        Task { @MainActor in
            let source = registry.source(id: UUID(uuidString: book.sourceID ?? ""))
            let chapters = store.chapters(for: book).filter { !$0.isCached && $0.remoteURL != nil }
            let total = chapters.count
            if total == 0 {
                self.update(taskID) { _ in .finished(0) }
                return
            }
            var done = 0
            for ch in chapters {
                if !self.tasks.contains(where: { $0.id == taskID }) { return }  // 被取消
                self.update(taskID) { _ in .running(done: done, total: total, current: ch.title) }
                guard let urlString = ch.remoteURL else { continue }
                do {
                    let text: String
                    if let src = source, src.kind == .rules || src.kind == .jsonAPI {
                        text = try await WebBookSource.content(source: src, chapterURL: urlString)
                    } else {
                        let resp = try await HTTPClient.shared.fetchText(urlString, source: source)
                        text = TextSanitizer.normalizeBody(HTMLParser.htmlToPlainText(resp.text))
                    }
                    try store.writeChapterCache(book: book, chapter: ch, text: text)
                    done += 1
                } catch {
                    // 单章失败不中断
                }
                try? await Task.sleep(nanoseconds: 250_000_000)  // 限速，避免把站打死
            }
            book.isFullyDownloaded = book.cachedChapterCount >= book.chapterCount
            self.update(taskID) { _ in .finished(done) }
        }
    }

    /// 预下载后续 N 章（阅读器翻页时后台补缓存）
    func prefetch(book: Book, fromChapters chapters: [Chapter], store: Store,
                  registry: SourceRegistry = .shared) {
        let pending = chapters.filter { !$0.isCached && $0.remoteURL != nil }.prefix(5)
        guard !pending.isEmpty else { return }
        let source = registry.source(id: UUID(uuidString: book.sourceID ?? ""))

        Task { @MainActor in
            for ch in pending {
                guard let urlString = ch.remoteURL else { continue }
                if let src = source, src.kind == .rules || src.kind == .jsonAPI,
                   let text = try? await WebBookSource.content(source: src, chapterURL: urlString) {
                    try? store.writeChapterCache(book: book, chapter: ch, text: text)
                } else if let resp = try? await HTTPClient.shared.fetchText(urlString, source: source) {
                    let text = TextSanitizer.normalizeBody(HTMLParser.htmlToPlainText(resp.text))
                    try? store.writeChapterCache(book: book, chapter: ch, text: text)
                }
            }
        }
    }

    private func update(_ id: UUID, _ transform: (DownloadTask.State) -> DownloadTask.State) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].state = transform(tasks[idx].state)
    }

    /// 清理已结束的任务
    func clearFinished() {
        tasks.removeAll { if case .running = $0.state { return false }; return true }
    }
}
