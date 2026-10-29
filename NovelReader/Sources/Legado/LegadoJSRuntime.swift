//
//  LegadoJSRuntime.swift
//  NovelReader
//
//  书源脚本沙箱。
//
//  Legado 书源里大量规则写成 `@js:` 或 `{{ }}`，依赖一套 `java.*`
//  宿主函数（java.ajax / java.base64Decode / java.md5Encode …）。
//  这里用系统自带的 JavaScriptCore 提供同名函数，脚本可以原样跑。
//
//  线程模型：JSContext 不是线程安全的，所有求值都串到一条串行队列上；
//  java.ajax 是同步阻塞的（脚本里就是这么用的），所以必须在后台线程，
//  不能在主线程调用 evaluate。
//

import Foundation
import JavaScriptCore
import CryptoKit

final class LegadoJSRuntime {

    // MARK: - 状态

    private let context: JSContext!
    private let queue = DispatchQueue(label: "com.novelreader.legado.js")
    private let session: URLSession
    private let sourceBaseURL: String
    /// 与 Swift 侧共享的变量表（java.put / java.get）
    private var variables: [String: String]
    /// 默认超时（秒）
    private let timeout: TimeInterval
    /// 日志回调（调试用）
    var logHandler: ((String) -> Void)?
    /// java.put 写入变量时回调，供外部把变量同步回规则上下文
    var onVariableChanged: ((String, String) -> Void)?

    init(sourceBaseURL: String,
         variables: [String: String] = [:],
         jsLib: String? = nil,
         timeout: TimeInterval = 30) {
        self.sourceBaseURL = sourceBaseURL
        self.variables = variables
        self.timeout = timeout

        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.httpShouldSetCookies = true
        config.httpCookieAcceptPolicy = .always
        self.session = URLSession(configuration: config)

        // JSContext 只在内存耗尽时创建失败。这里没有可用的降级路径，
        // 失败时 context 为 nil，后续所有求值返回 nil，上层按「规则未命中」处理。
        self.context = JSContext(virtualMachine: JSVirtualMachine())

        context?.exceptionHandler = { [weak self] _, exception in
            let msg = exception?.toString() ?? "unknown"
            self?.logHandler?("[JS] \(msg)")
        }

        installHostObjects()
        installRuntimeVariables()

        if let jsLib, !jsLib.isEmpty {
            _ = context?.evaluateScript(jsLib)
        }
    }

    // MARK: - 求值

    /// 把外部变量表灌进 JS 全局作用域（每次求值前同步，保证 @put 的变量脚本可见）
    func syncVariables(_ values: [String: String]) {
        guard context != nil else { return }
        queue.sync {
            for (k, v) in values {
                variables[k] = v
                context.setObject(v, forKeyedSubscript: k as NSString)
            }
        }
    }

    /// 在串行队列上执行脚本，返回 result 变量的字符串值
    func evaluate(_ code: String, currentResult: String? = nil) -> String? {
        guard context != nil else { return nil }
        var output: String?
        queue.sync {
            if let currentResult {
                context.setObject(currentResult, forKeyedSubscript: "result" as NSString)
            }
            let value = context.evaluateScript(code)
            if let exception = context.exception {
                logHandler?("[JS] 异常：\(exception.toString() ?? "")")
                context.exception = nil
            }
            output = Self.stringValue(of: value, in: context)
            if output == nil {
                output = Self.stringValue(of: context.objectForKeyedSubscript("result"), in: context)
            }
        }
        return output
    }

    /// 把 JSValue 转成字符串；对象优先走 JSON.stringify
    private static func stringValue(of value: JSValue?, in context: JSContext) -> String? {
        guard let value, !value.isUndefined, !value.isNull else { return nil }
        if value.isString { return value.toString() }
        if value.isNumber || value.isBoolean { return value.toString() }
        if value.isArray || value.isObject {
            context.setObject(value, forKeyedSubscript: "__tmpOut" as NSString)
            let json = context.evaluateScript("JSON.stringify(__tmpOut)")
            let s = json?.toString()
            if let s, s != "undefined", s != "null" { return s }
            return value.toString()
        }
        return value.toString()
    }

    // MARK: - 宿主函数

    private func installRuntimeVariables() {
        guard context != nil else { return }
        context.setObject(sourceBaseURL, forKeyedSubscript: "baseUrl" as NSString)
        context.setObject(sourceBaseURL, forKeyedSubscript: "sourceUrl" as NSString)
        for (k, v) in variables {
            context.setObject(v, forKeyedSubscript: k as NSString)
        }
        _ = context.evaluateScript("var cookie = {}; var cache = {}; var source = {};")
    }

    private func installHostObjects() {
        guard context != nil else { return }
        _ = context.evaluateScript("var java = {}; var console = {};")

        guard let java = context.objectForKeyedSubscript("java") else { return }

        // ---- 网络 ----

        let ajax: @convention(block) (JSValue) -> String = { [weak self] arg in
            guard let self else { return "" }
            var url = ""
            var headers: [String: String] = [:]
            var body: String? = nil
            var method = "GET"

            if arg.isString {
                url = arg.toString() ?? ""
            } else if arg.isObject {
                url = arg.objectForKeyedSubscript("url")?.toString() ?? ""
                method = arg.objectForKeyedSubscript("method")?.toString()?.uppercased() ?? "GET"
                body = arg.objectForKeyedSubscript("body")?.toString()
                if let h = arg.objectForKeyedSubscript("headers"), h.isObject,
                   let dict = h.toDictionary() as? [String: Any] {
                    for (k, v) in dict { headers[k] = "\(v)" }
                }
            }
            return self.syncRequest(url: url, method: method, headers: headers, body: body)
        }
        java.setObject(ajax, forKeyedSubscript: "ajax" as NSString)

        let post: @convention(block) (JSValue, JSValue) -> String = { [weak self] urlV, bodyV in
            guard let self else { return "" }
            var headers: [String: String] = ["Content-Type": "application/json"]
            if let third = bodyV as JSValue?, third.isObject,
               let dict = third.toDictionary() as? [String: Any],
               dict["headers"] != nil {
                // 三参形式：post(url, body, headers) —— 这里第二个参数才是 body
            }
            return self.syncRequest(url: urlV.toString() ?? "",
                                    method: "POST",
                                    headers: headers,
                                    body: bodyV.toString())
        }
        java.setObject(post, forKeyedSubscript: "post" as NSString)

        // ---- 变量 ----

        let put: @convention(block) (String, JSValue) -> Void = { [weak self] key, value in
            guard let self else { return }
            let text = value.toString() ?? ""
            self.variables[key] = text
            self.context.setObject(text, forKeyedSubscript: key as NSString)
            self.onVariableChanged?(key, text)
        }
        java.setObject(put, forKeyedSubscript: "put" as NSString)

        let get: @convention(block) (String) -> String = { [weak self] key in
            self?.variables[key] ?? ""
        }
        java.setObject(get, forKeyedSubscript: "get" as NSString)

        // ---- 编解码 ----

        let b64encode: @convention(block) (String) -> String = { s in
            Data(s.utf8).base64EncodedString()
        }
        java.setObject(b64encode, forKeyedSubscript: "base64Encode" as NSString)

        let b64decode: @convention(block) (String) -> String = { s in
            guard let d = Data(base64Encoded: s, options: .ignoreUnknownCharacters) else { return "" }
            return String(data: d, encoding: .utf8) ?? ""
        }
        java.setObject(b64decode, forKeyedSubscript: "base64Decode" as NSString)

        let b64decodeToBytes: @convention(block) (String) -> [Int] = { s in
            guard let d = Data(base64Encoded: s, options: .ignoreUnknownCharacters) else { return [] }
            return d.map { Int($0) }
        }
        java.setObject(b64decodeToBytes, forKeyedSubscript: "base64DecodeToByteArray" as NSString)

        // ---- 摘要 ----

        let md5: @convention(block) (String) -> String = { s in
            let digest = Insecure.MD5.hash(data: Data(s.utf8))
            return digest.map { String(format: "%02x", $0) }.joined()
        }
        java.setObject(md5, forKeyedSubscript: "md5Encode" as NSString)

        let md5_16: @convention(block) (String) -> String = { s in
            let digest = Insecure.MD5.hash(data: Data(s.utf8))
            let hex = digest.map { String(format: "%02x", $0) }.joined()
            return String(hex.dropFirst(8).dropLast(8))
        }
        java.setObject(md5_16, forKeyedSubscript: "md5Encode16" as NSString)

        let sha1: @convention(block) (String) -> String = { s in
            let digest = Insecure.SHA1.hash(data: Data(s.utf8))
            return digest.map { String(format: "%02x", $0) }.joined()
        }
        java.setObject(sha1, forKeyedSubscript: "digestHex" as NSString)

        // ---- URL 编码 ----

        let encodeURI: @convention(block) (String) -> String = { s in
            s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? s
        }
        java.setObject(encodeURI, forKeyedSubscript: "encodeURI" as NSString)

        let encodeURIComponent: @convention(block) (String) -> String = { s in
            var allowed = CharacterSet.alphanumerics
            allowed.insert(charactersIn: "-._~")
            return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
        }
        java.setObject(encodeURIComponent, forKeyedSubscript: "encodeURIComponent" as NSString)

        // ---- 时间 ----

        let timeFormat: @convention(block) (Double) -> String = { ts in
            let date = Date(timeIntervalSince1970: ts > 1e12 ? ts / 1000 : ts)
            let f = DateFormatter()
            f.dateFormat = "yyyy/MM/dd HH:mm"
            return f.string(from: date)
        }
        java.setObject(timeFormat, forKeyedSubscript: "timeFormat" as NSString)

        // ---- 日志 ----

        let log: @convention(block) (JSValue) -> Void = { [weak self] v in
            self?.logHandler?("[脚本] \(v.toString() ?? "")")
        }
        java.setObject(log, forKeyedSubscript: "log" as NSString)

        let toast: @convention(block) (JSValue) -> Void = { [weak self] v in
            self?.logHandler?("[提示] \(v.toString() ?? "")")
        }
        java.setObject(toast, forKeyedSubscript: "toast" as NSString)
        java.setObject(toast, forKeyedSubscript: "longToast" as NSString)

        // ---- 正则 ----

        let regex: @convention(block) (String, String, Int) -> String = { pattern, input, mode in
            guard let re = try? NSRegularExpression(pattern: pattern) else { return "" }
            let ns = input as NSString
            let range = NSRange(location: 0, length: ns.length)
            switch mode {
            case 1: // 只取第一个匹配
                guard let m = re.firstMatch(in: input, range: range) else { return "" }
                return ns.substring(with: m.range)
            case 2: // 替换为空
                return re.stringByReplacingMatches(in: input, range: range, withTemplate: "")
            default:
                let ms = re.matches(in: input, range: range)
                return ms.map { ns.substring(with: $0.range) }.joined()
            }
        }
        java.setObject(regex, forKeyedSubscript: "regex" as NSString)

        // console.log
        if let console = context.objectForKeyedSubscript("console") {
            console.setObject(log, forKeyedSubscript: "log" as NSString)
        }
    }

    // MARK: - 同步 HTTP

    /// 供脚本同步调用。必须在后台线程使用。
    private func syncRequest(url: String,
                             method: String,
                             headers: [String: String],
                             body: String?) -> String {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let resolved: String
        if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
            resolved = trimmed
        } else if let base = URL(string: sourceBaseURL),
                  let abs = URL(string: trimmed, relativeTo: base) {
            resolved = abs.absoluteString
        } else {
            return ""
        }

        guard let requestURL = URL(string: resolved) else { return "" }

        var request = URLRequest(url: requestURL)
        request.httpMethod = method
        request.timeoutInterval = timeout
        for (k, v) in headers {
            request.setValue(v, forHTTPHeaderField: k)
        }
        if let body, method != "GET" {
            request.httpBody = body.data(using: .utf8)
        }
        if request.value(forHTTPHeaderField: "User-Agent") == nil {
            request.setValue(
                "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148",
                forHTTPHeaderField: "User-Agent")
        }

        let semaphore = DispatchSemaphore(value: 0)
        var output = ""

        let task = session.dataTask(with: request) { data, response, _ in
            defer { semaphore.signal() }
            guard let data else { return }
            if let http = response as? HTTPURLResponse,
               let charset = http.textEncodingName,
               !charset.lowercased().contains("utf-8"),
               let enc = String.Encoding(charsetName: charset),
               let s = String(data: data, encoding: enc) {
                output = s
                return
            }
            output = String(data: data, encoding: .utf8)
                ?? String(data: data, encoding: .isoLatin1)
                ?? ""
        }
        task.resume()

        if semaphore.wait(timeout: .now() + timeout + 5) == .timedOut {
            task.cancel()
            return ""
        }
        return output
    }
}

// MARK: - String.Encoding 便捷构造

extension String.Encoding {
    /// 把 HTTP charset 名字映射到 String.Encoding。认不出来按 UTF-8 处理。
    init?(charsetName: String) {
        let name = charsetName.lowercased()
        if name.contains("gbk") || name.contains("gb2312") || name.contains("gb18030") {
            // GB18030 覆盖 GBK/GB2312
            let cfEnc = CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
            self = String.Encoding(rawValue: cfEnc)
            return
        }
        if name.contains("big5") {
            let cfEnc = CFStringConvertEncodingToNSStringEncoding(
                CFStringEncoding(CFStringEncodings.big5.rawValue))
            self = String.Encoding(rawValue: cfEnc)
            return
        }
        if name.contains("iso-8859-1") || name.contains("latin1") {
            self = .isoLatin1
            return
        }
        self = .utf8
    }
}
