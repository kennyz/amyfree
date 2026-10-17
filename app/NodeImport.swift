import CoreImage
import Foundation

/// 从图片中识别二维码文字（CoreImage 内置识别器，无第三方依赖）。
func decodeQRCodes(at url: URL) -> [String] {
    guard let image = CIImage(contentsOf: url),
          let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh])
    else { return [] }
    return detector.features(in: image).compactMap { ($0 as? CIQRCodeFeature)?.messageString }
}

/// 节点分享链接的协议前缀；http(s) 地址通常是订阅而不是单个节点。
let nodeLinkSchemes = ["vless://", "vmess://", "ss://", "trojan://"]

enum NodeLinkCheck: Equatable { case link(String), subscription, unsupported }

/// 二维码或输入的文字中挑出第一条节点链接。
func nodeLink(in texts: [String]) -> NodeLinkCheck {
    let lines = texts.flatMap { $0.split(whereSeparator: \.isNewline) }.map { $0.trimmingCharacters(in: .whitespaces) }
    if let link = lines.first(where: { line in nodeLinkSchemes.contains { line.lowercased().hasPrefix($0) } }) { return .link(link) }
    if lines.contains(where: { $0.lowercased().hasPrefix("http://") || $0.lowercased().hasPrefix("https://") }) { return .subscription }
    return .unsupported
}
