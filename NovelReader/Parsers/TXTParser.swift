//
//  TXTParser.swift
//  NovelReader
//
//  TXT 解析：编码探测 -> 解码 -> 章节切分 -> 元信息抽取
//

import Foundation

struct ParsedBook {
    var title: String
    var author: String
    var summary: String
    var chapters: [SplitChapter]
    var format: String
}

enum TXTParser {

    /// 解析本地 TXT 文件
    static func parse(fileURL: URL, fallbackTitle: String? = nil) throws -> ParsedBook {
        let data = try Data(contentsOf: fileURL)
        return try parse(data: data, fileName: fileURL.lastPathComponent, fallbackTitle: fallbackTitle)
    }

    static func parse(data: Data, fileName: String, fallbackTitle: String? = nil) throws -> ParsedBook {
        guard let decoded = TextSanitizer.decode(data: data), !decoded.text.isEmpty else {
            throw ParseError.encodingFailed
        }
        let text = decoded.text

        let nameInfo = ChapterSplitter.parseFileNameTitle(fileName)

        // 头部元信息：前 60 行里找 "作者：xxx" / "书名：xxx" / 简介
        var author = nameInfo.author
        var title = fallbackTitle ?? nameInfo.title
        var summary = ""
        let headLines = text.prefix(4000).components(separatedBy: "\n").prefix(60).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        for line in headLines {
            if line.isEmpty { continue }
            if author.isEmpty, let a = extractValue(line, keys: ["作者", "作 者", "著者", "Author"]) {
                author = a
            }
            if let t = extractValue(line, keys: ["书名", "书 名", "小说名", "Title"]), !t.isEmpty {
                title = t
            }
            if summary.count < 400, let s = extractValue(line, keys: ["简介", "内容简介", "内容介绍", "摘要"]) {
                summary += (summary.isEmpty ? "" : "\n") + s
            }
        }

        var chapters = ChapterSplitter.split(text, bookTitle: title)
        guard !chapters.isEmpty else { throw ParseError.emptyContent }

        // 章节内缩进处理
        chapters = chapters.map {
            SplitChapter(title: $0.title, content: TextSanitizer.applyIndent($0.content))
        }

        return ParsedBook(
            title: title.isEmpty ? (fileName as NSString).deletingPathExtension : title,
            author: author,
            summary: summary,
            chapters: chapters,
            format: "txt"
        )
    }

    private static func extractValue(_ line: String, keys: [String]) -> String? {
        for key in keys {
            if line.hasPrefix(key) {
                var v = String(line.dropFirst(key.count))
                v = v.trimmingCharacters(in: CharacterSet(charactersIn: "：: \t　"))
                if !v.isEmpty, v.count <= 60 { return v }
            }
        }
        return nil
    }
}

enum ParseError: LocalizedError {
    case encodingFailed
    case emptyContent
    case unsupportedFormat(String)

    var errorDescription: String? {
        switch self {
        case .encodingFailed:      return "无法识别文件编码"
        case .emptyContent:        return "文件内容为空或无法解析出章节"
        case .unsupportedFormat(let f): return "暂不支持的格式：\(f)"
        }
    }
}
