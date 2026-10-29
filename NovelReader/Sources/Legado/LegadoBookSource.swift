//
//  LegadoBookSource.swift
//  NovelReader
//
//  Legado（阅读 App）书源格式的 Swift 映射。
//
//  字段名与 Legado 导出的 JSON 保持完全一致，这样从网上拿到的
//  书源 JSON 可以原样解码，导出的文件也能被 Legado 直接导入。
//
//  Legado 的 JSON 有个坑：同一个字段在不同作者手里可能是数字、
//  字符串或 null（例如 lastUpdateTime 有时是 "1700000000000"）。
//  所以这里不用合成的 Codable，全部走宽容解码。
//

import Foundation

// MARK: - 类型宽容解码

/// 把 "123" / 123 / 123.0 都读成 Int64；失败返回 nil。
enum LegadoDecode {
    static func int64(_ c: KeyedDecodingContainer<some CodingKey>, _ k: some CodingKey) -> Int64? {
        if let v = try? c.decodeIfPresent(Int64.self, forKey: k) { return v }
        if let v = try? c.decodeIfPresent(Int.self, forKey: k) { return Int64(v) }
        if let v = try? c.decodeIfPresent(Double.self, forKey: k) { return Int64(v) }
        if let s = try? c.decodeIfPresent(String.self, forKey: k) {
            return Int64(s.trimmingCharacters(in: .whitespaces))
        }
        return nil
    }

    static func int(_ c: KeyedDecodingContainer<some CodingKey>, _ k: some CodingKey) -> Int? {
        int64(c, k).map { Int($0) }
    }

    static func bool(_ c: KeyedDecodingContainer<some CodingKey>, _ k: some CodingKey) -> Bool? {
        if let v = try? c.decodeIfPresent(Bool.self, forKey: k) { return v }
        if let n = int(c, k) { return n != 0 }
        if let s = try? c.decodeIfPresent(String.self, forKey: k) {
            let t = s.trimmingCharacters(in: .whitespaces).lowercased()
            if ["true", "1", "yes", "on"].contains(t) { return true }
            if ["false", "0", "no", "off"].contains(t) { return false }
        }
        return nil
    }

    /// 空字符串归一成 nil，避免规则里出现 "" 被判成"有规则但匹配不到"
    static func string(_ c: KeyedDecodingContainer<some CodingKey>, _ k: some CodingKey) -> String? {
        guard let s = try? c.decodeIfPresent(String.self, forKey: k) else { return nil }
        return s.isEmpty ? nil : s
    }
}

// MARK: - 书源类型

enum LegadoSourceType: Int, Codable, CaseIterable {
    case text = 0
    case audio = 1
    case image = 2
    case file = 3

    var displayName: String {
        switch self {
        case .text:  return "文本"
        case .audio: return "音频"
        case .image: return "图片"
        case .file:  return "文件"
        }
    }
}

// MARK: - 搜索规则

struct LegadoSearchRule: Codable, Equatable {
    /// 搜索结果 URL 里必须包含的关键字，用于判定"搜到了但其实是空结果页"
    var checkKeyWord: String?
    /// 结果列表容器
    var bookList: String?
    var name: String?
    var author: String?
    var intro: String?
    var kind: String?
    var lastChapter: String?
    var updateTime: String?
    var bookUrl: String?
    var coverUrl: String?
    var wordCount: String?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        checkKeyWord = LegadoDecode.string(c, .checkKeyWord)
        bookList = LegadoDecode.string(c, .bookList)
        name = LegadoDecode.string(c, .name)
        author = LegadoDecode.string(c, .author)
        intro = LegadoDecode.string(c, .intro)
        kind = LegadoDecode.string(c, .kind)
        lastChapter = LegadoDecode.string(c, .lastChapter)
        updateTime = LegadoDecode.string(c, .updateTime)
        bookUrl = LegadoDecode.string(c, .bookUrl)
        coverUrl = LegadoDecode.string(c, .coverUrl)
        wordCount = LegadoDecode.string(c, .wordCount)
    }

    var isUsable: Bool { !(bookList ?? "").isEmpty }
}

// MARK: - 发现规则

struct LegadoExploreRule: Codable, Equatable {
    var bookList: String?
    var name: String?
    var author: String?
    var intro: String?
    var kind: String?
    var lastChapter: String?
    var updateTime: String?
    var bookUrl: String?
    var coverUrl: String?
    var wordCount: String?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bookList = LegadoDecode.string(c, .bookList)
        name = LegadoDecode.string(c, .name)
        author = LegadoDecode.string(c, .author)
        intro = LegadoDecode.string(c, .intro)
        kind = LegadoDecode.string(c, .kind)
        lastChapter = LegadoDecode.string(c, .lastChapter)
        updateTime = LegadoDecode.string(c, .updateTime)
        bookUrl = LegadoDecode.string(c, .bookUrl)
        coverUrl = LegadoDecode.string(c, .coverUrl)
        wordCount = LegadoDecode.string(c, .wordCount)
    }
}

// MARK: - 详情规则

struct LegadoBookInfoRule: Codable, Equatable {
    /// 详情页预检：命中才继续解析（常用于跳过"本书已下架"页面）
    var `init`: String?
    var name: String?
    var author: String?
    var intro: String?
    var kind: String?
    var lastChapter: String?
    var updateTime: String?
    var coverUrl: String?
    /// 目录页地址；为空时用详情页地址当目录页
    var tocUrl: String?
    var wordCount: String?
    var canReName: String?
    var downloadUrls: String?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.`init` = LegadoDecode.string(c, .`init`)
        name = LegadoDecode.string(c, .name)
        author = LegadoDecode.string(c, .author)
        intro = LegadoDecode.string(c, .intro)
        kind = LegadoDecode.string(c, .kind)
        lastChapter = LegadoDecode.string(c, .lastChapter)
        updateTime = LegadoDecode.string(c, .updateTime)
        coverUrl = LegadoDecode.string(c, .coverUrl)
        tocUrl = LegadoDecode.string(c, .tocUrl)
        wordCount = LegadoDecode.string(c, .wordCount)
        canReName = LegadoDecode.string(c, .canReName)
        downloadUrls = LegadoDecode.string(c, .downloadUrls)
    }
}

// MARK: - 目录规则

struct LegadoTocRule: Codable, Equatable {
    var chapterList: String?
    var chapterName: String?
    var chapterUrl: String?
    var formatJs: String?
    var isVolume: String?
    var isVip: String?
    var updateTime: String?
    /// 下一页目录地址（分页目录站）
    var nextTocUrl: String?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        chapterList = LegadoDecode.string(c, .chapterList)
        chapterName = LegadoDecode.string(c, .chapterName)
        chapterUrl = LegadoDecode.string(c, .chapterUrl)
        formatJs = LegadoDecode.string(c, .formatJs)
        isVolume = LegadoDecode.string(c, .isVolume)
        isVip = LegadoDecode.string(c, .isVip)
        updateTime = LegadoDecode.string(c, .updateTime)
        nextTocUrl = LegadoDecode.string(c, .nextTocUrl)
    }

    var isUsable: Bool { !(chapterList ?? "").isEmpty }
}

// MARK: - 正文规则

struct LegadoContentRule: Codable, Equatable {
    var content: String?
    var title: String?
    var nextContentUrl: String?
    /// 需要 WebView 执行 JS 才能拿到正文时用（本站暂不支持，留字段）
    var webJs: String?
    var sourceRegex: String?
    var replaceRegex: String?
    var imageStyle: String?
    var payAction: String?

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        content = LegadoDecode.string(c, .content)
        title = LegadoDecode.string(c, .title)
        nextContentUrl = LegadoDecode.string(c, .nextContentUrl)
        webJs = LegadoDecode.string(c, .webJs)
        sourceRegex = LegadoDecode.string(c, .sourceRegex)
        replaceRegex = LegadoDecode.string(c, .replaceRegex)
        imageStyle = LegadoDecode.string(c, .imageStyle)
        payAction = LegadoDecode.string(c, .payAction)
    }

    var isUsable: Bool { !(content ?? "").isEmpty }
}

// MARK: - 书源

struct LegadoBookSource: Codable, Identifiable, Equatable {
    /// 书源唯一标识：站点根地址
    var bookSourceUrl: String = ""
    var bookSourceName: String = ""
    /// 逗号分隔的分组名
    var bookSourceGroup: String?
    /// 0 文本 / 1 音频 / 2 图片 / 3 文件
    var bookSourceType: Int = 0
    var bookSourceComment: String?
    var customOrder: Int = 0
    var enabled: Bool = true
    var enabledExplore: Bool = true
    /// 请求头，JSON 字符串或 "key:value\nkey:value"
    var header: String?
    var loginUrl: String?
    var loginUi: String?
    var loginCheckJs: String?
    var coverDecodeJs: String?
    /// 书源级公共 JS 库，会被拼进每个规则的 JS 环境
    var jsLib: String?

    /// 搜索 URL 模板，支持 {{key}} {{page}}
    var searchUrl: String?
    /// 发现页 URL 模板，JSON 数组或规则字符串
    var exploreUrl: String?
    var exploreScreen: String?
    var searchScreen: String?

    var ruleSearch: LegadoSearchRule?
    var ruleExplore: LegadoExploreRule?
    var ruleBookInfo: LegadoBookInfoRule?
    var ruleToc: LegadoTocRule?
    var ruleContent: LegadoContentRule?

    var lastUpdateTime: Int64 = 0
    /// 超时毫秒
    var respondTime: Int64 = 180_000
    var weight: Int = 0
    var variableComment: String?
    var concurrentRate: String?

    var id: String { bookSourceUrl }

    var type: LegadoSourceType { LegadoSourceType(rawValue: bookSourceType) ?? .text }

    /// 分组标签
    var groupTags: [String] {
        (bookSourceGroup ?? "")
            .split(whereSeparator: { $0 == "," || $0 == "，" || $0 == ";" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// 站名首字，用于列表占位图标
    var initial: String {
        String(bookSourceName.first ?? "源")
    }

    /// 是否具备完整阅读链路（搜索→详情→目录→正文）
    var readiness: LegadoReadiness {
        guard !bookSourceUrl.isEmpty else { return .invalid("缺少站点地址") }
        guard !bookSourceName.isEmpty else { return .invalid("缺少书源名称") }
        guard ruleToc?.isUsable == true else { return .incomplete("缺少目录规则") }
        guard ruleContent?.isUsable == true else { return .incomplete("缺少正文规则") }
        let canSearch = ruleSearch?.isUsable == true && !(searchUrl ?? "").isEmpty
        let canExplore = ruleExplore != nil && !(exploreUrl ?? "").isEmpty
        if !canSearch && !canExplore { return .incomplete("既不能搜索也不能发现") }
        return .ready
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bookSourceUrl = LegadoDecode.string(c, .bookSourceUrl) ?? ""
        bookSourceName = LegadoDecode.string(c, .bookSourceName) ?? ""
        bookSourceGroup = LegadoDecode.string(c, .bookSourceGroup)
        bookSourceType = LegadoDecode.int(c, .bookSourceType) ?? 0
        bookSourceComment = LegadoDecode.string(c, .bookSourceComment)
        customOrder = LegadoDecode.int(c, .customOrder) ?? 0
        enabled = LegadoDecode.bool(c, .enabled) ?? true
        enabledExplore = LegadoDecode.bool(c, .enabledExplore) ?? true
        header = LegadoDecode.string(c, .header)
        loginUrl = LegadoDecode.string(c, .loginUrl)
        loginUi = LegadoDecode.string(c, .loginUi)
        loginCheckJs = LegadoDecode.string(c, .loginCheckJs)
        coverDecodeJs = LegadoDecode.string(c, .coverDecodeJs)
        jsLib = LegadoDecode.string(c, .jsLib)
        searchUrl = LegadoDecode.string(c, .searchUrl)
        exploreUrl = LegadoDecode.string(c, .exploreUrl)
        exploreScreen = LegadoDecode.string(c, .exploreScreen)
        searchScreen = LegadoDecode.string(c, .searchScreen)
        ruleSearch = try? c.decodeIfPresent(LegadoSearchRule.self, forKey: .ruleSearch)
        ruleExplore = try? c.decodeIfPresent(LegadoExploreRule.self, forKey: .ruleExplore)
        ruleBookInfo = try? c.decodeIfPresent(LegadoBookInfoRule.self, forKey: .ruleBookInfo)
        ruleToc = try? c.decodeIfPresent(LegadoTocRule.self, forKey: .ruleToc)
        ruleContent = try? c.decodeIfPresent(LegadoContentRule.self, forKey: .ruleContent)
        lastUpdateTime = LegadoDecode.int64(c, .lastUpdateTime) ?? 0
        respondTime = LegadoDecode.int64(c, .respondTime) ?? 180_000
        weight = LegadoDecode.int(c, .weight) ?? 0
        variableComment = LegadoDecode.string(c, .variableComment)
        concurrentRate = LegadoDecode.string(c, .concurrentRate)
    }
}

// MARK: - 可用性

enum LegadoReadiness: Equatable {
    case ready
    case incomplete(String)
    case invalid(String)

    var isReady: Bool { self == .ready }

    var label: String {
        switch self {
        case .ready:            return "可用"
        case .incomplete(let r): return r
        case .invalid(let r):    return r
        }
    }

    var symbolName: String {
        switch self {
        case .ready:      return "checkmark.seal.fill"
        case .incomplete: return "exclamationmark.triangle.fill"
        case .invalid:    return "xmark.octagon.fill"
        }
    }
}

// MARK: - 运行时结果类型

/// 搜索结果条目
struct LegadoSearchResult: Identifiable, Equatable {
    var id: String { "\(sourceURL)|\(bookURL)" }

    var sourceName: String
    var sourceURL: String
    var name: String
    var author: String
    var intro: String
    var kind: String
    var lastChapter: String
    var wordCount: String
    var coverURL: String?
    /// 详情页绝对地址
    var bookURL: String
}

/// 书籍详情
struct LegadoBookDetail: Equatable {
    var name: String
    var author: String
    var intro: String
    var kind: String
    var lastChapter: String
    var wordCount: String
    var coverURL: String?
    /// 目录页绝对地址
    var tocURL: String
}

/// 目录条目
struct LegadoChapterItem: Identifiable, Equatable {
    var id: String { "\(index)|\(url)" }
    var index: Int
    var title: String
    /// 正文页绝对地址
    var url: String
    var isVip: Bool
}

/// 引擎错误
enum LegadoError: LocalizedError {
    case badSourceURL(String)
    case noSearchRule
    case noTocRule
    case noContentRule
    case network(String)
    case ruleFailed(String)
    case jsError(String)
    case emptyResult

    var errorDescription: String? {
        switch self {
        case .badSourceURL(let s):  return "站点地址无效：\(s)"
        case .noSearchRule:         return "该书源没有可用的搜索规则"
        case .noTocRule:            return "该书源没有可用的目录规则"
        case .noContentRule:        return "该书源没有可用的正文规则"
        case .network(let s):       return "网络错误：\(s)"
        case .ruleFailed(let s):    return "规则执行失败：\(s)"
        case .jsError(let s):       return "脚本错误：\(s)"
        case .emptyResult:          return "没有匹配到结果"
        }
    }
}
