//
//  LegadoStore.swift
//  NovelReader
//
//  Legado 书源的持久化。整个书源列表存成 Documents/Sources/legado-sources.json，
//  格式就是 Legado 导出的 JSON 数组，直接对拷可用。
//

import Foundation
import Observation

/// 一次导入的结果
struct LegadoImportSummary: Equatable {
    var added: Int = 0
    var updated: Int = 0
    var skipped: Int = 0

    var total: Int { added + updated }

    var description: String {
        var parts: [String] = []
        if added > 0 { parts.append("新增 \(added)") }
        if updated > 0 { parts.append("更新 \(updated)") }
        if skipped > 0 { parts.append("跳过 \(skipped)") }
        return parts.isEmpty ? "没有可用书源" : parts.joined(separator: "，")
    }
}

@Observable
@MainActor
final class LegadoStore {

    /// 全部书源，按 customOrder 升序
    private(set) var sources: [LegadoBookSource] = []
    /// 最近一次操作的提示
    var statusMessage: String?

    private let fileName = "legado-sources.json"

    init() {
        load()
    }

    // MARK: - 路径

    private var fileURL: URL {
        BookStorage.sourcesDirectory.appendingPathComponent(fileName)
    }

    // MARK: - 读写

    func load() {
        let url = fileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            sources = []
            return
        }
        do {
            let data = try Data(contentsOf: url)
            sources = try decodeList(data)
            sortInPlace()
        } catch {
            statusMessage = "读取书源失败：\(error.localizedDescription)"
            sources = []
        }
    }

    func save() {
        do {
            try BookStorage.ensure(BookStorage.sourcesDirectory)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
            let data = try encoder.encode(sources)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            statusMessage = "保存书源失败：\(error.localizedDescription)"
        }
    }

    private func decodeList(_ data: Data) throws -> [LegadoBookSource] {
        var raw = data
        if raw.starts(with: [0xEF, 0xBB, 0xBF]) {
            raw = raw.dropFirst(3)
        }
        let decoder = JSONDecoder()

        // 先按数组整体解，最省事
        if let list = try? decoder.decode([LegadoBookSource].self, from: raw) {
            return list
        }
        // 单个对象
        if let one = try? decoder.decode(LegadoBookSource.self, from: raw) {
            return [one]
        }
        // 数组里有坏条目：逐条解，坏的跳过
        guard let obj = try? JSONSerialization.jsonObject(with: raw) else {
            throw LegadoError.ruleFailed("书源文件不是合法 JSON")
        }
        let items: [Any]
        if let array = obj as? [Any] {
            items = array
        } else if obj is [String: Any] {
            items = [obj]
        } else {
            throw LegadoError.ruleFailed("书源 JSON 顶层既不是数组也不是对象")
        }
        var out: [LegadoBookSource] = []
        for item in items {
            guard let d = try? JSONSerialization.data(withJSONObject: item),
                  let source = try? decoder.decode(LegadoBookSource.self, from: d) else { continue }
            out.append(source)
        }
        return out
    }

    // MARK: - 导入

    @discardableResult
    func importData(_ data: Data) throws -> LegadoImportSummary {
        var raw = data
        if raw.starts(with: [0xEF, 0xBB, 0xBF]) {
            raw = raw.dropFirst(3)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: raw) else {
            throw LegadoError.ruleFailed("不是合法 JSON")
        }

        let items: [Any]
        if let array = obj as? [Any] {
            items = array
        } else if obj is [String: Any] {
            items = [obj]
        } else {
            throw LegadoError.ruleFailed("书源 JSON 顶层既不是数组也不是对象")
        }

        let decoder = JSONDecoder()
        var summary = LegadoImportSummary()

        for item in items {
            guard let d = try? JSONSerialization.data(withJSONObject: item),
                  let source = try? decoder.decode(LegadoBookSource.self, from: d) else {
                summary.skipped += 1
                continue
            }
            guard !source.bookSourceUrl.trimmingCharacters(in: .whitespaces).isEmpty else {
                summary.skipped += 1
                continue
            }
            if let index = sources.firstIndex(where: { $0.bookSourceUrl == source.bookSourceUrl }) {
                sources[index] = source
                summary.updated += 1
            } else {
                sources.append(source)
                summary.added += 1
            }
        }

        sortInPlace()
        save()
        statusMessage = "导入完成：\(summary.description)"
        return summary
    }

    @discardableResult
    func importFile(at url: URL) throws -> LegadoImportSummary {
        let needsScope = url.startAccessingSecurityScopedResource()
        defer { if needsScope { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        return try importData(data)
    }

    /// 从网址导入（订阅式书源）
    func importRemote(_ urlString: String) async throws -> LegadoImportSummary {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespaces)) else {
            throw LegadoError.badSourceURL(urlString)
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode >= 400 {
            throw LegadoError.network("HTTP \(http.statusCode)")
        }
        return try importData(data)
    }

    // MARK: - 导出

    func exportData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .withoutEscapingSlashes]
        return try encoder.encode(sources)
    }

    /// 导出到临时文件，方便走系统分享
    func exportToTemporaryFile() throws -> URL {
        let data = try exportData()
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("云书阁书源-\(Self.stamp()).json")
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func stamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmm"
        return formatter.string(from: Date())
    }

    // MARK: - 增删改

    func remove(at offsets: IndexSet) {
        sources.remove(atOffsets: offsets)
        save()
    }

    func remove(_ source: LegadoBookSource) {
        sources.removeAll { $0.bookSourceUrl == source.bookSourceUrl }
        save()
    }

    func toggleEnabled(_ source: LegadoBookSource) {
        guard let index = sources.firstIndex(where: { $0.bookSourceUrl == source.bookSourceUrl }) else { return }
        sources[index].enabled.toggle()
        save()
    }

    func update(_ source: LegadoBookSource) {
        guard let index = sources.firstIndex(where: { $0.bookSourceUrl == source.bookSourceUrl }) else { return }
        sources[index] = source
        sortInPlace()
        save()
    }

    func removeAll() {
        sources.removeAll()
        save()
    }

    // MARK: - 查询

    var enabledSources: [LegadoBookSource] {
        sources.filter { $0.enabled && $0.readiness.isReady }
    }

    /// 所有分组标签，用于分组展示
    var groups: [String] {
        var seen = Set<String>()
        for source in sources {
            for tag in source.groupTags { seen.insert(tag) }
        }
        return seen.sorted()
    }

    func sources(in group: String?) -> [LegadoBookSource] {
        guard let group, group != "全部" else { return sources }
        return sources.filter { $0.groupTags.contains(group) }
    }

    private func sortInPlace() {
        sources.sort { lhs, rhs in
            if lhs.customOrder != rhs.customOrder { return lhs.customOrder < rhs.customOrder }
            if lhs.bookSourceName != rhs.bookSourceName { return lhs.bookSourceName < rhs.bookSourceName }
            return lhs.bookSourceUrl < rhs.bookSourceUrl
        }
    }
}
