//
//  EPUBParser.swift
//  NovelReader
//
//  EPUB 解析：解包 zip -> 读 container.xml -> OPF 元数据与 spine -> 章节 HTML 转纯文本
//  只用 Foundation + libz（zlib inflate），无第三方依赖，避免自签工程引入 SPM 依赖
//

import Foundation

/// 极简 ZIP 读取器（支持 stored / deflate，忽略加密与 ZIP64 之外的老式结构）
final class ZIPArchive {
    struct Entry {
        var name: String
        var compressionMethod: UInt16
        var compressedSize: UInt32
        var uncompressedSize: UInt32
        var localHeaderOffset: UInt32
        var crc32: UInt32
    }

    private let data: Data
    private(set) var entries: [String: Entry] = [:]

    init?(data: Data) {
        self.data = data
        guard let eocdOffset = ZIPArchive.findEOCD(data) else { return nil }
        let eocd = data.subdata(in: eocdOffset..<min(eocdOffset + 22, data.count))
        guard eocd.count >= 22 else { return nil }

        let total = Int(eocd.uint16(at: 10))
        let cdOffset = Int(eocd.uint32(at: 16))

        guard cdOffset > 0, cdOffset < data.count else { return nil }

        var p = cdOffset
        for _ in 0..<total {
            guard p + 46 <= data.count else { break }
            guard data.uint32(at: p) == 0x02014b50 else { break }
            let method = data.uint16(at: p + 10)
            let crc = data.uint32(at: p + 16)
            let compSize = data.uint32(at: p + 20)
            let uncompSize = data.uint32(at: p + 24)
            let nameLen = Int(data.uint16(at: p + 28))
            let extraLen = Int(data.uint16(at: p + 30))
            let commentLen = Int(data.uint16(at: p + 32))
            let localOffset = data.uint32(at: p + 42)

            guard p + 46 + nameLen <= data.count else { break }
            let nameData = data.subdata(in: (p + 46)..<(p + 46 + nameLen))
            let name = String(data: nameData, encoding: .utf8) ?? ""
            if !name.isEmpty, !name.hasSuffix("/") {
                entries[name] = Entry(name: name, compressionMethod: method,
                                      compressedSize: compSize, uncompressedSize: uncompSize,
                                      localHeaderOffset: localOffset, crc32: crc)
            }
            p += 46 + nameLen + extraLen + commentLen
        }
        if entries.isEmpty { return nil }
    }

    private static func findEOCD(_ data: Data) -> Int? {
        guard data.count >= 22 else { return nil }
        let maxBack = min(data.count, 65557)
        var i = data.count - 22
        let lower = data.count - maxBack
        while i >= lower {
            if data[i] == 0x50, data[i + 1] == 0x4b, data[i + 2] == 0x05, data[i + 3] == 0x06 {
                return i
            }
            i -= 1
        }
        return nil
    }

    func read(_ name: String) -> Data? {
        guard let e = entries[name] else { return nil }
        let lo = Int(e.localHeaderOffset)
        guard lo + 30 <= data.count, data.uint32(at: lo) == 0x04034b50 else { return nil }
        let nameLen = Int(data.uint16(at: lo + 26))
        let extraLen = Int(data.uint16(at: lo + 28))
        let start = lo + 30 + nameLen + extraLen
        let end = start + Int(e.compressedSize)
        guard start >= 0, end <= data.count, start < end else { return nil }
        let payload = data.subdata(in: start..<end)

        switch e.compressionMethod {
        case 0:
            return payload
        case 8:
            return payload.inflateRaw()
        default:
            return nil
        }
    }

    func readString(_ name: String) -> String? {
        guard let d = read(name) else { return nil }
        if let s = String(data: d, encoding: .utf8) { return s }
        if let charset = TextSanitizer.sniffCharset(fromHTML: d), let s = TextSanitizer.decode(data: d, charset: charset) {
            return s
        }
        return TextSanitizer.decode(data: d)?.text
    }
}

enum EPUBParser {

    static func parse(fileURL: URL) throws -> ParsedBook {
        let data = try Data(contentsOf: fileURL)
        return try parse(zipData: data, fallbackTitle: (fileURL.lastPathComponent as NSString).deletingPathExtension)
    }

    static func parse(zipData: Data, fallbackTitle: String) throws -> ParsedBook {
        guard let zip = ZIPArchive(data: zipData) else { throw ParseError.unsupportedFormat("epub/zip") }

        // 1. container.xml -> rootfile
        var opfPath: String?
        if let container = zip.readString("META-INF/container.xml"),
           let re = try? NSRegularExpression(pattern: #"full-path\s*=\s*"([^"]+)""#),
           let m = re.firstMatch(in: container, range: NSRange(location: 0, length: (container as NSString).length)),
           let r = Range(m.range(at: 1), in: container) {
            opfPath = String(container[r])
        }
        if opfPath == nil {
            opfPath = zip.entries.keys.first { $0.lowercased().hasSuffix(".opf") }
        }
        guard let opf = opfPath, let opfXML = zip.readString(opf) else {
            throw ParseError.unsupportedFormat("epub 缺少 OPF")
        }

        let opfDir = (opf as NSString).deletingLastPathComponent

        // 2. 元数据
        let title = firstMatch(opfXML, #"<dc:title[^>]*>(.*?)</dc:title>"#) ?? fallbackTitle
        let author = firstMatch(opfXML, #"<dc:creator[^>]*>(.*?)</dc:creator>"#) ?? ""
        let summary = (firstMatch(opfXML, #"<dc:description[^>]*>(.*?)</dc:description>"#) ?? "")
            .strippedHTML()

        // 3. manifest id -> href
        var manifest: [String: String] = [:]
        if let re = try? NSRegularExpression(pattern: #"<item\b[^>]*>"#, options: [.caseInsensitive]) {
            let ns = opfXML as NSString
            re.enumerateMatches(in: opfXML, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                guard let m else { return }
                let tag = ns.substring(with: m.range)
                if let id = attr(tag, "id"), let href = attr(tag, "href") {
                    manifest[id] = href
                }
            }
        }

        // 4. spine 顺序
        var spineIDs: [String] = []
        if let re = try? NSRegularExpression(pattern: #"<itemref\b[^>]*>"#, options: [.caseInsensitive]) {
            let ns = opfXML as NSString
            re.enumerateMatches(in: opfXML, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                guard let m else { return }
                let tag = ns.substring(with: m.range)
                if let idref = attr(tag, "idref") { spineIDs.append(idref) }
            }
        }

        var chapters: [SplitChapter] = []
        var navTitles: [String: String] = [:]   // href -> 目录里的标题

        // 5. 读 nav / toc 获取真实章节标题
        for candidate in ["nav", "toc", "toc4"] {
            for (name, _) in zip.entries {
                let lower = name.lowercased()
                guard lower.hasSuffix(".\(candidate).xhtml") || lower.hasSuffix(".\(candidate).html") else { continue }
                if let html = zip.readString(name) {
                    navTitles.merge(parseNavTitles(html, baseDir: (name as NSString).deletingLastPathComponent)) { a, _ in a }
                }
            }
        }

        // 6. 逐 spine 项抽取正文
        for idref in spineIDs {
            guard let href = manifest[idref] else { continue }
            let cleanHref = href.removingPercentEncoding ?? href
            let fullPath = opfDir.isEmpty ? cleanHref : "\(opfDir)/\(cleanHref)"
            guard let html = zip.readString(fullPath) ?? zip.readString(cleanHref) else { continue }

            let text = HTMLParser.htmlToPlainText(html)
            guard !text.isEmpty else { continue }

            // 若该文件本身包含多个"第X章"，进一步切分
            let sub = ChapterSplitter.split(text, bookTitle: navTitles[cleanHref] ?? "")
            if sub.count > 1 {
                for s in sub {
                    chapters.append(SplitChapter(title: s.title, content: TextSanitizer.applyIndent(s.content)))
                }
            } else {
                let title = navTitles[cleanHref]
                    ?? firstMatch(html, #"<h[1-3][^>]*>(.*?)</h[1-3]>"#)?.strippedHTML()
                    ?? firstMatch(html, #"<title[^>]*>(.*?)</title>"#)?.strippedHTML()
                    ?? "第\(chapters.count + 1)节"
                let body = TextSanitizer.normalizeBody(text)
                if body.count < 30 { continue }   // 封面页/版权页
                chapters.append(SplitChapter(title: title.trimmingCharacters(in: .whitespaces),
                                             content: TextSanitizer.applyIndent(body)))
            }
        }

        guard !chapters.isEmpty else { throw ParseError.emptyContent }

        return ParsedBook(
            title: title.strippedHTML().trimmingCharacters(in: .whitespaces),
            author: author.trimmingCharacters(in: .whitespaces),
            summary: summary,
            chapters: chapters,
            format: "epub"
        )
    }

    // MARK: - nav 解析

    private static func parseNavTitles(_ html: String, baseDir: String) -> [String: String] {
        var result: [String: String] = [:]
        guard let re = try? NSRegularExpression(pattern: #"<a\b[^>]*href\s*=\s*"([^"]+)"[^>]*>(.*?)</a>"#,
                                               options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return result }
        let ns = html as NSString
        re.enumerateMatches(in: html, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m, m.numberOfRanges > 2,
                  let hr = Range(m.range(at: 1), in: html),
                  let tr = Range(m.range(at: 2), in: html) else { return }
            var href = String(html[hr])
            if let hashIdx = href.firstIndex(of: "#") { href = String(href[href.startIndex..<hashIdx]) }
            guard !href.isEmpty else { return }
            let title = String(html[tr]).strippedHTML().trimmingCharacters(in: .whitespaces)
            guard !title.isEmpty else { return }
            result[href] = title
            if !baseDir.isEmpty {
                result["\(baseDir)/\(href)"] = title
            }
        }
        return result
    }

    private static func firstMatch(_ s: String, _ pattern: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern,
                                                options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    private static func attr(_ tag: String, _ name: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: #"\b\#(name)\s*=\s*["']([^"']*)["']"#,
                                                options: [.caseInsensitive]) else { return nil }
        let ns = tag as NSString
        guard let m = re.firstMatch(in: tag, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }
}

// MARK: - Data 小工具

extension Data {
    func uint16(at offset: Int) -> UInt16 {
        guard offset + 2 <= count else { return 0 }
        return UInt16(self[offset]) | (UInt16(self[offset + 1]) << 8)
    }

    func uint32(at offset: Int) -> UInt32 {
        guard offset + 4 <= count else { return 0 }
        return UInt32(self[offset])
            | (UInt32(self[offset + 1]) << 8)
            | (UInt32(self[offset + 2]) << 16)
            | (UInt32(self[offset + 3]) << 24)
    }
}

// MARK: - raw deflate 解压（libz）

import zlib

extension Data {
    /// 解压 raw deflate 流（ZIP method 8）
    ///
    /// 实现要点：
    ///   1. 指针必须全程有效：zlib 在多次 inflate 调用之间会继续读 next_in，
    ///      所以整个循环必须放在 withUnsafeMutableBufferPointer 的作用域内，
    ///      不能在作用域结束后再调用 inflate（那样 next_in 是悬垂指针）。
    ///   2. 不用嵌套的 withUnsafeMutableBufferPointer，避免 "overlapping accesses"；
    ///      输出用独立分配的 scratch 缓冲。
    func inflateRaw() -> Data? {
        guard !isEmpty else { return Data() }

        var input = [UInt8](self)
        let inputCount = input.count

        var stream = z_stream()
        let initStatus = inflateInit2_(&stream, -MAX_WBITS, ZLIB_VERSION,
                                       Int32(MemoryLayout<z_stream>.size))
        guard initStatus == Z_OK else { return nil }
        defer { inflateEnd(&stream) }

        let chunkSize = 64 * 1024
        let scratch = UnsafeMutablePointer<UInt8>.allocate(capacity: chunkSize)
        defer { scratch.deallocate() }

        // 整个解压循环都在 input 的指针作用域内完成。
        // 所有可变状态（out / status）都在闭包内，通过元组带出，
        // 避免"闭包内外同时访问同一变量"的独占性错误。
        let result: (data: Data, ok: Bool) = input.withUnsafeMutableBufferPointer { inPtr -> (Data, Bool) in
            var out = Data()
            var status: Int32 = Z_OK
            stream.next_in = inPtr.baseAddress
            stream.avail_in = uInt(inputCount)

            repeat {
                stream.next_out = scratch
                stream.avail_out = uInt(chunkSize)
                status = zlib.inflate(&stream, Z_NO_FLUSH)
                let produced = chunkSize - Int(stream.avail_out)
                if produced > 0 {
                    out.append(scratch, count: produced)
                }
                if status == Z_STREAM_END { break }
                if status != Z_OK && status != Z_BUF_ERROR { break }
                if stream.avail_in == 0 && produced == 0 { break }
            } while true

            let ok = (status == Z_STREAM_END || status == Z_OK || status == Z_BUF_ERROR)
            return (out, ok)
        }

        guard result.ok, !result.data.isEmpty else { return nil }
        return result.data
    }
}
