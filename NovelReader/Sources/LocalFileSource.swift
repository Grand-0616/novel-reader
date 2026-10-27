//
//  LocalFileSource.swift
//  NovelReader
//
//  本地文件源：扫描 App 沙盒 Books/ 与 Inbox/，支持外部导入
//

import Foundation

enum LocalFileSource {

    static let supportedExtensions: Set<String> = ["txt", "epub", "html", "htm", "xhtml"]

    /// 扫描目录下所有可导入的小说文件
    static func scanDirectory(_ url: URL, recursive: Bool = true) -> [URL] {
        let fm = FileManager.default
        var results: [URL] = []

        let keys: [URLResourceKey] = [.isRegularFileKey, .isDirectoryKey, .nameKey, .fileSizeKey]
        if recursive,
           let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: keys,
                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
            for case let fileURL as URL in enumerator {
                if isSupported(fileURL) { results.append(fileURL) }
            }
        } else {
            let items = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: keys,
                                                    options: [.skipsHiddenFiles])) ?? []
            results = items.filter(isSupported)
        }
        return results.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    static func isSupported(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { return false }
        return supportedExtensions.contains(url.pathExtension.lowercased())
    }

    /// 把外部文件复制进沙盒 Books 目录（用于"导入到本地"）
    static func importCopy(from source: URL, toStableName: String) throws -> URL {
        let fm = FileManager.default
        var url = source
        // 安全作用域资源
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        let ext = source.pathExtension.lowercased()
        let safeName = toStableName.replacingOccurrences(of: "/", with: "_")
        let dest = BookStorage.booksDirectory
            .appendingPathComponent(safeName)
            .appendingPathExtension(ext)

        if fm.fileExists(atPath: dest.path) {
            try fm.removeItem(at: dest)
        }
        // 跨卷移动失败时回退为复制
        do {
            try fm.copyItem(at: url, to: dest)
        } catch {
            let data = try Data(contentsOf: url)
            try data.write(to: dest, options: .atomic)
        }
        url = dest
        return url
    }

    /// 根据文件扩展名选择解析器
    static func parse(fileURL: URL) throws -> ParsedBook {
        switch fileURL.pathExtension.lowercased() {
        case "epub":
            return try EPUBParser.parse(fileURL: fileURL)
        case "html", "htm", "xhtml":
            let data = try Data(contentsOf: fileURL)
            let text = TextSanitizer.decode(data: data)?.text ?? ""
            let plain = HTMLParser.htmlToPlainText(text)
            let info = ChapterSplitter.parseFileNameTitle(fileURL.lastPathComponent)
            let chapters = ChapterSplitter.split(plain, bookTitle: info.title)
            guard !chapters.isEmpty else { throw ParseError.emptyContent }
            return ParsedBook(title: info.title, author: info.author, summary: "", chapters: chapters, format: "html")
        default:
            return try TXTParser.parse(fileURL: fileURL)
        }
    }

    /// 估算文件大小（字节）
    static func fileSize(_ url: URL) -> Int64 {
        let v = try? url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(v?.fileSize ?? 0)
    }
}
