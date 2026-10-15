import AppKit
import CoreImage

/// 贴在选区边上的浮动工具条，可拖到别处。
@MainActor
final class ShotBarPanel: NSPanel {
    init(picker: ScreenshotPicker) {
        super.init(
            contentRect: NSRect(origin: .zero, size: ScreenshotCore.toolbarSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        animationBehavior = .none
        contentView = ShotToolbar(picker: picker)
    }

    override var canBecomeKey: Bool { false }
}

/// 选区 OCR 结果。空结果橙字提示，有结果可点选、一键复制。不关掉截图遮罩。
@MainActor
final class ShotOCRPanel: NSPanel {
    private let payload: String

    init(lines: [String]) {
        payload = lines.joined(separator: "\n")
        let empty = lines.isEmpty
        let size = ScreenshotCore.ocrPanelSize(lineCount: lines.count, empty: empty)
        super.init(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        animationBehavior = .none

        let root = NSView(frame: NSRect(origin: .zero, size: size))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.88).cgColor
        root.layer?.cornerRadius = 10
        root.layer?.masksToBounds = true

        let title = NSTextField(labelWithString: AppLanguage.localized("识别结果"))
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .white
        title.drawsBackground = false
        title.isBezeled = false
        title.frame = NSRect(x: 12, y: size.height - 32, width: 90, height: 20)
        root.addSubview(title)

        let close = NSButton(title: "×", target: self, action: #selector(closePanel))
        close.isBordered = false
        close.font = .systemFont(ofSize: 16, weight: .medium)
        close.contentTintColor = .white
        close.toolTip = AppLanguage.localized("关闭")
        close.frame = NSRect(x: size.width - 32, y: size.height - 34, width: 24, height: 24)
        root.addSubview(close)

        if empty {
            let hint = NSTextField(labelWithString: AppLanguage.localized("未识别到文字"))
            hint.font = .systemFont(ofSize: 13)
            hint.textColor = .systemOrange
            hint.drawsBackground = false
            hint.isBezeled = false
            hint.frame = NSRect(x: 12, y: 14, width: size.width - 24, height: 20)
            root.addSubview(hint)
        } else {
            let copy = NSButton(title: AppLanguage.localized("复制全部"), target: self, action: #selector(copyAll))
            copy.bezelStyle = .rounded
            copy.frame = NSRect(x: size.width - 120, y: size.height - 36, width: 80, height: 26)
            root.addSubview(copy)
            let tv = NSTextView(frame: NSRect(x: 10, y: 8, width: size.width - 20, height: size.height - 48))
            tv.string = payload
            tv.isEditable = false
            tv.isSelectable = true
            tv.drawsBackground = false
            tv.textColor = .white
            tv.font = .systemFont(ofSize: 13)
            tv.isVerticallyResizable = true
            tv.textContainer?.widthTracksTextView = true
            let scroll = NSScrollView(frame: tv.frame)
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = lines.count > 6
            scroll.documentView = tv
            tv.frame.size.width = scroll.contentSize.width
            root.addSubview(scroll)
        }
        contentView = root
    }

    override var canBecomeKey: Bool { true }

    @objc private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(payload, forType: .string)
    }

    @objc private func closePanel() {
        orderOut(nil)
    }
}

/// 滚动截图预览：选区右侧的缩略图，随拼接变长。
@MainActor
final class ShotScrollPreview: NSPanel {
    private let imageView = NSImageView()
    private let caption = NSTextField(labelWithString: AppLanguage.localized("滚动预览"))

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 236, height: 280),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        animationBehavior = .none
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 236, height: 280))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.88).cgColor
        root.layer?.cornerRadius = 10
        root.layer?.masksToBounds = true
        caption.font = .systemFont(ofSize: 11, weight: .medium)
        caption.textColor = .white
        caption.drawsBackground = false
        caption.isBezeled = false
        caption.alignment = .center
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.wantsLayer = true
        imageView.layer?.cornerRadius = 6
        imageView.layer?.masksToBounds = true
        root.addSubview(caption)
        root.addSubview(imageView)
        contentView = root
    }

    func show(_ img: NSImage, label: String? = nil) {
        let inner = ScreenshotCore.scrollPreviewSize(image: img.size)
        let size = CGSize(width: inner.width + 16, height: inner.height + 36)
        imageView.image = img
        caption.stringValue = label ?? "\(Int(img.size.width))×\(Int(img.size.height))"
        caption.frame = NSRect(x: 8, y: size.height - 26, width: size.width - 16, height: 18)
        imageView.frame = NSRect(x: 8, y: 8, width: inner.width, height: inner.height)
        contentView?.setFrameSize(size)
        setContentSize(size)
    }
}

@MainActor
final class ShotToolbar: NSView {
    private weak var picker: ScreenshotPicker?
    private var buttons: [ShotCanvas.Tool: NSButton] = [:]
    private var toolRow: [NSView] = []
    private var editViews: [NSView] = []
    private let configRow = NSView(frame: .zero)
    private var scrollBtn: NSButton!
    private var runBtn: NSButton!

    init(picker: ScreenshotPicker) {
        self.picker = picker
        super.init(frame: NSRect(origin: .zero, size: ScreenshotCore.toolbarSize))
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.withAlphaComponent(0.82).cgColor
        layer?.cornerRadius = 10
        layer?.masksToBounds = false
        layer?.borderWidth = 1.5
        layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.9).cgColor

        var x: CGFloat = 14
        let grip = NSView(frame: NSRect(x: 8, y: 14, width: 6, height: 16))
        grip.wantsLayer = true
        grip.layer?.backgroundColor = NSColor.white.withAlphaComponent(0.35).cgColor
        grip.layer?.cornerRadius = 1.5
        addSubview(grip)
        toolRow.append(grip)
        x = 22

        let items: [(ShotCanvas.Tool, String, String)] = [
            (.rect, "rectangle", AppLanguage.localized("矩形")),
            (.arrow, "arrow.up.right", AppLanguage.localized("箭头")),
            (.pen, "pencil", AppLanguage.localized("画笔")),
            (.text, "textformat", AppLanguage.localized("文字")),
            (.mosaic, "square.grid.3x3", AppLanguage.localized("马赛克")),
        ]
        for (i, item) in items.enumerated() {
            let b = makeButton(item.1, item.2)
            b.frame = NSRect(x: x, y: 8, width: 28, height: 28)
            b.target = self
            b.action = #selector(pickTool(_:))
            b.tag = i
            buttons[item.0] = b
            addSubview(b)
            toolRow.append(b)
            editViews.append(b)
            x += 32
        }
        scrollBtn = makeButton("arrow.up.and.down", AppLanguage.localized("滚动截图"))
        scrollBtn.frame = NSRect(x: x, y: 8, width: 28, height: 28)
        scrollBtn.target = self
        scrollBtn.action = #selector(enterScroll)
        addSubview(scrollBtn)
        toolRow.append(scrollBtn)
        x += 32
        x += 6
        let undoBtn = makeButton("arrow.uturn.backward", AppLanguage.localized("撤销"))
        undoBtn.frame = NSRect(x: x, y: 8, width: 28, height: 28)
        undoBtn.target = self
        undoBtn.action = #selector(undo)
        addSubview(undoBtn)
        toolRow.append(undoBtn)
        editViews.append(undoBtn)
        runBtn = NSButton(title: AppLanguage.localized("开始"), target: self, action: #selector(toggleScroll))
        runBtn.bezelStyle = .rounded
        runBtn.toolTip = AppLanguage.localized("空格也可开始/停止")
        runBtn.frame = NSRect(x: x, y: 8, width: 64, height: 28)
        runBtn.isHidden = true
        addSubview(runBtn)
        x += 36
        let ocr = NSButton(title: "OCR", target: self, action: #selector(ocrShot))
        ocr.bezelStyle = .rounded
        ocr.toolTip = AppLanguage.localized("识别选区文字（离线）")
        ocr.frame = NSRect(x: x, y: 8, width: 52, height: 28)
        addSubview(ocr)
        toolRow.append(ocr)
        editViews.append(ocr)
        x += 60
        let copy = NSButton(title: AppLanguage.localized("复制"), target: self, action: #selector(copyShot))
        copy.bezelStyle = .rounded
        copy.frame = NSRect(x: x, y: 8, width: 64, height: 28)
        addSubview(copy)
        toolRow.append(copy)
        x += 72
        let save = NSButton(title: AppLanguage.localized("保存"), target: self, action: #selector(saveShot))
        save.bezelStyle = .rounded
        save.frame = NSRect(x: x, y: 8, width: 64, height: 28)
        addSubview(save)
        toolRow.append(save)
        x += 72
        let close = makeButton("xmark", AppLanguage.localized("退出"))
        close.frame = NSRect(x: x, y: 8, width: 28, height: 28)
        close.target = self
        close.action = #selector(cancel)
        addSubview(close)
        toolRow.append(close)
        addSubview(configRow)
        refresh()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func makeButton(_ symbol: String, _ tip: String) -> NSButton {
        let img = NSImage(systemSymbolName: symbol, accessibilityDescription: tip)
        let b = NSButton(image: img ?? NSImage(), target: nil, action: nil)
        b.isBordered = false
        b.toolTip = tip
        b.imagePosition = .imageOnly
        b.contentTintColor = .white
        return b
    }

    @objc private func pickTool(_ sender: NSButton) {
        let items: [ShotCanvas.Tool] = [.rect, .arrow, .pen, .text, .mosaic]
        guard sender.tag < items.count else { return }
        picker?.pickTool(items[sender.tag])
        refresh()
    }

    @objc private func undo() { picker?.undoShot() }
    @objc private func copyShot() { picker?.copyShot() }
    @objc private func saveShot() { picker?.saveShot() }
    @objc private func ocrShot() { picker?.ocrShot() }
    @objc private func cancel() { picker?.cancel() }
    @objc private func enterScroll() { picker?.enterScrollMode() }
    @objc private func toggleScroll() { picker?.toggleScroll() }

    @objc private func pickColor(_ sender: NSButton) {
        let all = ScreenshotCore.MarkColor.allCases
        guard sender.tag < all.count else { return }
        picker?.setInk { $0.color = all[sender.tag] }
    }

    @objc private func pickStroke(_ sender: NSButton) {
        let all = ScreenshotCore.MarkInk.strokes
        guard sender.tag < all.count else { return }
        picker?.setInk { $0.stroke = all[sender.tag] }
    }

    @objc private func pickFont(_ sender: NSButton) {
        let all = ScreenshotCore.MarkInk.fonts
        guard sender.tag < all.count else { return }
        picker?.setInk { $0.fontSize = all[sender.tag] }
    }

    func refresh() {
        let scrolling = picker?.isScrollMode == true
        let running = picker?.isScrolling == true
        let current = picker?.currentTool
        for (tool, b) in buttons {
            b.contentTintColor = tool == current ? NSColor.controlAccentColor : .white
        }
        scrollBtn?.contentTintColor = scrolling ? NSColor.controlAccentColor : .white
        for v in editViews { v.isHidden = scrolling }
        runBtn?.isHidden = !scrolling
        runBtn?.title = running ? AppLanguage.localized("停止") : AppLanguage.localized("开始")
        let expanded = !scrolling && current != nil && current != .mosaic
        let toolY: CGFloat = expanded ? 44 : 8
        for v in toolRow {
            let y = v.frame.height < 20 ? toolY + 6 : toolY
            v.setFrameOrigin(NSPoint(x: v.frame.minX, y: y))
        }
        runBtn?.setFrameOrigin(NSPoint(x: runBtn.frame.minX, y: toolY))
        configRow.subviews.forEach { $0.removeFromSuperview() }
        configRow.isHidden = !expanded
        configRow.frame = NSRect(x: 0, y: 4, width: ScreenshotCore.toolbarSize.width, height: 32)
        if expanded { fillConfig(tool: current) }
        setFrameSize(ScreenshotCore.barSize(tool: current, scrollMode: scrolling))
    }

    private func fillConfig(tool: ShotCanvas.Tool?) {
        let ink = ScreenshotTool.shared.ink
        var x: CGFloat = 22
        for (i, color) in ScreenshotCore.MarkColor.allCases.enumerated() {
            let b = NSButton(frame: NSRect(x: x, y: 7, width: 18, height: 18))
            b.title = ""
            b.isBordered = false
            b.wantsLayer = true
            b.layer?.backgroundColor = color.nsColor.cgColor
            b.layer?.cornerRadius = 9
            let on = ink.color == color
            b.layer?.borderWidth = on ? 2 : (color == .white || color == .black ? 1 : 0)
            b.layer?.borderColor = on ? NSColor.controlAccentColor.cgColor : NSColor.white.withAlphaComponent(0.45).cgColor
            b.toolTip = color.label
            b.tag = i
            b.target = self
            b.action = #selector(pickColor(_:))
            configRow.addSubview(b)
            x += 24
        }
        x += 10
        if tool == .text {
            for (i, size) in ScreenshotCore.MarkInk.fonts.enumerated() {
                let b = NSButton(title: "\(Int(size))", target: self, action: #selector(pickFont(_:)))
                b.bezelStyle = .inline
                b.isBordered = false
                b.tag = i
                b.frame = NSRect(x: x, y: 4, width: 36, height: 24)
                b.contentTintColor = ink.fontSize == size ? NSColor.controlAccentColor : .white
                b.toolTip = AppLanguage.localized("字号")
                configRow.addSubview(b)
                x += 38
            }
        } else {
            for (i, w) in ScreenshotCore.MarkInk.strokes.enumerated() {
                let side = w + 6
                let b = NSButton(frame: NSRect(x: x, y: 16 - side / 2, width: side, height: side))
                b.title = ""
                b.isBordered = false
                b.wantsLayer = true
                b.layer?.backgroundColor = NSColor.white.cgColor
                b.layer?.cornerRadius = side / 2
                b.alphaValue = ink.stroke == w ? 1 : 0.35
                b.toolTip = w == 2 ? AppLanguage.localized("细") : (w == 4 ? AppLanguage.localized("中") : AppLanguage.localized("粗"))
                b.tag = i
                b.target = self
                b.action = #selector(pickStroke(_:))
                configRow.addSubview(b)
                x += 28
            }
        }
    }
}

@MainActor
final class ShotCanvas: NSView, NSTextViewDelegate {
    enum Tool { case rect, arrow, pen, text, mosaic }
    enum Mark {
        case rect(CGRect, ScreenshotCore.MarkInk)
        case arrow(CGPoint, CGPoint, ScreenshotCore.MarkInk)
        case pen([CGPoint], ScreenshotCore.MarkInk)
        case mosaic(CGRect, NSImage?)
        case text(CGRect, String, ScreenshotCore.MarkInk)
    }

    var tool: Tool = .rect { didSet { onToolChange?() } }
    var ink = ScreenshotCore.MarkInk.default
    var onToolChange: (() -> Void)?
    var onDone: (() -> Void)?
    private let image: NSImage
    // 标注坐标统一使用 sourceCG 的像素坐标；显示和导出各自只做一次映射。
    private var marks: [Mark] = []
    private var draft: Mark?
    private var dragStart: CGPoint?
    private var textHost: NSView?
    private var textView: NSTextView?
    private let sourceCG: CGImage?
    private let ci = CIContext(options: [.useSoftwareRenderer: false])
    private var renderingScale: CGFloat = 1

    init(image: NSImage, scaleX: CGFloat = 1, scaleY: CGFloat = 1) {
        self.image = image
        self.sourceCG = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        super.init(frame: .zero)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { false }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.imageInterpolation = .none
        image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
        marks.forEach { draw($0) }
        if let draft { draw(draft) }
    }

    private func draw(_ mark: Mark) {
        switch mark {
        case .rect(let r, let ink):
            ink.color.nsColor.setStroke()
            let p = NSBezierPath(rect: toView(r))
            p.lineWidth = ink.stroke * renderingScale
            p.stroke()
        case .arrow(let a, let b, let ink):
            ink.color.nsColor.setStroke()
            drawArrow(from: toView(a), to: toView(b), width: ink.stroke * renderingScale)
        case .pen(let pts, let ink):
            guard pts.count > 1 else { return }
            ink.color.nsColor.setStroke()
            let p = NSBezierPath()
            p.move(to: toView(pts[0]))
            pts.dropFirst().forEach { p.line(to: toView($0)) }
            p.lineWidth = ink.stroke * renderingScale
            p.lineCapStyle = .round
            p.lineJoinStyle = .round
            p.stroke()
        case .mosaic(let r, let img):
            if let img {
                img.draw(in: toView(r), from: .zero, operation: .copy, fraction: 1)
            } else {
                NSColor.black.withAlphaComponent(0.28).setFill()
                toView(r).fill()
            }
        case .text(let r, let s, let ink):
            (s as NSString).draw(in: toView(r), withAttributes: textAttrs(ink))
        }
    }

    private func textAttrs(_ ink: ScreenshotCore.MarkInk) -> [NSAttributedString.Key: Any] {
        [
            .font: NSFont.systemFont(ofSize: ink.fontSize * renderingScale, weight: .medium),
            .foregroundColor: ink.color.nsColor,
        ]
    }

    private func drawArrow(from: CGPoint, to: CGPoint, width: CGFloat) {
        let path = NSBezierPath()
        path.move(to: from)
        path.line(to: to)
        path.lineWidth = width
        path.lineCapStyle = .round
        path.stroke()
        let angle = atan2(to.y - from.y, to.x - from.x)
        let len: CGFloat = 12 * renderingScale
        let head = NSBezierPath()
        head.move(to: to)
        head.line(to: CGPoint(x: to.x + cos(angle + .pi * 0.82) * len, y: to.y + sin(angle + .pi * 0.82) * len))
        head.move(to: to)
        head.line(to: CGPoint(x: to.x + cos(angle - .pi * 0.82) * len, y: to.y + sin(angle - .pi * 0.82) * len))
        head.lineWidth = width
        head.lineCapStyle = .round
        head.stroke()
    }

    private func bakeMosaic(_ r: CGRect) -> NSImage {
        let size = NSSize(width: max(r.width, 1), height: max(r.height, 1))
        guard r.width >= 2, r.height >= 2, let cg = sourceCG else { return NSImage(size: size) }
        // r 已经是 CGImage 像素坐标；CGImage 原点在左下，画布坐标同样如此。
        let crop = CGRect(
            x: r.minX,
            y: CGFloat(cg.height) - r.maxY,
            width: r.width,
            height: r.height
        ).integral
        let input = CIImage(cgImage: cg).cropped(to: crop)
        let filter = CIFilter(name: "CIPixellate")
        filter?.setValue(input, forKey: kCIInputImageKey)
        filter?.setValue(8.0, forKey: kCIInputScaleKey)
        filter?.setValue(CIVector(x: crop.midX, y: crop.midY), forKey: kCIInputCenterKey)
        guard let out = filter?.outputImage?.cropped(to: crop),
              let outCG = ci.createCGImage(out, from: crop) else { return NSImage(size: size) }
        return NSImage(cgImage: outCG, size: size)
    }

    // 原始截图像素是唯一坐标系；不使用 NSImage.size（point）参与标注计算。
    private var sourceSize: CGSize {
        guard let sourceCG else { return CGSize(width: 1, height: 1) }
        return CGSize(width: sourceCG.width, height: sourceCG.height)
    }
    private var viewScaleX: CGFloat { sourceSize.width > 0 ? bounds.width / sourceSize.width : 1 }
    private var viewScaleY: CGFloat { sourceSize.height > 0 ? bounds.height / sourceSize.height : 1 }

    private func toView(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x * viewScaleX, y: p.y * viewScaleY)
    }
    private func toView(_ r: CGRect) -> CGRect {
        CGRect(x: r.origin.x * viewScaleX, y: r.origin.y * viewScaleY,
               width: r.width * viewScaleX, height: r.height * viewScaleY)
    }
    private func toImage(_ p: CGPoint) -> CGPoint {
        CGPoint(x: p.x / max(viewScaleX, 0.01), y: p.y / max(viewScaleY, 0.01))
    }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount >= 2 {
            draft = nil
            dragStart = nil
            copyImage()
            return
        }
        if textView != nil {
            commitText()
            if tool == .text { return }
        }
        let p = toImage(convert(event.locationInWindow, from: nil))
        dragStart = p
        switch tool {
        case .rect: draft = .rect(CGRect(origin: p, size: .zero), ink)
        case .mosaic: draft = .mosaic(CGRect(origin: p, size: .zero), nil)
        case .arrow: draft = .arrow(p, p, ink)
        case .pen: draft = .pen([p], ink)
        case .text: beginText(at: convert(event.locationInWindow, from: nil)); dragStart = nil
        }
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let start = dragStart else { return }
        let p = toImage(convert(event.locationInWindow, from: nil))
        switch tool {
        case .rect: draft = .rect(ScreenshotCore.rect(from: start, to: p), ink)
        case .mosaic: draft = .mosaic(ScreenshotCore.rect(from: start, to: p), nil)
        case .arrow: draft = .arrow(start, p, ink)
        case .pen:
            if case .pen(var pts, _) = draft { pts.append(p); draft = .pen(pts, ink) }
        case .text: break
        }
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        if case .mosaic(let r, _) = draft {
            if r.width >= 4, r.height >= 4 { marks.append(.mosaic(r, bakeMosaic(r))) }
        } else if let draft {
            marks.append(draft)
        }
        self.draft = nil
        dragStart = nil
        needsDisplay = true
    }

    private func beginText(at p: NSPoint) {
        commitText()
        let h = max(28, ink.fontSize + 12)
        var frame = NSRect(x: p.x, y: p.y - h + 6, width: 240, height: h)
        if frame.maxX > bounds.maxX { frame.origin.x = max(0, bounds.maxX - frame.width) }
        if frame.minX < 0 { frame.origin.x = 0 }
        if frame.minY < 0 { frame.origin.y = 0 }
        let host = NSView(frame: frame)
        host.wantsLayer = true
        host.layer?.borderWidth = 1.5
        host.layer?.borderColor = ink.color.nsColor.cgColor
        host.layer?.cornerRadius = 3
        host.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        let tv = NSTextView(frame: host.bounds.insetBy(dx: 6, dy: 4))
        tv.drawsBackground = false
        tv.font = .systemFont(ofSize: ink.fontSize, weight: .medium)
        tv.textColor = ink.color.nsColor
        tv.insertionPointColor = ink.color.nsColor
        tv.isRichText = false
        tv.usesFontPanel = false
        tv.isHorizontallyResizable = false
        tv.isVerticallyResizable = true
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: frame.width - 12, height: 1e7)
        tv.autoresizingMask = [.width, .height]
        tv.delegate = self
        host.addSubview(tv)
        addSubview(host)
        textHost = host
        textView = tv
        window?.makeFirstResponder(tv)
    }

    func textDidChange(_ notification: Notification) {
        guard let tv = textView, let host = textHost, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        lm.ensureLayout(for: tc)
        let used = lm.usedRect(for: tc)
        let w = host.frame.width
        let h = min(max(ink.fontSize + 12, used.height + 12), bounds.height)
        let top = host.frame.maxY
        host.setFrameSize(NSSize(width: w, height: h))
        host.setFrameOrigin(NSPoint(x: host.frame.minX, y: max(0, top - h)))
        tv.frame = host.bounds.insetBy(dx: 6, dy: 4)
    }

    @objc func commitText() {
        guard let host = textHost, let tv = textView else { return }
        let s = tv.string.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty {
            let r = CGRect(
                x: host.frame.minX / max(viewScaleX, 0.01),
                y: host.frame.minY / max(viewScaleY, 0.01),
                width: host.frame.width / max(viewScaleX, 0.01),
                height: host.frame.height / max(viewScaleY, 0.01)
            )
            marks.append(.text(r, s, ink))
        }
        host.removeFromSuperview()
        textHost = nil
        textView = nil
        needsDisplay = true
    }

    func syncEditorStyle() {
        guard let tv = textView, let host = textHost else { return }
        tv.font = .systemFont(ofSize: ink.fontSize, weight: .medium)
        tv.textColor = ink.color.nsColor
        tv.insertionPointColor = ink.color.nsColor
        host.layer?.borderColor = ink.color.nsColor.cgColor
        textDidChange(Notification(name: NSText.didChangeNotification, object: tv))
    }

    @objc func undo() {
        commitText()
        guard !marks.isEmpty else { return }
        marks.removeLast()
        needsDisplay = true
    }

    func snapshot() -> NSImage {
        commitText()
        return render()
    }

    @objc func copyImage() {
        commitText()
        guard let tiff = render().tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(png, forType: .png)
        onDone?()
    }

    @objc func saveImage() {
        commitText()
        let wasVisible = AppShell.shared.mainWindow?.isVisible == true
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = AppLanguage.localized("截图.png")
        panel.level = NSWindow.Level(rawValue: NSWindow.Level.screenSaver.rawValue + 2)
        panel.begin { [weak self] ret in
            var dismissed = false
            if ret == .OK, let url = panel.url, let self,
               let tiff = self.render().tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try? png.write(to: url)
                dismissed = true
                self.onDone?()
            }
            AppShell.shared.afterSystemPanel(mainWasVisible: wasVisible, overlayStillUp: !dismissed)
        }
    }

    private func render() -> NSImage {
        let size = image.size
        var rect = CGRect(origin: .zero, size: size)
        guard let cg = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return image }
        let width = cg.width
        let height = cg.height
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height,
                                       bitsPerComponent: 8, bytesPerRow: 0,
                                       space: colorSpace,
                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return image }

        let sx = size.width > 0 ? CGFloat(width) / size.width : 1
        let sy = size.height > 0 ? CGFloat(height) / size.height : 1
        context.interpolationQuality = .none
        // 底图和标注都在同一个 CGContext 中合成，避免 NSBitmapImageRep 的 point
        // 尺寸元数据再次参与布局，导致右侧/上方被裁掉。
        context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
        let nsContext = NSGraphicsContext(cgContext: context, flipped: false)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = nsContext
        context.saveGState()
        // marks 已经是原始 CGImage 像素坐标，不能再 scaleBy；否则矩形会
        // 被二次放大并从右侧/上方裁掉。倍率只用于线宽、文字和箭头大小。
        renderingScale = (sx + sy) / 2
        for mark in marks {
            switch mark {
            case .rect(let r, let ink):
                ink.color.nsColor.setStroke()
                let p = NSBezierPath(rect: r); p.lineWidth = ink.stroke; p.stroke()
            case .arrow(let a, let b, let ink):
                ink.color.nsColor.setStroke(); drawArrow(from: a, to: b, width: ink.stroke)
            case .pen(let pts, let ink):
                guard pts.count > 1 else { continue }
                ink.color.nsColor.setStroke()
                let p = NSBezierPath(); p.move(to: pts[0]); pts.dropFirst().forEach { p.line(to: $0) }
                p.lineWidth = ink.stroke; p.lineCapStyle = .round; p.lineJoinStyle = .round; p.stroke()
            case .mosaic(let r, let img):
                img?.draw(in: r, from: .zero, operation: .copy, fraction: 1)
            case .text(let r, let s, let ink):
                (s as NSString).draw(in: r, withAttributes: textAttrs(ink))
            }
        }
        renderingScale = 1
        context.restoreGState()
        NSGraphicsContext.restoreGraphicsState()
        guard let output = context.makeImage() else { return image }
        return NSImage(cgImage: output, size: size)
    }
}
