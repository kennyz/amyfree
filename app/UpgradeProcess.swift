import Foundation

// Drain output concurrently so large error output cannot block a download process.
private final class UpgradeOutput {
    private let lock = NSLock()
    private var data = Data()
    func append(_ chunk: Data) { lock.lock(); data.append(chunk); lock.unlock() }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

enum UpgradeProcess {
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval,
                    output: (String) -> Void = { _ in }, tick: () -> Void = {}) throws -> (status: Int32, text: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
        process.environment = AppRuntime.environment
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
        let buffer = UpgradeOutput(), drained = DispatchSemaphore(value: 0)
        try process.run()
        DispatchQueue.global(qos: .utility).async {
            while true {
                let chunk = pipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                buffer.append(chunk)
            }
            drained.signal()
        }
        let deadline = Date().addingTimeInterval(timeout)
        var last = ""
        while process.isRunning {
            let current = buffer.text
            if current != last { output(current); last = current }
            tick()
            if Date() > deadline {
                process.terminate()
                throw AppUpdateError(message: "更新超时，请检查网络后重试。")
            }
            Thread.sleep(forTimeInterval: 0.15)
        }
        process.waitUntilExit()
        _ = drained.wait(timeout: .now() + 5)
        let text = buffer.text; output(text); tick()
        return (process.terminationStatus, text)
    }
}
