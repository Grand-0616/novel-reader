//
//  HTMLParser.swift
//  NovelReader
//
// 轻量 HTML 处理：HTML -> 纯文本、链接/标题抽取、简单 CSS 选择器
//  只依赖 Foundation 的正则与字符串处理，无第三方库
//

import Foundation

enum HTMLParser {

    // MARK: - HTML -> 纯文本

    /// 把 HTML 转成可读纯文本，保留段落换行
    static func htmlToPlainText(_ html: String) -> String {
        var s = html

        // 去掉 script / style / head
        for tag in ["script", "style", "noscript", "svg"] {
            s = s.replacingOccurrences(of: "<\(tag)[^>]*>[\\s\\S]*?</\(tag)>", with: "",
                                       options: [.regularExpression, .caseInsensitive])
        }
        s = s.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)

        // 块级标签转换行
        let blockTags = ["p", "div", "br", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6",
                         "section", "article", "blockquote", "dd", "dt", "table", "ul", "ol", "hr"]
        for tag in blockTags {
            s = s.replacingOccurrences(of: "</?\(tag)[^>]*>", with: "\n",
                                       options: [.regularExpression, .caseInsensitive])
        }

        // 去掉剩余标签
        s = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)

        // 实体解码
        s = decodeEntities(s)

        // 清理
        s = s.replacingOccurrences(of: "\r\n", with: "\n")
        s = s.replacingOccurrences(of: "[\\t ]+\n", with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression)

        let lines = s.components(separatedBy: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        var out: [String] = []
        for l in lines {
            if l.isEmpty {
                if out.last?.isEmpty == true { continue }
                out.append("")
            } else {
                out.append(l)
            }
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// HTML 实体解码
    static func decodeEntities(_ s: String) -> String {
        var out = s
        let named: [String: String] = [
            "nbsp": " ", "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
            "hellip": "…", "mdash": "—", "ndash": "–", "ldquo": "“", "rdquo": "”",
            "lsquo": "‘", "rsquo": "’", "middot": "·", "times": "×", "copy": "©",
            "reg": "®", "trade": "™", "bull": "•", "emsp": " ", "ensp": " ", "thinsp": " ",
        ]
        // 命名实体
        if let re = try? NSRegularExpression(pattern: #"&([a-zA-Z]{2,10});"#) {
            let ns = out as NSString
            var result = ""
            var last = 0
            re.enumerateMatches(in: out, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                guard let m, m.numberOfRanges > 1 else { return }
                result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let name = ns.substring(with: m.range(at: 1)).lowercased()
                result += named[name] ?? ns.substring(with: m.range)
                last = m.range.location + m.range.length
            }
            result += ns.substring(from: last)
            out = result
        }
        // 数字实体
        if let re = try? NSRegularExpression(pattern: #"&#(x?)([0-9a-fA-F]{1,6});"#) {
            let ns = out as NSString
            var result = ""
            var last = 0
            re.enumerateMatches(in: out, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
                guard let m, m.numberOfRanges > 2 else { return }
                result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let isHex = ns.substring(with: m.range(at: 1)) == "x"
                let numStr = ns.substring(with: m.range(at: 2))
                if let code = UInt32(numStr, radix: isHex ? 16 : 10), let scalar = Unicode.Scalar(code) {
                    result.append(Character(scalar))
                } else {
                    result += ns.substring(with: m.range)
                }
                last = m.range.location + m.range.length
            }
            result += ns.substring(from: last)
            out = result
        }
        return out
    }

    // MARK: - 正则抽取

    /// 抽取所有匹配正则的内容
    static func matches(_ pattern: String, in text: String, options: NSRegularExpression.Options = [.caseInsensitive, .dotMatchesLineSeparators]) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let ns = text as NSString
        var out: [String] = []
        re.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m else { return }
            if m.numberOfRanges > 1 {
                out.append(ns.substring(with: m.range(at: 1)))
            } else {
                out.append(ns.substring(with: m.range))
            }
        }
        return out
    }

    static func firstMatch(_ pattern: String, in text: String, options: NSRegularExpression.Options = [.caseInsensitive, .dotMatchesLineSeparators]) -> String? {
        matches(pattern, in: text, options: options).first
    }

    static func attrValue(_ tag: String, _ name: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: #"\b\#(name)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+))"#,
                                                options: [.caseInsensitive]) else { return nil }
        let ns = tag as NSString
        guard let m = re.firstMatch(in: tag, range: NSRange(location: 0, length: ns.length)) else { return nil }
        for i in 1..<m.numberOfRanges where m.range(at: i).location != NSNotFound {
            return ns.substring(with: m.range(at: i))
        }
        return nil
    }

    /// 抽取页面里所有 <a href> 文本与链接
    static func anchors(in html: String) -> [(href: String, text: String, html: String)] {
        guard let re = try? NSRegularExpression(pattern: #"<a\b([^>]*)>([\s\S]*?)</a>"#,
                                                options: [.caseInsensitive]) else { return [] }
        let ns = html as NSString
        var out: [(String, String, String)] = []
        re.enumerateMatches(in: html, range: NSRange(location: 0, length: ns.length)) { m, _, _ in
            guard let m, m.numberOfRanges > 2 else { return }
            let tag = ns.substring(with: m.range)
            let inner = ns.substring(with: m.range(at: 2))
            if let href = attrValue(tag, "href") {
                out.append((href, htmlToPlainText(inner).trimmingCharacters(in: .whitespaces), m.range.length > 0 ? tag : ""))
            }
        }
        return out
    }

    /// 粗粒度取 <title>
    static func pageTitle(_ html: String) -> String? {
        guard let raw = firstMatch(#"<title[^>]*>([\s\S]*?)</title>"#, in: html) else { return nil }
        let text = htmlToPlainText(raw).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

// MARK: - String 便捷

extension String {
    func strippedHTML() -> String {
        HTMLParser.htmlToPlainText(self)
    }
}
