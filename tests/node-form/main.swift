import CoreImage
import Foundation

var failures = 0
func expect(_ condition: Bool, _ message: String) {
    if !condition { failures += 1; print("FAIL: \(message)") }
}
func values(_ pairs: [[String]: String]) -> [Int: String] {
    var result: [Int: String] = [:]
    for (index, field) in NodeFormField.all.enumerated() { if let value = pairs[field.path] { result[index] = value } }
    return result
}

// 表单只改动自己管理的字段；reality-opts 等未覆盖的字段原样保留。
let base: [String: Any] = ["name": "a", "type": "vless", "server": "old.example", "port": 443, "uuid": "u",
                           "tls": true, "reality-opts": ["public-key": "k"], "network": "ws",
                           "ws-opts": ["path": "/old", "max-early-data": 2048]]
var form = values([["name"]: "a", ["server"]: " new.example ", ["port"]: "8443", ["uuid"]: "u", ["tls"]: "true",
                   ["network"]: "ws", ["ws-opts", "path"]: "/new", ["ws-opts", "headers", "Host"]: "", ["udp"]: ""])
var node = buildNode(base: base, type: "vless", values: form)
expect(node["server"] as? String == "new.example", "text is trimmed")
expect(node["port"] as? Int == 8443, "port is numeric")
expect(node["tls"] as? Bool == true && node["udp"] == nil, "toggles map to true or absent")
expect((node["reality-opts"] as? [String: String])?["public-key"] == "k", "unmanaged fields are kept")
let ws = node["ws-opts"] as? [String: Any]
expect(ws?["path"] as? String == "/new" && ws?["max-early-data"] as? Int == 2048 && ws?["headers"] == nil, "nested paths update in place")

// 切换为 trojan + tcp：不适用的字段（uuid、tls、ws 路径）被移除。
form = values([["name"]: "a", ["server"]: "s", ["port"]: "443", ["uuid"]: "u", ["password"]: "p", ["tls"]: "true",
               ["network"]: "tcp", ["ws-opts", "path"]: "/new", ["sni"]: "sni.example"])
node = buildNode(base: base, type: "trojan", values: form)
expect(node["uuid"] == nil && node["tls"] == nil, "fields hidden for the protocol are dropped")
expect(node["password"] as? String == "p" && node["sni"] as? String == "sni.example", "protocol fields are written")
expect((node["ws-opts"] as? [String: Any])?["path"] == nil, "ws path dropped off ws transport")
expect(buildNode(base: [:], type: "vless", values: values([["port"]: "abc"]))["port"] as? String == "abc", "unparsable port kept for validation")

// 显示：数字转文字，布尔不被当作数字。
let port = NodeFormField.all.first { $0.path == ["port"] }!
let tls = NodeFormField.all.first { $0.path == ["tls"] }!
expect(port.display(in: ["port": 443]) == "443", "number display")
expect(tls.display(in: ["tls": true]) == "true" && tls.display(in: ["tls": false]) == "", "bool display")
let decoded = try! JSONSerialization.jsonObject(with: Data(#"{"port":443,"tls":true}"#.utf8)) as! [String: Any]
expect(port.display(in: decoded) == "443" && tls.display(in: decoded) == "true", "JSON numbers and booleans display correctly")
expect(NodeFormField.all.filter { $0.visible(type: "ss", network: "tcp") }.map(\.path.first!) == ["name", "server", "port", "cipher", "password", "udp"], "ss form fields")

// 二维码：生成 → 写入 PNG → 识别，并从中挑出节点链接。
let link = "trojan://pw@t.example:443?sni=t.example#qr-node"
let generator = CIFilter(name: "CIQRCodeGenerator")!
generator.setValue(Data(link.utf8), forKey: "inputMessage")
let qr = generator.outputImage!.transformed(by: CGAffineTransform(scaleX: 12, y: 12))
let padded = qr.composited(over: CIImage(color: .white).cropped(to: qr.extent.insetBy(dx: -40, dy: -40)))
let png = FileManager.default.temporaryDirectory.appendingPathComponent("amyfree-qr-\(UUID().uuidString).png")
try! CIContext().writePNGRepresentation(of: padded, to: png, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
defer { try? FileManager.default.removeItem(at: png) }
expect(decodeQRCodes(at: png) == [link], "QR code image decodes to the link")
expect(decodeQRCodes(at: URL(fileURLWithPath: "/nonexistent.png")).isEmpty, "missing image yields nothing")
expect(nodeLink(in: ["note\n  " + link]) == .link(link), "link found among lines")
expect(nodeLink(in: ["VLESS://u@h:1#x"]) == .link("VLESS://u@h:1#x"), "scheme match ignores case")
expect(nodeLink(in: ["https://sub.example/token"]) == .subscription, "subscription URL detected")
expect(nodeLink(in: ["hello"]) == .unsupported, "plain text unsupported")

print("Node form tests: \(failures) failures")
exit(failures == 0 ? 0 : 1)
