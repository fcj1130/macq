import AppKit
import CryptoKit
import Foundation
import CoreImage
import Vision

/// 开发者工具箱：纯转换逻辑（无 UI、无状态），探针可直接验证。
/// 面板视图只负责输入输出，转换全部走这里。
enum DevTool: String, CaseIterable, Identifiable, Codable {
    case json
    case base64
    case url
    case timestamp
    case uuid
    case html
    case hash
    case qr
    case picker
    case password

    var id: String { rawValue }

    var name: String {
        switch self {
        case .json: "JSON 美化"
        case .base64: "Base64"
        case .url: "URL 编码"
        case .timestamp: "时间戳"
        case .uuid: "UUID"
        case .html: "HTML 编码"
        case .hash: "Hash"
        case .qr: "二维码"
        case .picker: "取色器"
        case .password: "随机密码"
        }
    }

    var icon: String {
        switch self {
        case .json: "curlybraces"
        case .base64: "doc.badge.gearshape"
        case .url: "link"
        case .timestamp: "clock"
        case .uuid: "number"
        case .html: "chevron.left.forwardslash.chevron.right"
        case .hash: "number.square"   // SF Symbol 没有 "hash"，实测不存在
        case .qr: "qrcode"
        case .picker: "eyedropper"
        case .password: "key"
        }
    }

    /// 面板左侧导航的默认顺序
    static let defaultOrder: [DevTool] = [.json, .base64, .url, .timestamp, .uuid, .html, .hash, .qr, .picker, .password]
}

enum DevToolboxCore {
    // MARK: - 密码生成

    public struct PasswordConfig: Codable, Equatable {
        /// 四类字符开关
        public var digits = true
        public var lowercase = true
        public var uppercase = true
        public var special = true
        /// 特殊字符集合（用户可改）
        public var specialChars = "!@#$%^&*-_=+?"
        /// 密码长度（4–128，越界自动钳制）
        public var length = 16
        /// 生成数量（1–100）
        public var count = 1

        public init() {}
    }

    public enum PasswordGen {
        /// 容易混淆的字符（需求指定：0 O i l I）
        public static let confusables: Set<Character> = ["0", "O", "i", "l", "I"]

        public static let digitPool = Set("0123456789").subtracting(confusables)
        public static let lowerPool = Set("abcdefghijklmnopqrstuvwxyz").subtracting(confusables)
        public static let upperPool = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ").subtracting(confusables)

        /// 特殊字符池：用户配置去重 + 剔除混淆字符
        public static func specialPool(_ c: PasswordConfig) -> String {
            String(Set(c.specialChars).sorted().filter { !$0.isWhitespace && !confusables.contains($0) })
        }

        /// 按配置生成 count 条密码：每类选中的字符集至少出一个，其余从全池补齐后洗牌。
        /// 随机源由调用方注入（探针可注入固定种子复现）。
        public static func generate(_ c: PasswordConfig, rng: inout some RandomNumberGenerator) -> [String] {
            let len = min(max(c.length, 4), 128)
            let n = min(max(c.count, 1), 100)
            var pools: [String] = []
            if c.digits { pools.append(String(digitPool.sorted())) }
            if c.lowercase { pools.append(String(lowerPool.sorted())) }
            if c.uppercase { pools.append(String(upperPool.sorted())) }
            if c.special { pools.append(specialPool(c)) }
            let all = pools.joined()
            guard !all.isEmpty, len >= pools.count else { return [] }
            func pick(_ s: String) -> Character {
                let a = Array(s)
                return a[Int(rng.next() % UInt64(a.count))]
            }
            var out: [String] = []
            for _ in 0..<n {
                var chars = pools.map(pick)              // 每类至少一个
                while chars.count < len { chars.append(pick(String(all))) }
                for i in stride(from: chars.count - 1, to: 0, by: -1) {
                    let j = Int(rng.next() % UInt64(i + 1))
                    chars.swapAt(i, j)
                }
                out.append(String(chars))
            }
            return out
        }
    }

    // MARK: - JSON

    /// 美化（缩进排版 + 键排序）。输入不是合法 JSON 时返回 nil，错误文案由调用方展示。
    static func jsonPretty(_ input: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(input.utf8), options: [.fragmentsAllowed]) else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .fragmentsAllowed]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// 压缩成单行
    static func jsonMinify(_ input: String) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(input.utf8), options: [.fragmentsAllowed]) else { return nil }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .fragmentsAllowed]) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Base64

    static func base64Encode(_ input: String) -> String {
        Data(input.utf8).base64EncodedString()
    }

    static func base64Decode(_ input: String) -> String? {
        // 宽松模式：证书/密钥里常见的 MIME 折行（内部换行）默认解码会直接失败
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = Data(base64Encoded: text, options: .ignoreUnknownCharacters) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - URL

    /// 全量百分号编码（字母数字之外全部编码），适合编码「一段要放进 URL 的值」
    static func urlEncode(_ input: String) -> String {
        input.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? input
    }

    static func urlDecode(_ input: String) -> String? {
        input.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
    }

    // MARK: - Hash

    enum HashAlgorithm: String, CaseIterable, Identifiable, Codable {
        case md5, sha1, sha256, sha512

        var id: String { rawValue }

        var name: String {
            switch self {
            case .md5: "MD5"
            case .sha1: "SHA-1"
            case .sha256: "SHA-256"
            case .sha512: "SHA-512"
            }
        }

        /// 摘要十六进制长度（小写/大写相同）
        var hexLength: Int {
            switch self {
            case .md5: 32
            case .sha1: 40
            case .sha256: 64
            case .sha512: 128
            }
        }
    }

    /// 输入的 UTF-8 字节摘要 → 十六进制，默认小写
    static func hashHex(_ input: String, algorithm: HashAlgorithm, uppercase: Bool = false) -> String {
        let data = Data(input.utf8)
        let hex: String
        switch algorithm {
        case .md5: hex = Insecure.MD5.hash(data: data).hexString
        case .sha1: hex = Insecure.SHA1.hash(data: data).hexString
        case .sha256: hex = SHA256.hash(data: data).hexString
        case .sha512: hex = SHA512.hash(data: data).hexString
        }
        return uppercase ? hex.uppercased() : hex
    }

    // MARK: - 二维码

    /// 纠错级别：L≈7% M≈15% Q≈25% H≈30%，级别越高可客纳内容越少
    enum QRCorrectionLevel: String, CaseIterable, Identifiable, Codable {
        case low = "L", medium = "M", quarter = "Q", high = "H"

        var id: String { rawValue }

        var hint: String {
            switch self {
            case .low: "7%"
            case .medium: "15%"
            case .quarter: "25%"
            case .high: "30%"
            }
        }
    }

    /// 生成二维码 PNG（白底黑码，无插值放大保持模块锐利）；内容超出容量时返回 nil。
    /// logo：叠加居中白底圆角垫片 + 图片，约占 24% 边长——建议配合 H 级别（30% 纠错）保扫描。
    static func qrPNG(_ text: String, level: QRCorrectionLevel = .medium, pixels: Int = 600, logo: NSImage? = nil) -> Data? {
        guard !text.isEmpty, let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue(level.rawValue, forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }   // 内容超容量时为 nil
        let scale = CGFloat(pixels) / max(output.extent.width, 1)
        let transformed = output.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let white = CIImage(color: CIColor.white).cropped(to: transformed.extent)
        let composed = transformed.composited(over: white)
        guard let qrCG = CIContext().createCGImage(composed, from: composed.extent) else { return nil }

        guard let logo else {
            let rep = NSBitmapImageRep(cgImage: qrCG)
            return rep.representation(using: .png, properties: [:])
        }

        // logo 版本：手绘到位图（垫片 + 居中图片），二维码本体仍无插值
        let size = CGFloat(pixels)
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        guard let context = NSGraphicsContext(bitmapImageRep: rep) else {
            NSGraphicsContext.restoreGraphicsState(); return nil
        }
        NSGraphicsContext.current = context
        context.imageInterpolation = .none
        context.cgContext.draw(qrCG, in: CGRect(x: 0, y: 0, width: size, height: size))
        let side = size * 0.24
        let logoRect = CGRect(x: (size - side) / 2, y: (size - side) / 2, width: side, height: side)
        NSBezierPath(roundedRect: logoRect, xRadius: side * 0.12, yRadius: side * 0.12).setClip()
        NSColor.white.setFill()
        logoRect.fill()
        logo.draw(in: logoRect, from: .zero, operation: .sourceOver, fraction: 1.0, respectFlipped: false,
                  hints: [.interpolation: NSImageInterpolation.high])
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .png, properties: [:])
    }

    /// 解析图片里的二维码文本（多张时全部返回）；无二维码返回空数组
    static func qrDecode(_ image: NSImage) -> [String] {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return [] }
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
        return (request.results ?? []).compactMap(\ .payloadStringValue)
    }

    // MARK: - 颜色

    /// NSColor → #RRGGBB（includeAlpha 时追加 AA）。
    /// 先归一化到 sRGB：calibrated 空间的分量不等于显示值。
    static func hexString(_ color: NSColor, includeAlpha: Bool = false) -> String {
        guard let c = color.usingColorSpace(.sRGB) else { return "" }
        func byte(_ v: CGFloat) -> String { String(format: "%02X", Int((v * 255).rounded())) }
        var hex = "#" + byte(c.redComponent) + byte(c.greenComponent) + byte(c.blueComponent)
        if includeAlpha { hex += byte(c.alphaComponent) }
        return hex
    }

    /// CSS rgba(...)，透明度两位小数
    static func cssRGBA(_ color: NSColor) -> String {
        guard let c = color.usingColorSpace(.sRGB) else { return "" }
        func byte(_ v: CGFloat) -> Int { Int((v * 255).rounded()) }
        return String(format: "rgba(%d, %d, %d, %.2f)", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent), c.alphaComponent)
    }

    /// 解析 HEX：支持 #RGB / #RRGGBB / #RRGGBBAA（大小写、有无 #）
    static func color(fromHex raw: String) -> NSColor? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard [3, 6, 8].contains(text.count), text.allSatisfy({ $0.isHexDigit }) else { return nil }
        if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }   // #fff → #ffffff
        func channel(_ start: Int) -> CGFloat { CGFloat(UInt64(text.dropFirst(start).prefix(2), radix: 16) ?? 0) / 255 }
        let alpha: CGFloat = text.count == 8 ? channel(6) : 1
        return NSColor(srgbRed: channel(0), green: channel(2), blue: channel(4), alpha: alpha)
    }

    // MARK: - 时间戳

    struct TimestampInfo: Equatable {
        var seconds: Int          // 10 位秒级
        var milliseconds: Int     // 13 位毫秒级
        var localDash: String     // 本地日期 yyyy-MM-dd HH:mm:ss
        var localSlash: String    // 本地日期 yyyy/MM/dd HH:mm:ss
        var iso8601: String       // ISO 8601（含时区）
        var relative: String      // 相对现在
    }

    /// 兼容秒（10 位）/ 毫秒（13 位）输入，其它位数按秒处理；0 = 纪元起点，同样有效
    static func normalizeTimestamp(_ raw: String) -> Int? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(text) else { return nil }
        return text.count >= 13 ? value / 1000 : value
    }

    static func timestampInfo(seconds: Int, now: Date = Date()) -> TimestampInfo {
        let date = Date(timeIntervalSince1970: TimeInterval(seconds))
        let iso = Self.isoFormatter.string(from: date)
        let delta = now.timeIntervalSince(date)
        var relative: String
        switch abs(delta) {
        case ..<60:
            relative = delta >= 0 ? AppLanguage.localized("刚刚") : String(format: AppLanguage.localized("%d 秒后"), Int(-delta))
        case ..<3600:
            relative = delta >= 0 ? String(format: AppLanguage.localized("%d 分钟前"), Int(delta / 60)) : String(format: AppLanguage.localized("%d 分钟后"), Int(-delta / 60))
        case ..<86400:
            relative = delta >= 0 ? String(format: AppLanguage.localized("%d 小时前"), Int(delta / 3600)) : String(format: AppLanguage.localized("%d 小时后"), Int(-delta / 3600))
        default:
            relative = delta >= 0 ? String(format: AppLanguage.localized("%d 天前"), Int(delta / 86400)) : String(format: AppLanguage.localized("%d 天后"), Int(-delta / 86400))
        }
        return TimestampInfo(seconds: seconds, milliseconds: seconds * 1000,
                             localDash: Self.dashFormatter.string(from: date),
                             localSlash: Self.slashFormatter.string(from: date),
                             iso8601: iso, relative: relative)
    }

    /// 日期 → 秒级时间戳
    static func timestamp(from date: Date) -> Int {
        Int(date.timeIntervalSince1970)
    }

    /// 日期 → 毫秒级时间戳（四舍五入到整毫秒）
    static func timestampMs(from date: Date) -> Int {
        Int((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// 解析用户粘贴/输入的日期文本；不带时区标记的格式按本地时区。
    /// 支持：yyyy-MM-dd[ HH:mm[:ss]]、yyyy/MM/dd[ HH:mm[:ss]]、T 分隔的本地时间、ISO8601（含时区）。
    static func parseDate(_ raw: String) -> Date? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let date = Self.isoFormatter.date(from: text) { return date }   // ISO8601（含 Z/偏移）
        for formatter in Self.inputFormatters {
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    /// 日期输入的解析器集合（POSIX 字面格式，不受系统区域影响）
    private static let inputFormatters: [DateFormatter] = {
        ["yyyy-MM-dd HH:mm:ss", "yyyy/MM/dd HH:mm:ss",
         "yyyy-MM-dd HH:mm", "yyyy/MM/dd HH:mm",
         "yyyy-MM-dd", "yyyy/MM/dd",
         "yyyy-MM-dd'T'HH:mm:ss"].map { format in
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            return formatter
        }
    }()

    /// 本地日期的两种展示格式（用户指定）：yyyy-MM-dd HH:mm:ss 与 yyyy/MM/dd HH:mm:ss。
    /// en_US_POSIX：固定字面格式，不随系统区域把符号本地化。
    private static let dashFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static let slashFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy/MM/dd HH:mm:ss"
        return formatter
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    // MARK: - UUID

    /// 生成 UUID；默认大写带连字符，两个开关由调用方传入
    static func generateUUID(uppercase: Bool = true, hyphenated: Bool = true) -> String {
        let raw = UUID().uuidString
        let cased = uppercase ? raw : raw.lowercased()
        return hyphenated ? cased : cased.replacingOccurrences(of: "-", with: "")
    }

    // MARK: - HTML

    static func htmlEncode(_ input: String) -> String {
        let map: [Character: String] = [
            "&": "&amp;", "<": "&lt;", ">": "&gt;", "\"": "&quot;", "'": "&#39;",
        ]
        return input.map { map[$0] ?? String($0) }.joined()
    }

    static func htmlDecode(_ input: String) -> String? {
        // 轻量实体替换：覆盖编码侧的全部实体 + 常见命名实体 + 十进制/十六进制数字实体。
        // 不用 NSAttributedString(.html)——那会拉起 WebKit，每次按键上百毫秒。
        var result = ""
        var scanner = Substring(input)
        while let amp = scanner.firstIndex(of: "&") {
            result += scanner[..<amp]
            let rest = scanner[amp...]
            guard let semicolon = rest.firstIndex(of: ";"), rest.distance(from: rest.startIndex, to: semicolon) <= 12 else {
                result += "&"
                scanner = rest.dropFirst()
                continue
            }
            let entity = rest[rest.index(after: rest.startIndex)..<semicolon]  // “amp” 这一段
            result += Self.resolveHTMLEntity(String(entity)) ?? "&"
            scanner = rest[rest.index(after: semicolon)...]
        }
        result += scanner
        return result
    }

    /// 实体名/数字实体 → 字符；解不了的返回 nil（按原样保留 &）
    private static func resolveHTMLEntity(_ entity: String) -> String? {
        let named: [String: String] = [
            "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": " ",
            "copy": "©", "reg": "®", "trade": "™", "hellip": "…", "mdash": "—", "ndash": "–",
            "ldquo": "“", "rdquo": "”", "lsquo": "‘", "rsquo": "’", "laquo": "«", "raquo": "»",
            "bull": "•", "middot": "·", "deg": "°", "euro": "€", "pound": "£", "yen": "¥",
            "cent": "¢", "sect": "§", "para": "¶", "times": "×", "divide": "÷", "plusmn": "±",
        ]
        if let mapped = named[entity] { return mapped }
        if entity.hasPrefix("#") {
            let digits = entity.dropFirst()
            let value = digits.hasPrefix("x") || digits.hasPrefix("X")
                ? UInt32(digits.dropFirst(), radix: 16)
                : UInt32(digits)
            if let value, let scalar = Unicode.Scalar(value) { return String(Character(scalar)) }
        }
        return nil
    }
}


extension Digest {
    /// 小写十六进制（避免每个算法各写一遍 map/format）
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
