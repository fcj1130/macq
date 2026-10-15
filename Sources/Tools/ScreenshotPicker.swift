import AppKit
import os

/// 全屏选区：先钉一个透明框（不截图），工具条默认不选工具，此时可拖/缩放选区；
/// 选工具或复制/保存时才真正截屏。钉钉同款。
@MainActor
final class ScreenshotPicker {
    var onCancel: (() -> Void)?

    private var overlays: [ShotOverlayWindow] = []
    private var monitor: Any?
    fileprivate var canvas: ShotCanvas?
    private var bar: ShotBarPanel?
    private var ocrPanel: ShotOCRPanel?
    private var preview: ShotScrollPreview?
    private var toast: NSPanel?
    private var hover: CGRect?
    private var selection: CGRect?
    private var dragStart: CGPoint?
    private var pinned = false
    var isScrollMode = false
    var isScrolling = false
    private var stitched: NSImage?
    private var scrollTask: Task<Void, Never>?
    private var globalKeys: Any?
    private let wheelSource: CGEventSource? = {
        let s = CGEventSource(stateID: .privateState)
        s?.localEventsSuppressionInterval = 0
        return s
    }()
    private var handle: ScreenshotCore.Handle?
    private var moveOrigin: CGPoint?
    private var moveRect: CGRect?
    private var wins: [ScreenshotCore.Win] = []
    private let log = Logger(subsystem: "com.mymy.macq", category: "screenshot")

    var isActive: Bool { !overlays.isEmpty }

    func start() {
        guard overlays.isEmpty else { return }
        if !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }
        wins = ScreenshotCore.liveWindows()
        for screen in NSScreen.screens {
            let w = ShotOverlayWindow(screen: screen, picker: self)
            overlays.append(w)
            w.orderFrontRegardless()
        }
        overlays.first?.makeKey()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleKey(event) == true ? nil : event
        }
        log.info("进入截图选区")
    }

    func cancel() {
        teardown()
        onCancel?()
    }

    func pickTool(_ t: ShotCanvas.Tool) {
        if isScrollMode { exitScrollMode() }
        ensureCanvas()
        canvas?.ink = ScreenshotTool.shared.ink
        canvas?.tool = t
        (bar?.contentView as? ShotToolbar)?.refresh()
        if let sel = selection { relayoutBar(sel) }
    }

    func setInk(_ mutate: (inout ScreenshotCore.MarkInk) -> Void) {
        var ink = ScreenshotTool.shared.ink
        mutate(&ink)
        ScreenshotTool.shared.ink = ink
        canvas?.ink = ink
        canvas?.syncEditorStyle()
        (bar?.contentView as? ShotToolbar)?.refresh()
    }

    func undoShot() { canvas?.undo() }

    func copyShot() {
        if isScrollMode {
            stopScroll()
            guard let img = stitched ?? grabCurrent() else { cancel(); return }
            writePasteboard(img)
            finish()
            return
        }
        if let canvas { canvas.copyImage(); return }
        guard let img = grabCurrent() else { cancel(); return }
        writePasteboard(img)
        finish()
    }

    func ocrShot() {
        let img = canvas?.snapshot() ?? grabCurrent()
        guard let img else { return }
        presentOCR(ScreenshotCore.recognizeText(in: img))
    }

    private func presentOCR(_ lines: [String]) {
        ocrPanel?.orderOut(nil)
        let panel = ShotOCRPanel(lines: lines)
        ocrPanel = panel
        let barFrame = bar?.frame ?? .zero
        let screen = overlays.first { $0.frame.intersects(barFrame) }?.frame
            ?? NSScreen.main?.frame ?? .zero
        let size = ScreenshotCore.ocrPanelSize(lineCount: lines.count, empty: lines.isEmpty)
        panel.setFrame(ScreenshotCore.ocrPanelFrame(bar: barFrame, size: size, screen: screen), display: true)
        panel.orderFrontRegardless()
    }

    func saveShot() {
        if isScrollMode {
            stopScroll()
            guard let img = stitched ?? grabCurrent() else { cancel(); return }
            saveImage(img)
            return
        }
        if let canvas { canvas.saveImage(); return }
        guard let img = grabCurrent() else { cancel(); return }
        saveImage(img)
    }

    private func saveImage(_ img: NSImage) {
        let wasVisible = AppShell.shared.mainWindow?.isVisible == true
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = AppLanguage.localized("截图.png")
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        panel.begin { [weak self] ret in
            var dismissed = false
            if ret == .OK, let url = panel.url, let self,
               let tiff = img.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: url)
                dismissed = true
                self.finish()
            }
            AppShell.shared.afterSystemPanel(mainWasVisible: wasVisible, overlayStillUp: !dismissed)
        }
    }

    private func pin() {
        guard let sel = selection, sel.width >= 8, sel.height >= 8 else { return }
        pinned = true
        hover = nil
        dragStart = nil
        showBar(for: sel)
        redraw()
        log.info("钉选区 \(Int(sel.width))×\(Int(sel.height))（尚未截屏）")
    }

    private func showBar(for sel: CGRect) {
        if bar == nil {
            let bar = ShotBarPanel(picker: self)
            self.bar = bar
        }
        relayoutBar(sel)
        bar?.orderFrontRegardless()
    }

    private func relayoutBar(_ sel: CGRect) {
        let screen = overlays.first { $0.frame.intersects(sel) }?.frame
            ?? NSScreen.main?.frame ?? .zero
        let size = ScreenshotCore.barSize(tool: currentTool, scrollMode: isScrollMode)
        let frame = ScreenshotCore.toolbarFrame(selection: sel, size: size, screen: screen)
        bar?.setFrame(frame, display: true)
        bar?.contentView?.setFrameSize(size)
    }

    private func ensureCanvas() {
        guard canvas == nil else { return }
        guard let sel = selection, let img = grabCurrent() else { cancel(); return }
        let host = overlays.first { $0.frame.intersects(sel) } ?? overlays.first
        guard let host, let content = host.contentView else { cancel(); return }
        // 选区/窗口坐标可能经过 integral 舍入；画布实际尺寸与截图点尺寸因此不一定完全相等。
        // 用实际画布尺寸映射标注坐标，避免编辑框与导出截图发生亚像素偏移。
        let canvasFrame = host.convertFromScreen(sel)
        let displayScaleX = img.size.width > 0 ? canvasFrame.width / img.size.width : 1
        let displayScaleY = img.size.height > 0 ? canvasFrame.height / img.size.height : 1
        let canvas = ShotCanvas(image: img, scaleX: displayScaleX, scaleY: displayScaleY)
        canvas.ink = ScreenshotTool.shared.ink
        canvas.frame = canvasFrame
        canvas.onDone = { [weak self] in self?.finish() }
        canvas.onToolChange = { [weak self] in (self?.bar?.contentView as? ShotToolbar)?.refresh() }
        content.addSubview(canvas)
        self.canvas = canvas
        host.makeKey()
        host.makeFirstResponder(canvas)
        log.info("截屏 \(Int(sel.width))×\(Int(sel.height))，开始标注")
        redraw()
    }

    private func grabCurrent() -> NSImage? {
        guard let sel = selection else { return nil }
        let host = overlays.first { $0.frame.intersects(sel) } ?? overlays.first
        let wid = CGWindowID(UInt32(truncatingIfNeeded: host?.windowNumber ?? 0))
        var img = ScreenshotCore.grab(cocoa: sel, below: wid)
        // 滚动时不能整屏抓：预览/工具条在遮罩上面，会被拍进去。
        if img == nil, !isScrolling {
            overlays.forEach { $0.orderOut(nil) }
            img = ScreenshotCore.grab(cocoa: sel, below: kCGNullWindowID)
            overlays.forEach { $0.orderFrontRegardless() }
        }
        if img == nil { log.error("截图失败（多半是屏幕录制权限）") }
        return img
    }

    private func writePasteboard(_ img: NSImage) {
        guard let tiff = img.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(png, forType: .png)
    }

    private func finish() {
        teardown()
    }

    fileprivate var isEditing: Bool { canvas != nil }
    fileprivate var isPinned: Bool { pinned }
    var currentTool: ShotCanvas.Tool? { canvas?.tool }

    private var screenUnion: CGRect {
        NSScreen.screens.map(\.frame).reduce(.null) { $0.union($1) }
    }

    func enterScrollMode() {
        guard pinned else { return }
        if isScrollMode { return }
        canvas?.removeFromSuperview()
        canvas = nil
        ocrPanel?.orderOut(nil)
        ocrPanel = nil
        isScrollMode = true
        overlays.forEach { $0.ignoresMouseEvents = true }
        preview?.ignoresMouseEvents = true
        stitched = grabCurrent()
        showPreview()
        (bar?.contentView as? ShotToolbar)?.refresh()
        if let sel = selection { relayoutBar(sel) }
        log.info("进入滚动截图")
        // 不自动开始：必须手动点「开始」（或空格），鼠标移入选区才滚动；
        // 提示常驻在遮罩底部，停止状态一直显示，开始后隐藏。
    }

    func toggleScroll() {
        if isScrolling { stopScroll() } else { startScroll() }
    }

    private func startScroll() {
        guard isScrollMode, !isScrolling else { return }
        isScrolling = true
        overlays.forEach { $0.ignoresMouseEvents = true }
        redraw()
        preview?.ignoresMouseEvents = true
        if globalKeys == nil {
            globalKeys = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] e in
                DispatchQueue.main.async {
                    guard let self else { return }
                    if e.keyCode == 49, self.isScrollMode { self.toggleScroll() }
                }
            }
        }
        (bar?.contentView as? ShotToolbar)?.refresh()
        if stitched == nil { stitched = grabCurrent(); showPreview() }
        // Retina 下捕获像素是点的一倍，期望新增按真实缩放算。
        var pxPerPoint = 2.0
        if let img = stitched {
            var r = CGRect(origin: .zero, size: img.size)
            if let cg = img.cgImage(forProposedRect: &r, context: nil, hints: nil), img.size.width > 0 {
                pxPerPoint = Double(cg.width) / img.size.width
            }
        }
        scrollTask?.cancel()
        scrollTask = Task { @MainActor [weak self] in
            var same = 0.0
            var ticks = 0
            while let self, !Task.isCancelled, self.isScrolling {
                guard let sel = self.selection,
                      ScreenshotCore.cursorInSelection(NSEvent.mouseLocation, sel)
                else {
                    try? await Task.sleep(nanoseconds: 50_000_000)
                    continue
                }
                let step = ScreenshotCore.scrollStep(selectionHeight: sel.height)
                let expected = Int(Double(step) * pxPerPoint)
                self.nudgeScroll(step: step)
                // 等页面动画停稳再截（连截两帧一致）：截到动画中间帧必错位，
                // 这是之前不连续的根源。
                guard let next = await self.settledGrab() else { break }
                // 单次拼接：只对长图（唯一基线）拼一次。
                // ponytail: 之前对 lastView/stitched 各拼一次，两次判定分叉
                // （一次成功一次门槛失败）后底部错位，后续追加全是重复/断层。
                let r = ScreenshotCore.stitchVertical(
                    base: self.stitched ?? next, next: next, expectedAdded: expected
                )
                guard !Task.isCancelled, self.isScrolling else { break }
                if r.identical {
                    // 强证据（像素纹丝不动）算 1 票，对不上（懒加载/动画）只算半票，
                    // 避免异步内容闪一下就被误判到底。
                    same += r.stable ? 1 : 0.5
                    if ScreenshotCore.scrollHitBottom(streak: same, need: 3) {
                        // 到底前验证：同倍步长再滚一下、等更久（懒加载内容到齐），
                        // 位移落在搜索窗内才可信。3 倍步长会甩出 ±240px 窗口，必误判。
                        self.nudgeScroll(step: step)
                        guard let verify = await self.settledGrab(maxTries: 14, intervalMs: 60) else { break }
                        var recovered = false
                        if !Task.isCancelled, self.isScrolling {
                            let rv = ScreenshotCore.stitchVertical(
                                base: self.stitched ?? verify, next: verify, expectedAdded: expected
                            )
                            if !rv.identical {
                                same = 0
                                self.stitched = rv.image
                                self.showPreview()
                                recovered = true
                            }
                        }
                        if recovered { continue }
                        self.showPreview()
                        self.stopScroll(atBottom: true)
                        break
                    }
                    continue
                }
                same = 0
                self.stitched = r.image
                ticks += 1
                if ticks % 2 == 1 { self.showPreview() }
            }
        }
    }

    /// 滚动后等页面停稳再返回那一帧；两次连截几乎一致才算稳，
    /// 否则用更长的间隔重试（页面动画/懒加载还在进行中）。
    private func settledGrab(maxTries: Int = 10, intervalMs: UInt64 = 50) async -> NSImage? {
        var prev = grabCurrent()
        for _ in 0..<maxTries {
            try? await Task.sleep(nanoseconds: intervalMs * 1_000_000)
            guard !Task.isCancelled, isScrolling, let cur = grabCurrent() else { return nil }
            if ScreenshotCore.framesQuiet(a: prev, b: cur) { return cur }
            prev = cur
        }
        return prev
    }

    private func stopScroll(atBottom: Bool = false) {
        isScrolling = false
        scrollTask?.cancel()
        scrollTask = nil
        redraw()
        if let g = globalKeys { NSEvent.removeMonitor(g); globalKeys = nil }
        (bar?.contentView as? ShotToolbar)?.refresh()
        if atBottom { showToast(AppLanguage.localized("已滚到底")) }
    }

    private func showToast(_ text: String, seconds: TimeInterval = 1.6) {
        toast?.orderOut(nil)
        let probe = NSTextField(labelWithString: text)
        probe.font = .systemFont(ofSize: 13, weight: .medium)
        probe.sizeToFit()
        let size = NSSize(width: max(180, probe.frame.width + 28), height: 36)
        let screen = overlays.first?.frame ?? NSScreen.main?.frame ?? .zero
        var origin = CGPoint(x: screen.midX - size.width / 2, y: screen.midY + 80)
        if let sel = selection {
            origin = CGPoint(x: sel.midX - size.width / 2, y: sel.midY)
        }
        let p = NSPanel(
            contentRect: NSRect(origin: origin, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 3)
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = true
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.86).cgColor
        root.layer?.cornerRadius = 8
        let lab = NSTextField(labelWithString: text)
        lab.font = .systemFont(ofSize: 13, weight: .medium)
        lab.textColor = .white
        lab.alignment = .center
        lab.frame = root.bounds.insetBy(dx: 8, dy: 8)
        root.addSubview(lab)
        p.contentView = root
        toast = p
        p.orderFrontRegardless()
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self, weak p] in
            guard self?.toast === p else { return }
            p?.orderOut(nil)
            self?.toast = nil
        }
    }

    private func exitScrollMode() {
        stopScroll()
        isScrollMode = false
        overlays.forEach { $0.ignoresMouseEvents = false }
        preview?.orderOut(nil)
        preview = nil
        toast?.orderOut(nil)
        toast = nil
        stitched = nil
        (bar?.contentView as? ShotToolbar)?.refresh()
        if let sel = selection { relayoutBar(sel) }
    }

    private func nudgeScroll(step: Int32) {
        guard selection != nil else { return }
        let mouse = NSEvent.mouseLocation
        let cocoa = CGRect(x: mouse.x, y: mouse.y, width: 1, height: 1)
        let loc = ScreenshotCore.cgRect(fromCocoa: cocoa, mainHeight: ScreenshotCore.mainHeight).origin
        // 标成连续像素，魔法鼠标平滑不会把离散档吞掉。
        guard let e = CGEvent(
            scrollWheelEvent2Source: wheelSource, units: .pixel,
            wheelCount: 1, wheel1: -step, wheel2: 0, wheel3: 0
        ) else { return }
        e.location = loc
        e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        e.post(tap: .cghidEventTap)
    }

    private func showPreview() {
        guard let img = stitched, let sel = selection else { return }
        if preview == nil {
            let p = ShotScrollPreview()
            preview = p
        }
        preview?.show(
            ScreenshotCore.scrollPreviewThumb(img),
            label: "\(Int(img.size.width))×\(Int(img.size.height))"
        )
        let screen = overlays.first { $0.frame.intersects(sel) }?.frame
            ?? NSScreen.main?.frame ?? .zero
        let size = preview?.frame.size ?? ScreenshotCore.scrollPreviewSize(image: img.size)
        let extra = CGSize(width: size.width, height: size.height)
        preview?.setFrame(ScreenshotCore.scrollPreviewFrame(selection: sel, size: extra, screen: screen), display: true)
        preview?.orderFrontRegardless()
    }

    fileprivate func mouseMoved(_ global: CGPoint) {
        if canvas != nil || isScrollMode { return }
        if pinned, let sel = selection {
            if ScreenshotCore.hitHandle(global, in: sel) != nil { NSCursor.crosshair.set() }
            else if sel.contains(global) { NSCursor.openHand.set() }
            else { NSCursor.arrow.set() }
            return
        }
        hover = ScreenshotCore.window(at: global, in: wins)?.rect
        redraw()
    }

    fileprivate func mouseDown(_ global: CGPoint) {
        if isScrollMode { return }
        if canvas != nil {
            canvas?.commitText()
            return
        }
        hover = nil
        if pinned, let sel = selection {
            if let h = ScreenshotCore.hitHandle(global, in: sel) {
                handle = h
                return
            }
            if sel.contains(global) {
                moveOrigin = global
                moveRect = sel
                NSCursor.closedHand.set()
                return
            }
            pinned = false
            bar?.orderOut(nil)
            bar = nil
            ocrPanel?.orderOut(nil)
            ocrPanel = nil
        }
        dragStart = global
        if let win = ScreenshotCore.window(at: global, in: wins) {
            selection = win.rect
        } else {
            selection = nil
        }
        redraw()
    }

    fileprivate func mouseDragged(_ global: CGPoint) {
        if canvas != nil || isScrollMode { return }
        if let origin = moveOrigin, let base = moveRect {
            let d = CGPoint(x: global.x - origin.x, y: global.y - origin.y)
            selection = ScreenshotCore.move(base, by: d, in: screenUnion)
            if let sel = selection { relayoutBar(sel) }
            redraw()
            return
        }
        if let h = handle, let sel = selection {
            selection = ScreenshotCore.resize(sel, h, to: global)
            if let sel = selection { relayoutBar(sel) }
            redraw()
            return
        }
        guard let start = dragStart else { return }
        let r = ScreenshotCore.rect(from: start, to: global)
        if r.width >= 8 || r.height >= 8 { selection = r }
        redraw()
    }

    fileprivate func mouseUp(_ global: CGPoint) {
        if canvas != nil || isScrollMode { return }
        if handle != nil || moveOrigin != nil {
            handle = nil
            moveOrigin = nil
            moveRect = nil
            NSCursor.arrow.set()
            return
        }
        if let start = dragStart {
            let r = ScreenshotCore.rect(from: start, to: global)
            if r.width >= 8 && r.height >= 8 { selection = r }
        }
        dragStart = nil
        if let sel = selection, sel.width >= 8, sel.height >= 8 {
            pin()
        } else {
            selection = nil
            pinned = false
            redraw()
        }
    }

    fileprivate func doubleClick(_ global: CGPoint) {
        copyShot()
    }

    private func handleKey(_ event: NSEvent) -> Bool {
        if let canvas {
            if event.modifierFlags.contains(.command) {
                switch event.keyCode {
                case 6: canvas.undo(); return true
                case 8: canvas.copyImage(); return true
                case 1: canvas.saveImage(); return true
                default: break
                }
            }
            if event.keyCode == 53 { cancel(); return true }
            if event.keyCode == 36 || event.keyCode == 76 {
                if canvas.window?.firstResponder is NSTextView { return false }
                canvas.copyImage(); return true
            }
            return false
        }
        switch event.keyCode {
        case 49:
            if isScrollMode { toggleScroll(); return true }
            return false
        case 36, 76:
            if isScrollMode { return false }
            copyShot(); return true
        case 53: cancel(); return true
        default: return false
        }
    }

    fileprivate var overlayIDs: Set<UInt32> {
        Set(overlays.map { UInt32($0.windowNumber) })
    }

    fileprivate func state(in screen: NSRect) -> (hover: CGRect?, selection: CGRect?) {
        let h = hover.flatMap { screen.intersects($0) ? $0 : nil }
        let s = selection.flatMap { screen.intersects($0) ? $0 : nil }
        return (h, s)
    }

    private func redraw() {
        overlays.forEach { $0.contentView?.needsDisplay = true }
    }

    private func teardown() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        bar?.orderOut(nil)
        bar = nil
        ocrPanel?.orderOut(nil)
        ocrPanel = nil
        stopScroll()
        isScrollMode = false
        preview?.orderOut(nil)
        preview = nil
        toast?.orderOut(nil)
        toast = nil
        stitched = nil
        canvas?.removeFromSuperview()
        canvas = nil
        overlays.forEach { $0.orderOut(nil) }
        overlays.removeAll()
        hover = nil
        selection = nil
        dragStart = nil
        pinned = false
        handle = nil
        moveOrigin = nil
        moveRect = nil
        NSCursor.arrow.set()
    }
}

@MainActor
final class ShotOverlayWindow: NSPanel {
    init(screen: NSScreen, picker: ScreenshotPicker) {
        super.init(
            contentRect: screen.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        setFrame(screen.frame, display: true)
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isFloatingPanel = true
        becomesKeyOnlyIfNeeded = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false
        acceptsMouseMovedEvents = true
        animationBehavior = .none
        contentView = ShotPickView(picker: picker)
    }

    override var canBecomeKey: Bool { true }
}

@MainActor
final class ShotPickView: NSView {
    private weak var picker: ScreenshotPicker?

    init(picker: ScreenshotPicker) {
        self.picker = picker
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseMoved, .inVisibleRect],
            owner: self,
            userInfo: nil
        ))
    }

    override func mouseMoved(with event: NSEvent) { picker?.mouseMoved(global(event)) }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { picker?.doubleClick(global(event)) }
        else { picker?.mouseDown(global(event)) }
    }
    override func mouseDragged(with event: NSEvent) { picker?.mouseDragged(global(event)) }
    override func mouseUp(with event: NSEvent) { picker?.mouseUp(global(event)) }

    private func global(_ event: NSEvent) -> CGPoint {
        window?.convertPoint(toScreen: event.locationInWindow) ?? event.locationInWindow
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let picker, let window else { return }
        let screen = window.frame
        let state = picker.state(in: screen)
        func local(_ r: CGRect) -> CGRect {
            window.convertFromScreen(r)
        }

        let dim = NSBezierPath(rect: bounds)
        dim.windingRule = .evenOdd
        if let hover = state.hover { dim.append(NSBezierPath(rect: local(hover))) }
        if let sel = state.selection { dim.append(NSBezierPath(rect: local(sel))) }
        NSColor.black.withAlphaComponent(0.45).setFill()
        dim.fill()

        if let hover = state.hover {
            let r = local(hover)
            NSColor.systemBlue.setStroke()
            let p = NSBezierPath(rect: r.insetBy(dx: 1, dy: 1))
            p.lineWidth = 2
            p.stroke()
        }
        if let sel = state.selection {
            let r = local(sel)
            NSColor.systemBlue.setStroke()
            let p = NSBezierPath(rect: r.insetBy(dx: 0.5, dy: 0.5))
            p.lineWidth = 2
            p.stroke()
            if picker.isPinned && !picker.isEditing && !picker.isScrollMode {
                NSColor.white.setFill()
                NSColor.systemBlue.setStroke()
                for c in ScreenshotCore.handleCenters(r).values {
                    let h = NSRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8)
                    let hp = NSBezierPath(roundedRect: h, xRadius: 1, yRadius: 1)
                    hp.fill()
                    hp.lineWidth = 1
                    hp.stroke()
                }
                let label = "\(Int(sel.width)) × \(Int(sel.height))"
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: NSColor.white,
                ]
                let size = (label as NSString).size(withAttributes: attrs)
                var labOrigin = CGPoint(x: r.minX + 6, y: r.maxY + 6)
                if labOrigin.y + 18 > bounds.maxY { labOrigin.y = r.maxY - 22 }
                NSColor.black.withAlphaComponent(0.7).setFill()
                NSBezierPath(roundedRect: NSRect(x: labOrigin.x - 4, y: labOrigin.y - 2, width: size.width + 8, height: size.height + 4), xRadius: 4, yRadius: 4).fill()
                (label as NSString).draw(at: labOrigin, withAttributes: attrs)
            }
        }
        if picker.isEditing { return }

        let hint: String
        if picker.isScrollMode {
            hint = picker.isScrolling ? "" : AppLanguage.localized("点击「开始」或空格 · 鼠标移入选区自动滚动，移出暂停")
        } else if picker.isPinned {
            hint = AppLanguage.localized("拖动选区平移 · 手柄调大小 · 双击复制 · esc 取消")
        } else {
            hint = AppLanguage.localized("点击窗口或拖拽选区 · esc 取消")
        }
        guard !hint.isEmpty else { return }
        let ha: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let hs = (hint as NSString).size(withAttributes: ha)
        let hb = NSRect(x: (bounds.width - hs.width) / 2 - 12, y: 24, width: hs.width + 24, height: hs.height + 12)
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(roundedRect: hb, xRadius: 10, yRadius: 10).fill()
        (hint as NSString).draw(at: CGPoint(x: hb.minX + 12, y: hb.minY + 6), withAttributes: ha)
    }
}
