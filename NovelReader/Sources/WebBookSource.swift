//
//  WebBookSource.swift
//  NovelReader
//
//  规则书源 / JSON API 书源的实现：搜索、详情（目录）、章节正文
//

import Foundation

enum WebBookSource {

    // MARK: - 搜索

    static func search(source: RemoteSource, keyword: String, page: Int = 1) async throws -> [RemoteBookCandidate] {
        switch source.kind {
        case .rules:  return try await searchRules(source: source, keyword: keyword, page: page)
        case .jsonAPI: return try await searchJSON(source: source, keyword: keyword, page: page)
        default: return []
        }
    }

    private static func searchRules(source: RemoteSource, keyword: String, page: Int) async throws -> [RemoteBookCandidate] {
        guard !SourceRuleEngine.isEmpty(source.searchURLTemplate) else {
            throw ParseError.unsupportedFormat("未配置搜索地址模板")
        }
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        var urlStr = source.searchURLTemplate
            .replacingOccurrences(of: "{keyword}", with: encoded)
            .replacingOccurrences(of: "{page}", with: String(page))
            .replacingOccurrences(of: "{gbk}", with: encoded)
        if !source.pageQueryTemplate.isEmpty, !urlStr.contains("{page}") {
            urlStr += source.pageQueryTemplate.replacingOccurrences(of: "{page}", with: String(page))
        }

        let resp = try await HTTPClient.shared.fetchText(urlStr, source: source)
        guard resp.isOK else { throw HTTPError.badStatus(resp.statusCode) }
        let html = resp.text

        // 优先用 itemSelector 定位每一行，再在行内取子字段；否则全局取
        var results: [RemoteBookCandidate] = []

        if !SourceRuleEngine.isEmpty(source.searchItemSelector),
           let itemRule = CSSRule.parse(source.searchItemSelector) {
            let root = LightHTMLParser.parse(html)
            let items = root.select(itemRule)
            for item in items {
                let title = pick(source.searchTitleSelector, node: item, html: item.html) ?? ""
                guard !title.isEmpty else { continue }
                let link = pickLink(source.searchLinkSelector, node: item) ?? ""
                let author = pick(source.searchAuthorSelector, node: item, html: item.html) ?? ""
                let cover = pick(source.searchCoverSelector, node: item, html: item.html,
                                 preferAttribute: true) ?? ""
                results.append(RemoteBookCandidate(
                    sourceID: source.id,
                    sourceName: source.name,
                    title: title,
                    author: author,
                    coverURL: cover.isEmpty ? nil : absolute(cover, base: resp.finalURL.absoluteString),
                    summary: nil,
                    detailURL: absolute(link, base: resp.finalURL.absoluteString)
                ))
            }
        } else {
            let titles = SourceRuleEngine.texts(source.searchTitleSelector, in: html)
            let links = SourceRuleEngine.nodes(source.searchLinkSelector.isEmpty ? "a" : source.searchLinkSelector, in: html)
            let authors = SourceRuleEngine.texts(source.searchAuthorSelector, in: html)
            for (i, title) in titles.enumerated() {
                guard !title.isEmpty else { continue }
                let link = i < links.count ? (links[i].attributes["href"] ?? "") : ""
                let author = i < authors.count ? authors[i] : ""
                results.append(RemoteBookCandidate(
                    sourceID: source.id, sourceName: source.name,
                    title: title, author: author, coverURL: nil,
                    summary: nil, detailURL: absolute(link, base: resp.finalURL.absoluteString)
                ))
            }
        }
        return results
    }

    private static func searchJSON(source: RemoteSource, keyword: String, page: Int) async throws -> [RemoteBookCandidate] {
        let encoded = keyword.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? keyword
        var urlStr = source.searchURLTemplate
            .replacingOccurrences(of: "{keyword}", with: encoded)
            .replacingOccurrences(of: "{page}", with: String(page))
        if urlStr.isEmpty {
            urlStr = "\(source.baseURL)/search?q=\(encoded)"
        }
        let resp = try await HTTPClient.shared.fetchText(urlStr, source: source)
        guard resp.isOK else { throw HTTPError.badStatus(resp.statusCode) }
        guard let json = try? JSONSerialization.jsonObject(with: resp.data) else {
            throw HTTPError.emptyBody
        }
        let array = jsonArray(in: json, path: source.jsonSearchPath)
        var results: [RemoteBookCandidate] = []
        for item in array {
            guard let dict = item as? [String: Any] else { continue }
            let title = dict[source.jsonTitleField] as? String ?? ""
            guard !title.isEmpty else { continue }
            results.append(RemoteBookCandidate(
                sourceID: source.id, sourceName: source.name,
                title: title,
                author: dict[source.jsonAuthorField] as? String ?? "",
                coverURL: dict[source.jsonCoverField] as? String,
                summary: dict["intro"] as? String,
                detailURL: absolute(dict[source.jsonLinkField] as? String ?? "",
                                    base: source.baseURL)
            ))
        }
        return results
    }

    // MARK: - 详情 / 目录

    static func detail(source: RemoteSource, detailURL: String) async throws -> SourceBookDetail {
        switch source.kind {
        case .jsonAPI:
            return try await detailJSON(source: source, detailURL: detailURL)
        default:
            return try await detailRules(source: source, detailURL: detailURL)
        }
    }

    private static func detailRules(source: RemoteSource, detailURL: String) async throws -> SourceBookDetail {
        let resp = try await HTTPClient.shared.fetchText(detailURL, source: source)
        guard resp.isOK else { throw HTTPError.badStatus(resp.statusCode) }
        let html = resp.text
        let base = resp.finalURL.absoluteString

        let title = pick(source.detailTitleSelector, html: html)
            ?? HTMLParser.pageTitle(html)
            ?? "未命名"
        let author = pick(source.detailAuthorSelector, html: html) ?? ""
        let cover = pick(source.detailCoverSelector, html: html, preferAttribute: true)
        let summary = pick(source.detailSummarySelector, html: html) ?? ""

        // 章节列表
        var chapters: [SourceEntry] = []
        let chapterRule = source.detailChapterSelector.isEmpty ? "a" : source.detailChapterSelector
        if let css = CSSRule.parse(chapterRule) {
            let root = LightHTMLParser.parse(html)
            let nodes = root.select(css)
            for (idx, node) in nodes.enumerated() {
                let href = node.attributes["href"] ?? ""
                guard !href.isEmpty, !href.hasPrefix("javascript:"), !href.hasPrefix("#") else { continue }
                var chapterTitle = node.text
                if !SourceRuleEngine.isEmpty(source.detailChapterTitleSelector) {
                    if let inner = SourceRuleEngine.nodes(source.detailChapterTitleSelector, in: node.html).first?.text,
                       !inner.isEmpty {
                        chapterTitle = inner
                    }
                }
                if chapterTitle.isEmpty { chapterTitle = "第\(idx + 1)节" }
                chapters.append(SourceEntry(
                    title: chapterTitle,
                    author: nil, summary: nil, coverURL: nil,
                    href: absolute(href, base: base),
                    kind: .chapter,
                    mimeType: "text/html"
                ))
            }
        }

        return SourceBookDetail(
            title: title.trimmingCharacters(in: .whitespacesAndNewlines),
            author: author.trimmingCharacters(in: .whitespacesAndNewlines),
            coverURL: cover.flatMap { absolute($0, base: base) },
            summary: summary,
            chapters: chapters
        )
    }

    private static func detailJSON(source: RemoteSource, detailURL: String) async throws -> SourceBookDetail {
        let resp = try await HTTPClient.shared.fetchText(detailURL, source: source)
        guard resp.isOK else { throw HTTPError.badStatus(resp.statusCode) }
        guard let json = try? JSONSerialization.jsonObject(with: resp.data) else {
            throw HTTPError.emptyBody
        }
        var title = "未命名", author = "", cover: String? = nil, summary = ""
        if let dict = json as? [String: Any] {
            title = dict[source.jsonTitleField] as? String ?? title
            author = dict[source.jsonAuthorField] as? String ?? ""
            cover = dict[source.jsonCoverField] as? String
            summary = dict["intro"] as? String ?? dict["summary"] as? String ?? ""
        }
        var chapters: [SourceEntry] = []
        for item in jsonArray(in: json, path: source.jsonChapterPath) {
            guard let dict = item as? [String: Any] else { continue }
            let t = dict[source.jsonChapterTitleField] as? String ?? ""
            let u = dict[source.jsonChapterLinkField] as? String ?? ""
            guard !t.isEmpty, !u.isEmpty else { continue }
            chapters.append(SourceEntry(title: t, author: nil, summary: nil, coverURL: nil,
                                        href: absolute(u, base: source.baseURL),
                                        kind: .chapter, mimeType: "application/json"))
        }
        return SourceBookDetail(title: title, author: author, coverURL: cover, summary: summary, chapters: chapters)
    }

    // MARK: - 章节正文

    static func content(source: RemoteSource, chapterURL: String) async throws -> String {
        if source.kind == .jsonAPI {
            let resp = try await HTTPClient.shared.fetchText(chapterURL, source: source)
            guard resp.isOK else { throw HTTPError.badStatus(resp.statusCode) }
            if let json = try? JSONSerialization.jsonObject(with: resp.data) as? [String: Any],
               let c = json[source.jsonContentField] as? String {
                return TextSanitizer.normalizeBody(HTMLParser.htmlToPlainText(c))
            }
            return ""
        }

        let resp = try await HTTPClient.shared.fetchText(chapterURL, source: source)
        guard resp.isOK else { throw HTTPError.badStatus(resp.statusCode) }
        let html = resp.text
        let selector = source.contentSelector.isEmpty ? "body" : source.contentSelector
        var text = SourceRuleEngine.extractContent(html: html,
                                                   contentSelector: selector,
                                                   removeSelectors: source.contentRemoveSelectors)
        if text.count < 30 {
            // 规则失效兜底：取 <body> 里最长的 <div>
            let root = LightHTMLParser.parse(html)
            let divs = root.select(CSSRule.parse("div") ?? CSSRule(parts: []))
            let longest = divs.max { $0.text.count < $1.text.count }
            if let longest, longest.text.count > text.count {
                text = TextSanitizer.normalizeBody(longest.text)
            }
        }
        return TextSanitizer.applyIndent(text)
    }

    // MARK: - 工具

    private static func pick(_ rule: String, node: DOMNode? = nil, html: String?, preferAttribute: Bool = false) -> String? {
        let r = (rule ?? "").trimmingCharacters(in: .whitespaces)
        guard !r.isEmpty else { return nil }
        // 带 @attr 后缀
        if r.contains("@") && !r.hasPrefix("@") {
            if let node {
                let parts = r.split(separator: "@", maxSplits: 1).map(String.init)
                if let css = CSSRule.parse(parts[0]) {
                    // 在节点内查找
                    let subRoot = LightHTMLParser.parse(node.html)
                    if let n = subRoot.select(css).first ?? subRoot.select(css).first {
                        return n.attributes[parts[1].lowercased()]
                    }
                }
                return nil
            }
            return SourceRuleEngine.attrText(r, in: html ?? "")
        }
        if let node {
            if r.hasPrefix("@") {
                return node.attributes[String(r.dropFirst()).lowercased()]
            }
            if let css = CSSRule.parse(r) {
                let subRoot = LightHTMLParser.parse(node.html)
                if let n = subRoot.select(css).first { return n.text }
            }
            return nil
        }
        return SourceRuleEngine.text(r, in: html ?? "")
    }

    private static func pickLink(_ rule: String, node: DOMNode) -> String? {
        let r = (rule ?? "").trimmingCharacters(in: .whitespaces)
        if r.isEmpty {
            return node.attributes["href"] ?? node.descendants().first { $0.attributes["href"] != nil }?.attributes["href"]
        }
        if r.hasPrefix("@") {
            return node.attributes[String(r.dropFirst()).lowercased()]
        }
        if let css = CSSRule.parse(r) {
            let subRoot = LightHTMLParser.parse(node.html)
            if let n = subRoot.select(css).first {
                return n.attributes["href"]
            }
        }
        return nil
    }

    private static func absolute(_ href: String, base: String) -> String {
        if href.isEmpty { return base }
        if href.lowercased().hasPrefix("http") { return href }
        return URL(string: href, relativeTo: URL(string: base))?.absoluteString ?? href
    }

    private static func jsonArray(in json: Any, path: String) -> [Any] {
        if path.isEmpty {
            if let arr = json as? [Any] { return arr }
            // 猜测常见字段
            if let dict = json as? [String: Any] {
                for key in ["data", "items", "books", "list", "results", "chapters"] {
                    if let arr = dict[key] as? [Any] { return arr }
                }
            }
            return []
        }
        var current: Any? = json
        for key in path.split(separator: ".").map(String.init) {
            if let dict = current as? [String: Any] {
                current = dict[key]
            } else {
                return []
            }
        }
        return current as? [Any] ?? []
    }
}
