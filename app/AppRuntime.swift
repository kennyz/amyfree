import Foundation
import Security

struct RuntimeInstallError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum AppRuntime {
    static let files = ["mihomoctl.sh", "proxyctl.sh", "tun.sh", "verify_node.sh", "refresh-geodata.sh", "config.template.yaml",
                        "geoip.dat", "geosite.dat", "country.mmdb"]

    /// Native runtime helper (Rust) that replaced the Python scripts; built into Contents/MacOS.
    static let helperName = "amyfree-helper"
    static var bundledHelper: String { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/\(helperName)").path }

    /// The helper the app runs: the bundled one, or the copy in the config folder (debug runs outside a bundle).
    static func helper(in directory: String) -> String {
        FileManager.default.isExecutableFile(atPath: bundledHelper) ? bundledHelper : "\(directory)/\(helperName)"
    }

    static var environment: [String: String] {
        var result = ProcessInfo.processInfo.environment
        result["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin"
        // 运行脚本按此输出提示文字，与界面语言一致
        result["AMYFREE_LANG"] = AppLanguage.current.rawValue
        return result
    }

    @discardableResult
    static func prepare(directory: String) throws -> Bool {
        try installHelper(directory: directory)
        guard let resources = Bundle.main.resourceURL?.appendingPathComponent("runtime"),
              FileManager.default.fileExists(atPath: resources.path) else { return false }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        let destination = URL(fileURLWithPath: directory, isDirectory: true)
        let updated = try install(resources: resources,
                                  binary: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/mihomo"),
                                  destination: destination, version: version)
        return updated
    }

    /// Copies the bundled helper into the config folder whenever it differs, so the shell scripts
    /// (and terminal or administrator runs, which don't know where the app is) can use it.
    /// Also removes the Python launcher left by versions before 1.7.
    static func installHelper(directory: String) throws {
        let manager = FileManager.default
        let target = URL(fileURLWithPath: directory).appendingPathComponent(helperName)
        if manager.isExecutableFile(atPath: bundledHelper), let bundled = manager.contents(atPath: bundledHelper),
           manager.contents(atPath: target.path) != bundled {
            try manager.createDirectory(atPath: directory, withIntermediateDirectories: true)
            let temporary = target.deletingLastPathComponent().appendingPathComponent(".\(helperName).incoming")
            try? manager.removeItem(at: temporary)
            try bundled.write(to: temporary)
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: temporary.path)
            _ = try manager.replaceItemAt(target, withItemAt: temporary)
        }
        let launcher = URL(fileURLWithPath: directory).appendingPathComponent("python3")
        if let text = try? String(contentsOf: launcher, encoding: .utf8), text.contains("PYTHONDONTWRITEBYTECODE") {
            try? manager.removeItem(at: launcher)
        }
        for old in ["parse_sub.py", "subscription.py", "node_speed.py", "chain_proxy.py", "cert_probe.py", "node_manager.py", "nodes.py", "geodata_update.py"] {
            try? manager.removeItem(atPath: "\(directory)/\(old)")
        }
    }

    @discardableResult
    static func install(resources: URL, binary: URL, destination: URL, version: String) throws -> Bool {
        let manager = FileManager.default
        let marker = destination.appendingPathComponent(".amyfree-runtime-version")
        let ready = (["mihomo", "config.yaml", ".api-secret"] + files).allSatisfy {
            manager.fileExists(atPath: destination.appendingPathComponent($0).path)
        }
        if ready, (try? String(contentsOf: marker, encoding: .utf8)) == version { return false }
        for path in files.map({ resources.appendingPathComponent($0) }) + [binary] {
            guard manager.fileExists(atPath: path.path) else {
                throw RuntimeInstallError(message: tr("安装包缺少运行组件，请重新下载 Amyfree。", "The package is missing runtime components. Please download Amyfree again."))
            }
        }
        try manager.createDirectory(at: destination.appendingPathComponent("providers"),
                                    withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        for name in files {
            let target = destination.appendingPathComponent(name)
            // Preserve local rule databases; scripts are updated with each app version.
            if ["geoip.dat", "geosite.dat", "country.mmdb"].contains(name), manager.fileExists(atPath: target.path) { continue }
            try Data(contentsOf: resources.appendingPathComponent(name)).write(to: target, options: .atomic)
            try manager.setAttributes([.posixPermissions: name.hasSuffix(".sh") ? 0o755 : 0o644], ofItemAtPath: target.path)
        }
        let installedBinary = destination.appendingPathComponent("mihomo")
        try Data(contentsOf: binary).write(to: installedBinary, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: installedBinary.path)
        let config = destination.appendingPathComponent("config.yaml")
        if !manager.fileExists(atPath: config.path) {
            try Data(contentsOf: resources.appendingPathComponent("config.template.yaml")).write(to: config, options: .atomic)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
        }
        let secret = destination.appendingPathComponent(".api-secret")
        if !manager.fileExists(atPath: secret.path) {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                throw RuntimeInstallError(message: tr("无法生成本机密钥，请重新打开 Amyfree。", "Could not generate the local API key. Please reopen Amyfree."))
            }
            try (bytes.map { String(format: "%02x", $0) }.joined() + "\n").write(to: secret, atomically: true, encoding: .utf8)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secret.path)
        }
        try version.write(to: marker, atomically: true, encoding: .utf8)
        return true
    }
}
