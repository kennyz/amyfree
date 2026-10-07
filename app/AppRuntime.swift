import Foundation
import Security

struct RuntimeInstallError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum AppRuntime {
    static let files = ["mihomoctl.sh", "proxyctl.sh", "tun.sh", "verify_node.sh",
                        "parse_sub.py", "subscription.py", "node_speed.py", "chain_proxy.py",
                        "cert_probe.py", "nodes.py", "config.template.yaml",
                        "geoip.dat", "geosite.dat", "country.mmdb"]

    static var python: String {
        let bundled = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Python/bin/python3").path
        return FileManager.default.isExecutableFile(atPath: bundled) ? bundled : "/usr/bin/python3"
    }

    static var environment: [String: String] {
        var result = ProcessInfo.processInfo.environment
        result["PATH"] = "\(URL(fileURLWithPath: python).deletingLastPathComponent().path):/usr/bin:/bin:/usr/sbin:/sbin:/usr/local/bin:\(FileManager.default.homeDirectoryForCurrentUser.path)/.local/bin"
        let certificates = Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/Python/lib/python3.13/site-packages/certifi/cacert.pem").path
        if FileManager.default.fileExists(atPath: certificates) { result["SSL_CERT_FILE"] = certificates }
        // Never write bytecode back into the sealed, signed application bundle.
        result["PYTHONDONTWRITEBYTECODE"] = "1"
        result["PYTHONNOUSERSITE"] = "1"
        result.removeValue(forKey: "PYTHONHOME")
        result.removeValue(forKey: "PYTHONPATH")
        return result
    }

    @discardableResult
    static func prepare(directory: String) throws -> Bool {
        guard let resources = Bundle.main.resourceURL?.appendingPathComponent("runtime"),
              FileManager.default.fileExists(atPath: resources.path) else { return false }
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        let destination = URL(fileURLWithPath: directory, isDirectory: true)
        let updated = try install(resources: resources,
                                  binary: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/mihomo"),
                                  destination: destination, version: version)
        // Administrative and terminal launches do not inherit the app's environment.
        // Refresh the launcher when the application has moved to a new location.
        func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        var launcher = "#!/bin/bash\nexport PYTHONDONTWRITEBYTECODE=1 PYTHONNOUSERSITE=1\nunset PYTHONHOME PYTHONPATH\n"
        if let certificates = environment["SSL_CERT_FILE"] {
            launcher += "export SSL_CERT_FILE=\(quote(certificates))\n"
        }
        launcher += "exec \(quote(python)) \"$@\"\n"
        let target = destination.appendingPathComponent("python3")
        if (try? String(contentsOf: target, encoding: .utf8)) != launcher {
            try launcher.write(to: target, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        }
        return updated
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
                throw RuntimeInstallError(message: "安装包缺少运行组件，请重新下载 Amyfree。")
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
                throw RuntimeInstallError(message: "无法生成本机密钥，请重新打开 Amyfree。")
            }
            try (bytes.map { String(format: "%02x", $0) }.joined() + "\n").write(to: secret, atomically: true, encoding: .utf8)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: secret.path)
        }
        try version.write(to: marker, atomically: true, encoding: .utf8)
        return true
    }
}
