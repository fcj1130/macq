import AppKit
import CoreGraphics
import os
import SwiftUI

private let eyedropperLog = Logger(subsystem: "com.mymy.macq", category: "eyedropper")

/// CGWindowListCreateImage 在 SDK 27 被标记 obsoleted（运行时仍可用），探针的 swiftc
/// 按新目标编译会拒绝；用 silgen 直连符号绕过可用性检查，ABI 与原函数一致。
/// 第 4 参是 CGWindowImageOption（UInt32 位掩码），不是 CFArray。
@_silgen_name("CGWindowListCreateImage")
private func _cgWindowListCreateImage(_ screenBounds: CGRect, _ listOption: CGWindowListOption, _ windowID: CGWindowID, _ imageOption: UInt32) -> CGImage?
private let kWindowImageBestResolution: UInt32 = 1 << 4

/// 自研屏幕取色：透明全屏覆盖层 + 鼠标周围小区域实时捕获。
/// 架构要点（三次频闪教训换来的）：
/// - 放大镜是纯 AppKit 图层（LoupeLayerView），30Hz 换图直接 layer.contents，不过 SwiftUI；
///   SwiftUI 每帧更新透明窗口会整体重合成 → 模糊/清晰交替闪。
/// - nearest 采样：无插值，像素块风格，没有两态可跳。
/// - 内容比对：静止时捕获相同就跳过更新，静止必须静止。
/// - 位置/内容解耦：位置跟鼠标事件，内容 30Hz 轮询。
@MainActor
final class ScreenEyedropper {
    static let shared = ScreenEyedropper()
    private var windows: [LoupeWindow] = []
    private var magnifier: LoupeMagnifier?
    private var timer: Timer?
    private var onPick: ((NSColor) -> Void)?
    private var monitors: [Any] = []

    /// 进入取色模式；点击取色或 esc/右键取消后回调（取消不回调）
    func pick(_ completion: @escaping (NSColor) -> Void) {
        guard windows.isEmpty else { return }  // 已在取色中
        if !CGPreflightScreenCaptureAccess() {
            // 弹系统授权；本次会话可能仍读不到内容（未授权=只见壁纸），界面会提示重试
            _ = CGRequestScreenCaptureAccess()
        }
        onPick = completion
        for screen in NSScreen.screens {
            let w = LoupeWindow(screen: screen)
            windows.append(w)
            w.orderFrontRegardless()
        }
        magnifier = LoupeMagnifier()
        magnifier?.orderFrontRegardless()
        // 全局监听：点击取色 / esc·右键取消（覆盖层不抢 key window，用事件监听最稳）
        let click = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            guard let self else { return event }
            // 首帧还没到时 lastImage 为空，点下去会当成取消；先同步捕一帧
            self.captureVisible()
            self.finish(picked: self.magnifier?.centerColor())
            return nil
        }
        let cancel = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .keyDown]) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown && event.keyCode != 53 { return event }  // 只认 esc
            self.finish(picked: nil)
            return nil
        }
        // ⌘Tab 走之后 MacQ 不再是 key window，本地监听收不到 esc/右键，补全局取消
        let cancelGlobal = NSEvent.addGlobalMonitorForEvents(matching: [.rightMouseDown, .keyDown]) { [weak self] event in
            if event.type == .keyDown && event.keyCode != 53 { return }
            self?.finish(picked: nil)
        }
        let moveLocal = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
            self?.moveCursor()
            return event
        }
        let moveGlobal = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { [weak self] _ in
            self?.moveCursor()
        }
        monitors = [click, cancel, cancelGlobal, moveLocal, moveGlobal].compactMap { $0 }
        timer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.captureVisible()
            }
        }
        moveCursor()
        captureVisible()
    }

    private func finish(picked: NSColor?) {
        timer?.invalidate(); timer = nil
        monitors.forEach { NSEvent.removeMonitor($0) }; monitors = []
        windows.forEach { $0.orderOut(nil) }; windows = []
        magnifier?.orderOut(nil); magnifier = nil
        let cb = onPick; onPick = nil
        if let picked, let cb { cb(picked) }
    }

    /// 只更新放大镜位置（每次鼠标移动，无捕获开销）
    private func moveCursor() {
        let mouse = NSEvent.mouseLocation
        for w in windows {
            let inScreen = w.frame.insetBy(dx: -1, dy: -1).contains(mouse)
            w.setVisible(inScreen)
        }
        magnifier?.move(to: mouse)
    }

    /// 只捕获放大镜内容（约 30Hz）
    private func captureVisible() {
        let mouse = NSEvent.mouseLocation
        let hasPermission = CGPreflightScreenCaptureAccess()
        guard let overlay = windows.first(where: { $0.frame.insetBy(dx: -1, dy: -1).contains(mouse) }) else { return }
        overlay.setPermission(hasPermission)
        guard let magnifier else { return }
        magnifier.capture { Self.regionImage(around: mouse, radius: Loupe.radius, excluding: UInt32(overlay.windowNumber)) }
    }

    // MARK: - 捕获

    /// 鼠标周围 2r×2r 区域图像（排除自己的覆盖层窗口，避免拍到放大镜自身）
    nonisolated private static func regionImage(around mouse: NSPoint, radius: CGFloat, excluding windowID: CGWindowID) -> CGImage? {
        let mainH = NSScreen.screens.first?.frame.height ?? 0
        // ponytail: NS(原点左下)→CG(原点左上) 只按主屏换算，多屏混合布局的 Y 会偏——真遇到再修
        let x = (mouse.x - radius).rounded(.down)
        let y = (mainH - mouse.y - radius).rounded(.down)
        let rect = CGRect(x: x, y: y, width: radius * 2, height: radius * 2)
        return _cgWindowListCreateImage(rect, .optionOnScreenBelowWindow, windowID, kWindowImageBestResolution)
    }

    /// 读 CGImage 正中心像素（BGRA，CGWindowListCreateImage 的常见格式）
    nonisolated static func centerPixel(_ image: CGImage) -> NSColor? {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return nil }
        let bpp = max(image.bitsPerPixel / 8, 4)
        let i = (image.height / 2) * image.bytesPerRow + (image.width / 2) * bpp
        guard i + 2 < CFDataGetLength(data) else { return nil }
        return NSColor(srgbRed: CGFloat(bytes[i + 2]) / 255,
                       green: CGFloat(bytes[i + 1]) / 255,
                       blue: CGFloat(bytes[i]) / 255,
                       alpha: 1)
    }
}

private enum Loupe {
    static let size: CGFloat = 160
    static let radius: CGFloat = 16  // 32pt 捕获 → 160pt 窗 = 5 倍
}

/// 每屏一个的透明覆盖层窗口（只负责点击/取消事件面 + 底部提示条）
@MainActor
final class LoupeWindow: NSWindow {
    private let model = LoupeModel()

    init(screen: NSScreen) {
        let hosting = NSHostingView(rootView: LoupeHintView(model: model))
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        contentView = hosting
        setFrame(screen.frame, display: true)
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        ignoresMouseEvents = false
        hasShadow = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setVisible(_ visible: Bool) { model.visible = visible }
    func setPermission(_ ok: Bool) { model.hasPermission = ok }
}

/// 放大镜：独立不透明小窗（数字测色器形态）。
/// 透明覆盖层窗口下面的内容一变就要重新混合整层，那是静止时频闪的总根源；
/// 不透明窗口的合成不依赖底面，稳定。
@MainActor
final class LoupeMagnifier: NSWindow {
    let loupe = LoupeLayerView(frame: NSRect(x: 0, y: 0, width: Loupe.size, height: Loupe.size))
    private var lastImage: CGImage?
    private var nilStreak = 0

    init() {
        super.init(contentRect: loupe.frame, styleMask: .borderless, backing: .buffered, defer: false)
        contentView = loupe
        // 窗体透明 + 内容正圆裁剪：不透明方窗切圆角四角仍是黑块。
        // 圆内部图层是不透明的（黑底+图像），只有四角透明；小窗+内容比对，不走全屏透明窗那条频闪路径。
        isOpaque = false
        backgroundColor = .clear
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        ignoresMouseEvents = true
        hasShadow = true
        isMovable = false
        animationBehavior = .none
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    /// 圆心始终对准指针；贴边时探出屏幕，不把窗体夹在屏内（夹住后准星对不上边缘像素）
    func move(to mouse: NSPoint) {
        let size = loupe.frame.size
        setFrameOrigin(NSPoint(
            x: (mouse.x - size.width / 2).rounded(),
            y: (mouse.y - size.height / 2).rounded()))
    }

    func capture(_ capture: () -> CGImage?) {
        guard let img = capture() else {
            nilStreak += 1
            if nilStreak == 5 { eyedropperLog.error("捕获连续失败，放大镜停留在最后一帧") }
            return
        }
        nilStreak = 0
        // 内容相同就不动 layer——静止必须静止
        if let last = lastImage, Self.sameImageData(img, last) { return }
        lastImage = img
        loupe.contents = img
        if let c = ScreenEyedropper.centerPixel(img) { loupe.setPreview(c) }
        invalidateShadow()
    }

    /// 十字准星交点 = 当前画面正中心像素
    func centerColor() -> NSColor? {
        lastImage.flatMap { ScreenEyedropper.centerPixel($0) }
    }

    nonisolated private static func sameImageData(_ a: CGImage, _ b: CGImage) -> Bool {
        guard a.width == b.width, a.height == b.height else { return false }
        guard let da = a.dataProvider?.data, let db = b.dataProvider?.data else { return false }
        return CFEqual(da, db)
    }
}

/// 放大镜：纯 AppKit 图层（圆形裁剪 + nearest 采样 + 描边 + 十字准星 + 实时 HEX）
@MainActor
final class LoupeLayerView: NSView {
    var contents: CGImage? {
        didSet { layer?.contents = contents }
    }
    private let swatch = CALayer()
    private let hexText = CATextLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        layer = CALayer()
        let s = frameRect.size
        let r = min(s.width, s.height) / 2
        layer?.masksToBounds = true
        layer?.cornerRadius = r
        layer?.contentsGravity = .resize
        layer?.magnificationFilter = .nearest
        layer?.minificationFilter = .nearest
        layer?.backgroundColor = NSColor.black.cgColor
        let ring = CALayer()
        ring.cornerRadius = r
        ring.borderWidth = 2
        ring.borderColor = NSColor.white.cgColor
        ring.frame = NSRect(origin: .zero, size: s)
        layer?.addSublayer(ring)
        let v = CALayer()
        v.backgroundColor = NSColor.white.cgColor
        v.frame = NSRect(x: s.width / 2 - 0.5, y: s.height / 2 - 7, width: 1, height: 14)
        layer?.addSublayer(v)
        let h = CALayer()
        h.backgroundColor = NSColor.white.cgColor
        h.frame = NSRect(x: s.width / 2 - 7, y: s.height / 2 - 0.5, width: 14, height: 1)
        layer?.addSublayer(h)
        // 底部胶囊：色块 + HEX，读的就是准星中心像素
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        let hexW = ceil(("#000000" as NSString).size(withAttributes: [.font: font]).width)
        let swatchS: CGFloat = 12, gap: CGFloat = 6, pad: CGFloat = 10
        let inner = swatchS + gap + hexW
        let hudW = inner + pad * 2
        let hud = CALayer()
        hud.backgroundColor = NSColor(white: 0, alpha: 0.72).cgColor
        hud.cornerRadius = 11
        hud.frame = NSRect(x: (s.width - hudW) / 2, y: 14, width: hudW, height: 22)
        swatch.cornerRadius = 3
        swatch.borderWidth = 1
        swatch.borderColor = NSColor(white: 1, alpha: 0.45).cgColor
        swatch.frame = NSRect(x: pad, y: 5, width: swatchS, height: swatchS)
        hexText.font = font
        hexText.fontSize = 11
        hexText.foregroundColor = NSColor.white.cgColor
        hexText.alignmentMode = .left
        hexText.contentsScale = NSScreen.main?.backingScaleFactor ?? 2
        hexText.frame = NSRect(x: pad + swatchS + gap, y: 3, width: hexW, height: 16)
        hud.addSublayer(swatch)
        hud.addSublayer(hexText)
        layer?.addSublayer(hud)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setPreview(_ color: NSColor) {
        swatch.backgroundColor = color.cgColor
        hexText.string = DevToolboxCore.hexString(color)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hexText.contentsScale = window?.backingScaleFactor ?? 2
    }
}

@MainActor
final class LoupeModel: ObservableObject {
    @Published var visible = false
    @Published var hasPermission = true
}

/// SwiftUI 只负责底部提示条（低频、静态）
private struct LoupeHintView: View {
    @ObservedObject var model: LoupeModel

    var body: some View {
        VStack {
            Color.clear
            if model.visible {
                Text(model.hasPermission ? AppLanguage.localized("点击取色 · esc 取消") : AppLanguage.localized("缺少屏幕录制权限，只能捕到壁纸——请授权后重试"))
                    .font(.callout)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.ultraThinMaterial, in: Capsule())
                    .padding(.bottom, 16)
            }
        }
        .allowsHitTesting(false)
    }
}
