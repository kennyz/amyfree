import Foundation

/// 节点表单字段：按协议显示，读写 Clash 节点字典。表单未覆盖的字段（reality-opts、alpn 等）原样保留。
struct NodeFormField {
    enum Kind: Equatable { case text, number, toggle, choice([String]), combo([String]) }
    let path: [String]
    let title: String
    let kind: Kind
    let types: Set<String>?        // nil 表示所有协议
    var networks: Set<String>? = nil

    static let types = ["vless", "vmess", "trojan", "ss", "hysteria2", "tuic", "http", "socks5"]
    static let tlsTypes: Set<String> = ["vless", "vmess", "trojan", "hysteria2", "tuic", "http", "socks5"]
    static let transportTypes: Set<String> = ["vless", "vmess", "trojan"]

    static var all: [NodeFormField] { [
        NodeFormField(path: ["name"], title: tr("名称", "Name"), kind: .text, types: nil),
        NodeFormField(path: ["server"], title: tr("服务器", "Server"), kind: .text, types: nil),
        NodeFormField(path: ["port"], title: tr("端口", "Port"), kind: .number, types: nil),
        NodeFormField(path: ["cipher"], title: tr("加密方式", "Cipher"), kind: .combo(["aes-128-gcm", "aes-256-gcm", "chacha20-ietf-poly1305",
                      "2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm", "2022-blake3-chacha20-poly1305"]), types: ["ss"]),
        NodeFormField(path: ["cipher"], title: tr("加密方式", "Cipher"), kind: .combo(["auto", "aes-128-gcm", "chacha20-poly1305", "none"]), types: ["vmess"]),
        NodeFormField(path: ["uuid"], title: "UUID", kind: .text, types: ["vless", "vmess", "tuic"]),
        NodeFormField(path: ["alterId"], title: "alterId", kind: .number, types: ["vmess"]),
        NodeFormField(path: ["username"], title: tr("用户名", "Username"), kind: .text, types: ["http", "socks5"]),
        NodeFormField(path: ["password"], title: tr("密码", "Password"), kind: .text, types: ["ss", "trojan", "hysteria2", "tuic", "http", "socks5"]),
        NodeFormField(path: ["flow"], title: "Flow", kind: .combo(["", "xtls-rprx-vision"]), types: ["vless"]),
        NodeFormField(path: ["tls"], title: "TLS", kind: .toggle, types: ["vless", "vmess", "http", "socks5"]),
        NodeFormField(path: ["servername"], title: "SNI", kind: .text, types: ["vless", "vmess"]),
        NodeFormField(path: ["sni"], title: "SNI", kind: .text, types: ["trojan", "hysteria2", "tuic", "http"]),
        NodeFormField(path: ["skip-cert-verify"], title: tr("跳过证书验证", "Skip cert verify"), kind: .toggle, types: tlsTypes),
        NodeFormField(path: ["network"], title: tr("传输方式", "Transport"), kind: .choice(["tcp", "ws", "grpc"]), types: transportTypes),
        NodeFormField(path: ["ws-opts", "path"], title: tr("WS 路径", "WS path"), kind: .text, types: transportTypes, networks: ["ws"]),
        NodeFormField(path: ["ws-opts", "headers", "Host"], title: "WS Host", kind: .text, types: transportTypes, networks: ["ws"]),
        NodeFormField(path: ["grpc-opts", "grpc-service-name"], title: "gRPC service", kind: .text, types: transportTypes, networks: ["grpc"]),
        NodeFormField(path: ["udp"], title: "UDP", kind: .toggle, types: Set(types).subtracting(["http"])),
    ] }

    func visible(type: String, network: String) -> Bool {
        (types?.contains(type) ?? true) && (networks?.contains(network) ?? true)
    }

    /// 表单显示用的文字；开关以 "true"/"" 表示。
    func display(in node: [String: Any]) -> String {
        guard let value = nodeValue(node, path) else { return "" }
        if kind == .toggle { return (value as? Bool) == true ? "true" : "" }
        if let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() { return number.stringValue }
        return value as? String ?? "\(value)"
    }

    /// 文本转换为节点值；空值返回 nil（不写入）。端口等数字无法解析时保留原文，由保存时校验报错。
    func value(from text: String) -> Any? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .toggle: return trimmed == "true" ? true : nil
        case .number: return trimmed.isEmpty ? nil : (Int(trimmed) as Any?) ?? trimmed
        default: return trimmed.isEmpty ? nil : trimmed
        }
    }
}

func nodeValue(_ node: [String: Any], _ path: [String]) -> Any? {
    guard let key = path.first else { return nil }
    if path.count == 1 { return node[key] }
    return (node[key] as? [String: Any]).flatMap { nodeValue($0, Array(path.dropFirst())) }
}

/// 写入或删除（value 为 nil）嵌套字段；删除后变空的子字典一并移除。
func setNodeValue(_ node: inout [String: Any], _ path: [String], _ value: Any?) {
    guard let key = path.first else { return }
    if path.count == 1 { node[key] = value; return }
    var child = node[key] as? [String: Any] ?? [:]
    setNodeValue(&child, Array(path.dropFirst()), value)
    node[key] = child.isEmpty ? nil : child
}

/// 用表单值重建节点：先清除表单管理的全部字段，再写入当前协议可见的字段，其余字段保留。
func buildNode(base: [String: Any], type: String, values: [Int: String]) -> [String: Any] {
    var node = base
    let fields = NodeFormField.all
    for field in fields { setNodeValue(&node, field.path, nil) }
    node["type"] = type
    let network = fields.firstIndex { $0.path == ["network"] }.flatMap { values[$0] } ?? "tcp"
    for (index, field) in fields.enumerated() where field.visible(type: type, network: network) {
        if let value = field.value(from: values[index] ?? "") { setNodeValue(&node, field.path, value) }
    }
    return node
}
