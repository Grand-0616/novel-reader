//
//  TextSanitizer.swift
//  NovelReader
//
//  纯算法：编码探测、全角/半角归一、广告行清洗、章节标题识别
//  无 Foundation 之外依赖，便于在 macOS 上用 swift 直接跑单测
//

import Foundation

public enum TextSanitizer {

    // MARK: - 章节标题识别

    /// 常见中文小说章节标题正则（按优先级排列，先匹配到的先用）
    private static let chapterPatterns: [String] = [
        // 【第12章】归墟 / （第12章） 标题：括号包住章节号，后面可跟标题
        #"^\s{0,4}[【（(]\s*第\s*[0-9０-９零一二三四五六七八九十百千万两]{1,12}\s*[章节回卷]\s*[】）)][^。！？；]{0,40}$"#,
        // 第123章 标题 / 第123回 / 第一百二十三节
        #"^\s{0,8}第\s*[0-9０-９零一二三四五六七八九十百千万两]{1,12}\s*[章节回卷折幕话篇](?:\s|：|:|[^。！？；\n]{0,60})$"#,
        // 正文 第十二章
        #"^\s{0,8}正文\s*第\s*[0-9零一二三四五六七八九十百千万两]{1,12}\s*[章节回][^。！？；]{0,60}$"#,
        // 卷X 第Y章
        #"^\s{0,8}[卷部]\s*[0-9零一二三四五六七八九十百千万两]{1,6}\s*第\s*[0-9零一二三四五六七八九十百千万两]{1,12}\s*[章节回][^。！？；]{0,60}$"#,
        // Chapter 12 / CHAPTER XII
        #"^\s{0,8}chapter\s*[0-9ivxlcdm]{1,8}\b.{0,80}$"#,
        // 序章 / 楔子 / 尾声 / 后记 / 番外
        #"^\s{0,8}(?:序章|序言|序|楔子|引子|前言|尾声|后记|终章|大结局|番外[一二三四五六七八九十0-9]*)\s*.{0,40}$"#
    ]
    private static let compiledChapterPatterns: [NSRegularExpression] = chapterPatterns.compactMap {
        try? NSRegularExpression(pattern: $0, options: [.caseInsensitive])
    }

    /// 判断一行是否为章节标题
    public static func isChapterTitle(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 60 else { return false }
        // 排除正文里带句号的句子
        if trimmed.contains("。") && trimmed.count > 24 { return false }
        let range = NSRange(location: 0, length: (trimmed as NSString).length)
        for re in compiledChapterPatterns {
            if re.firstMatch(in: trimmed, options: [], range: range) != nil {
                return true
            }
        }
        return false
    }

    // MARK: - 广告/垃圾行清洗

    /// 常见盗版站插入行
    private static let junkMarkers: [String] = [
        "本章未完", "请收藏本站", "请记住本书", "首发地址", "最新章节请",
        "手机阅读", "手机用户请", "百度搜索", "笔趣阁", "www.", "http://", "https://",
        "天才一秒记住", "更新最快", "无弹窗", "广告", "加入书签", "投推荐票",
        "一秒记住本站", "章节错误", "举报后维护", "内容严重缺失", "请勿开启浏览器阅读模式",
        "红色字体", "推荐一个app", "你可以用", "本站域名", "顶点小说", "书趣阁"
    ]

    /// 是否为需要丢弃的广告/导航行
    public static func isJunkLine(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return false }
        if t.count <= 2 { return false }
        let lower = t.lowercased()
        // 纯符号行
        if t.allSatisfy({ "-=_*~·—─═　 ".contains($0) }) { return true }
        for m in junkMarkers {
            if lower.contains(m.lowercased()) { return true }
        }
        return false
    }

    // MARK: - 正文归一

    /// 归一化正文：统一换行、压缩空行、去首尾空白、去行内多余空格
    public static func normalizeBody(_ raw: String) -> String {
        var s = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .replacingOccurrences(of: "\u{00a0}", with: " ")   // NBSP
            .replacingOccurrences(of: "\u{3000}", with: "  ")  // 全角空格 -> 双半角（保留缩进感）
            .replacingOccurrences(of: "\u{FEFF}", with: "")

        // 去掉控制字符（保留 \n \t）
        s = String(s.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t" || !CharacterSet.controlCharacters.contains(scalar)
        })

        var lines: [String] = []
        var blankRun = 0
        for rawLine in s.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(rawLine)
            // 行内多空格压缩，但保留行首缩进（最多两个全角）
            line = line.replacingOccurrences(of: "[ \\t]{2,}", with: "  ", options: .regularExpression)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                blankRun += 1
                // 正文段落间最多保留 1 个空行
                if blankRun > 1 { continue }
                lines.append("")
            } else {
                blankRun = 0
                lines.append(isJunkLine(trimmed) ? "" : line)
            }
        }
        // 收尾处理
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeFirst()
        }
        return lines.joined(separator: "\n")
    }

    /// 段落自动缩进（无缩进的中文文本，按段加两个空格）
    public static func applyIndent(_ body: String) -> String {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false).map { String($0) }
        var indented = 0, total = 0
        for l in lines where !l.trimmingCharacters(in: .whitespaces).isEmpty {
            total += 1
            if l.hasPrefix("  ") || l.hasPrefix("\t") { indented += 1 }
        }
        // 已有 60% 以上缩进就不处理
        guard total > 0, Double(indented) / Double(total) < 0.6 else { return body }
        return lines.map { l -> String in
            let t = l.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? "" : "  " + t
        }.joined(separator: "\n")
    }

    // MARK: - 编码探测与解码

    /// 从原始字节猜测编码并解码（GB18030 / UTF-8 / UTF-16 / Big5）
    public static func decode(data: Data) -> (text: String, encoding: String)? {
        if data.isEmpty { return (String(), "utf-8") }

        // 1) BOM
        if data.count >= 3, data[0] == 0xEF, data[1] == 0xBB, data[2] == 0xBF {
            if let s = String(data: data.dropFirst(3), encoding: .utf8) { return (s, "utf-8-bom") }
        }
        if data.count >= 2, data[0] == 0xFF, data[1] == 0xFE {
            if let s = String(data: data, encoding: .utf16LittleEndian) { return (s, "utf-16le") }
        }
        if data.count >= 2, data[0] == 0xFE, data[1] == 0xFF {
            if let s = String(data: data, encoding: .utf16BigEndian) { return (s, "utf-16be") }
        }

        // 2) 严格 UTF-8
        if let s = String(data: data, encoding: .utf8), isValidUTF8(data) {
            return (s, "utf-8")
        }

        // 3) GB18030（覆盖 GBK/GB2312）
        let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let s = String(data: data, encoding: String.Encoding(rawValue: gb)) {
            return (s, "gb18030")
        }

        // 4) Big5
        let big5 = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue))
        if let s = String(data: data, encoding: String.Encoding(rawValue: big5)) {
            return (s, "big5")
        }

        // 5) 兜底：允许有损
        if let s = String(data: data, encoding: .isoLatin1) { return (s, "latin1") }
        return nil
    }

    /// 严格校验 UTF-8 合法性（String(data:encoding:.utf8) 有时会做替换）
    public static func isValidUTF8(_ data: Data) -> Bool {
        let buf = [UInt8](data)
        var i = 0
        let n = buf.count
        while i < n {
            let b = buf[i]
            if b < 0x80 { i += 1; continue }
            var need = 0
            if b & 0xE0 == 0xC0 { need = 1 }
            else if b & 0xF0 == 0xE0 { need = 2 }
            else if b & 0xF8 == 0xF0 { need = 3 }
            else { return false }
            if i + need >= n { return false }
            for k in 1...need {
                if buf[i + k] & 0xC0 != 0x80 { return false }
            }
            i += need + 1
        }
        return true
    }

    /// 从 HTML meta / XML declaration 里嗅探 charset
    public static func sniffCharset(fromHTML bytes: Data) -> String? {
        let head = bytes.prefix(4096)
        guard let ascii = String(data: head, encoding: .isoLatin1) else { return nil }
        let lower = ascii.lowercased()
        for pattern in [#"charset\s*=\s*["']?([a-z0-9\-_]+)"#] {
            if let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                let r = NSRange(location: 0, length: (lower as NSString).length)
                if let m = re.firstMatch(in: lower, options: [], range: r), m.numberOfRanges > 1,
                   let range = Range(m.range(at: 1), in: lower) {
                    return String(lower[range])
                }
            }
        }
        return nil
    }

    /// 用指定编码名解码
    public static func decode(data: Data, charset: String) -> String? {
        let name = charset.lowercased().trimmingCharacters(in: .whitespaces)
        switch name {
        case "utf-8", "utf8":
            return String(data: data, encoding: .utf8)
        case "gbk", "gb2312", "gb18030", "cp936", "x-gbk":
            let gb = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
            return String(data: data, encoding: String.Encoding(rawValue: gb))
        case "big5", "big5-hkscs":
            let b5 = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue))
            return String(data: data, encoding: String.Encoding(rawValue: b5))
        case "latin1", "iso-8859-1":
            return String(data: data, encoding: .isoLatin1)
        default:
            return decode(data: data)?.text
        }
    }
}
