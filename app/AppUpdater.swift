import Foundation

enum AppUpdater {
    static var currentVersion: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0" }

    // Called on a background queue; no GitHub token is needed for public releases.
    static func check() throws -> AvailableUpdate? {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/kennyz/amyfree/releases/latest")!)
        request.timeoutInterval = 25
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("Amyfree/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let semaphore = DispatchSemaphore(value: 0)
        var payload: Data?
        var status = 0
        var failure: Error?
        session.dataTask(with: request) { data, response, error in
            payload = data; status = (response as? HTTPURLResponse)?.statusCode ?? 0; failure = error
            semaphore.signal()
        }.resume()
        guard semaphore.wait(timeout: .now() + 30) == .success else { throw AppUpdateError(message: "检查更新超时，请稍后重试。") }
        if failure != nil { throw AppUpdateError(message: "暂时无法连接 GitHub，请检查网络后重试。") }
        guard status == 200, let data = payload else {
            throw AppUpdateError(message: status == 403 || status == 429 ? "GitHub 请求较多，请稍后重试。" : "更新服务暂时不可用，请稍后重试。")
        }
        return try UpdateRelease.parse(data, currentVersion: currentVersion)
    }

    static func stage(_ update: AvailableUpdate) throws -> URL {
        guard AppVersion(update.tag) != nil,
              let script = Bundle.main.resourceURL?.appendingPathComponent("install.sh"),
              FileManager.default.fileExists(atPath: script.path) else {
            throw AppUpdateError(message: "请从 GitHub Release 安装正式版后使用在线更新。")
        }
        let result = run("/bin/bash", [script.path, "--version", update.tag, "--stage-only"], timeout: 1000)
        guard result.status == 0,
              let line = result.out.split(separator: "\n").last(where: { $0.hasPrefix("AMYFREE_STAGED=") }) else {
            throw AppUpdateError(message: "下载或校验更新失败，当前版本继续可用。\n\(result.out.suffix(700))")
        }
        let path = String(line.dropFirst("AMYFREE_STAGED=".count))
        let directory = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).resolvingSymlinksInPath()
        guard directory.lastPathComponent.hasPrefix("amyfree-install."),
              directory.deletingLastPathComponent().resolvingSymlinksInPath() == temporary,
              FileManager.default.fileExists(atPath: directory.appendingPathComponent("install.sh").path) else {
            throw AppUpdateError(message: "无法读取更新暂存文件，请重试。")
        }
        return directory
    }

    static func handoff(_ directory: URL) throws {
        let destination = Bundle.main.bundleURL
        guard destination.lastPathComponent == "Amyfree.app",
              FileManager.default.isWritableFile(atPath: destination.deletingLastPathComponent().path) else {
            throw AppUpdateError(message: "应用所在目录不可写，请将 Amyfree 拖入 Applications 或 ~/Applications 后重试。")
        }
        let logDirectory = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs")
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        let log = logDirectory.appendingPathComponent("Amyfree-update.log")
        FileManager.default.createFile(atPath: log.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let output = try FileHandle(forWritingTo: log)
        defer { try? output.close() }
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/bash")
        helper.arguments = [directory.appendingPathComponent("install.sh").path, "--staged", directory.path,
                            "--target", destination.path, "--wait-pid", String(ProcessInfo.processInfo.processIdentifier)]
        helper.currentDirectoryURL = directory
        helper.standardInput = FileHandle.nullDevice
        helper.standardOutput = output; helper.standardError = output
        helper.environment = AppRuntime.environment
        try helper.run()
    }
}
