//
//  SourceRuleEngine.swift
//  NovelReader
//
//  规则书源引擎：CSS 选择器（支持基础语法）与 XPath 兜底
//  规则字符串写法：
//    "div#content"                 -> 取 id 为 content 的 div 的文本
//    "div.content p"               -> 后代选择器
//    "class:entry-title"           -> class 简写
//    "id:list a"                   -> id 简写
//    "//div[@id='list']//a"        -> XPath（简化实现）
//    "@attr:href"                  -> 取属性
//

import Foundation

// MARK: - 选择器

struct CSSSelector {
    var tag: String?          // 标签名，nil 表示任意
    var id: String?
    var classes: [String] = []
    var attrEquals: [(String, String)] = []

    var specificity: Int { (tag != nil ? 1 : 0) + (id != nil ? 100 : 0) + classes.count * 10 }
}

struct CSSRule {
    var parts: [CSSSelector]   // 后代链

    /// 解析 "div#id.cls > a" 形式（简化为后代匹配，> 与空格同义）
    static func parse(_ raw: String) -> CSSRule? {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return nil }
        let tokens = s
            .replacingOccurrences(of: ">", with: " ")
            .split(separator: " ")
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        var parts: [CSSSelector] = []
        for token in tokens {
            var sel = CSSSelector()
            var buf = ""
            var mode: Character = "t"   // t=tag, i=id, c=class
            for ch in token {
                if ch == "#" || ch == "." {
                    if !buf.isEmpty { apply(&sel, buf, mode) }
                    buf = ""
                    mode = (ch == "#") ? "i" : "c"
                } else if ch == "[" {
                    if !buf.isEmpty { apply(&sel, buf, mode) }
                    buf = ""
                    mode = "["
                } else if ch == "]" && mode == "[" {
                    let pair = buf.split(separator: "=").map(String.init)
                    if pair.count == 2 {
                        let val = pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                        sel.attrEquals.append((pair[0], val))
                    }
                    buf = ""
                    mode = "t"
                } else {
                    buf.append(ch)
                }
            }
            if !buf.isEmpty && mode != "[" { apply(&sel, buf, mode) }
            parts.append(sel)
        }
        return CSSRule(parts: parts)
    }

    private static func apply(_ sel: inout CSSSelector, _ value: String, _ mode: Character) {
        switch mode {
        case "i": sel.id = value
        case "c": sel.classes.append(value)
        default:  sel.tag = value.lowercased() == "*" ? nil : value.lowercased()
        }
    }
}

// MARK: - 简化 DOM

final class DOMNode {
    let tag: String
    let attributes: [String: String]
    let rawOpenTag: String
    weak var parent: DOMNode?
    var children: [DOMNode] = []
    var textFragments: [String] = []

    init(tag: String, attributes: [String: String], rawOpenTag: String) {
        self.tag = tag
        self.attributes = attributes
        self.rawOpenTag = rawOpenTag
    }

    var classList: [String] {
        (attributes["class"] ?? "").split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" }).map(String.init)
    }

    var text: String {
        var parts = textFragments
        for c in children { parts.append(c.text) }
        return HTMLParser.decodeEntities(parts.joined()).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var html: String {
        var out = "<\(tag)"
        for (k, v) in attributes { out += " \(k)=\"\(v)\"" }
        out += ">"
        out += textFragments.joined()
        for c in children { out += c.html }
        out += "</\(tag)>"
        return out
    }

    var innerText: String { text }

    func matches(_ sel: CSSSelector) -> Bool {
        if let t = sel.tag, t != tag { return false }
        if let id = sel.id, attributes["id"] != id { return false }
        if !sel.classes.isEmpty {
            let cl = classList
            for c in sel.classes where !cl.contains(c) { return false }
        }
        for (k, v) in sel.attrEquals where attributes[k] != v { return false }
        return true
    }

    /// 后代查找
    func descendants() -> [DOMNode] {
        var out: [DOMNode] = []
        for c in children {
            out.append(c)
            out.append(contentsOf: c.descendants())
        }
        return out
    }

    func select(_ rule: CSSRule) -> [DOMNode] {
        var current: [DOMNode] = [self]
        for sel in rule.parts {
            var next: [DOMNode] = []
            for node in current {
                next.append(contentsOf: node.descendants().filter { $0.matches(sel) })
            }
            // 去重（同一节点可能被多个祖先命中）
            var seen = Set<ObjectIdentifier>()
            var unique: [DOMNode] = []
            for n in next where !seen.contains(ObjectIdentifier(n)) {
                seen.insert(ObjectIdentifier(n))
                unique.append(n)
            }
            current = unique
            if current.isEmpty { return [] }
        }
        return current
    }
}

// MARK: - HTML 解析器（容错栈式）

enum LightHTMLParser {
    static let voidTags: Set<String> = ["br", "img", "hr", "meta", "link", "input", "area", "base",
                                        "col", "embed", "param", "source", "track", "wbr"]

    static func parse(_ html: String) -> DOMNode {
        let root = DOMNode(tag: "#root", attributes: [:], rawOpenTag: "")
        var stack: [DOMNode] = [root]

        var i = html.startIndex
        var textBuf = ""
        let n = html.count
        var guardCount = 0

        while i < html.endIndex && guardCount < 5_000_000 {
            guardCount += 1
            if html[i] == "<" {
                // 注释
                if html[i...].hasPrefix("<!--") {
                    guard let end = html.range(of: "-->", range: i..<html.endIndex) else { break }
                    i = end.upperBound
                    continue
                }
                // script/style 整体跳过
                if let closing = html[i...].range(of: ">") {
                    let tagContent = String(html[html.index(after: i)..<closing.lowerBound])
                    let tagName = tagContent.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" || $0 == "/" })
                        .first.map(String.init)?.lowercased() ?? ""
                    if tagName == "script" || tagName == "style" {
                        if let endRange = html.range(of: "</\(tagName)", options: .caseInsensitive,
                                                     range: closing.upperBound..<html.endIndex) {
                            if !textBuf.isEmpty {
                                stack.last?.textFragments.append(textBuf)
                                textBuf = ""
                            }
                            i = endRange.lowerBound
                            if let c = html[i...].range(of: ">") { i = c.upperBound }
                            continue
                        }
                    }

                    if !textBuf.isEmpty {
                        stack.last?.textFragments.append(textBuf)
                        textBuf = ""
                    }

                    let rawTag = String(html[i...closing.lowerBound]) + ">"
                    let isClosing = tagContent.hasPrefix("/") || tagContent.hasPrefix(" ")
                    let selfClosing = tagContent.hasSuffix("/")

                    if isClosing {
                        let name = tagName
                        if let idx = stack.lastIndex(where: { $0.tag == name }), idx > 0 {
                            stack.removeSubrange(idx..<stack.count)
                        }
                    } else if !tagName.isEmpty && tagName != "!" && tagName != "?" {
                        var attrs: [String: String] = [:]
                        if let re = try? NSRegularExpression(pattern: #"([a-zA-Z_:][-a-zA-Z0-9_:.]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#) {
                            let ns = rawTag as NSString
                            re.enumerateMatches(in: rawTag, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                                guard let m, m.numberOfRanges > 1 else { return }
                                let key = ns.substring(with: m.range(at: 1)).lowercased()
                                for k in 2..<m.numberOfRanges where m.range(at: k).location != NSNotFound {
                                    attrs[key] = ns.substring(with: m.range(at: k))
                                    break
                                }
                            }
                        }
                        let node = DOMNode(tag: tagName, attributes: attrs, rawOpenTag: rawTag)
                        node.parent = stack.last
                        stack.last?.children.append(node)
                        if !voidTags.contains(tagName) && !selfClosing {
                            stack.append(node)
                        }
                    }
                    i = closing.upperBound
                    continue
                }
            }
            textBuf.append(html[i])
            i = html.index(after: i)
            // 文本太长时定期冲刷
            if textBuf.count > 8192 {
                stack.last?.textFragments.append(textBuf)
                textBuf = ""
            }
        }
        if !textBuf.isEmpty { stack.last?.textFragments.append(textBuf) }
        return root
    }
}

// MARK: - 规则执行

enum SourceRuleEngine {

    /// 规则是否为空
    static func isEmpty(_ rule: String?) -> Bool {
        (rule ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 取第一个匹配节点的文本
    static func text(_ rule: String, in html: String) -> String? {
        let r = rule.trimmingCharacters(in: .whitespaces)
        if r.isEmpty { return nil }
        if r.hasPrefix("//") {
            return xpathText(r, in: html)
        }
        if r.hasPrefix("@") {
            // "@href" 这类纯属性规则，需要从 HTML 里直接抓属性值
            return attrText(r, in: html)
        }
        guard let css = CSSRule.parse(r) else { return nil }
        let root = LightHTMLParser.parse(html)
        return root.select(css).first?.text
    }

    /// 取所有匹配节点的文本
    static func texts(_ rule: String, in html: String) -> [String] {
        let r = rule.trimmingCharacters(in: .whitespaces)
        if r.isEmpty { return [] }
        guard let css = CSSRule.parse(r) else { return [] }
        let root = LightHTMLParser.parse(html)
        return root.select(css).map { $0.text }.filter { !$0.isEmpty }
    }

    /// 取所有匹配节点
    static func nodes(_ rule: String, in html: String) -> [DOMNode] {
        guard let css = CSSRule.parse(rule) else { return [] }
        let root = LightHTMLParser.parse(html)
        return root.select(css)
    }

    /// 取第一个匹配节点的属性文本
    static func attr(_ rule: String, in node: DOMNode) -> String? {
        // 形如 "@href" 或 "@data-id"
        var name = rule
        if name.hasPrefix("@") { name.removeFirst() }
        if name.hasPrefix("attr:") { name = String(name.dropFirst(5)) }
        guard !name.isEmpty else { return nil }
        return node.attributes[name.lowercased()]
    }

    /// 从 HTML 直接取属性：规则形如 "a.title@href" 或 "@href"
    static func attrText(_ rule: String, in html: String) -> String? {
        let r = rule.trimmingCharacters(in: .whitespaces)
        if r.hasPrefix("@") {
            // 直接在根节点上找
            let name = String(r.dropFirst())
            if let m = HTMLParser.firstMatch(#"\b\#(name)\s*=\s*(?:"([^"]*)"|'([^']*)')"#, in: html) {
                return m
            }
            return nil
        }
        let parts = r.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return text(r, in: html) }
        let cssPart = parts[0]
        let attrName = parts[1]
        let root = LightHTMLParser.parse(html)
        if let css = CSSRule.parse(cssPart) {
            if let first = root.select(css).first {
                return first.attributes[attrName.lowercased()]
            }
        }
        return nil
    }

    /// 简化 XPath：支持 //tag、//tag[@attr='v']、//*[@id='x']、末尾 //text()
    static func xpathNodes(_ xpath: String, in html: String) -> [DOMNode] {
        let root = LightHTMLParser.parse(html)
        var expr = xpath
        if expr.hasSuffix("/text()") {
            expr = String(expr.dropLast(7))
        }
        // 按 // 分段
        let segments = expr.components(separatedBy: "//").filter { !$0.isEmpty }
        var current: [DOMNode] = [root]
        for seg in segments {
            var tag: String? = nil
            var pred: (String, String)? = nil

            if let bracketStart = seg.firstIndex(of: "[") {
                let tagPart = String(seg[seg.startIndex..<bracketStart]).trimmingCharacters(in: .whitespaces)
                let predPart = String(seg[bracketStart...])
                    .trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
                tag = (tagPart == "*" || tagPart.isEmpty) ? nil : tagPart.lowercased()
                // @attr='value'
                if let re = try? NSRegularExpression(pattern: #"@([\w-]+)\s*=\s*['"]([^'"]*)['"]"#),
                   let m = re.firstMatch(in: predPart, range: NSRange(location: 0, length: (predPart as NSString).length)),
                   m.numberOfRanges > 2 {
                    pred = ((predPart as NSString).substring(with: m.range(at: 1)).lowercased(),
                            (predPart as NSString).substring(with: m.range(at: 2)))
                }
            } else {
                let tagPart = seg.trimmingCharacters(in: .whitespaces)
                // 带 class 的写法 div.content
                if let dot = tagPart.firstIndex(of: ".") {
                    let tagName = String(tagPart[tagPart.startIndex..<dot]).lowercased()
                    let cls = String(tagPart[tagPart.index(after: dot)...])
                    var next: [DOMNode] = []
                    for node in current {
                        next.append(contentsOf: node.descendants().filter {
                            ($0.tag == tagName || tagName.isEmpty) && $0.classList.contains(cls)
                        })
                    }
                    current = next
                    continue
                }
                tag = tagPart.isEmpty ? nil : tagPart.lowercased()
            }

            var next: [DOMNode] = []
            for node in current {
                var candidates = node.descendants()
                if let tag { candidates = candidates.filter { $0.tag == tag } }
                if let pred { candidates = candidates.filter { $0.attributes[pred.0] == pred.1 } }
                next.append(contentsOf: candidates)
            }
            var seen = Set<ObjectIdentifier>()
            current = next.filter { seen.insert(ObjectIdentifier($0)).inserted }
            if current.isEmpty { return [] }
        }
        return current
    }

    static func xpathText(_ xpath: String, in html: String) -> String? {
        xpathNodes(xpath, in: html).first?.text
    }

    /// 清理正文：去掉指定坏块（如广告 div）
    static func cleanContent(_ html: String, removeSelectors: [String]) -> String {
        var body = html
        if !removeSelectors.isEmpty {
            let root = LightHTMLParser.parse(body)
            var removeIDs = Set<ObjectIdentifier>()
            for sel in removeSelectors {
                guard let css = CSSRule.parse(sel) else { continue }
                for node in root.select(css) {
                    removeIDs.insert(ObjectIdentifier(node))
                    node.children.removeAll()
                    node.textFragments.removeAll()
                }
            }
            if !removeIDs.isEmpty {
                body = root.html
            }
        }
        return HTMLParser.htmlToPlainText(body)
    }

    /// 从正文 HTML 按规则抽取干净文本
    static func extractContent(html: String, contentSelector: String, removeSelectors: [String]) -> String {
        let target: String
        if contentSelector.hasPrefix("//") {
            let nodes = xpathNodes(contentSelector, in: html)
            target = nodes.first?.html ?? ""
        } else if let css = CSSRule.parse(contentSelector) {
            let root = LightHTMLParser.parse(html)
            if let node = root.select(css).first {
                target = node.html
            } else {
                target = html
            }
        } else {
            target = html
        }
        let text = cleanContent(target, removeSelectors: removeSelectors)
        return TextSanitizer.normalizeBody(text)
    }
}
