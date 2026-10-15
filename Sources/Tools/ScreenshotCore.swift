import AppKit
import CoreGraphics
import Vision

/// 截图纯逻辑：坐标换算、窗口命中、选区缩放。无 UI、无权限，方便探针直接验。
enum ScreenshotCore {
    static func cocoaRect(fromCG r: CGRect, mainHeight: CGFloat) -> CGRect {
        CGRect(x: r.origin.x, y: mainHeight - r.origin.y - r.height, width: r.width, height: r.height)
    }

    static func cgRect(fromCocoa r: CGRect, mainHeight: CGFloat) -> CGRect {
        cocoaRect(fromCG: r, mainHeight: mainHeight)
    }

    struct Win: Equatable {
        let id: UInt32
        let rect: CGRect
    }

    /// 从 CGWindowList 字典里抽出可截的普通窗口（layer 0、够大、未隐藏）。
    static func windows(
        from list: [[String: Any]],
        mainHeight: CGFloat,
        skipIDs: Set<UInt32> = [],
        minSide: CGFloat = 40
    ) -> [Win] {
        var out: [Win] = []
        for w in list {
            let layer = (w[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            guard layer == 0 else { continue }
            let alpha = (w[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            guard alpha > 0.05 else { continue }
            let id = UInt32((w[kCGWindowNumber as String] as? NSNumber)?.intValue ?? 0)
            guard id != 0, !skipIDs.contains(id) else { continue }
            guard let bounds = w[kCGWindowBounds as String] as? [String: Any] else { continue }
            let x = (bounds["X"] as? NSNumber)?.doubleValue ?? 0
            let y = (bounds["Y"] as? NSNumber)?.doubleValue ?? 0
            let width = (bounds["Width"] as? NSNumber)?.doubleValue ?? 0
            let height = (bounds["Height"] as? NSNumber)?.doubleValue ?? 0
            guard width >= minSide, height >= minSide else { continue }
            let cg = CGRect(x: x, y: y, width: width, height: height)
            out.append(Win(id: id, rect: cocoaRect(fromCG: cg, mainHeight: mainHeight)))
        }
        return out
    }

    /// 命中点最前的窗口。`windows` 须是前→后（`CGWindowListCopyWindowInfo` 的顺序）。
    /// 不能按面积：被挡住的小窗面积更小，会把前台大窗（如全屏 Chrome）抢走。
    static func window(at p: CGPoint, in windows: [Win]) -> Win? {
        windows.first { $0.rect.contains(p) }
    }

    enum Handle: CaseIterable {
        case nw, n, ne, e, se, s, sw, w
    }

    static func handleCenters(_ r: CGRect) -> [Handle: CGPoint] {
        [
            .nw: CGPoint(x: r.minX, y: r.maxY),
            .n: CGPoint(x: r.midX, y: r.maxY),
            .ne: CGPoint(x: r.maxX, y: r.maxY),
            .e: CGPoint(x: r.maxX, y: r.midY),
            .se: CGPoint(x: r.maxX, y: r.minY),
            .s: CGPoint(x: r.midX, y: r.minY),
            .sw: CGPoint(x: r.minX, y: r.minY),
            .w: CGPoint(x: r.minX, y: r.midY),
        ]
    }

    static func hitHandle(_ p: CGPoint, in r: CGRect, slop: CGFloat = 8) -> Handle? {
        handleCenters(r).min { $0.value.distance(to: p) < $1.value.distance(to: p) }
            .flatMap { $0.value.distance(to: p) <= slop ? $0.key : nil }
    }

    static func resize(_ r: CGRect, _ handle: Handle, to p: CGPoint, minSize: CGFloat = 8) -> CGRect {
        var minX = r.minX, maxX = r.maxX, minY = r.minY, maxY = r.maxY
        switch handle {
        case .n, .nw, .ne: maxY = p.y
        case .s, .sw, .se: minY = p.y
        case .e, .w: break
        }
        switch handle {
        case .e, .ne, .se: maxX = p.x
        case .w, .nw, .sw: minX = p.x
        case .n, .s: break
        }
        var out = CGRect(x: Swift.min(minX, maxX), y: Swift.min(minY, maxY),
                         width: abs(maxX - minX), height: abs(maxY - minY))
        if out.width < minSize { out.size.width = minSize }
        if out.height < minSize { out.size.height = minSize }
        return out
    }

    static func move(_ r: CGRect, by d: CGPoint, in bounds: CGRect) -> CGRect {
        var out = r.offsetBy(dx: d.x, dy: d.y)
        if out.width > bounds.width { out.origin.x = bounds.minX }
        else {
            if out.minX < bounds.minX { out.origin.x = bounds.minX }
            if out.maxX > bounds.maxX { out.origin.x = bounds.maxX - out.width }
        }
        if out.height > bounds.height { out.origin.y = bounds.minY }
        else {
            if out.minY < bounds.minY { out.origin.y = bounds.minY }
            if out.maxY > bounds.maxY { out.origin.y = bounds.maxY - out.height }
        }
        return out
    }

    static func rect(from a: CGPoint, to b: CGPoint) -> CGRect {
        CGRect(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(b.x - a.x), height: abs(b.y - a.y))
    }

    static func confirmRect(_ r: CGRect, in selection: CGRect) -> CGRect {
        let size = CGSize(width: 64, height: 26)
        var origin = CGPoint(x: selection.maxX - size.width, y: selection.minY - size.height - 8)
        if origin.y < r.minY + 8 { origin.y = selection.maxY + 8 }
        if origin.x < r.minX + 8 { origin.x = r.minX + 8 }
        if origin.x + size.width > r.maxX - 8 { origin.x = r.maxX - size.width - 8 }
        return CGRect(origin: origin, size: size)
    }

    enum MarkColor: String, CaseIterable {
        case red, green, blue, yellow, black, white, gray
        var label: String {
            switch self {
            case .red: "红"
            case .green: "绿"
            case .blue: "蓝"
            case .yellow: "黄"
            case .black: "黑"
            case .white: "白"
            case .gray: "灰"
            }
        }
        var nsColor: NSColor {
            switch self {
            case .red: NSColor(srgbRed: 1, green: 0.27, blue: 0.23, alpha: 1)
            case .green: NSColor(srgbRed: 0.22, green: 0.78, blue: 0.35, alpha: 1)
            case .blue: NSColor(srgbRed: 0.20, green: 0.55, blue: 1, alpha: 1)
            case .yellow: NSColor(srgbRed: 1, green: 0.84, blue: 0.04, alpha: 1)
            case .black: .black
            case .white: .white
            case .gray: NSColor(srgbRed: 0.55, green: 0.55, blue: 0.55, alpha: 1)
            }
        }
    }

    struct MarkInk: Equatable {
        var color: MarkColor
        var stroke: CGFloat
        var fontSize: CGFloat
        static let `default` = MarkInk(color: .red, stroke: 4, fontSize: 18)
        static let strokes: [CGFloat] = [2, 4, 8]
        static let fonts: [CGFloat] = [14, 18, 24, 32]
    }

    static let toolbarSize = CGSize(width: 512, height: 44)

    static func barSize(tool: ShotCanvas.Tool?, scrollMode: Bool = false) -> CGSize {
        if scrollMode { return toolbarSize }
        let extra = (tool != nil && tool != .mosaic)
        return CGSize(width: toolbarSize.width, height: extra ? 80 : 44)
    }

    static func ocrPanelSize(lineCount: Int, empty: Bool) -> CGSize {
        if empty { return CGSize(width: 300, height: 52) }
        let body = min(180, max(48, CGFloat(lineCount) * 20 + 16))
        return CGSize(width: 300, height: body + 44)
    }

    /// 识别结果优先贴工具条右侧，右边不够就放到下面。
    static func ocrPanelFrame(bar: CGRect, size: CGSize, screen: CGRect, gap: CGFloat = 8) -> CGRect {
        var origin = CGPoint(x: bar.maxX + gap, y: bar.minY)
        if origin.x + size.width > screen.maxX - gap {
            origin.x = bar.minX
            origin.y = bar.minY - size.height - gap
            if origin.y < screen.minY + gap {
                origin.y = bar.maxY + gap
            }
        }
        origin.x = min(max(origin.x, screen.minX + gap), screen.maxX - size.width - gap)
        origin.y = min(max(origin.y, screen.minY + gap), screen.maxY - size.height - gap)
        return CGRect(origin: origin, size: size)
    }

    /// 离线 OCR。中英混排，精确模式。失败或空白返回空数组。
    static func recognizeText(in image: NSImage) -> [String] {
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return [] }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        do { try handler.perform([request]) } catch { return [] }
        let obs = request.results ?? []
        let sorted = obs.sorted { a, b in
            if abs(a.boundingBox.midY - b.boundingBox.midY) > 0.02 {
                return a.boundingBox.midY > b.boundingBox.midY
            }
            return a.boundingBox.minX < b.boundingBox.minX
        }
        return sorted.compactMap {
            $0.topCandidates(1).first?.string
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }.filter { !$0.isEmpty }
    }

    struct Stitch {
        let image: NSImage
        let overlap: Int
        let identical: Bool
        /// identical 时这帧是否「像素级纹丝不动」（强证据）。对不上只算半票（弱证据）。
        var stable: Bool = false
    }

    /// 竖向拼接两帧：在 `next` 顶部找与 `base` 底部最像的重叠带，只追加新出来的部分。
    /// 两帧几乎一样（滚到底）时 `identical = true`，返回原图。
    /// `expectedAdded`：这一步预计新增像素（步长 × 屏幕缩放）。匹配窗口围绕它开，
    /// 避免重复列表在远处配错行；配不上也不硬拼，当本帧没滚，交给到底累计。
    static func stitchVertical(base: NSImage, next: NSImage, expectedAdded: Int = 160) -> Stitch {
        var r1 = CGRect(origin: .zero, size: base.size)
        var r2 = CGRect(origin: .zero, size: next.size)
        guard let a = base.cgImage(forProposedRect: &r1, context: nil, hints: nil),
              let b = next.cgImage(forProposedRect: &r2, context: nil, hints: nil),
              a.width == b.width, a.height > 0, b.height > 0
        else { return Stitch(image: base, overlap: 0, identical: false) }
        let Ha = a.height, Hb = b.height, W = a.width
        // 只栅上一视口。用底部窄条在下一帧里定位，整页 MAD 在重复列表上会配错行。
        let bandH = min(Ha, Hb)
        let bandRect = CGRect(x: 0, y: Ha - bandH, width: W, height: bandH)
        guard let band = a.cropping(to: bandRect) ?? a.cropping(to: CGRect(x: 0, y: 0, width: W, height: bandH)),
              let pa = ShotPix(band), let pb = ShotPix(b)
        else { return Stitch(image: base, overlap: 0, identical: false) }
        // 全帧几乎没变：滚不动（到底）。stepX=4 对闪烁光标这类小动画不敏感。
        if Ha >= Hb, pa.meanAbs(y: 0, other: pb, y: 0, rows: Hb, width: W, stepX: 4) < 2 {
            return Stitch(image: base, overlap: Hb, identical: true, stable: true)
        }
        // 底部模板要够厚，否则在重复行间随便哪都能配上。
        let tH = min(64, max(16, bandH / 6))
        let tplY = bandH - tH
        let center = (Hb - expectedAdded) - tH
        let yLo = max(0, center - 240)
        let yHi = min(bandH - tH, center + 240)
        guard yHi >= yLo, yLo >= 0 else {
            return Stitch(image: base, overlap: Hb, identical: true, stable: false)
        }
        var bestY = yLo
        var best = Double.greatestFiniteMagnitude
        var ty = yLo
        while ty <= yHi {
            let mad = pa.meanAbs(y: tplY, other: pb, y: ty, rows: tH, width: W, stepX: 2)
            if mad < best {
                best = mad
                bestY = ty
            }
            ty += 2
        }
        let lo = max(yLo, bestY - 3)
        let hi = min(yHi, bestY + 3)
        ty = lo
        while ty <= hi {
            let mad = pa.meanAbs(y: tplY, other: pb, y: ty, rows: tH, width: W, stepX: 1)
            if mad < best {
                best = mad
                bestY = ty
            }
            ty += 1
        }
        let bestO = bestY + tH
        let added = Hb - bestO
        // 质量门槛：配不上不硬拼，当本帧没滚。
        guard best < 20, added > 6 else {
            return Stitch(image: base, overlap: Hb, identical: true, stable: false)
        }
        // 交叉验证：上一帧中部再校一条，重复周期刚好落进窗口时靠它排除。
        // 映射规则：上一帧 y 的内容出现在下一帧 y - added；模板滚出帧顶就跳过。
        let t2 = min(48, tplY)
        let y2 = tplY - t2
        let y2next = y2 - added
        if t2 >= 16, y2next >= 0 {
            let v = pa.meanAbs(y: y2, other: pb, y: y2next, rows: t2, width: W, stepX: 2)
            if v > 26 {
                return Stitch(image: base, overlap: Hb, identical: true, stable: false)
            }
        }
        let newH = Ha + added
        if newH > 16384 {
            return Stitch(image: base, overlap: bestO, identical: true)
        }
        let space = CGColorSpaceCreateDeviceRGB()
        let info = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let ctx = CGContext(
            data: nil, width: W, height: newH, bitsPerComponent: 8, bytesPerRow: 0,
            space: space, bitmapInfo: info
        ) else { return Stitch(image: base, overlap: bestO, identical: false) }
        ctx.draw(a, in: CGRect(x: 0, y: added, width: W, height: Ha))
        if let strip = b.cropping(to: CGRect(x: 0, y: bestO, width: W, height: added)) {
            ctx.draw(strip, in: CGRect(x: 0, y: 0, width: W, height: added))
        }
        guard let out = ctx.makeImage() else {
            return Stitch(image: base, overlap: bestO, identical: false)
        }
        let scale = base.size.width / CGFloat(a.width)
        let img = NSImage(cgImage: out, size: NSSize(width: CGFloat(W) * scale, height: CGFloat(newH) * scale))
        return Stitch(image: img, overlap: bestO, identical: false)
    }

    static func scrollHitBottom(streak: Double, need: Double = 3) -> Bool {
        streak >= need
    }

    /// 固定小步，避免大选区一次滚几百像素对不齐。
    static func scrollStep(selectionHeight: CGFloat) -> Int32 {
        Int32(min(120, max(64, selectionHeight * 0.15)))
    }

    static func cursorInSelection(_ p: CGPoint, _ sel: CGRect) -> Bool {
        sel.insetBy(dx: 2, dy: 2).contains(p)
    }

    /// 两帧是否已“停稳”：页面滚动动画没结束时帧在亚像素位置上变化，
    /// 拼接必然错位。连截两帧几乎一致才可值拼。
    static func framesQuiet(a: NSImage?, b: NSImage?) -> Bool {
        guard let a, let b else { return false }
        var r1 = CGRect(origin: .zero, size: a.size)
        var r2 = CGRect(origin: .zero, size: b.size)
        guard let ca = a.cgImage(forProposedRect: &r1, context: nil, hints: nil),
              let cb = b.cgImage(forProposedRect: &r2, context: nil, hints: nil),
              ca.width == cb.width, ca.height == cb.height,
              let pa = ShotPix(ca), let pb = ShotPix(cb)
        else { return false }
        return pa.meanAbs(y: 0, other: pb, y: 0, rows: ca.height, width: ca.width, stepX: 4) < 1.5
    }

    static func scrollPreviewSize(image: NSSize, cap: CGSize = CGSize(width: 220, height: 420)) -> CGSize {
        let sx = cap.width / Swift.max(image.width, 1)
        let sy = cap.height / Swift.max(image.height, 1)
        let s = Swift.min(sx, sy, 1)
        return CGSize(width: Swift.max(48, (image.width * s).rounded()), height: Swift.max(48, (image.height * s).rounded()))
    }

    /// 预览只喂缩略图，避免每帧把整张长图丢给 NSImageView。
    static func scrollPreviewThumb(_ img: NSImage) -> NSImage {
        let size = scrollPreviewSize(image: img.size)
        let out = NSImage(size: size)
        out.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .low
        img.draw(in: NSRect(origin: .zero, size: size), from: .zero, operation: .copy, fraction: 1)
        out.unlockFocus()
        return out
    }

    /// 点下面最前的普通窗口所属进程。跳过本进程（遮罩/工具条）。
    static func ownerPID(from list: [[String: Any]], atCG p: CGPoint, skipPID: pid_t) -> pid_t? {
        for w in list {
            let layer = (w[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            guard layer == 0 else { continue }
            let pid = pid_t((w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0)
            guard pid != 0, pid != skipPID else { continue }
            guard let bounds = w[kCGWindowBounds as String] as? [String: Any] else { continue }
            let r = CGRect(
                x: (bounds["X"] as? NSNumber)?.doubleValue ?? 0,
                y: (bounds["Y"] as? NSNumber)?.doubleValue ?? 0,
                width: (bounds["Width"] as? NSNumber)?.doubleValue ?? 0,
                height: (bounds["Height"] as? NSNumber)?.doubleValue ?? 0
            )
            if r.contains(p) { return pid }
        }
        return nil
    }

    static func scrollPreviewFrame(selection: CGRect, size: CGSize, screen: CGRect, gap: CGFloat = 8) -> CGRect {
        let clamp: (CGPoint) -> CGRect = { p in
            var o = p
            o.x = min(max(o.x, screen.minX + gap), max(screen.minX + gap, screen.maxX - size.width - gap))
            o.y = min(max(o.y, screen.minY + gap), max(screen.minY + gap, screen.maxY - size.height - gap))
            return CGRect(origin: o, size: size)
        }
        let candidates = [
            CGPoint(x: selection.maxX + gap, y: selection.maxY - size.height),
            CGPoint(x: selection.minX - size.width - gap, y: selection.maxY - size.height),
            CGPoint(x: selection.minX, y: selection.minY - size.height - gap),
            CGPoint(x: selection.minX, y: selection.maxY + gap),
            CGPoint(x: screen.maxX - size.width - gap, y: screen.maxY - size.height - gap),
            CGPoint(x: screen.minX + gap, y: screen.maxY - size.height - gap),
            CGPoint(x: screen.maxX - size.width - gap, y: screen.minY + gap),
            CGPoint(x: screen.minX + gap, y: screen.minY + gap),
        ].map(clamp)
        if let fit = candidates.first(where: { $0.intersection(selection).isNull || $0.intersection(selection).isEmpty }) {
            return fit
        }
        return candidates.min(by: {
            $0.intersection(selection).width * $0.intersection(selection).height
                < $1.intersection(selection).width * $1.intersection(selection).height
        }) ?? clamp(CGPoint(x: screen.minX + gap, y: screen.minY + gap))
    }

    /// 工具条默认贴在选区下方；下方不够就放到上方，并夹在当前屏内。
    static func toolbarFrame(selection: CGRect, size: CGSize, screen: CGRect, gap: CGFloat = 8) -> CGRect {
        var origin = CGPoint(x: selection.midX - size.width / 2, y: selection.minY - size.height - gap)
        if origin.y < screen.minY + gap {
            origin.y = selection.maxY + gap
        }
        if origin.y + size.height > screen.maxY - gap {
            origin.y = min(selection.minY - size.height - gap, screen.maxY - size.height - gap)
            origin.y = max(origin.y, screen.minY + gap)
        }
        origin.x = min(max(origin.x, screen.minX + gap), screen.maxX - size.width - gap)
        return CGRect(origin: origin, size: size)
    }
}

private extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat {
        hypot(x - other.x, y - other.y)
    }
}

/// 把 CGImage 栅成 RGBA，行 0 = 图像顶。拼接时比重叠带用。
private final class ShotPix {
    let w, h, stride: Int
    let buf: UnsafeMutablePointer<UInt8>

    init?(_ img: CGImage) {
        w = img.width
        h = img.height
        stride = w * 4
        buf = UnsafeMutablePointer<UInt8>.allocate(capacity: stride * h)
        buf.initialize(repeating: 0, count: stride * h)
        let space = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: stride,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            buf.deallocate()
            return nil
        }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
    }

    deinit { buf.deallocate() }

    func meanAbs(y: Int, other: ShotPix, y by: Int, rows: Int, width: Int, stepX: Int = 1) -> Double {
        let rows = min(rows, h - y, other.h - by)
        guard rows > 0, y >= 0, by >= 0 else { return 999 }
        var sum = 0
        var n = 0
        let ww = min(width, w, other.w)
        let x0 = ww / 20
        let x1 = max(x0 + 1, ww - ww / 10)
        for row in 0..<rows {
            let pa = buf + (y + row) * stride
            let pb = other.buf + (by + row) * stride
            var x = x0
            while x < x1 {
                let i = x * 4
                sum += abs(Int(pa[i]) - Int(pb[i]))
                    + abs(Int(pa[i + 1]) - Int(pb[i + 1]))
                    + abs(Int(pa[i + 2]) - Int(pb[i + 2]))
                n += 3
                x += stepX
            }
        }
        return n == 0 ? 0 : Double(sum) / Double(n)
    }
}

@_silgen_name("CGWindowListCreateImage")
private func _shotGrab(_ screenBounds: CGRect, _ listOption: CGWindowListOption, _ windowID: CGWindowID, _ imageOption: UInt32) -> CGImage?
// CGWindowImageOption：BestResolution = 1<<3，NominalResolution = 1<<4。
// 写成 1<<4 会按 1x 截，Retina 上拉伸发糊。
private let kShotBestResolution: UInt32 = 1 << 3

extension ScreenshotCore {
    static var mainHeight: CGFloat {
        NSScreen.screens.first(where: { $0.frame.origin == .zero })?.frame.height
            ?? NSScreen.main?.frame.height ?? 0
    }

    static func liveWindows(skipIDs: Set<UInt32> = []) -> [Win] {
        let opts: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(opts, kCGNullWindowID) as? [[String: Any]] else { return [] }
        return windows(from: raw, mainHeight: mainHeight, skipIDs: skipIDs)
    }

    /// 按 Cocoa 矩形截屏。`below` 传遮罩窗口 id，拍到的是它下面的真实桌面。
    static func grab(cocoa: CGRect, below windowID: CGWindowID = kCGNullWindowID) -> NSImage? {
        let cg = cgRect(fromCocoa: cocoa, mainHeight: mainHeight)
        let opt: CGWindowListOption = windowID == kCGNullWindowID ? .optionOnScreenOnly : .optionOnScreenBelowWindow
        guard let img = _shotGrab(cg, opt, windowID, kShotBestResolution) else { return nil }
        return NSImage(cgImage: img, size: cocoa.size)
    }
}
