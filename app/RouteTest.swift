import Foundation

// 地址测试：经本机代理端口发出真实请求，再从内核日志读取这次连接命中的规则与出口。
// /connections 只列出仍在进行的连接，短请求和被拦截的连接常常查不到；
// 内核在 info 级别会为每条连接记录一行 "match … using …"，因此以日志为准。

struct RouteMatch: Equatable {
    var rule: String        // 内核规则名：DomainSuffix、GeoSite、Match …
    var payload: String     // 规则内容，如 github.com；Match 为空
    var policy: String      // PROXY / DIRECT / REJECT / 手动选择 …
    var node: String?       // 走代理时实际使用的节点
    var dialError: String?  // 内核连接上游失败时的错误

    /// 对应 config.yaml 里的规则类型，用于在自定义规则列表中定位
    var ruleType: String? {
        ["DomainSuffix": "DOMAIN-SUFFIX", "Domain": "DOMAIN", "IPCIDR": "IP-CIDR", "IPCIDR6": "IP-CIDR6"][rule]
    }
}

struct RouteTestResult {
    var url: URL
    var match: RouteMatch?
    var status: Int?
    var elapsed: TimeInterval
    var error: String?
}

enum RouteTester {
    /// 补全协议：用户常只输入域名
    static func normalize(_ input: String) -> URL? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if !text.contains("://") { text = "https://" + text }
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    static func target(_ url: URL) -> String {
        let host = url.host ?? ""
        let port = url.port ?? (url.scheme?.lowercased() == "http" ? 80 : 443)
        return (host.contains(":") ? "[\(host)]" : host) + ":\(port)"
    }

    private static let matched = try! NSRegularExpression(pattern: #"\[TCP\] (\S+) --> (\S+) match (\w+)(?:\((.*)\))? using ([^\["]+?)(?:\[(.*)\])?"\s*$"#)
    private static let failed = try! NSRegularExpression(pattern: #"\[TCP\] dial (\S+) \(match (\w+)(?:/([^)]*))?\) (\S+) --> (\S+) error: (.*)"\s*$"#)

    /// 解析一行内核日志；只接受经代理端口（本机回环地址）发往目标的连接，排除 TUN 接管的其他 App 流量。
    static func parse(line: String, target: String) -> RouteMatch? {
        func groups(_ regex: NSRegularExpression) -> [String?]? {
            let range = NSRange(line.startIndex..., in: line)
            guard let found = regex.firstMatch(in: line, range: range) else { return nil }
            return (1..<found.numberOfRanges).map { Range(found.range(at: $0), in: line).map { String(line[$0]) } }
        }
        func local(_ source: String?) -> Bool { source?.hasPrefix("127.0.0.1:") == true || source?.hasPrefix("[::1]:") == true }
        if let g = groups(matched), local(g[0]), g[1] == target, let rule = g[2], let policy = g[4] {
            return RouteMatch(rule: rule, payload: g[3] ?? "", policy: policy, node: g[5])
        }
        if let g = groups(failed), local(g[3]), g[4] == target, let policy = g[0], let rule = g[1] {
            return RouteMatch(rule: rule, payload: g[2] ?? "", policy: policy, node: nil, dialError: g[5])
        }
        return nil
    }

    /// 读取 offset 之后新写入的日志；内核重启会清空日志，此时从头读。
    static func scan(log: String, from offset: UInt64, target: String) -> RouteMatch? {
        guard let handle = FileHandle(forReadingAtPath: log) else { return nil }
        defer { try? handle.close() }
        let size = handle.seekToEndOfFile()
        handle.seek(toFileOffset: size >= offset ? offset : 0)
        let text = String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
        let matches = text.split(separator: "\n").compactMap { parse(line: String($0), target: target) }
        return matches.first { $0.dialError == nil } ?? matches.first
    }

    /// 阻塞执行，请在后台线程调用
    static func run(_ url: URL, log: String = "\(CFG_DIR)/mihomo.log") -> RouteTestResult {
        let offset = (try? FileManager.default.attributesOfItem(atPath: log)[.size] as? NSNumber)?.uint64Value ?? 0
        let started = Date()
        let (status, error) = request(url)
        let elapsed = Date().timeIntervalSince(started)
        // 日志写入稍有延迟，短暂轮询
        var match: RouteMatch?
        let deadline = Date().addingTimeInterval(1.5)
        repeat {
            match = scan(log: log, from: offset, target: target(url))
            if match != nil { break }
            Thread.sleep(forTimeInterval: 0.15)
        } while Date() < deadline
        return RouteTestResult(url: url, match: match, status: status, elapsed: elapsed, error: error)
    }

    /// 收到响应头即取消，不下载正文
    private final class HeadersOnly: NSObject, URLSessionDataDelegate {
        var status: Int?
        var error: Error?
        let done = DispatchSemaphore(value: 0)
        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            status = (response as? HTTPURLResponse)?.statusCode
            completionHandler(.cancel)
        }
        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if status == nil { self.error = error }
            done.signal()
        }
    }

    private static func request(_ url: URL) -> (Int?, String?) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPEnable as String: true,
            kCFNetworkProxiesHTTPProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPPort as String: 7890,
            "HTTPSEnable": true, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 7890,
        ]
        configuration.timeoutIntervalForRequest = 15
        let delegate = HeadersOnly()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        session.dataTask(with: url).resume()
        guard delegate.done.wait(timeout: .now() + 20) == .success else { return (nil, tr("请求超时", "Request timed out")) }
        return (delegate.status, delegate.error?.localizedDescription)
    }
}
