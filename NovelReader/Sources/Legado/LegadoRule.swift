//
//  LegadoRule.swift
//  NovelReader
//
//  Legado 规则执行器。
//
//  Legado 的规则不是单一语法，而是一套管道 DSL。一条规则长这样：
//
//      @css:div#list dd@css:a@href
//      @json:$.data.list[*]@json:name
//      @xpath://div[@id='content']//text()
//      class.abc@text##广告##  ##
//      {{$.data.items}} 或 {{java.ajax(...)}}
//
//  求值顺序（与 Legado 一致）：
//      1. 拆 `||`（左边失败才用右边）
//      2. 拆 `&&`（在左边结果上继续跑右边）
//      3. 处理 `-` 排除前缀
//      4. 展开 `{{ }}` 模板（变量 / JSON / JS）
//      5. 按 `@` 切段，逐段应用（css / json / xpath / js / 属性 / 正则）
//
//  不支持的语法会在结果里返回 nil，由上层判定为"规则未命中"，
//  而不是抛错打断整条链路 —— 这和 Legado 的容错行为一致。
//

import Foundation

// MARK: - 规则作用对象

/// 规则当前的求值对象。HTML 走 DOM，JSON 走字典树，纯文本直接切。
enum LegadoContent {
    case html(String)
    case json(Any)
    case text(String)

    var stringValue: String {
        switch self {
        case .html(let s), .text(let s): return s
        case .json(let v):               return LegadoJSON.stringify(v)
        }
    }

    /// JSON 内容的原始值；非 JSON 内容返回 nil
    var jsonValue: Any? {
        if case .json(let v) = self { return v }
        return nil
    }
}

// MARK: - 求值上下文

/// 一次解析流程里的可变状态：变量表、站点根、当前页。
final class LegadoRuleContext {
    /// 书源根地址（用于相对 URL 补全）
    let sourceBaseURL: URL?
    /// 当前正在解析的页面地址
    var currentURL: URL?
    /// @put / java.put 存下来的变量
    var variables: [String: String] = [:]
    /// 书源级公共 JS
    var jsLib: String?
    /// JS 求值器（由 LegadoJSRuntime 注入，避免本文件依赖 JavaScriptCore）
    var jsEvaluator: ((String, LegadoRuleContext) -> String?)?

    init(sourceURL: String, currentURL: URL? = nil) {
        self.sourceBaseURL = URL(string: sourceURL)
        self.currentURL = currentURL
    }

    /// 把相对地址补成绝对地址
    func absolute(_ raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return s }
        if s.hasPrefix("http://") || s.hasPrefix("https://") { return s }
        if s.hasPrefix("//") { return "https:" + s }
        if s.hasPrefix("data:") || s.hasPrefix("blob:") { return s }

        let base = currentURL ?? sourceBaseURL
        guard let base else { return s }

        if s.hasPrefix("/") {
            var comps = URLComponents(url: base, resolvingAgainstBaseURL: false)
            comps?.path = s
            comps?.query = nil
            comps?.fragment = nil
            return comps?.url?.absoluteString ?? s
        }
        return URL(string: s, relativeTo: base)?.absoluteString ?? s
    }
}

// MARK: - JSON 小工具

enum LegadoJSON {
    /// 把任意 JSON 值转成字符串（字符串原样返回，数字去掉 .0）
    static func stringify(_ v: Any) -> String {
        switch v {
        case let s as String:            return s
        case let n as NSNumber:
            // JSON 解析出来的 Bool 也是 NSNumber，用 CFTypeID 区分
            if CFGetTypeID(n) == CFBooleanGetTypeID() {
                return n.boolValue ? "true" : "false"
            }
            let d = n.doubleValue
            if d == d.rounded() && abs(d) < 1e15 {
                return String(Int64(d))
            }
            return n.stringValue
        case is NSNull:                  return ""
        case let a as [Any]:             return a.map { stringify($0) }.joined(separator: "\n")
        case let d as [String: Any]:
            if let data = try? JSONSerialization.data(withJSONObject: d, options: [.fragmentsAllowed]),
               let s = String(data: data, encoding: .utf8) {
                return s
            }
            return ""
        default:                         return String(describing: v)
        }
    }

    static func parse(_ text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed, .allowFragments])
    }

    /// 简化 JSONPath：`$`、`.key`、`[n]`、`[*]`、`.*`、`..key`（递归下降）
    static func query(_ path: String, in root: Any) -> [Any] {
        var expr = path.trimmingCharacters(in: .whitespaces)
        if expr.hasPrefix("$") { expr.removeFirst() }
        guard !expr.isEmpty else { return [root] }

        var current: [Any] = [root]
        var i = expr.startIndex

        while i < expr.endIndex {
            if expr[i] == "." {
                // 递归下降 `..key`
                if expr.index(after: i) < expr.endIndex, expr[expr.index(after: i)] == "." {
                    let after = expr.index(i, offsetBy: 2)
                    let key = readIdent(expr, from: after)
                    guard !key.isEmpty else { return [] }
                    var out: [Any] = []
                    for node in current { collectRecursive(node, key: key, into: &out) }
                    current = out
                    i = expr.index(after, offsetBy: key.count)
                } else {
                    let after = expr.index(after: i)
                    if after < expr.endIndex, expr[after] == "*" {
                        current = current.flatMap { expandAll($0) }
                        i = expr.index(after: after)
                    } else {
                        let key = readIdent(expr, from: after)
                        if key.isEmpty {
                            i = after
                        } else {
                            current = current.compactMap { child($0, key: key) }
                            i = expr.index(after, offsetBy: key.count)
                        }
                    }
                }
            } else if expr[i] == "[" {
                guard let close = expr[i...].firstIndex(of: "]") else { return [] }
                let inner = String(expr[expr.index(after: i)..<close]).trimmingCharacters(in: .whitespaces)
                if inner == "*" {
                    current = current.flatMap { expandAll($0) }
                } else if let idx = Int(inner) {
                    current = current.compactMap { node -> Any? in
                        guard let arr = node as? [Any], idx >= 0, idx < arr.count else { return nil }
                        return arr[idx]
                    }
                } else {
                    // ['key'] 形式
                    let key = inner.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                    current = current.compactMap { child($0, key: key) }
                }
                i = expr.index(after: close)
            } else {
                // 裸 key（不以点开头）
                let key = readIdent(expr, from: i)
                if key.isEmpty { i = expr.index(after: i); continue }
                current = current.compactMap { child($0, key: key) }
                i = expr.index(after, offsetBy: key.count)
            }

            if current.isEmpty { return [] }
        }
        return current
    }

    private static func readIdent(_ s: String, from start: String.Index) -> String {
        var out = ""
        var i = start
        while i < s.endIndex {
            let c = s[i]
            if c.isLetter || c.isNumber || c == "_" || c == "-" {
                out.append(c)
                i = s.index(after: i)
            } else {
                break
            }
        }
        return out
    }

    private static func child(_ node: Any, key: String) -> Any? {
        if let d = node as? [String: Any] { return d[key] }
        if let arr = node as? [Any] {
            // 对数组取 key 时，逐元素取再摊平（Legado 的隐式行为）
            let mapped = arr.compactMap { ($0 as? [String: Any])?[key] }
            return mapped.isEmpty ? nil : mapped
        }
        return nil
    }

    private static func expandAll(_ node: Any) -> [Any] {
        if let arr = node as? [Any] { return arr }
        if let d = node as? [String: Any] { return d.values.map { $0 } }
        return [node]
    }

    private static func collectRecursive(_ node: Any, key: String, into out: inout [Any]) {
        if let d = node as? [String: Any] {
            if let v = d[key] { out.append(v) }
            for (_, v) in d { collectRecursive(v, key: key, into: &out) }
        } else if let arr = node as? [Any] {
            for v in arr { collectRecursive(v, key: key, into: &out) }
        }
    }
}

// MARK: - 规则执行器

enum LegadoRule {

    /// 主入口：对给定内容求值一条规则
    static func evaluate(_ rawRule: String?,
                         on content: LegadoContent,
                         ctx: LegadoRuleContext) -> String? {
        guard let rawRule else { return nil }
        let rule = rawRule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rule.isEmpty, rule != "-" else { return nil }

        // 1. `||`：左边有结果就用左边
        if let orParts = splitTopLevel(rule, separator: "||"), orParts.count > 1 {
            for part in orParts {
                if let r = evaluate(part, on: content, ctx: ctx), !r.isEmpty { return r }
            }
            return nil
        }

        // 2. `&&`：在左边结果上继续跑右边
        if let andParts = splitTopLevel(rule, separator: "&&"), andParts.count > 1 {
            var carry: String? = nil
            var currentContent = content
            for part in andParts {
                let trimmed = part.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { continue }
                guard let r = evaluate(trimmed, on: currentContent, ctx: ctx) else { return nil }
                carry = r
                currentContent = .text(r)
            }
            return carry
        }

        // 3. `-` 排除：`-规则` 表示"匹配到就整体判失败"
        if rule.hasPrefix("-") {
            let inner = String(rule.dropFirst())
            let hit = evaluate(inner, on: content, ctx: ctx)
            return (hit == nil || hit!.isEmpty) ? nil : nil
        }

        // 4. 纯正则规则（不依赖选择器）
        if rule.hasPrefix("##") || rule.contains("##") {
            // 只有形如 `##re##rep` 且没有其它前缀时才整体当正则
            let noPrefix = !(rule.hasPrefix("@css:") || rule.hasPrefix("@json:")
                             || rule.hasPrefix("@xpath:") || rule.hasPrefix("@js:"))
            if noPrefix {
                return applyRegex(rule, to: content.stringValue)
            }
        }

        // 5. `{{ }}` 模板
        if rule.contains("{{") {
            return expandTemplate(rule, on: content, ctx: ctx)
        }

        // 6. `@` 分段管道
        if rule.hasPrefix("@") {
            return runPipeline(rule, on: content, ctx: ctx)
        }

        // 7. `$.` 开头视作 JSON 路径
        if rule.hasPrefix("$") {
            return runJSON(rule, on: content)
        }

        // 8. `//` 或 `/` 开头视作 XPath
        if rule.hasPrefix("//") || rule.hasPrefix("/") {
            return runXPath(rule, on: content)
        }

        // 9. 默认当 CSS 选择器（Legado 默认行为）
        return runCSS(rule, on: content)
    }

    /// 返回规则匹配到的 HTML 节点集合。
    /// `evaluate` 只给一个字符串，但「书籍列表」「章节目录」这类规则需要拿到所有节点
    /// 再逐个取字段，所以单开一个入口。非 CSS 规则（json/xpath/js）返回空，
    /// 由上层按内容类型另走分支。
    static func selectNodes(_ rawRule: String?,
                            in content: LegadoContent,
                            ctx: LegadoRuleContext) -> [DOMNode] {
        guard let rawRule else { return [] }
        let trimmed = rawRule.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "-" else { return [] }

        // `||`：取第一个有结果的分支
        if let orParts = splitTopLevel(trimmed, separator: "||"), orParts.count > 1 {
            for part in orParts {
                let nodes = selectNodes(part, in: content, ctx: ctx)
                if !nodes.isEmpty { return nodes }
            }
            return []
        }

        var rule = trimmed
        if rule.hasPrefix("@css:") {
            rule = String(rule.dropFirst(5))
        } else if rule.hasPrefix("@") || rule.hasPrefix("$") || rule.hasPrefix("/") {
            // 非 CSS 规则交给 evaluate，结果包成单个文本节点
            if let s = evaluate(rule, on: content, ctx: ctx),
               !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return [textNode(s)]
            }
            return []
        }

        let (base, pseudos) = extractPseudos(rule)
        let selector = base.isEmpty ? rule : base
        let (nodes, _) = selectCSS(selector, in: content)
        return applyPseudos(nodes, pseudos)
    }

    /// 把纯文本包成 DOMNode，让上层用同一套代码取值
    static func textNode(_ s: String) -> DOMNode {
        let node = DOMNode(tag: "#text", attributes: [:], rawOpenTag: "")
        node.textFragments = [s]
        return node
    }

    // MARK: - 顶层切分（不切括号/引号内的分隔符）

    static func splitTopLevel(_ s: String, separator: String) -> [String]? {
        guard s.contains(separator) else { return nil }
        var parts: [String] = []
        var depth = 0
        var inSingle = false
        var inDouble = false
        var current = ""
        var i = s.startIndex

        while i < s.endIndex {
            let c = s[i]
            if c == "'" && !inDouble { inSingle.toggle() }
            else if c == "\"" && !inSingle { inDouble.toggle() }
            else if !inSingle && !inDouble {
                if c == "(" || c == "[" || c == "{" { depth += 1 }
                else if c == ")" || c == "]" || c == "}" { depth -= 1 }
                else if depth == 0, s[i...].hasPrefix(separator) {
                    parts.append(current)
                    current = ""
                    i = s.index(i, offsetBy: separator.count)
                    continue
                }
            }
            current.append(c)
            i = s.index(after: i)
        }
        parts.append(current)
        return parts
    }

    // MARK: - 模板展开

    static func expandTemplate(_ rule: String,
                               on content: LegadoContent,
                               ctx: LegadoRuleContext) -> String? {
        var result = ""
        var i = rule.startIndex

        while i < rule.endIndex {
            if rule[i...].hasPrefix("{{"),
               let close = rule[i...].range(of: "}}") {
                let expr = String(rule[rule.index(i, offsetBy: 2)..<close.lowerBound])
                    .trimmingCharacters(in: .whitespaces)
                let value = evalTemplateExpr(expr, on: content, ctx: ctx) ?? ""
                result += value
                i = close.upperBound
            } else {
                result.append(rule[i])
                i = rule.index(after: i)
            }
        }

        // 整个规则就是一个 {{ }} 时，返回求值结果本身
        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if rule.hasPrefix("{{"), rule.hasSuffix("}}"),
           rule.components(separatedBy: "{{").count == 2 {
            return trimmed
        }
        // 模板展开后可能还带选择器后缀，继续跑管道
        if trimmed != rule, trimmed.hasPrefix("@") {
            return runPipeline(trimmed, on: content, ctx: ctx)
        }
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func evalTemplateExpr(_ expr: String,
                                         on content: LegadoContent,
                                         ctx: LegadoRuleContext) -> String? {
        guard !expr.isEmpty else { return nil }

        // {{$.path}} —— 在当前 JSON 上取值
        if expr.hasPrefix("$") {
            if case .json(let root) = content {
                let vals = LegadoJSON.query(expr, in: root)
                if vals.isEmpty { return nil }
                return LegadoJSON.stringify(vals.count == 1 ? vals[0] : vals)
            }
            if let parsed = LegadoJSON.parse(content.stringValue) {
                let vals = LegadoJSON.query(expr, in: parsed)
                if vals.isEmpty { return nil }
                return LegadoJSON.stringify(vals.count == 1 ? vals[0] : vals)
            }
            return nil
        }

        // {{key}} / {{page}} 等简单变量
        if expr.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) {
            return ctx.variables[expr]
        }

        // 其余交给 JS
        return ctx.jsEvaluator?(expr, ctx)
    }

    // MARK: - @ 管道

    private static func runPipeline(_ rule: String,
                                    on content: LegadoContent,
                                    ctx: LegadoRuleContext) -> String? {
        // 按 `@` 切段，忽略空段；首段（前缀）必须为空
        var segments: [String] = []
        var current = ""
        var i = rule.startIndex
        var depth = 0
        while i < rule.endIndex {
            let c = rule[i]
            if c == "(" || c == "[" || c == "{" { depth += 1 }
            else if c == ")" || c == "]" || c == "}" { depth -= 1 }
            if c == "@" && depth == 0 {
                segments.append(current)
                current = ""
            } else {
                current.append(c)
            }
            i = rule.index(after: i)
        }
        segments.append(current)

        var node: Any? = nil          // CSS 选中后的节点
        var stringValue: String? = nil
        var jsonValue: Any? = nil
        var working = content

        for seg in segments {
            let s = seg.trimmingCharacters(in: .whitespaces)
            if s.isEmpty { continue }

            if s.hasPrefix("css:") {
                let selector = String(s.dropFirst(4))
                let (nodes, isHTML) = selectCSS(selector, in: working)
                if isHTML {
                    if nodes.isEmpty { return nil }
                    node = nodes.first
                    stringValue = nodes.first?.html
                    working = .html(nodes.first?.html ?? "")
                } else {
                    if nodes.isEmpty { return nil }
                    stringValue = nodes.first?.text
                    working = .text(stringValue ?? "")
                }
            } else if s.hasPrefix("json:") {
                let path = String(s.dropFirst(5))
                let root: Any
                if let j = jsonValue { root = j }
                else if case .json(let j) = working { root = j }
                else if let parsed = LegadoJSON.parse(working.stringValue) { root = parsed }
                else { return nil }

                let vals = LegadoJSON.query(path, in: root)
                if vals.isEmpty { return nil }
                jsonValue = vals.count == 1 ? vals[0] : vals
                stringValue = LegadoJSON.stringify(jsonValue!)
                working = .text(stringValue!)
            } else if s.hasPrefix("xpath:") {
                let xp = String(s.dropFirst(6))
                guard case .html(let html) = working else { return nil }
                let nodes = SourceRuleEngine.xpathNodes(xp, in: html)
                if nodes.isEmpty { return nil }
                node = nodes.first
                stringValue = nodes.first?.text
                working = .text(stringValue ?? "")
            } else if s.hasPrefix("js:") {
                let code = String(s.dropFirst(3))
                ctx.variables["result"] = stringValue ?? working.stringValue
                guard let out = ctx.jsEvaluator?(code, ctx) else { return nil }
                stringValue = out
                jsonValue = LegadoJSON.parse(out)
                working = .text(out)
            } else if s.hasPrefix("get:") {
                let key = String(s.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                guard let v = ctx.variables[key] else { return nil }
                stringValue = v
                working = .text(v)
            } else if s.hasPrefix("put:") {
                // @put:{key:rule} —— 求值 rule 并存进 key，不改变当前值
                let body = String(s.dropFirst(4)).trimmingCharacters(in: .whitespaces)
                applyPut(body, on: working, ctx: ctx)
            } else {
                // 属性 / 文本操作符
                guard let result = applyOperator(s, node: node, working: working) else { return nil }
                stringValue = result
                working = .text(result)
            }
        }

        guard var out = stringValue else { return nil }

        // 末尾带正则：`@css:a@href##pattern##rep`
        if out.contains("##"), !rule.contains("@js:") {
            if let replaced = applyRegex(out, to: out) { out = replaced }
        }
        return out
    }

    private static func applyPut(_ body: String,
                                 on content: LegadoContent,
                                 ctx: LegadoRuleContext) {
        // 形如 {key:"规则"} 或 {key:规则}
        var s = body
        if s.hasPrefix("{") { s.removeFirst() }
        if s.hasSuffix("}") { s.removeLast() }

        for pair in s.split(separator: ",") {
            let comps = pair.split(separator: ":", maxSplits: 1)
            guard comps.count == 2 else { continue }
            let key = comps[0].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            var rule = comps[1].trimmingCharacters(in: .whitespaces)
            rule = rule.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if let v = evaluate(rule, on: content, ctx: ctx) {
                ctx.variables[key] = v
            }
        }
    }

    // MARK: - CSS

    /// 返回 (匹配节点, 是否按 HTML 语义)
    private static func selectCSS(_ selector: String, in content: LegadoContent) -> ([DOMNode], Bool) {
        let html: String
        switch content {
        case .html(let s): html = s
        case .text(let s): html = s
        case .json(let v): html = LegadoJSON.stringify(v)
        }

        var sel = selector.trimmingCharacters(in: .whitespaces)
        if sel.isEmpty { sel = "*" }

        // 剥离 :eq(n) / :first / :last / :odd / :even / :lt / :gt / :contains
        let (cleanSelector, pseudos) = extractPseudos(sel)
        sel = cleanSelector.isEmpty ? "*" : cleanSelector

        guard let rule = CSSRule.parse(sel) else { return ([], true) }
        let root = LightHTMLParser.parse(html)
        var nodes = root.select(rule)
        nodes = applyPseudos(nodes, pseudos)
        return (nodes, true)
    }

    private enum Pseudo {
        case eq(Int)
        case lt(Int)
        case gt(Int)
        case first
        case last
        case odd
        case even
        case contains(String)
    }

    private static func extractPseudos(_ selector: String) -> (String, [Pseudo]) {
        var pseudos: [Pseudo] = []
        var out = ""
        var i = selector.startIndex

        while i < selector.endIndex {
            if selector[i] == ":" {
                let rest = selector[i...]
                // 找出伪类名
                var j = selector.index(after: i)
                var name = ""
                while j < selector.endIndex, selector[j].isLetter {
                    name.append(selector[j])
                    j = selector.index(after: j)
                }
                var arg: String? = nil
                if j < selector.endIndex, selector[j] == "(",
                   let close = selector[j...].firstIndex(of: ")") {
                    arg = String(selector[selector.index(after: j)..<close])
                    j = selector.index(after: close)
                }

                switch name.lowercased() {
                case "eq":       if let a = arg, let n = Int(a.trimmingCharacters(in: .whitespaces)) { pseudos.append(.eq(n)) }
                case "lt":       if let a = arg, let n = Int(a.trimmingCharacters(in: .whitespaces)) { pseudos.append(.lt(n)) }
                case "gt":       if let a = arg, let n = Int(a.trimmingCharacters(in: .whitespaces)) { pseudos.append(.gt(n)) }
                case "first":    pseudos.append(.first)
                case "last":     pseudos.append(.last)
                case "odd":      pseudos.append(.odd)
                case "even":     pseudos.append(.even)
                case "contains": if let a = arg { pseudos.append(.contains(a.trimmingCharacters(in: CharacterSet(charactersIn: " \"'")))) }
                default:
                    // 不认识的伪类原样保留（交给 CSSRule 当标签名的一部分，通常匹配不到）
                    out.append(selector[i..<j])
                    i = j
                    continue
                }
                i = j
            } else {
                out.append(selector[i])
                i = selector.index(after: i)
            }
        }
        return (out, pseudos)
    }

    private static func applyPseudos(_ nodes: [DOMNode], _ pseudos: [Pseudo]) -> [DOMNode] {
        var out = nodes
        for p in pseudos {
            switch p {
            case .eq(let n):
                out = (n >= 0 && n < out.count) ? [out[n]] : []
            case .lt(let n):
                out = Array(out.prefix(max(0, n)))
            case .gt(let n):
                out = n + 1 < out.count ? Array(out.suffix(from: n + 1)) : []
            case .first:
                out = out.first.map { [$0] } ?? []
            case .last:
                out = out.last.map { [$0] } ?? []
            case .odd:
                out = out.enumerated().filter { $0.offset % 2 == 1 }.map { $0.element }
            case .even:
                out = out.enumerated().filter { $0.offset % 2 == 0 }.map { $0.element }
            case .contains(let s):
                out = out.filter { $0.text.contains(s) }
            }
        }
        return out
    }

    private static func runCSS(_ rule: String, on content: LegadoContent) -> String? {
        // 纯 CSS 规则可能带 `@属性` 后缀，也可能带 `##正则`
        var selector = rule
        var attr: String? = nil
        var regex: String? = nil

        if let idx = selector.firstIndex(of: "@"), idx != selector.startIndex {
            attr = String(selector[selector.index(after: idx)...]).trimmingCharacters(in: .whitespaces)
            selector = String(selector[selector.startIndex..<idx])
        }
        if let rIdx = selector.range(of: "##") {
            regex = String(selector[rIdx.lowerBound...])
            selector = String(selector[selector.startIndex..<rIdx.lowerBound])
        }

        let (nodes, _) = selectCSS(selector, in: content)
        guard let first = nodes.first else { return nil }

        var value: String
        if let attr {
            switch attr {
            case "text":      value = first.text
            case "ownText":   value = first.textFragments.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            case "textNodes": value = first.textFragments.joined(separator: "\n")
            case "html":      value = first.html
            default:
                value = first.attributes[attr.lowercased()] ?? ""
            }
        } else {
            value = first.text
        }

        if let regex, let replaced = applyRegex(regex, to: value) { value = replaced }
        return value.isEmpty ? nil : value
    }

    // MARK: - JSON

    private static func runJSON(_ path: String, on content: LegadoContent) -> String? {
        let root: Any
        switch content {
        case .json(let v): root = v
        default:
            guard let parsed = LegadoJSON.parse(content.stringValue) else { return nil }
            root = parsed
        }
        let vals = LegadoJSON.query(path, in: root)
        guard !vals.isEmpty else { return nil }
        let s = LegadoJSON.stringify(vals.count == 1 ? vals[0] : vals)
        return s.isEmpty ? nil : s
    }

    // MARK: - XPath

    private static func runXPath(_ xpath: String, on content: LegadoContent) -> String? {
        guard case .html(let html) = content else { return nil }
        var expr = xpath
        var attr: String? = nil
        if let idx = expr.range(of: "@", options: .backwards), idx.lowerBound != expr.startIndex {
            let tail = String(expr[idx.upperBound...])
            if ["href", "src", "title", "alt", "data-id"].contains(tail.lowercased()) {
                attr = tail
                expr = String(expr[expr.startIndex..<idx.lowerBound])
            }
        }
        let nodes = SourceRuleEngine.xpathNodes(expr, in: html)
        guard let first = nodes.first else { return nil }
        if let attr { return first.attributes[attr.lowercased()] }
        let t = first.text
        return t.isEmpty ? nil : t
    }

    // MARK: - 正则

    /// `##pattern##replacement` 替换；`##pattern###` 只取第一个；`##pattern` 取全部拼接
    static func applyRegex(_ spec: String, to input: String) -> String? {
        let parts = spec.components(separatedBy: "##")
        guard parts.count >= 2 else { return nil }
        let pattern = parts[1]
        guard !pattern.isEmpty else { return nil }
        let replacement = parts.count >= 3 ? parts[2] : nil

        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }
        let ns = input as NSString
        let range = NSRange(location: 0, length: ns.length)

        if let replacement {
            if replacement.isEmpty {
                // `##pattern###`：只取第一个匹配
                guard let m = re.firstMatch(in: input, range: range) else { return nil }
                return ns.substring(with: m.range)
            }
            let out = re.stringByReplacingMatches(in: input, range: range, withTemplate: replacement)
            return out
        }

        let matches = re.matches(in: input, range: range)
        guard !matches.isEmpty else { return nil }
        let picked = matches.map { ns.substring(with: $0.range) }.filter { !$0.isEmpty }
        return picked.isEmpty ? nil : picked.joined()
    }

    // MARK: - 属性 / 文本操作符

    private static func applyOperator(_ op: String,
                                      node: Any?,
                                      working: LegadoContent) -> String? {
        guard let domNode = node as? DOMNode else {
            // 没有节点时，操作符作用于当前字符串
            let s = working.stringValue
            switch op {
            case "text", "ownText", "textNodes": return s
            case "html":                          return s
            default:                              return s.isEmpty ? nil : s
            }
        }

        switch op {
        case "text":
            let t = domNode.text
            return t.isEmpty ? nil : t
        case "ownText":
            let t = domNode.textFragments.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        case "textNodes":
            let t = domNode.textFragments.joined(separator: "\n")
            return t.isEmpty ? nil : t
        case "html":
            let t = domNode.html
            return t.isEmpty ? nil : t
        default:
            return domNode.attributes[op.lowercased()]
        }
    }
}
