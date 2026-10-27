//
//  OPDSSource.swift
//  NovelReader
//
//  NAS 书库接入：OPDS 1.2 / OPDS-PSE、HTTP 目录索引、WebDAV(PROPFIND)
//  兼容 calibre-web、COPS、Komga、Kavita、群晖 Web Station、nginx autoindex
//

import Foundation

struct OPDSFeed {
    var title: String
    var entries: [SourceEntry]
    var nextURL: String?
    var isNavigation: Bool
}

enum OPDSSource {

    // MARK: - 统一 browse 入口

    /// 浏览某个书源的某个目录
    static func browse(source: RemoteSource, url: String?) async throws -> [SourceEntry] {
        let target = url ?? source.baseURL
        switch source.kind {
        case .opds:
            let feed = try await fetchFeed(source: source, url: target)
            return feed.entries
        case .httpDirectory:
            return try await fetchHTTPDirectory(source: source, url: target)
        case .webdav:
            return try await fetchWebDAV(source: source, url: target)
        default:
            return []
        }
    }

    /// 连通性测试
    static func ping(source: RemoteSource) async throws -> String {
        let entries = try await browse(source: source, url: nil)
        return "连接成功，当前目录 \(entries.count) 项"
    }

    // MARK: - OPDS

    static func fetchFeed(source: RemoteSource, url: String) async throws -> OPDSFeed {
        let resp = try await HTTPClient.shared.fetchText(url, source: source)
        guard resp.isOK else { throw HTTPError.badStatus(resp.statusCode) }
        let xml = resp.text

        let feedTitle = HTMLParser.firstMatch(#"<title[^>]*>([\s\S]*?)</title>"#, in: xml)?
            .strippedHTML().trimmingCharacters(in: .whitespaces) ?? source.name

        var entries: [SourceEntry] = []
        // 逐个 <entry> 处理
        if let re = try? NSRegularExpression(pattern: #"<entry\b[\s\S]*?</entry>"#, options: [.caseInsensitive]) {
            let ns = xml as NSString
            re.enumerateMatches(in: xml, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                guard let m else { return }
                let block = ns.substring(with: m.range)
                if let e = parseOPDSEntry(block, feedIsNavigation: false) {
                    entries.append(e)
                }
            }
        }

        var nextURL: String?
        // rel="next"
        if let re = try? NSRegularExpression(pattern: #"<link\b[^>]*rel\s*=\s*"next"[^>]*>"#, options: [.caseInsensitive]),
           let m = re.firstMatch(in: xml, range: NSRange(location: 0, length: (xml as NSString).length)) {
            let tag = (xml as NSString).substring(with: m.range)
            nextURL = HTMLParser.attrValue(tag, "href")
        }

        // 判断是否为导航 feed（acquisition vs navigation）
        let hasNav = entries.contains { $0.kind == .directory }
        return OPDSFeed(title: feedTitle, entries: entries, nextURL: nextURL, isNavigation: hasNav)
    }

    private static func parseOPDSEntry(_ block: String, feedIsNavigation: Bool) -> SourceEntry? {
        let title = HTMLParser.firstMatch(#"<title[^>]*>([\s\S]*?)</title>"#, in: block)?
            .strippedHTML().trimmingCharacters(in: .whitespaces) ?? ""
        guard !title.isEmpty else { return nil }

        let author = HTMLParser.firstMatch(#"<author[^>]*>[\s\S]*?<name[^>]*>([\s\S]*?)</name>"#, in: block)?
            .strippedHTML().trimmingCharacters(in: .whitespaces)
        let summary = HTMLParser.firstMatch(#"<content[^>]*>([\s\S]*?)</content>"#, in: block)?
            .strippedHTML().trimmingCharacters(in: .whitespaces)
        let summaryAlt = HTMLParser.firstMatch(#"<summary[^>]*>([\s\S]*?)</summary>"#, in: block)?
            .strippedHTML().trimmingCharacters(in: .whitespaces)

        // 图片链接
        var coverURL: String?
        var entryHref: String?
        var mime: String?
        var isChapter = false

        if let re = try? NSRegularExpression(pattern: #"<link\b[^>]*>"#, options: [.caseInsensitive]) {
            let ns = block as NSString
            var best: (href: String, type: String, rel: String, priority: Int)?
            re.enumerateMatches(in: block, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                guard let m else { return }
                let tag = ns.substring(with: m.range)
                let href = HTMLParser.attrValue(tag, "href") ?? ""
                let type = (HTMLParser.attrValue(tag, "type") ?? "").lowercased()
                let rel = (HTMLParser.attrValue(tag, "rel") ?? "").lowercased()

                if rel.contains("http://opds-spec.org/image") || rel.contains("thumbnail") || rel.contains("cover") {
                    if coverURL == nil, !href.isEmpty { coverURL = href }
                    return
                }
                if type.hasPrefix("image/") { return }

                // 章节/正文链接（OPDS-PSE 分页）
                if rel.contains("pse") || rel.contains("content") || type.contains("html") {
                    if !href.isEmpty { isChapter = true }
                }

                // 下载类型优先级
                var priority = 0
                if type.contains("epub") || href.lowercased().hasSuffix(".epub") { priority = 100 }
                else if type.contains("text/plain") || href.lowercased().hasSuffix(".txt") { priority = 90 }
                else if type.contains("html") || href.lowercased().hasSuffix(".html") || href.lowercased().hasSuffix(".htm") { priority = 80 }
                else if type.contains("atom+xml") || rel == "subsection" { priority = 70 }
                else if type.contains("application/x-mobipocket") || href.lowercased().hasSuffix(".mobi") { priority = 50 }
                else if type.contains("fb2") { priority = 40 }
                else if type.isEmpty { priority = 10 }

                if best == nil || priority > best!.priority {
                    best = (href, type, rel, priority)
                }
            }
            if let best, !best.href.isEmpty {
                entryHref = best.href
                mime = best.type
            }
        }

        // 没有 link 的纯导航条目：取第一个 rel=subsection
        if entryHref == nil,
           let tag = HTMLParser.firstMatch(#"<link\b[^>]*subsection[^>]*>"#, in: block) {
            entryHref = HTMLParser.attrValue(tag, "href")
        }

        guard let href = entryHref else { return nil }

        let kind: SourceEntryKind
        if isChapter || (mime?.contains("html") == true && !feedIsNavigation) {
            kind = .chapter
        } else if mime?.contains("atom+xml") == true || mime?.contains("navigation") == true {
            kind = .directory
        } else {
            kind = .book
        }

        return SourceEntry(
            title: title,
            author: author,
            summary: (summary?.isEmpty == false ? summary : summaryAlt),
            coverURL: coverURL,
            href: href,
            kind: kind,
            mimeType: mime
        )
    }

    // MARK: - HTTP 目录（autoindex）

    static func fetchHTTPDirectory(source: RemoteSource, url: String) async throws -> [SourceEntry] {
        let resp = try await HTTPClient.shared.fetchText(url, source: source)
        guard resp.isOK else { throw HTTPError.badStatus(resp.statusCode) }
        let html = resp.text
        let baseURL = resp.finalURL.absoluteString

        // 先尝试识别常见索引表格结构（nginx / apache / Python SimpleHTTP / 群晖）
        var entries: [SourceEntry] = []
        var seen = Set<String>()

        for (href, text, _) in HTMLParser.anchors(in: html) {
            guard !href.isEmpty,
                  !href.hasPrefix("#"),
                  !href.lowercased().hasPrefix("javascript:"),
                  !href.hasPrefix("?"),
                  !href.hasPrefix("mailto:") else { continue }

            let decodedHref = href.removingPercentEncoding ?? href
            // 跳过父目录 / 排序链接
            if decodedHref.hasPrefix("../") || decodedHref.hasPrefix("..") { continue }
            if decodedHref.hasPrefix("?") || decodedHref.hasPrefix("/") { continue }
            if text.isEmpty || text == "Parent Directory" || text == "上级目录" { continue }
            if seen.contains(decodedHref) { continue }
            seen.insert(decodedHref)

            // 绝对地址
            let absolute: String
            if decodedHref.lowercased().hasPrefix("http") {
                absolute = decodedHref
            } else {
                absolute = URL(string: decodedHref, relativeTo: URL(string: baseURL))?.absoluteString ?? decodedHref
            }

            let lower = decodedHref.lowercased()
            let isDirLink = lower.hasSuffix("/") || !(lower as NSString).pathExtension.isEmpty == false

            if isDirLink && lower.hasSuffix("/") {
                entries.append(SourceEntry(title: text.hasSuffix("/") ? String(text.dropLast()) : text,
                                           author: nil, summary: nil, coverURL: nil,
                                           href: absolute, kind: .directory, mimeType: "text/directory"))
                continue
            }

            let ext = (decodedHref as NSString).pathExtension.lowercased()
            if LocalFileSource.supportedExtensions.contains(ext) {
                let info = ChapterSplitter.parseFileNameTitle(text.isEmpty ? decodedHref : text)
                entries.append(SourceEntry(title: info.title,
                                           author: info.author.isEmpty ? nil : info.author,
                                           summary: nil, coverURL: nil,
                                           href: absolute, kind: .book, mimeType: "application/\(ext)"))
            } else if ["mobi", "azw3", "pdf", "doc", "docx"].contains(ext) {
                // 不支持但有提示
                entries.append(SourceEntry(title: text.isEmpty ? decodedHref : text,
                                           author: nil, summary: "格式 \(ext) 暂不支持离线阅读，可直接下载到本地",
                                           coverURL: nil, href: absolute, kind: .book,
                                           mimeType: "application/\(ext)"))
            }
        }

        // 若页面结构特殊（没有 a 标签的表格），尝试解析 JSON（群晖/自建 API）
        if entries.isEmpty {
            if let json = try? JSONSerialization.jsonObject(with: resp.data) as? [String: Any],
               let files = json["files"] as? [[String: Any]] {
                for f in files {
                    guard let name = f["name"] as? String else { continue }
                    let ext = (name as NSString).pathExtension.lowercased()
                    let isDir = (f["isDir"] as? Bool) ?? false
                    let abs = URL(string: name, relativeTo: URL(string: baseURL))?.absoluteString ?? name
                    if isDir {
                        entries.append(SourceEntry(title: name, author: nil, summary: nil, coverURL: nil,
                                                   href: abs.hasSuffix("/") ? abs : abs + "/",
                                                   kind: .directory, mimeType: "text/directory"))
                    } else if LocalFileSource.supportedExtensions.contains(ext) {
                        entries.append(SourceEntry(title: (name as NSString).deletingPathExtension,
                                                   author: nil, summary: nil, coverURL: nil,
                                                   href: abs, kind: .book, mimeType: "application/\(ext)"))
                    }
                }
            }
        }

        return entries
    }

    // MARK: - WebDAV

    static func fetchWebDAV(source: RemoteSource, url: String) async throws -> [SourceEntry] {
        guard let target = HTTPClient.resolve(url, base: source.baseURL) else {
            throw HTTPError.invalidURL(url)
        }
        var request = URLRequest(url: target)
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("text/xml,application/xml", forHTTPHeaderField: "Accept")
        request.setValue(source.userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <D:propfind xmlns:D="DAV:">
          <D:prop>
            <D:displayname/>
            <D:getcontentlength/>
            <D:getcontenttype/>
            <D:resourcetype/>
            <D:getlastmodified/>
          </D:prop>
        </D:propfind>
        """.utf8)

        if !source.username.isEmpty {
            let token = Data("\(source.username):\(source.password)".utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        for (k, v) in source.headers { request.setValue(v, forHTTPHeaderField: k) }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw HTTPError.badStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        let xml = TextSanitizer.decode(data: data)?.text ?? ""

        var entries: [SourceEntry] = []
        let selfPath = target.path

        if let re = try? NSRegularExpression(pattern: #"<[dD]:response\b[\s\S]*?</[dD]:response>"#) {
            let ns = xml as NSString
            re.enumerateMatches(in: xml, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                guard let m else { return }
                let block = ns.substring(with: m.range)
                guard let hrefRaw = HTMLParser.firstMatch(#"<[dD]:href[^>]*>([\s\S]*?)</[dD]:href>"#, in: block) else { return }
                let href = hrefRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                let decoded = href.removingPercentEncoding ?? href
                guard let itemURL = URL(string: decoded, relativeTo: target)?.absoluteURL else { return }

                // 跳过自身
                if itemURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ==
                    selfPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")) { return }

                let isCollection = block.range(of: "collection", options: .caseInsensitive) != nil
                let name = HTMLParser.firstMatch(#"<[dD]:displayname[^>]*>([\s\S]*?)</[dD]:displayname>"#, in: block)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? itemURL.lastPathComponent
                guard !name.isEmpty else { return }

                if isCollection {
                    entries.append(SourceEntry(title: name, author: nil, summary: nil, coverURL: nil,
                                               href: itemURL.absoluteString, kind: .directory,
                                               mimeType: "text/directory"))
                } else {
                    let ext = itemURL.pathExtension.lowercased()
                    if LocalFileSource.supportedExtensions.contains(ext) {
                        let info = ChapterSplitter.parseFileNameTitle(name)
                        entries.append(SourceEntry(title: info.title,
                                                   author: info.author.isEmpty ? nil : info.author,
                                                   summary: nil, coverURL: nil,
                                                   href: itemURL.absoluteString, kind: .book,
                                                   mimeType: "application/\(ext)"))
                    }
                }
            }
        }
        return entries
    }
}
