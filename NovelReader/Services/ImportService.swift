//
//  ImportService.swift
//  NovelReader
//
//  导入服务：文件导入、URL 下载导入、OPDS/HTTP 目录下载导入、在线书源整本下载
//  —— 所有解析都在后台线程完成，只把轻量结果带回主线程落库
//

import Foundation
import UIKit

struct ImportProgress: Equatable {
    var phase: String = ""
    var fraction: Double = 0
    var detail: String = ""
}

enum ImportError: LocalizedError {
    case unsupportedType(String)
    case emptyBook
    case noSource
    case cancelled

    var errorDescription: String? {
        switch self {
        case .unsupportedType(let t): return "不支持的格式：\(t)"
        case .emptyBook:              return "没有解析出任何章节"
        case .noSource:               return "书源不存在或已删除"
        case .cancelled:              return "已取消"
        }
    }
}

final class ImportService {
    static let shared = ImportService()

    private init() {}

    // MARK: - 1. 本地文件导入

    /// 从文件选择器拿到的 URL 导入（自动复制进沙盒）
    @MainActor
    func importLocalFile(at url: URL,
                         store: Store,
                         progress: (@Sendable (ImportProgress) -> Void)? = nil) async throws -> Book {
        let ext = url.pathExtension.lowercased()
        guard LocalFileSource.supportedExtensions.contains(ext) else {
            throw ImportError.unsupportedType(ext)
        }
        progress?(ImportProgress(phase: "复制文件", fraction: 0.05))
        let info = ChapterSplitter.parseFileNameTitle(url.lastPathComponent)
        let stableName = "\(info.title)_\(UUID().uuidString.prefix(6))"
        let localCopy = try LocalFileSource.importCopy(from: url, toStableName: stableName)

        progress?(ImportProgress(phase: "解析章节", fraction: 0.4))
        let parsed = try await Self.parseOffMain(localCopy)
        guard !parsed.chapters.isEmpty else {
            try? FileManager.default.removeItem(at: localCopy)
            throw ImportError.emptyBook
        }
        progress?(ImportProgress(phase: "写入书库", fraction: 0.9))
        let book = try store.insertBook(parsed, origin: .localFile, localFileURL: localCopy)
        progress?(ImportProgress(phase: "完成", fraction: 1))
        return book
    }

    /// 扫描 Inbox 目录（通过"文件"App / iTunes 拖进来的文件）
    @MainActor
    func importFromInbox(store: Store,
                         progress: (@Sendable (ImportProgress) -> Void)? = nil) async throws -> [Book] {
        let files = LocalFileSource.scanDirectory(BookStorage.inboxDirectory)
        var books: [Book] = []
        for (i, f) in files.enumerated() {
            progress?(ImportProgress(phase: "导入 \(f.lastPathComponent)",
                                     fraction: Double(i) / Double(max(files.count, 1))))
            if let book = try? await importLocalFile(at: f, store: store) {
                books.append(book)
                try? FileManager.default.removeItem(at: f)
            }
        }
        progress?(ImportProgress(phase: "完成", fraction: 1))
        return books
    }

    // MARK: - 2. 远程文件导入（NAS / 直链）

    /// 从 URL 下载并导入一整本书（.txt/.epub）
    @MainActor
    func importRemoteFile(url: String,
                          source: RemoteSource?,
                          store: Store,
                          origin: BookOrigin,
                          progress: (@Sendable (ImportProgress) -> Void)? = nil) async throws -> Book {
        progress?(ImportProgress(phase: "下载文件", fraction: 0.1))
        let data = try await HTTPClient.shared.fetchData(url, source: source)

        // 若服务端返回的是 HTML 目录页而不是文件，转为"按目录导入"
        if let parsed = try? await Self.parseDataOffMain(data: data, fileName: Self.fileName(from: url)) {
            let cover = await CoverLoader.load(url: (source?.baseURL ?? ""), source: source)
            _ = cover
            progress?(ImportProgress(phase: "写入书库", fraction: 0.9))
            let book = try store.insertBook(parsed, origin: origin,
                                            sourceID: source?.id.uuidString,
                                            remoteURL: url)
            progress?(ImportProgress(phase: "完成", fraction: 1))
            return book
        }

        // 兜底：当作 HTML 页面解析正文
        guard let text = TextSanitizer.decode(data: data)?.text, !text.isEmpty else {
            throw ImportError.emptyBook
        }
        let plain = HTMLParser.htmlToPlainText(text)
        let info = ChapterSplitter.parseFileNameTitle(Self.fileName(from: url))
        let chapters = ChapterSplitter.split(plain, bookTitle: info.title)
        guard !chapters.isEmpty else { throw ImportError.emptyBook }

        let parsed = ParsedBook(title: info.title, author: info.author, summary: "",
                                chapters: chapters, format: "html")
        let book = try store.insertBook(parsed, origin: origin,
                                        sourceID: source?.id.uuidString,
                                        remoteURL: url)
        progress?(ImportProgress(phase: "完成", fraction: 1))
        return book
    }

    // MARK: - 3. 在线书源整本导入（规则书源 / JSON API）

    /// 从书源详情页抓取整个目录 + 所有章节正文，落库为离线可读
    @MainActor
    func importWebBook(detailURL: String,
                       source: RemoteSource,
                       store: Store,
                       maxChapters: Int = 10_000,
                       progress: (@Sendable (ImportProgress) -> Void)? = nil) async throws -> Book {
        progress?(ImportProgress(phase: "获取目录", fraction: 0.02))
        let detail = try await WebBookSource.detail(source: source, detailURL: detailURL)
        guard !detail.chapters.isEmpty else { throw ImportError.emptyBook }

        let chapters = Array(detail.chapters.prefix(maxChapters))
        var texts: [String] = []
        texts.reserveCapacity(chapters.count)

        for (i, ch) in chapters.enumerated() {
            let frac = 0.05 + 0.85 * Double(i) / Double(max(chapters.count, 1))
            progress?(ImportProgress(phase: "下载章节", fraction: frac,
                                     detail: "\(i + 1)/\(chapters.count) \(ch.title)"))
            do {
                let content = try await WebBookSource.content(source: source, chapterURL: ch.href)
                texts.append(content.isEmpty ? "（本章内容为空）" : content)
            } catch {
                texts.append("（本章下载失败：\(error.localizedDescription)）")
            }
        }

        progress?(ImportProgress(phase: "写入书库", fraction: 0.92))
        let splitChapters = zip(chapters, texts).map { SplitChapter(title: $0.title, content: $1) }
        var coverData: Data?
        if let coverURL = detail.coverURL {
            coverData = await CoverLoader.load(url: coverURL, source: source)
        }
        let parsed = ParsedBook(title: detail.title, author: detail.author,
                                summary: detail.summary, chapters: splitChapters, format: "html")
        let book = try store.insertBook(parsed, origin: .web,
                                        sourceID: source.id.uuidString,
                                        remoteURL: detailURL,
                                        coverData: coverData)
        progress?(ImportProgress(phase: "完成", fraction: 1))
        return book
    }

    /// NAS 上的 HTML 目录书：抓目录页里的章节链接逐个下载
    @MainActor
    func importChaptersFromPage(entryURL: String,
                                source: RemoteSource,
                                store: Store,
                                progress: (@Sendable (ImportProgress) -> Void)? = nil) async throws -> Book {
        progress?(ImportProgress(phase: "读取目录页", fraction: 0.02))
        let resp = try await HTTPClient.shared.fetchText(entryURL, source: source)
        guard resp.isOK else { throw HTTPError.badStatus(resp.statusCode) }
        let html = resp.text
        let base = resp.finalURL.absoluteString

        // 抓所有看起来像章节的链接
        var links: [(title: String, url: String)] = []
        var seen = Set<String>()
        for (href, text, _) in HTMLParser.anchors(in: html) {
            guard !text.isEmpty, text.count <= 60,
                  !href.hasPrefix("#"), !href.lowercased().hasPrefix("javascript:") else { continue }
            let abs = HTTPClient.resolve(href, base: base)?.absoluteString ?? href
            guard seen.insert(abs).inserted else { continue }
            if TextSanitizer.isChapterTitle(text) || links.isEmpty {
                links.append((text, abs))
            }
        }
        guard !links.isEmpty else { throw ImportError.emptyBook }

        var texts: [String] = []
        for (i, l) in links.enumerated() {
            let frac = 0.05 + 0.9 * Double(i) / Double(max(links.count, 1))
            progress?(ImportProgress(phase: "下载章节", fraction: frac, detail: "\(i + 1)/\(links.count)"))
            if let page = try? await HTTPClient.shared.fetchText(l.url, source: source) {
                let plain = HTMLParser.htmlToPlainText(page.text)
                texts.append(TextSanitizer.normalizeBody(plain))
            } else {
                texts.append("（下载失败）")
            }
        }

        let title = HTMLParser.pageTitle(html) ?? source.name
        let chapters = zip(links, texts).map { SplitChapter(title: $0.0.title, content: $0.1) }
        let parsed = ParsedBook(title: title, author: "", summary: "", chapters: chapters, format: "html")
        let book = try store.insertBook(parsed, origin: source.kind == .opds ? .opds : .directURL,
                                        sourceID: source.id.uuidString,
                                        remoteURL: entryURL)
        progress?(ImportProgress(phase: "完成", fraction: 1))
        return book
    }

    // MARK: - 工具

    /// 后台解析（避免大文件卡主线程）
    nonisolated static func parseOffMain(_ url: URL) async throws -> ParsedBook {
        try await Task.detached(priority: .userInitiated) { () throws -> ParsedBook in
            try LocalFileSource.parse(fileURL: url)
        }.value
    }

    nonisolated static func parseDataOffMain(data: Data, fileName: String) async throws -> ParsedBook {
        try await Task.detached(priority: .userInitiated) { () throws -> ParsedBook in
            if fileName.lowercased().hasSuffix(".epub") || data.isZipArchive {
                return try EPUBParser.parse(zipData: data,
                                            fallbackTitle: (fileName as NSString).deletingPathExtension)
            }
            return try TXTParser.parse(data: data, fileName: fileName)
        }.value
    }

    nonisolated static func fileName(from urlString: String) -> String {
        let path = URL(string: urlString)?.lastPathComponent ?? "book.txt"
        let decoded = path.removingPercentEncoding ?? path
        return decoded.isEmpty ? "book.txt" : decoded
    }
}

extension Data {
    var isZipArchive: Bool {
        count >= 4 && self[0] == 0x50 && self[1] == 0x4b
    }
}
