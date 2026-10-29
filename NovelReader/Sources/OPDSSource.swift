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

/// WebDAV 专用会话：局域网 NAS 常见三种情况会直接卡死普通 URLSession
///   1. 群晖/威联通默认用自签证书（https 5006），系统会直接拒绝握手
///   2. PROPFIND 命中 301 时，URLSession 默认把方法降级成 GET，服务器回 405
///   3. 默认配置会走缓存，改了目录内容看不到变化
private final class WebDAVTrustDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession,
                    didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
           let trust = challenge.protectionSpace.serverTrust {
            completionHandler(.useCredential, URLCredential(trust: trust))
        } else {
            completionHandler(.performDefaultHandling, nil)
        }
    }

    /// 重定向时保留原始方法与请求体，否则 PROPFIND 会变成 GET
    func urlSession(_ session: URLSession,
                    task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let original = task.originalRequest else {
            completionHandler(request)
            return
        }
        var req = request
        req.httpMethod = original.httpMethod
        req.httpBody = original.httpBody
        for (key, value) in original.allHTTPHeaderFields ?? [:] where key.lowercased() != "host" {
            req.setValue(value, forHTTPHeaderField: key)
        }
        completionHandler(req)
    }
}

enum OPDSSource {

    private static let webDAVSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 60
        config.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        return URLSession(configuration: config,
                          delegate: WebDAVTrustDelegate(),
                          delegateQueue: nil)
    }()

    /// 合并重复斜杠、去掉尾斜杠，避免拼出 /books//a.txt
    static func normalizeWebDAVPath(_ url: URL) -> URL {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        var path = comps.path
        while path.contains("//") {
            path = path.replacingOccurrences(of: "//", with: "/")
        }
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        comps.path = path.isEmpty ? "/" : path
        return comps.url ?? url
    }


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
        guard let raw = HTTPClient.resolve(url, base: source.baseURL) else {
            throw HTTPError.invalidURL(url)
        }
        let target = normalizeWebDAVPath(raw)

        var request = URLRequest(url: target)
        request.httpMethod = "PROPFIND"
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("text/xml,application/xml", forHTTPHeaderField: "Accept")
        request.setValue(source.userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 25
        request.httpBody = Data("""
        <?xml version="1.0" encoding="utf-8"?>
        <D:propfind xmlns:D="DAV:">
          <D:prop>
            <D:displayname/>
            <D:getcontentlength/>
            <D:getcontenttype/>
            <D:resourcetype/>
          </D:prop>
        </D:propfind>
        """.utf8)

        if !source.username.isEmpty {
            let token = Data("\(source.username):\(source.password)".utf8).base64EncodedString()
            request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        }
        for (k, v) in source.headers { request.setValue(v, forHTTPHeaderField: k) }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await webDAVSession.data(for: request)
        } catch let error as URLError {
            throw HTTPError.transport(describe(error, target: target))
        }
        guard let http = response as? HTTPURLResponse else {
            throw HTTPError.transport("无 HTTP 响应")
        }
        // 207 Multi-Status 是 WebDAV 的正常返回
        guard (200..<300).contains(http.statusCode) else {
            throw HTTPError.transport(describe(status: http.statusCode,
                                               headers: http.allHeaderFields,
                                               target: target))
        }
        let xml = TextSanitizer.decode(data: data)?.text ?? ""

        var entries: [SourceEntry] = []
        // 用规范化后的路径做自身比较，避免/尾斜杠差异
        let selfPath = target.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))

        if let re = try? NSRegularExpression(pattern: #"<[dD]:response\b[\s\S]*?</[dD]:response>"#) {
            let ns = xml as NSString
            re.enumerateMatches(in: xml, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                guard let m else { return }
                let block = ns.substring(with: m.range)
                guard let hrefRaw = HTMLParser.firstMatch(#"<[dD]:href[^>]*>([\s\S]*?)</[dD]:href>"#, in: block) else { return }
                let href = hrefRaw.trimmingCharacters(in: .whitespacesAndNewlines)
                    .replacingOccurrences(of: "&amp;", with: "&")
                let decoded = href.removingPercentEncoding ?? href

                // WebDAV 的 href 可能是：
                //   绝对路径  /webdav/books/a.txt
                //   完整 URL  http://nas:5005/books/a.txt
                //   相对路径  books/a.txt
                let itemURL: URL?
                if decoded.lowercased().hasPrefix("http") {
                    itemURL = URL(string: decoded)
                } else if decoded.hasPrefix("/") {
                    // 绝对路径：拼到 host 上，忽略 baseURL 的 path
                    var comps = URLComponents(url: target, resolvingAgainstBaseURL: false)
                    comps?.path = decoded
                    comps?.query = nil
                    itemURL = comps?.url
                } else {
                    itemURL = URL(string: decoded, relativeTo: target)?.absoluteURL
                }
                guard let itemURL else { return }

                // 跳过自身
                let itemPath = itemURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                if itemPath == selfPath { return }
                // 跳过上上级（某些服务器会返回）
                if itemPath.isEmpty { return }

                let isCollection = block.range(of: "collection", options: .caseInsensitive) != nil
                let name = HTMLParser.firstMatch(#"<[dD]:displayname[^>]*>([\s\S]*?)</[dD]:displayname>"#, in: block)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? itemURL.lastPathComponent
                guard !name.isEmpty else { return }

                if isCollection {
                    var href = itemURL.absoluteString
                    if !href.hasSuffix("/") { href += "/" }
                    entries.append(SourceEntry(title: name, author: nil, summary: nil, coverURL: nil,
                                               href: href, kind: .directory,
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

    // MARK: - WebDAV 错误说明

    /// 把系统错误码翻成人能看懂、能直接照着改的提示
    private static func describe(_ error: URLError, target: URL) -> String {
        let host = target.host ?? ""
        let port = target.port.map { ":\($0)" } ?? ""
        switch error.code {
        case .cannotFindHost, .dnsLookupFailed:
            return "找不到主机 \(host)。请确认 NAS 的 IP 填写正确、手机和 NAS 在同一个局域网。"
        case .cannotConnectToHost:
            return "连不上 \(host)\(port)。请确认 WebDAV 服务已启动、端口没写错（群晖 HTTP 5005 / HTTPS 5006，威联通 5000 / 5001，Nextcloud 通常 80 / 443），并检查防火墙。"
        case .timedOut:
            return "连接 \(host)\(port) 超时。地址可能不对，或 NAS 拒绝了这个端口。"
        case .notConnectedToInternet:
            return "手机当前没有网络。"
        case .networkConnectionLost:
            return "连接被中断，请重试。"
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate:
            return "\(host) 的 HTTPS 证书不被信任。自签证书需要确认地址用 https 且端口正确；也可以改用 HTTP 端口。"
        case .unsupportedURL:
            return "地址格式不对：\(target.absoluteString)"
        default:
            return "网络错误（\(error.code.rawValue)）：\(error.localizedDescription)"
        }
    }

    private static func describe(status: Int, headers: [AnyHashable: Any], target: URL) -> String {
        let authHeader = (headers.first { ($0.key as? String)?.lowercased() == "www-authenticate" }?.value as? String) ?? ""
        switch status {
        case 401:
            if authHeader.lowercased().contains("digest") {
                return "服务器要求 Digest 认证（401）。请在 NAS 的 WebDAV 设置里允许 Basic 认证，或改用其他端口/协议。"
            }
            return "认证失败（401）。请检查用户名和密码；群晖需要在「套件中心」安装并启动 WebDAV Server，且账号有该目录的访问权限。"
        case 403:
            return "没有权限（403）。这个账号对 \(target.path) 没有读取权限。"
        case 404:
            return "路径不存在（404）：\(target.path)。地址要指向 WebDAV 的根目录或其中的子目录，例如 http://192.168.1.100:5005/books"
        case 405, 501:
            return "服务器不接受 PROPFIND（\(status)）。这个地址可能不是 WebDAV 目录，或者被反向代理拦了。"
        case 423:
            return "目录被锁定（423），请稍后重试。"
        case 507:
            return "服务器存储不足（507）。"
        default:
            return "服务器返回 \(status)：\(target.absoluteString)"
        }
    }
}
