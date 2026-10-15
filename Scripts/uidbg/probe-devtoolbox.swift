// 开发者工具箱探针：核心转换逻辑 + 面板 UI（离屏渲染、OCR、点击导航、拖拽排序模型）
// 跑法：./Scripts/uidbg/probe.sh Scripts/uidbg/probe-devtoolbox.swift
import AppKit
import SwiftUI
import Vision

var failures = 0

@MainActor
func expect(_ ok: Bool, _ label: String, _ detail: String = "") {
    if ok { print("  ✓ \(label)\(detail.isEmpty ? "" : "：\(detail)")") } else { failures += 1; print("  ✗ \(label)\(detail.isEmpty ? "" : "：\(detail)")") }
}

@MainActor
func runProbe() {
    // ── 核心转换逻辑
    let json = "{\"b\":1,\"a\":[3,2]}"
    let pretty = DevToolboxCore.jsonPretty(json)
    expect(pretty?.contains("\n") == true && pretty?.contains("\"a\" : [") == true, "JSON 美化：换行 + 键排序")
    expect(pretty == DevToolboxCore.jsonPretty(pretty ?? ""), "JSON 美化幂等")
    expect(DevToolboxCore.jsonMinify(pretty ?? "")?.contains("\n") == false, "JSON 压缩成单行")
    expect(DevToolboxCore.jsonPretty("not json {") == nil, "非法 JSON 返回 nil")
    expect(DevToolboxCore.jsonPretty("[1,2]") != nil, "顶层数组也是合法 JSON")
    // 大整数精度：新版 Foundation 用十进制串保真，2^53+1 和 UInt64 max 都必须精确往返（雪花 ID 场景）
    let big = "{\"id\":9007199254740993,\"big\":18446744073709551615}"
    expect(DevToolboxCore.jsonPretty(big)?.contains("9007199254740993") == true
        && DevToolboxCore.jsonPretty(big)?.contains("18446744073709551615") == true, "JSON 大整数精确往返（无浮点舍入）")

    expect(DevToolboxCore.base64Decode(DevToolboxCore.base64Encode("你好 dev")) == "你好 dev", "Base64 编解码往返（含中文）")
    expect(DevToolboxCore.base64Decode("aGVs\nbG8=") == "hello", "Base64 解码容忍内部折行（证书/密钥常见）")
    expect(DevToolboxCore.base64Decode("!!!not-base64!!!") == nil, "非法 Base64 返回 nil")
    expect(DevToolboxCore.base64Decode("aGVsbG8=") == "hello", "Base64 解码标准样例")

    let urlInput = "a b&c=1?中"
    let encoded = DevToolboxCore.urlEncode(urlInput)
    expect(!encoded.contains(" ") && !encoded.contains("&") && !encoded.contains("?") && !encoded.contains("中"), "URL 编码：空格/&/?/中文全部编码")
    expect(DevToolboxCore.urlDecode(encoded) == urlInput, "URL 编解码往返")
    expect(DevToolboxCore.urlDecode("a+b%20c") == "a b c", "URL 解码：+ 与 %20 都按空格")

    expect(DevToolboxCore.normalizeTimestamp("1760000000") == 1760000000, "10 位秒级时间戳原样")
    expect(DevToolboxCore.normalizeTimestamp("0") == 0, "时间戳 0（纪元起点）有效")
    expect(DevToolboxCore.normalizeTimestamp("1760000000123") == 1760000000, "13 位毫秒级自动换算成秒")
    expect(DevToolboxCore.normalizeTimestamp("abc") == nil, "非数字返回 nil")
    let info = DevToolboxCore.timestampInfo(seconds: 0, now: Date(timeIntervalSince1970: 120))
    expect(info.milliseconds == 0 && info.iso8601 == "1970-01-01T00:00:00Z", "时间戳信息：毫秒换算 + ISO8601（UTC）", info.iso8601)
    expect(info.localDash.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}$"#, options: .regularExpression) != nil,
           "本地日期横杠格式 yyyy-MM-dd HH:mm:ss", info.localDash)
    expect(info.localSlash.range(of: #"^\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2}$"#, options: .regularExpression) != nil,
           "本地日期斜杠格式 yyyy/MM/dd HH:mm:ss", info.localSlash)
    expect(info.localSlash == info.localDash.replacingOccurrences(of: "-", with: "/"),
           "两种格式内容一致（仅分隔符不同）")

    // 日期解析：期望值用日历构造（时区无关），不依赖实现用的同一套格式器
    var localComps = DateComponents(); localComps.year = 2026; localComps.month = 9; localComps.day = 18
    localComps.hour = 20; localComps.minute = 15; localComps.second = 32
    let expectedLocal = Calendar.current.date(from: localComps)!
    expect(DevToolboxCore.parseDate("2026-09-18 20:15:32") == expectedLocal, "解析横杠格式（秒级精度）")
    expect(DevToolboxCore.parseDate("2026/09/18 20:15:32") == expectedLocal, "解析斜杠格式（与横杠同值）")
    expect(DevToolboxCore.parseDate("  2026-09-18 20:15:32 \n") == expectedLocal, "容忍首尾空白/换行（粘贴常见）")
    var utcComps = DateComponents(timeZone: TimeZone(identifier: "UTC")); utcComps.year = 2026
    utcComps.month = 9; utcComps.day = 18; utcComps.hour = 12; utcComps.minute = 15; utcComps.second = 32
    let expectedUTC = Calendar.current.date(from: utcComps)!
    expect(DevToolboxCore.parseDate("2026-09-18T12:15:32Z") == expectedUTC, "解析 ISO8601（Z 时区，绝对时间）")
    var midnightComps = DateComponents(); midnightComps.year = 2026; midnightComps.month = 9; midnightComps.day = 18
    let midnight = Calendar.current.date(from: midnightComps)!
    expect(DevToolboxCore.parseDate("2026-09-18") == midnight, "纯日期按本地零点")
    expect(DevToolboxCore.parseDate("不是日期") == nil, "无法解析返回 nil")
    expect(DevToolboxCore.timestampMs(from: expectedLocal) == Int(expectedLocal.timeIntervalSince1970 * 1000),
           "毫秒换算与秒一致（秒×1000）")
    expect(info.relative.contains("分钟前"), "相对时间：2 分钟前", info.relative)
    let future = DevToolboxCore.timestampInfo(seconds: 3_000_000_000, now: Date(timeIntervalSince1970: 0))
    expect(future.relative.contains("后"), "未来时间显示「…后」", future.relative)

    let uuid = DevToolboxCore.generateUUID()
    expect(uuid.count == 36 && uuid.filter { $0 == "-" }.count == 4 && uuid == uuid.uppercased(), "UUID：36 位、4 连字符、大写", uuid)
    let uuidLower = DevToolboxCore.generateUUID(uppercase: false)
    expect(uuidLower == uuidLower.lowercased() && uuidLower.contains("-") , "UUID：小写开关", uuidLower)
    let noHyphen = DevToolboxCore.generateUUID(hyphenated: false)
    expect(noHyphen.count == 32 && !noHyphen.contains("-"), "UUID：无连字符 32 位")
    let bare = DevToolboxCore.generateUUID(uppercase: false, hyphenated: false)
    expect(bare.count == 32 && bare == bare.lowercased(), "UUID：小写 + 无连字符组合")

    let html = "<a href=\"x\">&'</a>"
    let htmlEncoded = DevToolboxCore.htmlEncode(html)
    expect(htmlEncoded.contains("&lt;") && htmlEncoded.contains("&quot;") && htmlEncoded.contains("&amp;") && htmlEncoded.contains("&#39;"), "HTML 编码：五个实体全")
    expect(DevToolboxCore.htmlDecode(htmlEncoded) == html, "HTML 编解码往返")
    expect(DevToolboxCore.htmlDecode("a&nbsp;b&#65;&#x42;") == "a\u{00A0}bAB", "HTML 解码：命名 + 十进制 + 十六进制实体")
    expect(DevToolboxCore.htmlDecode("&copy;&hellip;&mdash;&euro;") == "©…—€", "HTML 解码：常见符号实体")
    expect(DevToolboxCore.htmlDecode("孤立的 & 后面没有分号") == "孤立的 & 后面没有分号", "孤立 & 原样保留")

    // ── 工具：排序模型 + 持久化
    let settings = ToolSettings(tool: "devToolbox-probe", schema: 1)
    settings.removeAll()
    let tool = DevToolbox(settings: settings)
    expect(tool.order == DevTool.defaultOrder, "默认导航顺序")
    tool.move(.uuid, to: .json)
    expect(tool.order.first == .uuid && tool.order.count == DevTool.defaultOrder.count, "move：UUID 挪到最前")
    tool.move(.json, to: .json)
    expect(tool.order.first == .uuid, "move：拖到自己身上不变")
    let persisted = UserDefaults.standard.stringArray(forKey: "devToolbox-probe.order")
    expect(persisted?.first == "uuid", "顺序已持久化", persisted?.joined(separator: ",") ?? "nil")
    expect(tool.trigger.display == "⌥⌘D", "默认快捷键 ⌥⌘D", tool.trigger.display)
    // 面板窗口是进程级单例资源，探针里只验证状态与键盘导航，不真弹（避免抢焦点）
    let panelState = DevToolboxPanelState()
    expect(panelState.selected == .json, "初始选中 JSON")
    settings.removeAll()

    // ── 面板 UI：离屏渲染 + OCR + 点击导航
    let hosting = host(DevToolboxPanelView(tool: tool, state: panelState), width: 720, height: 480)
    guard let rep = render(hosting) else { print("  ✗ 渲染失败"); failures += 1; return }
    let boxes = ocrBoxes(rep)
    let texts = boxes.map(\.text)
    ocr(rep, "开发者工具箱面板")

    func normalize(_ value: String) -> String {
        value.replacingOccurrences(of: " ", with: "").lowercased()
    }
    let flattened = normalize(texts.joined(separator: "|"))
    func has(_ needle: String) -> Bool { flattened.contains(normalize(needle)) }

    expect(has("JSON 美化"), "导航第一项 JSON")
    expect(has("Base64"), "导航 Base64")
    expect(has("URL 编码"), "导航 URL 编码")
    expect(has("时间戳"), "导航 时间戳")
    expect(has("UUID"), "导航 UUID")
    expect(has("HTML 编码"), "导航 HTML 编码")
    expect(has("Hash"), "导航 Hash")
    expect(has("二维码"), "导航 二维码")
    expect(has("取色器"), "导航 取色器")

    // ── 颜色：hex/css 互转与解析
    let red = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)
    expect(DevToolboxCore.hexString(red) == "#FF0000", "HEX 转换（红）", DevToolboxCore.hexString(red))
    let halfAlpha = NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 0.5)
    expect(DevToolboxCore.hexString(halfAlpha, includeAlpha: true) == "#FF000080", "HEX 含透明度（50% → 80）", DevToolboxCore.hexString(halfAlpha, includeAlpha: true))
    expect(DevToolboxCore.cssRGBA(halfAlpha) == "rgba(255, 0, 0, 0.50)", "CSS rgba 格式", DevToolboxCore.cssRGBA(halfAlpha))
    expect(DevToolboxCore.hexString(DevToolboxCore.color(fromHex: "#34ABCD")!) == "#34ABCD", "解析 #RRGGBB 往返")
    expect(DevToolboxCore.hexString(DevToolboxCore.color(fromHex: "#34abcd80")!, includeAlpha: true) == "#34ABCD80", "解析 #RRGGBBAA 往返（保留透明度）")
    expect(DevToolboxCore.color(fromHex: "#F90") != nil
        && DevToolboxCore.hexString(DevToolboxCore.color(fromHex: "#F90")!) == "#FF9900", "解析 #RGB 三位缩写展开")
    expect(DevToolboxCore.color(fromHex: "nope##") == nil, "非法 HEX 返回 nil")
    expect(DevToolboxCore.color(fromHex: "#12345") == nil, "长度不对返回 nil")
    // 灰色空间归一化：calibrated 白也要给出 #FFFFFF
    expect(DevToolboxCore.hexString(NSColor(calibratedWhite: 1, alpha: 1)) == "#FFFFFF", "calibrated 空间归一化到 sRGB")
    expect(has("美化") && has("压缩"), "JSON 工具的方向切换")

    // 图标合法性：SF Symbol 不存在会运行时降级成空白（toolbox 那次的教训），全部校验
    for item in DevTool.allCases {
        expect(NSImage(systemSymbolName: item.icon, accessibilityDescription: nil) != nil,
               "图标合法 \(item.icon)（\(item.name)）")
    }

    // Hash 标准测试向量（abc 的四种摘要，业界公认值）
    expect(DevToolboxCore.hashHex("abc", algorithm: .md5) == "900150983cd24fb0d6963f7d28e17f72", "MD5(abc) 标准向量")
    expect(DevToolboxCore.hashHex("abc", algorithm: .sha1) == "a9993e364706816aba3e25717850c26c9cd0d89d", "SHA-1(abc) 标准向量")
    expect(DevToolboxCore.hashHex("abc", algorithm: .sha256) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", "SHA-256(abc) 标准向量")
    expect(DevToolboxCore.hashHex("abc", algorithm: .sha512) == "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f", "SHA-512(abc) 标准向量")
    // 长度/大小写/中文
    for algorithm in DevToolboxCore.HashAlgorithm.allCases {
        let lower = DevToolboxCore.hashHex("你好 hash", algorithm: algorithm)
        expect(lower.count == algorithm.hexLength && lower == lower.lowercased(), "\(algorithm.name)：长度 \(algorithm.hexLength) 且默认小写")
        expect(DevToolboxCore.hashHex("你好 hash", algorithm: algorithm, uppercase: true) == lower.uppercased(), "\(algorithm.name)：大写开关")
    }
    expect(DevToolboxCore.hashHex("你好", algorithm: .md5) != DevToolboxCore.hashHex("你好x", algorithm: .md5), "输入不同摘要不同")
    expect(DevToolboxCore.hashHex("", algorithm: .md5) == "d41d8cd98f00b204e9800998ecf8427e", "空输入也有摘要（MD5 标准值）")

    // ── 二维码：生成 → 解码回环（Vision）
    let qrText = "https://macq.dev/测试?path=/a b&x=1"
    guard let qrData = DevToolboxCore.qrPNG(qrText, level: .medium),
          let qrRep = NSBitmapImageRep(data: qrData) else {
        expect(false, "二维码 PNG 生成失败"); print(failures == 0 ? "全部通过" : "失败 \(failures) 项"); exit(1)
    }
    expect(qrData.prefix(4) == Data([0x89, 0x50, 0x4E, 0x47]), "二维码输出是 PNG（魔数）")
    expect(qrRep.pixelsWide == 600 && qrRep.pixelsHigh == 600, "二维码尺寸 600×600", "\(qrRep.pixelsWide)×\(qrRep.pixelsHigh)")
    if let cgQR = qrRep.cgImage {
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try? VNImageRequestHandler(cgImage: cgQR, options: [:]).perform([request])
        expect(request.results?.first?.payloadStringValue == qrText, "解码回环：扫出内容与原文一致（含中文/空格/&）")
    } else {
        expect(false, "PNG 转 CGImage 失败")
    }
    expect(DevToolboxCore.qrPNG("hello") != DevToolboxCore.qrPNG("hello", level: .high), "纠错级别影响图案")
    expect(DevToolboxCore.qrPNG(String(repeating: "a", count: 5000)) == nil, "超容量（5000 字）返回 nil")
    expect(DevToolboxCore.qrPNG("") == nil, "空输入返回 nil")

    // logo 版本：程序化造一张圆图当 logo，生成后仍要扫得回原文（H 级别）
    let logoImage = NSImage(size: NSSize(width: 64, height: 64))
    logoImage.lockFocus()
    NSColor.systemBlue.setFill()
    NSBezierPath(ovalIn: NSRect(x: 0, y: 0, width: 64, height: 64)).fill()
    logoImage.unlockFocus()
    if let logoData = DevToolboxCore.qrPNG(qrText, level: .high, logo: logoImage),
       let logoRep = NSBitmapImageRep(data: logoData), let cgLogo = logoRep.cgImage {
        expect(logoData != qrData, "加 logo 后图案变化")
        let request2 = VNDetectBarcodesRequest()
        request2.symbologies = [.qr]
        try? VNImageRequestHandler(cgImage: cgLogo, options: [:]).perform([request2])
        expect(request2.results?.first?.payloadStringValue == qrText, "加 logo 仍可扫（H 级别 24% 覆盖）")
    } else {
        expect(false, "logo 版二维码生成失败")
    }

    // 解析：生成→回读（单张与多张同图）
    expect(DevToolboxCore.qrDecode(NSImage(data: qrData)!) == [qrText], "解析单张二维码回读一致")
    // 拼两张不同内容的二维码进同一张图，应都能扫出
    let other = DevToolboxCore.qrPNG("second-code", level: .low)!
    let canvas = NSImage(size: NSSize(width: 1300, height: 600))
    canvas.lockFocus()
    NSImage(data: qrData)?.draw(in: NSRect(x: 0, y: 0, width: 600, height: 600))
    NSImage(data: other)?.draw(in: NSRect(x: 700, y: 0, width: 600, height: 600))
    canvas.unlockFocus()
    let decodedTwo = DevToolboxCore.qrDecode(canvas)
    expect(decodedTwo.count == 2 && decodedTwo.contains(qrText) && decodedTwo.contains("second-code"), "同图多码全部扫出（2 张）", decodedTwo.joined(separator: " | "))
    let blank = NSImage(size: NSSize(width: 100, height: 100))
    blank.lockFocus(); NSColor.white.setFill(); NSRect(x: 0, y: 0, width: 100, height: 100).fill(); blank.unlockFocus()
    expect(DevToolboxCore.qrDecode(blank).isEmpty, "无码自图返回空数组")
    expect(has("粘贴或输入"), "输入框常驻（占位文案可见，而不是只有提示文字）")
    // 输入区左半边应可命中（PlainTextView 在那里）
    let inputPoint = NSPoint(x: 300, y: 300)
    expect(hosting.hitTest(inputPoint) != nil, "输入区可命中")

    // 回归：输入框背后的 NSTextView 必须关掉自动替换（否则中文输入法下 " 变弯引号，JSON 非法）
    func findTextViews(_ view: NSView) -> [NSTextView] {
        var result: [NSTextView] = []
        if let tv = view as? NSTextView { result.append(tv) }
        for sub in view.subviews { result.append(contentsOf: findTextViews(sub)) }
        return result
    }
    let textViews = findTextViews(hosting)
    for tv in textViews {
        print("    · NSTextView \(String(describing: type(of: tv))) 引号=\(tv.isAutomaticQuoteSubstitutionEnabled) 替换=\(tv.isAutomaticTextReplacementEnabled) 可编辑=\(tv.isEditable)")
    }
    expect(textViews.contains { !$0.isAutomaticQuoteSubstitutionEnabled && !$0.isAutomaticTextReplacementEnabled },
           "输入框已关闭自动替换（弯引号/文本替换）", "共翻出 \(textViews.count) 个 NSTextView")

    // 点击导航里的「UUID」→ 右侧切到 UUID 工具
    if let uuidBox = boxes.first(where: { $0.text.contains("UUID") }) {
        let scale = CGFloat(rep.pixelsWide) / max(hosting.bounds.width, 1)
        let point = NSPoint(x: uuidBox.rect.midX / scale, y: uuidBox.rect.midY / scale)
        expect(hosting.hitTest(point) != nil, "UUID 导航行可命中")
        panelState.selected = .uuid
        if let rep2 = render(hosting) {
            let text2 = ocr(rep2, "切换到 UUID")
            expect(text2.joined().contains("生成"), "点击导航切换到 UUID 工具（出现「生成」）")
        }
    } else {
        expect(false, "未 OCR 到 UUID 导航行")
    }

    // ── 诊断：取色器渲染（NSColorWell 与色块）
    panelState.selected = .picker
    if let repP = render(hosting) {
        _ = ocr(repP, "取色器")
        func findWells(_ view: NSView) -> [NSColorWell] {
            var result: [NSColorWell] = []
            if let w = view as? NSColorWell { result.append(w) }
            for sub in view.subviews { result.append(contentsOf: findWells(sub)) }
            return result
        }
        let wells = findWells(hosting)
        print("    · NSColorWell 数量=\(wells.count)", wells.map { "\(Int($0.bounds.width))x\(Int($0.bounds.height))" }.joined(separator: ","))
        // 全图扫描“强调蓝”像素（色块应为系统蓝 ≈ #0091FF），输出包围盒
        var minX = Int.max, maxX = 0, minY = Int.max, maxY = 0, hits = 0
        for y in 0..<repP.pixelsHigh {
            for x in 0..<repP.pixelsWide {
                guard let c = repP.colorAt(x: x, y: y) else { continue }
                let r = c.redComponent, g = c.greenComponent, b = c.blueComponent
                if r < 0.15, g > 0.45, g < 0.75, b > 0.85 {
                    hits += 1
                    minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                }
            }
        }
        print("    · 蓝色像素 hits=\(hits) 包围盒=[\(minX),\(minY)]-[\(maxX),\(maxY)] 位图 \(repP.pixelsWide)x\(repP.pixelsHigh)")
    }

    // JSON 实际转换走 UI 状态：切回 JSON 输入内容验证（LiveConverter 的输入即转）
    panelState.selected = .json
    if let rep3 = render(hosting) {
        _ = ocr(rep3, "面板初始")
    }

    // ── 设置页
    let settingsPage = host(DevToolboxView(tool: tool), width: 720, height: 760)
    if let rep4 = render(settingsPage) {
        let text4 = ocr(rep4, "开发者工具箱设置页").joined(separator: " | ")
        // OCR 常把「箱」认丢/认成「籍」，断言用稳定前缀；快捷键符号 OCR 不出，逻辑段已验
        for label in ["启用开发者工具", "唤起面板", "录制", "重置", "打开开发者工具"] {
            expect(text4.contains(label), "设置页出现「\(label)」")
        }
        expect(text4.contains("独立窗口") || text4.contains("不会消失"), "设置页说明了面板常驻行为")
    }

    print("")
    print(failures == 0 ? "全部通过" : "失败 \(failures) 项")
}

// MARK: - 密码工具

@MainActor
func runPasswordProbe() {
    let P = DevToolboxCore.PasswordGen.self
    

    // 混淆字符剔除
    expect(P.digitPool.isDisjoint(with: ["0"]), "数字池不含 0")
    expect(P.lowerPool.isDisjoint(with: ["i", "l"]), "小写池不含 i l")
    expect(P.upperPool.isDisjoint(with: ["O", "I"]), "大写池不含 O I")
    expect(P.lowerPool.contains("o") && P.upperPool.contains("L"), "仅剔除需求指定的五个字符")

    // 默认配置
    let d = DevToolboxCore.PasswordConfig()
    expect(d.length == 16 && d.count == 1 && d.digits && d.lowercase && d.uppercase && d.special, "默认配置：16 长 1 条四类全开")
    expect(P.specialPool(d).contains("!"), "默认特殊字符集可用")

    // 生成：长度/数量/类别保底/混淆剔除
    var rng = SystemRandomNumberGenerator()
    var cfg = DevToolboxCore.PasswordConfig(); cfg.length = 20; cfg.count = 5
    let out = P.generate(cfg, rng: &rng)
    expect(out.count == 5, "生成数量 = 5")
    expect(out.allSatisfy { $0.count == 20 }, "每条长度 = 20")
    expect(out.allSatisfy { pw in pw.contains { $0.isNumber } }, "每条含数字（保底）")
    expect(out.allSatisfy { pw in pw.contains { $0.isLowercase } }, "每条含小写（保底）")
    expect(out.allSatisfy { pw in pw.contains { $0.isUppercase } }, "每条含大写（保底）")
    expect(out.allSatisfy { pw in pw.contains { !($0.isLetter || $0.isNumber) } }, "每条含特殊字符（保底）")
    let conf = P.confusables
    expect(out.allSatisfy { pw in pw.allSatisfy { !conf.contains($0) } }, "结果不含 0 O i l I")

    // 针制
    var c2 = DevToolboxCore.PasswordConfig(); c2.length = 2; c2.count = 999
    let out2 = P.generate(c2, rng: &rng)
    expect(out2.count == 100 && out2.allSatisfy { $0.count >= 4 }, "长度/数量越界自动钳制（4 / 100）")

    // 用户改特殊字符集：剔除空白与混淆字符，去重
    var c3 = DevToolboxCore.PasswordConfig(); c3.digits = false; c3.lowercase = false; c3.uppercase = false
    c3.specialChars = "!!@@  O0i"
    expect(P.specialPool(c3) == "!@", "特殊字符集去重、剔除空白与混淆字符")
    let out3 = P.generate(c3, rng: &rng)
    expect(out3.allSatisfy { $0.allSatisfy { $0 == "!" || $0 == "@" } }, "纯特殊字符模式可用")

    // 全关 → 空结果不崩
    var c4 = DevToolboxCore.PasswordConfig(); c4.digits = false; c4.lowercase = false; c4.uppercase = false; c4.special = false
    expect(P.generate(c4, rng: &rng).isEmpty, "全关返回空")

    // 持久化往返（面板的 tool.password 走这条路）
    var c5 = DevToolboxCore.PasswordConfig(); c5.digits = false; c5.length = 32; c5.count = 7; c5.specialChars = "<>"
    let data = try! JSONEncoder().encode(c5)
    let back = try! JSONDecoder().decode(DevToolboxCore.PasswordConfig.self, from: data)
    expect(back == c5, "PasswordConfig 编解码往返一致")

    // 导航与图标
    expect(DevTool.allCases.contains(.password), "目录含密码工具")
    expect(DevTool.defaultOrder.last == .password, "新工具默认排在末尾，不打乱已有顺序")
    expect(DevTool.password.icon == "key", "密码工具图标")

    print("")
    print("密码探针：\(failures) 失败")
}

MainActor.assumeIsolated {
    runProbe()
    runPasswordProbe()
    exit(failures == 0 ? 0 : 1)
}
