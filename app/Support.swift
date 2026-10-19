// ============================================================
//  Swift 侧共用的路径与本地命令/API 辅助。
//  菜单栏由 Rust（app-rs）实现；尚未迁移的窗口仍用这些函数。
// ============================================================
import Foundation
// MARK: - 路径

let HOME = FileManager.default.homeDirectoryForCurrentUser.path
// 开发时可用 MIHOMO_HOME 指向仓库里的目录，避免去动 ~/.config：
//   MIHOMO_HOME=/path/to/repo/mihomo Amyfree.app/Contents/MacOS/Amyfree
let CFG_DIR = ProcessInfo.processInfo.environment["MIHOMO_HOME"] ?? "\(HOME)/.config/mihomo"
let CTL = "\(CFG_DIR)/mihomoctl.sh"
let PID_FILE = "\(CFG_DIR)/.mihomo.pid"
let SECRET_FILE = "\(CFG_DIR)/.api-secret"
let API = "127.0.0.1:9090"
let PROXY_URL = "http://127.0.0.1:7890"
let SUB_FILE = "\(CFG_DIR)/.sub-url"

// MARK: - 执行命令

struct RunResult {
    let status: Int32
    let out: String
}

@discardableResult
func run(_ launchPath: String, _ args: [String], timeout: TimeInterval = 25, input: String? = nil) -> RunResult {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: launchPath)
    p.arguments = args
    p.currentDirectoryPath = CFG_DIR

    p.environment = AppRuntime.environment

    let outPipe = Pipe()
    p.standardOutput = outPipe
    p.standardError = outPipe
    // 节点配置含凭据，经标准输入传递，不出现在进程参数里
    let inPipe = input.map { _ in Pipe() }
    if let inPipe = inPipe { p.standardInput = inPipe }

    do {
        try p.run()
    } catch {
        return RunResult(status: -1, out: tr("无法执行: ", "Could not run: ") + error.localizedDescription)
    }
    if let inPipe = inPipe, let input = input {
        inPipe.fileHandleForWriting.write(Data(input.utf8))
        try? inPipe.fileHandleForWriting.close()
    }

    // 超时保护：避免 curl 卡住导致菜单无响应
    let deadline = Date().addingTimeInterval(timeout)
    let sem = DispatchSemaphore(value: 0)
    var data = Data()
    DispatchQueue.global().async {
        data = outPipe.fileHandleForReading.readDataToEndOfFile()
        sem.signal()
    }
    while sem.wait(timeout: .now() + 0.05) == .timedOut {
        if Date() > deadline {
            p.terminate()
            return RunResult(status: -2, out: tr("命令超时", "Command timed out"))
        }
    }
    p.waitUntilExit()
    let text = String(data: data, encoding: .utf8) ?? ""
    return RunResult(status: p.terminationStatus, out: text)
}

// MARK: - 状态

var isRunning: Bool {
    guard let s = try? String(contentsOfFile: PID_FILE, encoding: .utf8) else {
        // 旧版以 root 启动的内核会留下仅 root 可读的 pid 文件，改问本地 API
        guard FileManager.default.fileExists(atPath: PID_FILE) else { return false }
        return httpGet("http://\(API)/version", timeout: 1) != nil
    }
    guard let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
    // TUN 模式下内核以 root 运行，kill 返回 EPERM 也说明进程存在
    return kill(pid, 0) == 0 || errno == EPERM
}

func apiSecret() -> String {
    (try? String(contentsOfFile: SECRET_FILE, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

/// 同步 HTTP GET（本地 API，极快；放后台线程调用）
func httpGet(_ urlStr: String, timeout: TimeInterval = 5) -> String? {
    guard let url = URL(string: urlStr) else { return nil }
    var req = URLRequest(url: url)
    req.timeoutInterval = timeout
    let secret = apiSecret()
    if !secret.isEmpty { req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization") }

    var result: String?
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: req) { data, _, _ in
        if let d = data { result = String(data: d, encoding: .utf8) }
        sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + timeout + 2)
    return result
}

/// 同步发送 PUT/DELETE 等请求到本地 API，返回是否成功（放后台线程调用）
@discardableResult
func httpSend(_ method: String, _ urlStr: String, json: [String: Any]? = nil, timeout: TimeInterval = 5) -> Bool {
    guard let url = URL(string: urlStr) else { return false }
    var req = URLRequest(url: url)
    req.httpMethod = method
    req.timeoutInterval = timeout
    let secret = apiSecret()
    if !secret.isEmpty { req.setValue("Bearer \(secret)", forHTTPHeaderField: "Authorization") }
    if let json = json {
        req.httpBody = try? JSONSerialization.data(withJSONObject: json)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
    }
    var ok = false
    let sem = DispatchSemaphore(value: 0)
    URLSession.shared.dataTask(with: req) { _, response, _ in
        ok = ((response as? HTTPURLResponse)?.statusCode).map { (200..<300).contains($0) } ?? false
        sem.signal()
    }.resume()
    _ = sem.wait(timeout: .now() + timeout + 2)
    return ok
}

