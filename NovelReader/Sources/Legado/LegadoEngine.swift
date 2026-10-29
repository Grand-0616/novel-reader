//
//  LegadoEngine.swift
//  NovelReader
//
//  Legado 书源的四段流水线：搜索 → 详情 → 目录 → 正文。
//
//  一个书源就是一组规则字符串，引擎负责：
//  1. 按模板拼请求（含 {{key}} {{page}} 占位符和 POST body）
//  2. 拉页面，自动判定 HTML / JSON
//  3. 用 LegadoRule 求值，拿列表节点后逐条取字段
//  4. 补全相对地址，产出统一的 Result / Detail / Chapter 类型
//

import Foundation

// MARK: - 发现页条目

/// exploreUrl 里的一项（分类名 + 地址）
struct LegadoExploreEntry: Identifiable, Hashable {
    var id: String { "\(title)|\(url)" }
    var title: String
    var url: String
}

// MARK: - 引擎

final class LegadoEngine {

    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        config.timeoutIntervalForRequest = 30
        self.session = URLSession(configuration: config)
    }

    // MARK: - 搜索

    func search(_ source: LegadoBookSource,
                keyword: String,
                page: Int = 1) async throws -> [LegadoSearchResult] {
        guard let rule = source.ruleSearch, rule.isUsable else {
            throw LegadoError.noSearchRule
        }
        let template = source.searchUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !template.isEmpty else { throw LegadoError.noSearchRule }

        let ctx = makeContext(source)
        let request = try buildRequest(template: template,
                                       keyword: keyword,
                                       page: page,
                                       ctx: ctx,
                                       headers: parseHeaders(source.header))
        let (content, finalURL) = try await fetch(request, ctx: ctx)
        ctx.currentURL = finalURL

        let items = bookContents(rule: rule.bookList, content: content, ctx: ctx)
        return items.compactMap { item in
            let name = value(rule.name, item, ctx)
            guard !name.isEmpty else { return nil }
            let bookURL = value(rule.bookUrl, item, ctx)
            return LegadoSearchResult(
                sourceName: source.bookSourceName,
                sourceURL: source.bookSourceUrl,
                name: name,
                author: value(rule.author, item, ctx),
                intro: value(rule.intro, item, ctx),
                kind: value(rule.kind, item, ctx),
                lastChapter: value(rule.lastChapter, item, ctx),
                wordCount: value(rule.wordCount, item, ctx),
                coverURL: optionalURL(rule.coverUrl, item, ctx),
                bookURL: bookURL.isEmpty
                    ? (finalURL?.absoluteString ?? source.bookSourceUrl)
                    : ctx.absolute(bookURL)
            )
        }
    }

    /// 多源并发聚合搜索。单个源失败不影响其它源。
    func searchAll(_ sources: [LegadoBookSource],
                   keyword: String,
                   page: Int = 1,
                   limit: Int = 8) async -> [LegadoSearchResult] {
        let enabled = sources.filter { $0.enabled && $0.readiness.isReady }
        guard !enabled.isEmpty else { return [] }

        return await withTaskGroup(of: [LegadoSearchResult].self) { group in
            var iterator = enabled.makeIterator()
            var running = 0
            var collected: [LegadoSearchResult] = []

            // 先填满并发窗口
            while running < limit, let source = iterator.next() {
                running += 1
                group.addTask { (try? await self.search(source, keyword: keyword, page: page)) ?? [] }
            }

            for await batch in group {
                collected.append(contentsOf: batch)
                running -= 1
                if let source = iterator.next() {
                    running += 1
                    group.addTask { (try? await self.search(source, keyword: keyword, page: page)) ?? [] }
                }
            }
            return collected
        }
    }

    // MARK: - 发现

    /// 解析 exploreUrl 成分类列表。支持三种写法：
    /// 1. `分类名::地址` 每行一条
    /// 2. JSON 数组 `[{"title":"..","url":".."}]`
    /// 3. 单个地址
    func exploreEntries(_ source: LegadoBookSource) -> [LegadoExploreEntry] {
        let raw = source.exploreUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return [] }

        if raw.hasPrefix("[") || raw.hasPrefix("{"),
           let data = raw.data(using: .utf8),
           let obj = try? JSONSerialization.jsonObject(with: data) {
            var out: [LegadoExploreEntry] = []
            collectExplore(obj, into: &out)
            if !out.isEmpty { return out }
        }

        var out: [LegadoExploreEntry] = []
        for line in raw.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            guard !text.isEmpty else { continue }
            if let range = text.range(of: "::") {
                let title = String(text[text.startIndex..<range.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                let url = String(text[range.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
                if !url.isEmpty {
                    out.append(LegadoExploreEntry(title: title.isEmpty ? url : title, url: url))
                }
            } else if text.hasPrefix("http") {
                out.append(LegadoExploreEntry(title: "全部", url: text))
            }
        }
        return out
    }

    private func collectExplore(_ node: Any, into out: inout [LegadoExploreEntry]) {
        if let array = node as? [Any] {
            for item in array { collectExplore(item, into: &out) }
            return
        }
        guard let dict = node as? [String: Any] else { return }

        let title = (dict["title"] as? String)
            ?? (dict["name"] as? String)
            ?? (dict["分类"] as? String)
            ?? ""
        let url = (dict["url"] as? String)
            ?? (dict["link"] as? String)
            ?? ""
        if !url.isEmpty {
            out.append(LegadoExploreEntry(title: title.isEmpty ? url : title, url: url))
            return
        }
        // 分组形式 {"分类名":[子项...]}
        for (key, value) in dict {
            if let array = value as? [Any] {
                var children: [LegadoExploreEntry] = []
                collectExplore(array, into: &children)
                for var child in children {
                    if child.title == child.url || child.title.isEmpty {
                        child.title = key
                    } else {
                        child.title = "\(key) · \(child.title)"
                    }
                    out.append(child)
                }
            }
        }
    }

    /// 跑一个发现分类
    func explore(_ source: LegadoBookSource,
                 entry: LegadoExploreEntry,
                 page: Int = 1) async throws -> [LegadoSearchResult] {
        guard let rule = source.ruleExplore ?? source.ruleSearch.map(LegadoExploreRule.init(search:)),
              rule.isUsable else {
            throw LegadoError.noSearchRule
        }

        let ctx = makeContext(source)
        let request = try buildRequest(template: entry.url,
                                       keyword: nil,
                                       page: page,
                                       ctx: ctx,
                                       headers: parseHeaders(source.header))
        let (content, finalURL) = try await fetch(request, ctx: ctx)
        ctx.currentURL = finalURL

        let items = bookContents(rule: rule.bookList, content: content, ctx: ctx)
        return items.compactMap { item in
            let name = value(rule.name, item, ctx)
            guard !name.isEmpty else { return nil }
            let bookURL = value(rule.bookUrl, item, ctx)
            return LegadoSearchResult(
                sourceName: source.bookSourceName,
                sourceURL: source.bookSourceUrl,
                name: name,
                author: value(rule.author, item, ctx),
                intro: value(rule.intro, item, ctx),
                kind: value(rule.kind, item, ctx),
                lastChapter: value(rule.lastChapter, item, ctx),
                wordCount: value(rule.wordCount, item, ctx),
                coverURL: optionalURL(rule.coverUrl, item, ctx),
                bookURL: bookURL.isEmpty
                    ? (finalURL?.absoluteString ?? source.bookSourceUrl)
                    : ctx.absolute(bookURL)
            )
        }
    }

    // MARK: - 详情

    func detail(_ source: LegadoBookSource, bookURL: String) async throws -> LegadoBookDetail {
        let rule = source.ruleBookInfo
        let ctx = makeContext(source, currentURL: URL(string: bookURL))

        // 没有详情规则就直接拿 bookURL 当目录页
        guard let rule else {
            return LegadoBookDetail(name: "", author: "", intro: "", kind: "",
                                    lastChapter: "", wordCount: "",
                                    coverURL: nil, tocURL: bookURL)
        }

        let request = try buildRequest(template: bookURL, keyword: nil, page: 1,
                                       ctx: ctx, headers: parseHeaders(source.header))
        let (content, finalURL) = try await fetch(request, ctx: ctx)
        ctx.currentURL = finalURL

        let tocRaw = value(rule.tocUrl, content, ctx)
        return LegadoBookDetail(
            name: value(rule.name, content, ctx),
            author: value(rule.author, content, ctx),
            intro: value(rule.intro, content, ctx),
            kind: value(rule.kind, content, ctx),
            lastChapter: value(rule.lastChapter, content, ctx),
            wordCount: value(rule.wordCount, content, ctx),
            coverURL: optionalURL(rule.coverUrl, content, ctx),
            tocURL: tocRaw.isEmpty
                ? (finalURL?.absoluteString ?? bookURL)
                : ctx.absolute(tocRaw)
        )
    }

    // MARK: - 目录

    func chapters(_ source: LegadoBookSource,
                  tocURL: String,
                  maxPages: Int = 5) async throws -> [LegadoChapterItem] {
        guard let rule = source.ruleToc, rule.isUsable else {
            throw LegadoError.noTocRule
        }

        let ctx = makeContext(source, currentURL: URL(string: tocURL))
        var results: [LegadoChapterItem] = []
        var nextURL: String? = tocURL
        var visited: Set<String> = []
        var pageCount = 0

        while let current = nextURL, pageCount < maxPages {
            guard !visited.contains(current) else { break }
            visited.insert(current)
            pageCount += 1

            let request = try buildRequest(template: current, keyword: nil, page: pageCount,
                                           ctx: ctx, headers: parseHeaders(source.header))
            let (content, finalURL) = try await fetch(request, ctx: ctx)
            ctx.currentURL = finalURL

            let nodes = bookContents(rule: rule.chapterList, content: content, ctx: ctx)
            for node in nodes {
                let title = value(rule.chapterName, node, ctx)
                let url = value(rule.chapterUrl, node, ctx)
                guard !title.isEmpty || !url.isEmpty else { continue }
                let absolute = url.isEmpty ? "" : ctx.absolute(url)
                let vipRaw = value(rule.isVip, node, ctx)
                results.append(LegadoChapterItem(
                    index: results.count,
                    title: title.isEmpty ? "第 \(results.count + 1) 章" : title,
                    url: absolute,
                    isVip: !vipRaw.isEmpty
                ))
            }

            // nextTocUrl：可能是地址，也可能是「下一页」节点里的 href
            let nextRaw = value(rule.nextTocUrl, content, ctx)
            if nextRaw.isEmpty {
                nextURL = nil
            } else {
                nextURL = ctx.absolute(nextRaw)
            }
        }

        // 重排 index，保证连续
        for i in results.indices {
            results[i].index = i
        }
        return results
    }

    // MARK: - 正文

    func content(_ source: LegadoBookSource, chapterURL: String) async throws -> String {
        guard let rule = source.ruleContent, rule.isUsable else {
            throw LegadoError.noContentRule
        }

        let ctx = makeContext(source, currentURL: URL(string: chapterURL))
        let request = try buildRequest(template: chapterURL, keyword: nil, page: 1,
                                       ctx: ctx, headers: parseHeaders(source.header))
        let (content, finalURL) = try await fetch(request, ctx: ctx)
        ctx.currentURL = finalURL

        // webJs：先用网页脚本改写页面（部分站点正文靠 JS 拼）
        if let webJs = rule.webJs, !webJs.isEmpty {
            _ = evaluateJS(webJs, ctx: ctx, currentResult: content.stringValue)
        }

        let raw = value(rule.content, content, ctx)
        guard !raw.isEmpty else { throw LegadoError.emptyResult }

        var text = raw

        // sourceRegex / replaceRegex：整页文本的清洗规则
        if let pattern = rule.sourceRegex, !pattern.isEmpty {
            text = LegadoRule.applyRegex(pattern, to: text) ?? text
        }
        if let pattern = rule.replaceRegex, !pattern.isEmpty {
            text = LegadoRule.applyRegex(pattern, to: text) ?? text
        }

        let plain = Self.htmlToPlainText(text)
        guard !plain.isEmpty else { throw LegadoError.emptyResult }
        return plain
    }

    // MARK: - 上下文

    private func makeContext(_ source: LegadoBookSource, currentURL: URL? = nil) -> LegadoRuleContext {
        let ctx = LegadoRuleContext(sourceURL: source.bookSourceUrl, currentURL: currentURL)
        ctx.jsLib = source.jsLib

        let runtime = LegadoJSRuntime(sourceBaseURL: source.bookSourceUrl,
                                      variables: ctx.variables,
                                      jsLib: source.jsLib)
        runtime.onVariableChanged = { [weak ctx] key, value in
            ctx?.variables[key] = value
        }
        // 闭包捕获 runtime，ctx 存活期间 runtime 不会被释放
        ctx.jsEvaluator = { [weak ctx] code, _ in
            guard let ctx else { return nil }
            runtime.syncVariables(ctx.variables)
            return runtime.evaluate(code)
        }
        return ctx
    }

    private func evaluateJS(_ code: String,
                            ctx: LegadoRuleContext,
                            currentResult: String?) -> String? {
        guard let evaluator = ctx.jsEvaluator else { return nil }
        _ = currentResult
        return evaluator(code, ctx)
    }

    // MARK: - 规则求值

    /// 取单个字段，结果做空白归一化
    private func value(_ rule: String?, _ content: LegadoContent, _ ctx: LegadoRuleContext) -> String {
        guard let raw = LegadoRule.evaluate(rule, on: content, ctx: ctx) else { return "" }
        return Self.normalize(raw)
    }

    private func optionalURL(_ rule: String?, _ content: LegadoContent, _ ctx: LegadoRuleContext) -> String? {
        let raw = value(rule, content, ctx)
        guard !raw.isEmpty else { return nil }
        return ctx.absolute(raw)
    }

    /// 把列表规则展开成一组可继续求值的子内容
    private func bookContents(_ rule: String?,
                              content: LegadoContent,
                              ctx: LegadoRuleContext) -> [LegadoContent] {
        guard let rule, !rule.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }

        // JSON 书源：$..books[*] 直接取数组元素
        if let root = content.jsonValue, rule.contains("$") {
            let paths = rule.split(separator: "||").map { $0.trimmingCharacters(in: .whitespaces) }
            for path in paths where path.hasPrefix("$") {
                let values = LegadoJSON.query(path, in: root)
                if !values.isEmpty { return values.map { .json($0) } }
            }
        }

        // HTML 书源：走 CSS 节点
        let nodes = LegadoRule.selectNodes(rule, in: content, ctx: ctx)
        return nodes.map { .html($0.html) }
    }

    // MARK: - 请求构建

    private func parseHeaders(_ raw: String?) -> [String: String] {
        guard let raw, !raw.trimmingCharacters(in: .whitespaces).isEmpty else { return [:] }
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return [:]
        }
        var out: [String: String] = [:]
        for (k, v) in obj { out[k] = "\(v)" }
        return out
    }

    /// 模板形如：
    ///   `https://a.com/search?q={{key}}&page={{page}}`
    ///   `https://a.com/search,{"method":"POST","body":"kw={{key}}&p={{page}}"}`
    private func buildRequest(template: String,
                              keyword: String?,
                              page: Int,
                              ctx: LegadoRuleContext,
                              headers: [String: String]) throws -> URLRequest {
        var urlPart = template
        var options: [String: Any] = [:]

        if let range = template.range(of: ",{") {
            urlPart = String(template[template.startIndex..<range.lowerBound])
            let jsonPart = String(template[range.lowerBound...].dropFirst())
            if let data = jsonPart.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                options = obj
            }
        }

        let expanded = expandTemplate(urlPart, keyword: keyword, page: page, ctx: ctx)
        guard let url = URL(string: expanded.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw LegadoError.badSourceURL(expanded)
        }

        var request = URLRequest(url: url)
        let method = (options["method"] as? String)?.uppercased() ?? "GET"
        request.httpMethod = method
        request.timeoutInterval = 30

        if let body = options["body"] as? String {
            request.httpBody = expandTemplate(body, keyword: keyword, page: page, ctx: ctx)
                .data(using: .utf8)
        } else if let body = options["body"] as? [String: Any],
                  let data = try? JSONSerialization.data(withJSONObject: body) {
            request.httpBody = data
        }

        var merged = headers
        if let extra = options["headers"] as? [String: Any] {
            for (k, v) in extra { merged[k] = "\(v)" }
        }
        for (k, v) in merged {
            request.setValue(v, forHTTPHeaderField: k)
        }
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue(
                "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
                forHTTPHeaderField: "User-Agent")
        }
        return request
    }

    /// 替换 {{key}} {{page}} 和其它表达式
    private func expandTemplate(_ template: String,
                                keyword: String?,
                                page: Int,
                                ctx: LegadoRuleContext) -> String {
        guard template.contains("{{") else { return template }

        var output = template
        let pattern = "\\{\\{([^{}]*)\\}\\}"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return template }

        // 从后往前替换，避免 range 位移
        let matches = regex.matches(in: output, range: NSRange(location: 0, length: (output as NSString).length))
        for match in matches.reversed() {
            guard let whole = Range(match.range, in: output),
                  let inner = Range(match.range(at: 1), in: output) else { continue }
            let expr = String(output[inner]).trimmingCharacters(in: .whitespaces)

            var replacement = ""
            switch expr {
            case "key":
                replacement = Self.percentEncode(keyword ?? "")
            case "page":
                replacement = String(page)
            default:
                // 交给 JS 求值；失败则查变量表
                if let js = ctx.jsEvaluator, let v = js(expr, ctx) {
                    replacement = v
                } else {
                    replacement = ctx.variables[expr] ?? ""
                }
            }
            output.replaceSubrange(whole, with: replacement)
        }
        return output
    }

    // MARK: - 网络

    private func fetch(_ request: URLRequest,
                       ctx: LegadoRuleContext) async throws -> (LegadoContent, URL?) {
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw LegadoError.network("响应不是 HTTP")
            }
            if http.statusCode >= 400 {
                throw LegadoError.network("HTTP \(http.statusCode)")
            }
            let text = Self.decode(data, response: http)
            let content = Self.classify(text, response: http)
            return (content, http.url)
        } catch let error as LegadoError {
            throw error
        } catch {
            throw LegadoError.network(error.localizedDescription)
        }
    }

    private static func decode(_ data: Data, response: HTTPURLResponse) -> String {
        // 1. Content-Type 里的 charset
        if let contentType = response.value(forHTTPHeaderField: "Content-Type"),
           let range = contentType.range(of: "charset=") {
            let name = contentType[range.upperBound...]
                .split(separator: ";").first.map(String.init) ?? ""
            if let enc = String.Encoding(charsetName: name),
               let s = String(data: data, encoding: enc) {
                return s
            }
        }
        // 2. 响应自带编码
        if let name = response.textEncodingName,
           let enc = String.Encoding(charsetName: name),
           let s = String(data: data, encoding: enc) {
            return s
        }
        // 3. UTF-8 → GB18030 → Latin1
        if let s = String(data: data, encoding: .utf8) { return s }
        if let enc = String.Encoding(charsetName: "gb18030"),
           let s = String(data: data, encoding: enc) {
            return s
        }
        return String(data: data, encoding: .isoLatin1) ?? ""
    }

    /// 判断返回体是 JSON 还是 HTML
    private static func classify(_ text: String, response: HTTPURLResponse) -> LegadoContent {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .html(text) }

        let contentType = (response.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let looksJSON = trimmed.hasPrefix("{") || trimmed.hasPrefix("[")

        if contentType.contains("json") || looksJSON {
            if let data = trimmed.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) {
                return .json(obj)
            }
        }
        return .html(text)
    }

    // MARK: - 文本处理

    static func percentEncode(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    /// 空白归一化：折叠行内多余空格，保留换行
    static func normalize(_ s: String) -> String {
        var text = s.replacingOccurrences(of: "\r\n", with: "\n")
        text = text.replacingOccurrences(of: "\r", with: "\n")
        text = text.replacingOccurrences(of: "\u{00A0}", with: " ")
        text = text.replacingOccurrences(of: "[ \\t]+", with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 把正文 HTML 转成适合阅读器的纯文本（段落用空行分隔）
    static func htmlToPlainText(_ html: String) -> String {
        var s = html

        s = s.replacingOccurrences(of: "(?is)<script.*?</script>", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?is)<style.*?</style>", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?is)<!--.*?-->", with: "", options: .regularExpression)

        s = s.replacingOccurrences(of: "(?i)<br\\s*/?>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)</p\\s*>", with: "\n\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)</div\\s*>", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "(?i)<p[^>]*>", with: "", options: .regularExpression)

        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        s = decodeEntities(s)
        s = normalize(s)

        // 连续空行压成一个
        s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)

        // 每行去首尾空白，丢掉纯空行里的空格
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var text = s
        let named: [String: String] = [
            "&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">",
            "&quot;": "\"", "&apos;": "'", "&mdash;": "—", "&ndash;": "–",
            "&hellip;": "…", "&ldquo;": "“", "&rdquo;": "”",
            "&lsquo;": "‘", "&rsquo;": "’", "&middot;": "·", "&times;": "×"
        ]
        for (k, v) in named {
            text = text.replacingOccurrences(of: k, with: v)
        }

        // 数字实体 &#123; / &#x1F600;
        if let regex = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);") {
            let ns = text as NSString
            let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
            for match in matches.reversed() {
                let isHex = ns.substring(with: match.range(at: 1)) == "x"
                let digits = ns.substring(with: match.range(at: 2))
                guard let code = UInt32(digits, radix: isHex ? 16 : 10),
                      let scalar = Unicode.Scalar(code) else { continue }
                text = (text as NSString).replacingCharacters(in: match.range, with: String(Character(scalar)))
            }
        }
        return text
    }
}

// MARK: - 规则可用性

extension LegadoExploreRule {
    /// 书源只配了搜索规则时，发现页复用搜索规则取字段
    init(search rule: LegadoSearchRule) {
        self.init()
        bookList = rule.bookList
        name = rule.name
        author = rule.author
        intro = rule.intro
        kind = rule.kind
        lastChapter = rule.lastChapter
        bookUrl = rule.bookUrl
        coverUrl = rule.coverUrl
        wordCount = rule.wordCount
    }
}
