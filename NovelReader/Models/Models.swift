//
//  Models.swift
//  NovelReader
//
//  核心数据模型：书架书籍、章节、章节正文缓存
//

import Foundation
import SwiftData

// MARK: - 书籍来源

enum BookOrigin: String, Codable, CaseIterable {
    /// 通过文件选择器 / 分享 / iTunes 导入的本地文件
    case localFile = "local"
    /// OPDS（NAS 书库：calibre-web / Kavita / Komga / COPS 等）
    case opds = "opds"
    /// 规则化网络书源
    case web = "web"
    /// 直接输入的 URL
    case directURL = "url"

    var displayName: String {
        switch self {
        case .localFile: return "本地文件"
        case .opds:      return "NAS 书库"
        case .web:       return "网络书源"
        case .directURL: return "链接导入"
        }
    }

    var symbolName: String {
        switch self {
        case .localFile: return "folder"
        case .opds:      return "externaldrive.connected.to.line.below"
        case .web:       return "globe.asia.australia"
        case .directURL: return "link"
        }
    }
}

// MARK: - 阅读进度

/// 阅读位置：章节序号 + 章节内字符偏移（char offset 是稳定的，不受字号影响）
struct ReadingPosition: Codable, Equatable {
    var chapterIndex: Int = 0
    /// 章节内文本的字符偏移（UTF-16 code unit，NSString 语义）
    var charOffset: Int = 0
    /// 冗余记录：该章总字数，用于估算百分比
    var chapterLength: Int = 0
}

// MARK: - Book

@Model
final class Book {
    @Attribute(.unique) var id: UUID
    var title: String
    var author: String
    var coverData: Data?

    /// 简介
    var summary: String

    /// 来源标识
    var originRaw: String
    var sourceID: String?

    /// 原始地址（URL / OPDS 下载地址 / NAS 路径）
    var remoteURL: String?
    /// 本地落盘文件相对路径（相对 Documents/Books/）
    var localFileRelativePath: String?
    /// 文件格式：txt / epub / html
    var fileFormat: String

    /// 总字数（已解析时）
    var totalCharacters: Int
    /// 章节数量
    var chapterCount: Int

    var createdAt: Date
    var updatedAt: Date

    /// 是否已完整下载（离线可读）
    var isFullyDownloaded: Bool
    /// 已缓存章节数
    var cachedChapterCount: Int

    // 阅读进度
    var positionChapterIndex: Int
    var positionCharOffset: Int
    var progressChapterTotal: Int

    /// 书架置顶
    var isPinned: Bool
    /// 最近一次打开
    var lastOpenedAt: Date?

    /// 排序权重（列表排序用）
    var sortString: String

    @Relationship(deleteRule: .cascade, inverse: \Chapter.book)
    var chapters: [Chapter] = []

    init(
        title: String,
        author: String = "",
        origin: BookOrigin,
        sourceID: String? = nil,
        remoteURL: String? = nil,
        fileFormat: String = "txt",
        summary: String = ""
    ) {
        self.id = UUID()
        self.title = title
        self.author = author
        self.originRaw = origin.rawValue
        self.sourceID = sourceID
        self.remoteURL = remoteURL
        self.fileFormat = fileFormat
        self.summary = summary
        self.totalCharacters = 0
        self.chapterCount = 0
        self.createdAt = Date()
        self.updatedAt = Date()
        self.isFullyDownloaded = false
        self.cachedChapterCount = 0
        self.positionChapterIndex = 0
        self.positionCharOffset = 0
        self.progressChapterTotal = 0
        self.isPinned = false
        self.sortString = title
    }

    var origin: BookOrigin {
        get { BookOrigin(rawValue: originRaw) ?? .localFile }
        set { originRaw = newValue.rawValue }
    }

    var readingProgress: Double {
        let total = max(progressChapterTotal, chapterCount, 1)
        let base = Double(positionChapterIndex) / Double(total)
        return min(max(base, 0), 1)
    }

    var position: ReadingPosition {
        get { ReadingPosition(chapterIndex: positionChapterIndex, charOffset: positionCharOffset, chapterLength: 0) }
        set {
            positionChapterIndex = newValue.chapterIndex
            positionCharOffset = newValue.charOffset
        }
    }

    var localFileURL: URL? {
        guard let rel = localFileRelativePath else { return nil }
        return BookStorage.booksDirectory.appendingPathComponent(rel)
    }

    var displayAuthor: String {
        author.isEmpty ? "未知作者" : author
    }
}

// MARK: - Chapter

@Model
final class Chapter {
    @Attribute(.unique) var id: UUID
    var index: Int
    var title: String

    /// 正文已缓存时：缓存文件相对路径（相对 Documents/Cache/）
    var cacheRelativePath: String?
    /// 未缓存时：远程地址
    var remoteURL: String?

    /// 章节正文长度（字符数）
    var characterCount: Int
    /// 是否已缓存到本地
    var isCached: Bool

    /// EPUB 场景：zip 内资源路径
    var archiveEntry: String?

    var book: Book?

    init(index: Int, title: String, characterCount: Int = 0) {
        self.id = UUID()
        self.index = index
        self.title = title
        self.characterCount = characterCount
        self.isCached = false
    }

    var cacheFileURL: URL? {
        guard let rel = cacheRelativePath else { return nil }
        return BookStorage.chapterCacheDirectory.appendingPathComponent(rel)
    }
}

// MARK: - 书库目录常量

enum BookStorage {
    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    static var booksDirectory: URL {
        ensure(documentsDirectory.appendingPathComponent("Books", isDirectory: true))
    }

    static var chapterCacheDirectory: URL {
        ensure(documentsDirectory.appendingPathComponent("ChapterCache", isDirectory: true))
    }

    static var inboxDirectory: URL {
        ensure(documentsDirectory.appendingPathComponent("Inbox", isDirectory: true))
    }

    static var sourcesDirectory: URL {
        ensure(documentsDirectory.appendingPathComponent("Sources", isDirectory: true))
    }

    static func ensure(_ url: URL) -> URL {
        if !FileManager.default.fileExists(atPath: url.path) {
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        }
        return url
    }

    static func relativePath(for url: URL, in base: URL) -> String? {
        let basePath = base.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        guard path.hasPrefix(basePath) else { return nil }
        let rel = String(path.dropFirst(basePath.count))
        return rel.hasPrefix("/") ? String(rel.dropFirst()) : rel
    }
}
