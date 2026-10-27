//
//  Store.swift
//  NovelReader
//
//  数据操作：把解析结果落库（SwiftData）+ 章节正文写缓存文件 + 进度读写
//

import Foundation
import SwiftData
import UIKit

@MainActor
final class Store {
    let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    // MARK: - 新增书籍

    /// 把解析结果写入数据库，返回 Book
    func insertBook(_ parsed: ParsedBook,
                    origin: BookOrigin,
                    sourceID: String? = nil,
                    remoteURL: String? = nil,
                    localFileURL: URL? = nil,
                    coverData: Data? = nil) throws -> Book {
        let book = Book(title: parsed.title.isEmpty ? "未命名" : parsed.title,
                        author: parsed.author,
                        origin: origin,
                        sourceID: sourceID,
                        remoteURL: remoteURL,
                        fileFormat: parsed.format,
                        summary: parsed.summary)
        book.coverData = coverData
        if let localFileURL {
            book.localFileRelativePath = BookStorage.relativePath(for: localFileURL, in: BookStorage.booksDirectory)
        }

        context.insert(book)

        // 写章节缓存
        // 性能说明：一本 3000 章的书会产生 3000 个 Chapter 对象 + 3000 次文件写入。
        // 这里分批 save，避免单次事务过大导致内存峰值和卡顿。
        let safeBookID = book.id.uuidString
        var totalChars = 0
        var cachedCount = 0

        for (idx, ch) in parsed.chapters.enumerated() {
            let chapter = Chapter(index: idx, title: ch.title, characterCount: ch.characterCount)
            chapter.book = book
            do {
                let rel = try ChapterCache.write(bookID: safeBookID, chapterIndex: idx, text: ch.content)
                chapter.cacheRelativePath = rel
                chapter.isCached = true
                cachedCount += 1
            } catch {
                chapter.isCached = false
            }
            totalChars += ch.characterCount
            context.insert(chapter)

            // 每 500 章提交一次，控制内存与事务大小
            if idx > 0, idx % 500 == 0 {
                try? context.save()
            }
        }

        book.chapterCount = parsed.chapters.count
        book.totalCharacters = totalChars
        book.cachedChapterCount = cachedCount
        book.progressChapterTotal = parsed.chapters.count
        book.isFullyDownloaded = cachedCount >= parsed.chapters.count
        book.updatedAt = Date()

        try? context.save()
        return book
    }

    // MARK: - 章节读写

    func chapters(for book: Book) -> [Chapter] {
        book.chapters.sorted { $0.index < $1.index }
    }

    func chapterText(_ chapter: Chapter) throws -> String {
        if let url = chapter.cacheFileURL, FileManager.default.fileExists(atPath: url.path) {
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                return text
            }
        }
        return ""
    }

    func writeChapterCache(book: Book, chapter: Chapter, text: String) throws {
        let rel = try ChapterCache.write(bookID: book.id.uuidString, chapterIndex: chapter.index, text: text)
        chapter.cacheRelativePath = rel
        chapter.isCached = true
        chapter.characterCount = text.count
        book.cachedChapterCount = chapters(for: book).filter(\.isCached).count
        book.isFullyDownloaded = book.cachedChapterCount >= book.chapterCount && book.chapterCount > 0
    }

    // MARK: - 进度

    func saveProgress(book: Book, chapterIndex: Int, charOffset: Int) {
        book.positionChapterIndex = chapterIndex
        book.positionCharOffset = charOffset
        book.lastOpenedAt = Date()
        book.progressChapterTotal = max(book.chapterCount, 1)
        book.updatedAt = Date()
        try? context.save()
    }

    // MARK: - 删除

    func delete(book: Book) {
        let bookID = book.id.uuidString
        context.delete(book)
        try? context.save()
        ChapterCache.removeAll(bookID: bookID)
        if let file = book.localFileURL {
            try? FileManager.default.removeItem(at: file)
        }
    }

    func delete(at offsets: IndexSet, in list: [Book]) {
        for i in offsets where i < list.count {
            delete(book: list[i])
        }
    }

    /// 清空所有缓存但保留书目
    func clearAllCaches() {
        try? FileManager.default.removeItem(at: BookStorage.chapterCacheDirectory)
        _ = BookStorage.ensure(BookStorage.chapterCacheDirectory)
        for book in allBooks() {
            for ch in book.chapters {
                ch.isCached = false
                ch.cacheRelativePath = nil
            }
            book.cachedChapterCount = 0
        }
        try? context.save()
    }

    func allBooks() -> [Book] {
        (try? context.fetch(FetchDescriptor<Book>())) ?? []
    }

    /// 磁盘占用（字节）
    func diskUsage() -> Int64 {
        func size(of url: URL) -> Int64 {
            guard let en = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
            var total: Int64 = 0
            for case let f as URL in en {
                let v = try? f.resourceValues(forKeys: [.fileSizeKey])
                total += Int64(v?.fileSize ?? 0)
            }
            return total
        }
        return size(of: BookStorage.chapterCacheDirectory)
            + size(of: BookStorage.booksDirectory)
            + size(of: BookStorage.inboxDirectory)
    }
}

// MARK: - 章节缓存文件

enum ChapterCache {
    /// 每本书一个目录：ChapterCache/<bookID>/<index>.txt
    static func write(bookID: String, chapterIndex: Int, text: String) throws -> String {
        let dir = BookStorage.chapterCacheDirectory.appendingPathComponent(bookID, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent(String(format: "%05d.txt", chapterIndex))
        try text.write(to: file, atomically: true, encoding: .utf8)
        return "\(bookID)/\(file.lastPathComponent)"
    }

    static func removeAll(bookID: String) {
        let dir = BookStorage.chapterCacheDirectory.appendingPathComponent(bookID, isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }
}

// MARK: - 封面工具

enum CoverLoader {
    /// 远程封面下载并压缩
    static func load(url: String, source: RemoteSource?) async -> Data? {
        guard !url.isEmpty else { return nil }
        guard let data = try? await HTTPClient.shared.fetchData(url, source: source) else { return nil }
        return compress(data)
    }

    static func compress(_ data: Data, maxSide: CGFloat = 600) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let size = image.size
        let scale = min(1, maxSide / max(size.width, size.height))
        let target = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: target)
        let scaled = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        return scaled.jpegData(compressionQuality: 0.82)
    }
}
