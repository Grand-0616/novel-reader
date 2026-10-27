//
//  BookSourceModels.swift
//  NovelReader
//
//  书源配置模型：NAS (OPDS / HTTP目录 / WebDAV) 与规则化网络书源
//  全部以 JSON 存储在 Documents/Sources/ 下，可在设置内直接编辑
//

import Foundation

// MARK: - 通用来源协议

enum SourceKind: String, Codable, CaseIterable {
    /// OPDS 订阅源（NAS 书库主力：calibre-web / COPS / Komga / Kavita）
    case opds
    /// 普通 HTTP 目录列表（nginx autoindex / Python http.server / 群晖索引页）
    case httpDirectory = "httpdir"
    /// WebDAV 目录
    case webdav
    /// 规则化小说站（搜索 + 目录 + 正文 XPath/CSS 规则）
    case rules
    /// 自定义 JSON API（你自己写的接口，返回统一结构）
    case jsonAPI = "jsonapi"

    var displayName: String {
        switch self {
        case .opds:          return "OPDS 书库"
        case .httpDirectory: return "HTTP 目录"
        case .webdav:        return "WebDAV"
        case .rules:         return "规则书源"
        case .jsonAPI:       return "JSON API"
        }
    }

    var symbolName: String {
        switch self {
        case .opds:          return "books.vertical"
        case .httpDirectory: return "folder.badge.gearshape"
        case .webdav:        return "network"
        case .rules:         return "text.magnifyingglass"
        case .jsonAPI:       return "curlybraces"
        }
    }
}

// MARK: - 远程书源配置

struct RemoteSource: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var kind: SourceKind
    /// 基础地址，如 http://192.168.1.10:8083/opds 或 https://example.com
    var baseURL: String

    /// HTTP Basic 认证（群晖 WebDAV 常用）
    var username: String = ""
    var password: String = ""

    /// 自定义请求头
    var headers: [String: String] = [:]

    /// 是否启用
    var isEnabled: Bool = true

    /// 规则书源相关（kind == .rules 时生效）
    var searchURLTemplate: String = ""
    var searchItemSelector: String = ""
    var searchTitleSelector: String = ""
    var searchAuthorSelector: String = ""
    var searchLinkSelector: String = ""
    var searchCoverSelector: String = ""

    var detailTitleSelector: String = ""
    var detailAuthorSelector: String = ""
    var detailCoverSelector: String = ""
    var detailSummarySelector: String = ""
    var detailChapterSelector: String = ""
    var detailChapterTitleSelector: String = ""

    var contentSelector: String = ""
    var contentRemoveSelectors: [String] = []

    /// 搜索分页参数模板，如 "&page={page}"
    var pageQueryTemplate: String = ""

    /// 编码：部分老站是 GBK/GB18030
    var encoding: String = "utf-8"

    /// 请求 UA
    var userAgent: String = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148"

    /// 上次连通性测试结果
    var lastCheckOK: Bool = false
    var lastCheckMessage: String = ""
    var lastCheckAt: Date?

    // JSON API 规则
    var jsonSearchPath: String = ""      // 如 "data.items"
    var jsonTitleField: String = "title"
    var jsonAuthorField: String = "author"
    var jsonLinkField: String = "url"
    var jsonCoverField: String = "cover"
    var jsonChapterPath: String = "chapters"
    var jsonChapterTitleField: String = "title"
    var jsonChapterLinkField: String = "url"
    var jsonContentField: String = "content"

    static func makeOPDS(name: String, url: String, user: String = "", pass: String = "") -> RemoteSource {
        RemoteSource(name: name, kind: .opds, baseURL: url, username: user, password: pass)
    }

    static func makeHTTPDir(name: String, url: String) -> RemoteSource {
        RemoteSource(name: name, kind: .httpDirectory, baseURL: url)
    }

    static func makeWebDAV(name: String, url: String, user: String, pass: String) -> RemoteSource {
        RemoteSource(name: name, kind: .webdav, baseURL: url, username: user, password: pass)
    }
}

// MARK: - 搜索结果条目

enum SourceEntryKind: String, Codable {
    case directory      // 目录（可继续进入）
    case book           // 可下载/可阅读的书
    case chapter        // 章节
}

/// 从书源里浏览到的一个条目（统一抽象：OPDS entry / HTML 目录项 / 搜索结果）
struct SourceEntry: Identifiable, Equatable {
    var id: String { "\(kind.rawValue)|\(href)" }

    var title: String
    var author: String?
    var summary: String?
    var coverURL: String?
    /// 绝对 URL 或相对 URL（相对于来源 baseURL）
    var href: String
    var kind: SourceEntryKind
    /// MIME，可用来判断格式
    var mimeType: String?
    /// 若该条目直接指向章节/正文
    var contentHint: String?
}

/// 网络书源详情页解析结果
struct SourceBookDetail {
    var title: String
    var author: String
    var coverURL: String?
    var summary: String
    var chapters: [SourceEntry]
}

// MARK: - 书目候选（用于"在线搜索后加入书架"）

struct RemoteBookCandidate: Identifiable, Equatable {
    var id: UUID = UUID()
    var sourceID: UUID
    var sourceName: String
    var title: String
    var author: String
    var coverURL: String?
    var summary: String?
    var detailURL: String
}
