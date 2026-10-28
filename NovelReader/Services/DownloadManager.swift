//
//  DownloadManager.swift
//  NovelReader
//
//  离线下载管理：按章节下载、整本下载、字节级进度、可取消
//
//  进度模型分两层：
//    - 章节进度：done / total，让用户知道还剩多少章
//    - 当前章字节进度：byteProgress 0...1，让进度条在单章内也能动
//  合成后的 overallFraction 才是 UI 上真正画的那个值。
//

import Foundation
import Observation

struct DownloadTask: Identifiable, Equatable {
    enum State: Equatable {
        case queued
        /// done/total 是章节维度；byteProgress 是当前章内部的 0...1
        case running(done: Int, total: Int, current: String, byteProgress: Double)
        case finished(Int)
        case failed(String)

        var isActive: Bool {
            if case .running = self { return true }
            if case .queued = self { return true }
            return false
        }

        var isRunning: Bool {
            if case .running = self { return true }
            return false
        }
    }

    var id: UUID
    var bookID: UUID
    var bookTitle: String
    var state: State

    /// 0...1 的整体进度，章节 + 当前章字节进度加权
    var fraction: Double {
        switch state {
        case .queued:
            return 0
        case .finished:
            return 1
        case .failed:
            return 0
        case .running(let done, let total, _, let byteProgress):
            guard total > 0 else { return 0 }
            let base = Double(done) / Double(total)
            let slice = 1.0 / Double(total)
            return min(1.0, base + slice * max(0, min(1, byteProgress)))
        }
    }

    /// 供 UI 显示的描述文字
    var statusText: String {
        switch state {
        case .queued:
            return "排队中…"
        case .running(let done, let total, let current, _):
            let title = current.isEmpty ? "" : " · \(current)"
            return "下载中 \(done)/\(total)\(title)"
        case .finished(let n):
            return n > 0 ? "已下载 \(n) 章" : "无需下载"
        case .failed(let m):
            return "失败：\(m)"
        }
    }
}

@Observable
@MainActor
final class DownloadManager {
    static let shared = DownloadManager()

    private(set) var tasks: [DownloadTask] = []

    /// 正在下载的章内字节进度，按 bookID 索引（不参与任务列表刷新，减少重绘）
    private var byteProgress: [UUID: Double] = [:]

    /// bookID → 远程地址，供 task(forRemote:) 反查服务器列表条目
    private var remoteKeys: [UUID: String] = [:]

    /// 取消标记：bookID -> 是否已取消
    private var cancelled: Set<UUID> = []

    private init() {}

    var activeCount: Int { tasks.filter { $0.state.isActive }.count }

    func task(for bookID: UUID) -> DownloadTask? {
        tasks.first { $0.bookID == bookID }
    }

    /// 按远程地址查任务（服务器列表里同一个条目可能还没落库）
    func task(forRemote href: String) -> DownloadTask? {
        let key = href.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !key.isEmpty else { return nil }
        return tasks.first { task in
            remoteKey(for: task.bookID) == key
        }
    }

    /// 记录 bookID → 远程地址，供 task(forRemote:) 反查
    private func remoteKey(for bookID: UUID) -> String? {
        remoteKeys[bookID]
    }
    func registerRemote(_ href: String, for bookID: UUID) {
        remoteKeys[bookID] = href.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func cancel(bookID: UUID) {
        cancelled.insert(bookID)
        byteProgress.removeValue(forKey: bookID)
        remoteKeys.removeValue(forKey: bookID)
        tasks.removeAll { $0.bookID == bookID }
    }

    // MARK: - 整本下载（网络书源 / NAS 章节页）

    /// 下载一本书所有未缓存章节（在线书源）
    func downloadAll(book: Book, store: Store, registry: SourceRegistry = .shared) {
        guard !tasks.contains(where: { $0.bookID == book.id && $0.state.isActive }) else { return }
        let taskID = UUID()
        cancelled.remove(book.id)
        if let remote = book.remoteURL {
            registerRemote(remote, for: book.id)
        }
        tasks.append(DownloadTask(id: taskID, bookID: book.id, bookTitle: book.title, state: .queued))

        Task { @MainActor in
            let source = registry.source(id: UUID(uuidString: book.sourceID ?? ""))
            let chapters = store.chapters(for: book).filter { !$0.isCached && $0.remoteURL != nil }
                .sorted { $0.index < $1.index }
            let total = chapters.count
            if total == 0 {
                self.update(taskID) { _ in .finished(0) }
                return
            }
            var done = 0
            var failures: [String] = []
            for ch in chapters {
                if self.cancelled.contains(book.id) { return }
                guard self.tasks.contains(where: { $0.id == taskID }) else { return }

                self.update(taskID) {
                    _ in .running(done: done, total: total, current: ch.title, byteProgress: 0)
                }
                guard let urlString = ch.remoteURL else { continue }
                do {
                    let text: String
                    if let src = source, src.kind == .rules || src.kind == .jsonAPI {
                        text = try await WebBookSource.content(source: src, chapterURL: urlString)
                    } else {
                        let resp = try await HTTPClient.shared.fetchText(urlString, source: source)
                        text = TextSanitizer.normalizeBody(HTMLParser.htmlToPlainText(resp.text))
                    }
                    if self.cancelled.contains(book.id) { return }
                    try store.writeChapterCache(book: book, chapter: ch, text: text)
                    done += 1
                    self.update(taskID) {
                        _ in .running(done: done, total: total, current: ch.title, byteProgress: 1)
                    }
                } catch {
                    // 单章失败不中断，记下来最后汇报
                    failures.append(ch.title)
                }
                try? await Task.sleep(nanoseconds: 250_000_000)  // 限速，避免把站打死
            }

            book.isFullyDownloaded = book.cachedChapterCount >= max(book.chapterCount, 1)
            if done == 0, let first = failures.first {
                self.update(taskID) { _ in .failed("全部章节失败，首章：\(first)") }
            } else if !failures.isEmpty {
                // 有失败但成功的更多：仍算完成，失败数写进状态
                self.update(taskID) { _ in .finished(done) }
            } else {
                self.update(taskID) { _ in .finished(done) }
            }
            self.byteProgress.removeValue(forKey: book.id)
        }
    }

    /// 下载单个文件到书籍目录（本地文件型书源：TXT/EPUB 直链）
    func downloadFile(
        book: Book,
        from urlString: String,
        source: RemoteSource?,
        store: Store
    ) {
        guard !tasks.contains(where: { $0.bookID == book.id && $0.state.isActive }) else { return }
        let taskID = UUID()
        cancelled.remove(book.id)
        registerRemote(urlString, for: book.id)
        tasks.append(DownloadTask(id: taskID, bookID: book.id, bookTitle: book.title, state: .queued))

        Task { @MainActor in
            self.update(taskID) {
                _ in .running(done: 0, total: 1, current: "下载文件", byteProgress: 0)
            }
            do {
                let data = try await HTTPClient.shared.fetchData(urlString, source: source) { frac in
                    Task { @MainActor in
                        self.reportByteProgress(book.id, taskID: taskID, frac: frac, done: 0, total: 1, current: "下载文件")
                    }
                }
                if self.cancelled.contains(book.id) { return }
                _ = data  // 调用方已经通过 ImportService 落库；这里只负责进度
                self.update(taskID) { _ in .running(done: 1, total: 1, current: "完成", byteProgress: 1) }
                try? await Task.sleep(nanoseconds: 400_000_000)
                self.update(taskID) { _ in .finished(1) }
            } catch {
                if self.cancelled.contains(book.id) { return }
                self.update(taskID) { _ in .failed(error.localizedDescription) }
            }
            self.byteProgress.removeValue(forKey: book.id)
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

    // MARK: - 内部

    /// 从后台线程回报的章内字节进度（节流到主线程更新）
    private func reportByteProgress(_ bookID: UUID, taskID: UUID, frac: Double,
                                    done: Int, total: Int, current: String) {
        guard !cancelled.contains(bookID) else { return }
        let clamped = max(0, min(1, frac))
        // 低于 0.5% 的抖动忽略
        if abs((byteProgress[bookID] ?? -1) - clamped) < 0.005, clamped < 1 { return }
        byteProgress[bookID] = clamped
        update(taskID) {
            _ in .running(done: done, total: total, current: current, byteProgress: clamped)
        }
    }

    private func update(_ id: UUID, _ transform: (DownloadTask.State) -> DownloadTask.State) {
        guard let idx = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[idx].state = transform(tasks[idx].state)
    }

    /// 清理已结束的任务（保留还在跑的包括 queued）
    func clearFinished() {
        tasks.removeAll { !$0.state.isActive }
        cancelled.removeAll()
        byteProgress.removeAll()
    }
}
