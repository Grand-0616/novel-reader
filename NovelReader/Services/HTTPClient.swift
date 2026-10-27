//
//  HTTPClient.swift
//  NovelReader
//
//  统一的网络请求封装：编码探测、超时、自定义 UA/Header、Basic Auth、下载到文件
//

import Foundation

struct HTTPResponse {
    var data: Data
    var text: String
    var statusCode: Int
    var headers: [String: String]
    var finalURL: URL

    var isOK: Bool { (200..<300).contains(statusCode) }

    var contentType: String { headers["content-type"]?.lowercased() ?? "" }
}

enum HTTPError: LocalizedError {
    case invalidURL(String)
    case badStatus(Int)
    case transport(String)
    case emptyBody

    var errorDescription: String? {
        switch self {
        case .invalidURL(let u): return "无效地址：\(u)"
        case .badStatus(let c):  return "服务器返回状态码 \(c)"
        case .transport(let m):  return "网络错误：\(m)"
        case .emptyBody:         return "响应内容为空"
        }
    }
}

final class HTTPClient {
    static let shared = HTTPClient()

    private let session: URLSession

    /// 默认 UA：伪装成移动端 Safari，很多站点对无 UA 请求直接拒绝
    static let defaultUserAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1"

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 120
        config.httpAdditionalHeaders = [
            "Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8",
        ]
        config.waitsForConnectivity = false
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        self.session = URLSession(configuration: config)
    }

    // MARK: - 获取文本

    /// - Parameters:
    ///   - charset: 强制编码；nil 时自动嗅探
    func fetchText(
        _ urlString: String,
        method: String = "GET",
        source: RemoteSource? = nil,
        charset: String? = nil,
        referer: String? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> HTTPResponse {
        guard let url = Self.resolve(urlString, base: source?.baseURL) else {
            throw HTTPError.invalidURL(urlString)
        }

        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(source?.userAgent ?? Self.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml,application/json;q=0.9,*/*;q=0.8",
                         forHTTPHeaderField: "Accept")
        if let referer, let refURL = Self.resolve(referer, base: source?.baseURL) {
            request.setValue(refURL.absoluteString, forHTTPHeaderField: "Referer")
        }
        if let source {
            for (k, v) in source.headers { request.setValue(v, forHTTPHeaderField: k) }
            if !source.username.isEmpty {
                let token = Data("\(source.username):\(source.password)".utf8).base64EncodedString()
                request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
            }
        }
        if let timeout { request.timeoutInterval = timeout }

        do {
            let (data, response) = try await session.data(for: request)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 0
            var headerDict: [String: String] = [:]
            http?.allHeaderFields.forEach { k, v in
                if let ks = k as? String, let vs = v as? String { headerDict[ks.lowercased()] = vs }
            }
            let finalURL = http?.url ?? url

            // 解码
            let resolvedCharset: String? = charset
                ?? TextSanitizer.sniffCharset(fromHTML: data)
                ?? source?.encoding
            let text: String
            if let cs = resolvedCharset, let decoded = TextSanitizer.decode(data: data, charset: cs) {
                text = decoded
            } else if let decoded = TextSanitizer.decode(data: data)?.text {
                text = decoded
            } else {
                text = String(data: data, encoding: .isoLatin1) ?? ""
            }

            return HTTPResponse(data: data, text: text, statusCode: status,
                                headers: headerDict, finalURL: finalURL)
        } catch {
            throw HTTPError.transport(error.localizedDescription)
        }
    }

    /// 获取原始字节（图片 / 电子书文件）
    func fetchData(_ urlString: String, source: RemoteSource? = nil, referer: String? = nil) async throws -> Data {
        guard let url = Self.resolve(urlString, base: source?.baseURL) else {
            throw HTTPError.invalidURL(urlString)
        }
        var request = URLRequest(url: url)
        request.setValue(source?.userAgent ?? Self.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        if let referer, let refURL = Self.resolve(referer, base: source?.baseURL) {
            request.setValue(refURL.absoluteString, forHTTPHeaderField: "Referer")
        }
        if let source {
            for (k, v) in source.headers { request.setValue(v, forHTTPHeaderField: k) }
            if !source.username.isEmpty {
                let token = Data("\(source.username):\(source.password)".utf8).base64EncodedString()
                request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
            }
        }
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                throw HTTPError.badStatus(http.statusCode)
            }
            guard !data.isEmpty else { throw HTTPError.emptyBody }
            return data
        } catch let e as HTTPError {
            throw e
        } catch {
            throw HTTPError.transport(error.localizedDescription)
        }
    }

    /// 流式下载到文件（大文件 / 整本下载），回调进度 0...1
    func download(
        _ urlString: String,
        to destination: URL,
        source: RemoteSource? = nil,
        referer: String? = nil,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws {
        guard let url = Self.resolve(urlString, base: source?.baseURL) else {
            throw HTTPError.invalidURL(urlString)
        }
        var request = URLRequest(url: url)
        request.setValue(source?.userAgent ?? Self.defaultUserAgent, forHTTPHeaderField: "User-Agent")
        if let referer, let refURL = Self.resolve(referer, base: source?.baseURL) {
            request.setValue(refURL.absoluteString, forHTTPHeaderField: "Referer")
        }
        if let source {
            for (k, v) in source.headers { request.setValue(v, forHTTPHeaderField: k) }
            if !source.username.isEmpty {
                let token = Data("\(source.username):\(source.password)".utf8).base64EncodedString()
                request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
            }
        }

        let (tempURL, response) = try await session.download(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw HTTPError.badStatus(http.statusCode)
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: tempURL, to: destination)
        progress?(1.0)
    }

    // MARK: - URL 工具

    /// 把相对地址解析成绝对地址
    static func resolve(_ href: String, base: String?) -> URL? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }
        if trimmed.lowercased().hasPrefix("http://") || trimmed.lowercased().hasPrefix("https://") {
            return URL(string: trimmed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? trimmed)
        }
        if trimmed.lowercased().hasPrefix("//") {
            let scheme = base?.lowercased().hasPrefix("https") == true ? "https:" : "http:"
            return URL(string: scheme + trimmed)
        }
        guard let base, let baseURL = URL(string: base) else { return nil }
        return URL(string: trimmed, relativeTo: baseURL)?.absoluteURL
    }

    /// 规范化来源 baseURL（补 scheme、去尾斜杠）
    static func normalizeBase(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if !s.lowercased().hasPrefix("http") {
            s = "http://" + s
        }
        guard let url = URL(string: s) else { return nil }
        var str = url.absoluteString
        if str.hasSuffix("/") { str.removeLast() }
        return str
    }
}
