//
//  SourceRegistry.swift
//  NovelReader
//
//  书源注册表：持久化到 Documents/Sources/sources.json，支持导入/导出 JSON
//

import Foundation
import Observation

@Observable
final class SourceRegistry {
    static let shared = SourceRegistry()

    private(set) var sources: [RemoteSource] = []

    private var fileURL: URL {
        BookStorage.sourcesDirectory.appendingPathComponent("sources.json")
    }

    private init() {
        load()
        prunePlaceholders()
    }

    /// 旧版本首次启动会写入 4 条占位示例（192.168.1.100 / example.com）。
    /// 这些地址对用户没有意义，未启用的一律清掉，避免书源页凭空多出几条。
    private func prunePlaceholders() {
        let hosts: Set<String> = ["192.168.1.100", "example.com"]
        let before = sources.count
        sources.removeAll { s in
            guard !s.isEnabled, let host = URL(string: s.baseURL)?.host else { return false }
            return hosts.contains(host)
        }
        if sources.count != before { save() }
    }

    // MARK: - 内置建议配置（地址留空，用户填自己的 NAS）

    static func builtinSuggestions() -> [RemoteSource] {
        var opds = RemoteSource.makeOPDS(name: "我的 NAS（OPDS）", url: "http://192.168.1.100:8083/opds")
        opds.isEnabled = false
        opds.lastCheckMessage = "请把地址改成你的 NAS 书库地址"

        var dir = RemoteSource.makeHTTPDir(name: "NAS 目录（HTTP）", url: "http://192.168.1.100:8080/books/")
        dir.isEnabled = false
        dir.lastCheckMessage = "开启 NAS 的目录索引后填地址"

        var dav = RemoteSource.makeWebDAV(name: "NAS（WebDAV）", url: "http://192.168.1.100:5005/books",
                                          user: "", pass: "")
        dav.isEnabled = false

        var sampleRules = RemoteSource(name: "规则书源示例", kind: .rules,
                                       baseURL: "https://example.com",
                                       searchURLTemplate: "https://example.com/search?q={keyword}&page={page}")
        sampleRules.isEnabled = false
        sampleRules.searchItemSelector = "div.result-item"
        sampleRules.searchTitleSelector = "h3 a"
        sampleRules.searchLinkSelector = "h3 a@href"
        sampleRules.searchAuthorSelector = "span.author"
        sampleRules.detailChapterSelector = "#list dd a"
        sampleRules.contentSelector = "#content"
        sampleRules.contentRemoveSelectors = ["div.ads", "script"]
        sampleRules.lastCheckMessage = "示例：把选择器换成目标站的真实结构"

        return [opds, dir, dav, sampleRules]
    }

    // MARK: - CRUD

    func add(_ source: RemoteSource) {
        var s = source
        if s.baseURL.isEmpty == false, let normalized = HTTPClient.normalizeBase(s.baseURL) {
            s.baseURL = normalized
        }
        sources.append(s)
        save()
    }

    func update(_ source: RemoteSource) {
        guard let idx = sources.firstIndex(where: { $0.id == source.id }) else { return }
        sources[idx] = source
        save()
    }

    func remove(_ source: RemoteSource) {
        sources.removeAll { $0.id == source.id }
        save()
    }

    func remove(at offsets: IndexSet) {
        sources.remove(atOffsets: offsets)
        save()
    }

    func source(id: UUID?) -> RemoteSource? {
        guard let id else { return nil }
        return sources.first { $0.id == id }
    }

    var enabledSources: [RemoteSource] { sources.filter(\.isEnabled) }

    func markCheck(_ id: UUID, ok: Bool, message: String) {
        guard let idx = sources.firstIndex(where: { $0.id == id }) else { return }
        sources[idx].lastCheckOK = ok
        sources[idx].lastCheckMessage = message
        sources[idx].lastCheckAt = Date()
        save()
    }

    // MARK: - 持久化

    func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let list = try? decoder.decode([RemoteSource].self, from: data) {
            sources = list
        }
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(sources) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    // MARK: - 导入导出

    /// 导出为 JSON 文本（可复制给其他设备）
    func exportJSON() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(sources),
              let text = String(data: data, encoding: .utf8) else { return "[]" }
        return text
    }

    /// 从 JSON 文本导入（合并，避免重复 id）
    @discardableResult
    func importJSON(_ text: String) throws -> Int {
        guard let data = text.data(using: .utf8) else { throw ParseError.emptyContent }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var incoming = try decoder.decode([RemoteSource].self, from: data)

        // 也兼容单个对象
        if incoming.isEmpty,
           let single = try? decoder.decode(RemoteSource.self, from: data) {
            incoming = [single]
        }
        var added = 0
        for var s in incoming {
            // 重分配 id 避免冲突
            if sources.contains(where: { $0.id == s.id }) {
                s.id = UUID()
                s.name += "（导入）"
            }
            sources.append(s)
            added += 1
        }
        save()
        return added
    }
}
