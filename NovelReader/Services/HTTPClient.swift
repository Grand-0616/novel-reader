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
    /// - Parameter progress: 字节级进度回调 0...1，在后台线程触发
    func fetchData(
        _ urlString: String,
        source: RemoteSource? = nil,
        referer: String? = nil,
        progress: (@Sendable (Double) -> Void)? = nil
    ) async throws -> Data {
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

        // 无进度回调时走原来的轻量路径
        guard let progress else {
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

        // 有进度回调：走 delegate 版本，边下边报进度
        progress(0)
        do {
            let (tempURL, response) = try await Self.downloadWithProgress(request: request, progress: progress)
            guard let http = response as? HTTPURLResponse else {
                throw HTTPError.transport("无 HTTP 响应")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw HTTPError.badStatus(http.statusCode)
            }
            let data = try Data(contentsOf: tempURL)
            guard !data.isEmpty else { throw HTTPError.emptyBody }
            progress(1)
            return data
        } catch let e as HTTPError {
            throw e
        } catch {
            throw HTTPError.transport(error.localizedDescription)
        }
    }

    /// 流式下载到文件（大文件 / 整本下载），回调字节级进度 0...1
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

        let (tempURL, response) = try await Self.downloadWithProgress(request: request, progress: progress)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw HTTPError.badStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: tempURL, to: destination)
        progress?(1.0)
    }

    /// 用 URLSessionDownloadDelegate 拿字节级进度。
    /// URLSession.download(for:) 的 AsyncSequence 只在结束时给结果，
    /// 中间没有任何进度，所以这里必须走 delegate。
    private static func downloadWithProgress(
        request: URLRequest,
        progress: (@Sendable (Double) -> Void)?
    ) async throws -> (URL, URLResponse) {
        let collector = DownloadProgressCollector(progress: progress)
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 25
        config.timeoutIntervalForResource = 300
        config.httpAdditionalHeaders = ["Accept-Language": "zh-CN,zh;q=0.9,en;q=0.8"]
        config.waitsForConnectivity = false
        let delegateSession = URLSession(configuration: config, delegate: collector, delegateQueue: nil)
        defer { delegateSession.finishTasksAndInvalidate() }
        return try await collector.run(session: delegateSession, request: request)
    }

    // MARK: - URL 工具

    /// 把相对地址解析成绝对地址
    ///
    /// 注意几个容易 404 的坑：
    ///   1. 已经是完整 URL 时不能再做百分号编码 —— 重新编码会把 `%2F` 变成 `%252F`，
    ///      也会把一些服务器的签名参数改坏。
    ///   2. 以 `/` 开头的绝对路径必须建立在 base 的 scheme+host+port 上，
    ///      完全忽略 base 的 path，否则会被拼成 /webdav/webdav/xxx。
    ///   3. baseURL 通常没有尾斜杠（normalizeBase 会去掉），
    ///      此时 `URL(string:relativeTo:)` 会把最后一段当文件名替换掉，
    ///      所以这里手工补一个尾斜杠再解析。
    static func resolve(_ href: String, base: String?) -> URL? {
        let trimmed = href.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return nil }

        let lower = trimmed.lowercased()

        // 1. 完整 URL：直接用，不做任何编码改写
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            if let u = URL(string: trimmed) { return u }
            // 含未转义字符（空格、中文）时才退回编码
            if let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed),
               let u = URL(string: encoded) {
                return u
            }
            return nil
        }

        // 2. 协议相对 //host/path
        if lower.hasPrefix("//") {
            let scheme = base?.lowercased().hasPrefix("https") == true ? "https:" : "http:"
            return URL(string: scheme + trimmed)
        }

        guard let base, let baseURL = URL(string: base) else { return nil }

        // 3. 绝对路径：只借用 base 的 origin
        if trimmed.hasPrefix("/") {
            guard var comps = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
                return URL(string: trimmed, relativeTo: baseURL)?.absoluteURL
            }
            comps.path = ""
            comps.query = nil
            comps.fragment = nil
            guard let origin = comps.url else { return nil }
            return URL(string: trimmed, relativeTo: origin)?.absoluteURL
        }

        // 4. 相对路径：给 base 补尾斜杠，避免最后一段被替换
        var baseString = base
        if !baseString.hasSuffix("/") {
            baseString += "/"
        }
        guard let safeBase = URL(string: baseString) else { return nil }
        return URL(string: trimmed, relativeTo: safeBase)?.absoluteURL
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

// MARK: - 下载进度采集

/// 把 URLSession 的 download 回调转成 async/await + 进度回调。
///
/// 只 resolve 一次：`didFinishDownloadingTo` 正常结束，`didCompleteWithError` 处理失败，
/// 两者都可能被调用，所以用 `finished` 标志做幂等保护。
final class DownloadProgressCollector: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: (@Sendable (Double) -> Void)?
    private var continuation: CheckedContinuation<(URL, URLResponse), Error>?
    private var finished = false
    private let lock = NSLock()
    /// 上一次上报的进度，避免每个数据包都触发 UI 刷新
    private var lastReported: Double = -1

    init(progress: (@Sendable (Double) -> Void)?) {
        self.progress = progress
        super.init()
    }

    func run(session: URLSession, request: URLRequest) async throws -> (URL, URLResponse) {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(URL, URLResponse), Error>) in
            lock.lock()
            continuation = cont
            lock.unlock()
            session.downloadTask(with: request).resume()
        }
    }

    /// 幂等地取出 continuation；已经有线程取过就返回 nil
    private func takeContinuation() -> CheckedContinuation<(URL, URLResponse), Error>? {
        lock.lock()
        defer { lock.unlock() }
        if finished { return nil }
        finished = true
        let c = continuation
        continuation = nil
        return c
    }

    // MARK: URLSessionDownloadDelegate

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite expected: Int64
    ) {
        guard let progress else { return }
        let fraction: Double
        if expected > 0 {
            fraction = min(1.0, Double(totalBytesWritten) / Double(expected))
        } else {
            // 服务器没给 Content-Length（chunked），用渐近增长，避免一直停在 0
            let written = Double(totalBytesWritten)
            fraction = min(0.95, written / (written + 65536))
        }
        // 变化不足 1% 就不上报，减少主线程刷新次数
        if fraction - lastReported < 0.01, fraction < 1.0 { return }
        lastReported = fraction
        progress(fraction)
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        guard let continuation = takeContinuation() else { return }
        // location 在回调返回后就被系统删掉，必须先搬到自己的临时文件
        let dest = FileManager.default.temporaryDirectory
            .appendingPathComponent("dl-\(UUID().uuidString)")
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
        } catch {
            continuation.resume(throwing: HTTPError.transport("临时文件保存失败：\(error.localizedDescription)"))
            return
        }
        let response = downloadTask.response ?? URLResponse(
            url: downloadTask.originalRequest?.url ?? URL(string: "about:blank")!,
            mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
        continuation.resume(returning: (dest, response))
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        guard let error else {
            // 没有 error：可能 didFinishDownloadingTo 已经处理过了，也可能没走到
            if let continuation = takeContinuation() {
                continuation.resume(throwing: HTTPError.transport("下载结束但没有拿到文件"))
            }
            return
        }
        guard let continuation = takeContinuation() else { return }
        if (error as NSError).code == NSURLErrorCancelled {
            continuation.resume(throwing: CancellationError())
        } else {
            continuation.resume(throwing: HTTPError.transport(error.localizedDescription))
        }
    }
}
