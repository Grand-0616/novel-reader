//
//  ChapterSplitter.swift
//  NovelReader
//
//  纯算法：把整本 TXT 按章节标题切分成章节数组
//

import Foundation

public struct SplitChapter {
    public var title: String
    public var content: String
    public init(title: String, content: String) {
        self.title = title
        self.content = content
    }
    public var characterCount: Int { content.count }
}

public enum ChapterSplitter {

    /// 单章超过该字符数时按自然段再拆（提升分页性能与内存）
    public static let maxChapterChars = 30_000
    /// 小于该长度的"章节"会被合并到下一章（标题误判保护）
    public static let minChapterChars = 40

    /// 切分整本书
    /// - Parameters:
    ///   - raw: 原始全文
    ///   - bookTitle: 书名，用于生成"正文"标题
    public static func split(_ raw: String, bookTitle: String = "正文") -> [SplitChapter] {
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        let lines = normalized.components(separatedBy: "\n")

        var chapters: [SplitChapter] = []
        var currentTitle: String = bookTitle
        var buffer: [String] = []
        var hasTitle = false

        func flush() {
            let body = TextSanitizer.normalizeBody(buffer.joined(separator: "\n"))
            buffer.removeAll(keepingCapacity: true)
            guard !body.isEmpty else { return }
            // 短章节保护：只有"短且不像正文"时才并入上一章。
            // 判断依据是句末标点 —— 真正的短章节（诗、引子）通常带标点，
            // 而误判产生的碎片（书名、页眉、分隔符）往往没有。
            if chapters.count > 0, body.count < minChapterChars, !ChapterSplitter.looksLikeProse(body) {
                let last = chapters.removeLast()
                let merged = last.content + "\n\n" + body
                chapters.append(SplitChapter(title: last.title, content: merged))
                return
            }
            chapters.append(SplitChapter(title: currentTitle, content: body))
        }

        for rawLine in lines {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            // 章节标题判定：整行匹配且行不含过多字符
            if !line.isEmpty, line.count <= 60, TextSanitizer.isChapterTitle(line) {
                if !hasTitle {
                    // 第一章之前的内容：多半是书名/作者/简介/网站声明
                    let preamble = TextSanitizer.normalizeBody(buffer.joined(separator: "\n"))
                    buffer.removeAll(keepingCapacity: true)
                    // 只有明显是正文的前言才保留
                    if ChapterSplitter.isRealPreamble(preamble) {
                        chapters.append(SplitChapter(title: "前言", content: preamble))
                    }
                    currentTitle = line
                    hasTitle = true
                    continue
                }
                flush()
                currentTitle = line
                buffer = []
            } else {
                buffer.append(rawLine)
            }
        }
        flush()

        // 完全没切出章节（不是标准小说，或全文没有章节标记）
        // 注意：必须用 hasTitle 判断，而不是 chapters.isEmpty ——
        // 因为无标题时会先 flush 出一章"正文"，导致永远走不到硬切分支。
        if !hasTitle {
            let body = TextSanitizer.normalizeBody(normalized)
            if body.isEmpty { return [] }
            return hardSplit(body, bookTitle: bookTitle)
        }

        if chapters.isEmpty {
            let body = TextSanitizer.normalizeBody(normalized)
            if body.isEmpty { return [] }
            return hardSplit(body, bookTitle: bookTitle)
        }

        // 单章过长再切
        var result: [SplitChapter] = []
        result.reserveCapacity(chapters.count)
        for ch in chapters {
            if ch.characterCount > maxChapterChars {
                result.append(contentsOf: paragraphSplit(ch))
            } else {
                result.append(ch)
            }
        }
        return result
    }

    /// 判断一段短文本是否像真正的正文（用于避免把正常短章节误合并）
    /// 依据：含句末标点、或含对话引号、或有多行内容
    static func looksLikeProse(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return false }
        let sentenceEnders = "。！？…；”』」!?;"
        if t.contains(where: { sentenceEnders.contains($0) }) { return true }
        // 多行且不是纯符号
        let lines = t.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if lines.count >= 2 { return true }
        // 足够长的单行
        return t.count >= 20
    }

    /// 判断第一章之前的内容是否值得保留为"前言"
    /// 过滤掉书名/作者/简介/网址这类元信息头
    static func isRealPreamble(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 200 else { return false }
        let lines = trimmed.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        // 元信息行：xxx：yyy 且很短
        let metaPrefixes = ["书名", "作者", "简介", "内容简介", "分类", "状态", "字数",
                            "更新时间", "最新章节", "来源", "网址", "声明", "版权"]
        var metaLines = 0
        var proseLines = 0
        for l in lines {
            if metaPrefixes.contains(where: { l.hasPrefix($0) }) && l.count <= 40 {
                metaLines += 1
            } else if l.contains("http") || l.contains("www.") {
                metaLines += 1
            } else if l.count > 12 {
                proseLines += 1
            }
        }
        // 真正的正文前言：长句明显多于元信息行
        return proseLines >= 3 && proseLines > metaLines * 2
    }

    /// 无章节标记时按字数硬切（以自然段为最小单位累积）
    public static func hardSplit(_ body: String, bookTitle: String) -> [SplitChapter] {
        // 先按空行/换行拆成段；若整段没有换行，则按句号再断
        var paragraphs = body.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        if paragraphs.count <= 1 {
            // 没有换行：按中文句末标点切片
            var pieces: [String] = []
            var current = ""
            for ch in body {
                current.append(ch)
                if "。！？…\n".contains(ch) {
                    pieces.append(current.trimmingCharacters(in: .whitespaces))
                    current = ""
                }
            }
            if !current.trimmingCharacters(in: .whitespaces).isEmpty {
                pieces.append(current.trimmingCharacters(in: .whitespaces))
            }
            paragraphs = pieces.filter { !$0.isEmpty }
        }

        var result: [SplitChapter] = []
        var buf: [String] = []
        var bufLen = 0
        var part = 1
        let targetLen = 6000

        func flush() {
            guard !buf.isEmpty else { return }
            let title = "\(bookTitle) - 第\(part)节"
            result.append(SplitChapter(title: title,
                                       content: TextSanitizer.normalizeBody(buf.joined(separator: "\n"))))
            buf.removeAll(keepingCapacity: true)
            bufLen = 0
            part += 1
        }

        for p in paragraphs {
            buf.append(p)
            bufLen += p.count + 1
            if bufLen >= targetLen { flush() }
        }
        flush()
        return result
    }

    /// 单章过长：按段落切分为 (1/N) (2/N)
    public static func paragraphSplit(_ chapter: SplitChapter) -> [SplitChapter] {
        let paragraphs = chapter.content.components(separatedBy: "\n")
        let targetChunks = max(2, Int(ceil(Double(chapter.characterCount) / Double(maxChapterChars))))
        var chunks: [[String]] = []
        var current: [String] = []
        var currentLen = 0
        let targetLen = chapter.characterCount / targetChunks
        for p in paragraphs {
            current.append(p)
            currentLen += p.count + 1
            if currentLen >= targetLen, chunks.count < targetChunks - 1 {
                chunks.append(current)
                current = []
                currentLen = 0
            }
        }
        if !current.isEmpty { chunks.append(current) }

        let total = chunks.count
        return chunks.enumerated().map { idx, lines in
            SplitChapter(
                title: total > 1 ? "\(chapter.title) (\(idx + 1)/\(total))" : chapter.title,
                content: TextSanitizer.normalizeBody(lines.joined(separator: "\n"))
            )
        }
    }

    /// 从文件名推断书名与作者：`书名 - 作者.txt` / `[作者]书名.txt` / `《书名》作者.txt`
    public static func parseFileNameTitle(_ fileName: String) -> (title: String, author: String) {
        var name = (fileName as NSString).deletingPathExtension
        name = name.trimmingCharacters(in: .whitespaces)

        // 《书名》作者
        if let re = try? NSRegularExpression(pattern: #"^《(.+?)》\s*(.*)$"#),
           let m = re.firstMatch(in: name, range: NSRange(location: 0, length: (name as NSString).length)),
           let tRange = Range(m.range(at: 1), in: name) {
            let title = String(name[tRange])
            var author = ""
            if m.numberOfRanges > 2, let aRange = Range(m.range(at: 2), in: name) {
                author = String(name[aRange]).trimmingCharacters(in: .whitespaces)
            }
            return (title, author)
        }
        // [作者]书名 或 【作者】书名
        if let re = try? NSRegularExpression(pattern: #"^[\[【](.+?)[\]】]\s*(.+)$"#),
           let m = re.firstMatch(in: name, range: NSRange(location: 0, length: (name as NSString).length)),
           let a = Range(m.range(at: 1), in: name), let t = Range(m.range(at: 2), in: name) {
            return (String(name[t]).trimmingCharacters(in: .whitespaces), String(name[a]))
        }
        // 书名 - 作者 / 书名_作者 / 书名（作者）
        for sep in [" - ", " – ", "—", "_", "（", "("] {
            if let r = name.range(of: sep, options: .backwards), r.lowerBound != name.startIndex {
                var title = String(name[name.startIndex..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
                var author = String(name[r.upperBound...]).trimmingCharacters(in: .whitespaces)
                if sep == "（" || sep == "(" {
                    author = author.replacingOccurrences(of: "）", with: "").replacingOccurrences(of: ")", with: "")
                    // (作者) 只在作者名较短时生效，避免误伤书名
                    if author.count > 12 { continue }
                }
                title = title.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
                if !title.isEmpty {
                    return (title, author)
                }
            }
        }
        // 书名作者连写：xxx 作者：xxx
        if let r = name.range(of: "作者") {
            let title = String(name[name.startIndex..<r.lowerBound]).trimmingCharacters(in: .whitespaces)
            var author = String(name[r.upperBound...])
            author = author.replacingOccurrences(of: "：", with: "").replacingOccurrences(of: ":", with: "")
                .trimmingCharacters(in: .whitespaces)
            if !title.isEmpty { return (title, author) }
        }
        return (name, "")
    }
}
