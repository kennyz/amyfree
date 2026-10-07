import Foundation

final class LocalNodeProbeBackend: NodeProbeBackend {
    private let directory: String
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    init(directory: String) { self.directory = directory }
    func fingerprint() -> String {
        // Python 的纳秒时间戳不能由 Foundation 精确重建；使用 helper 回传值并以文件签名检测变化。
        let paths = ["providers/nodes.yaml", ".mimio-chain.json"]
        return paths.map { path in
            let attributes = try? FileManager.default.attributesOfItem(atPath: "\(directory)/\(path)")
            return "\(attributes?[.systemFileNumber] ?? 0):\((attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0):\(attributes?[.size] ?? 0)"
        }.joined(separator: "|")
    }
    func perform(_ arguments: [String]) throws -> [String: Any] {
        let initial = fingerprint()
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        task.arguments = ["\(directory)/node_speed.py", "--home", directory] + arguments
        let output = Pipe()
        task.standardOutput = output
        task.standardError = FileHandle.nullDevice
        lock.lock()
        if cancelled { lock.unlock(); throw RoutingError("检测已取消") }
        process = task
        do { try task.run() } catch { process = nil; lock.unlock(); throw RoutingError("测速组件无法启动，请重新安装 Amyfree。") }
        lock.unlock()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        lock.lock(); process = nil; lock.unlock()
        guard var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { throw RoutingError("无法读取节点检测结果。") }
        if task.terminationStatus != 0 { throw RoutingError(object["error"] as? String ?? "节点检测失败。") }
        object["fingerprint"] = initial
        return object
    }
    func cancel() {
        lock.lock(); cancelled = true
        if process?.isRunning == true { process?.terminate() }
        lock.unlock()
    }
}
