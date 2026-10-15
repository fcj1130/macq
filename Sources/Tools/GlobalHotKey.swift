import AppKit
import Carbon.HIToolbox

/// 全局快捷键组合。展示文本在录制时直接从键盘事件取，省掉自己维护键码 → 字符映射。
struct KeyCombo: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    var display: String

    /// 默认 ⌥⌘V
    static let `default` = KeyCombo(keyCode: UInt32(kVK_ANSI_V),
                                    carbonModifiers: UInt32(optionKey | cmdKey),
                                    display: "⌥⌘V")

    /// 从键盘事件构造；必须带 ⌘/⌃/⌥ 之一，否则会全局吃掉普通按键
    init(keyCode: UInt32, carbonModifiers: UInt32, display: String) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        self.display = display
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.contains(.command) || flags.contains(.control) || flags.contains(.option) else { return nil }
        guard !event.modifierFlags.contains(.function), !event.modifierFlags.contains(.capsLock) else { return nil }
        let characters = (event.charactersIgnoringModifiers ?? "").uppercased()
        guard !characters.isEmpty else { return nil }

        var display = ""
        if flags.contains(.control) { display += "⌃" }
        if flags.contains(.option) { display += "⌥" }
        if flags.contains(.shift) { display += "⇧" }
        if flags.contains(.command) { display += "⌘" }
        self.init(keyCode: UInt32(event.keyCode), carbonModifiers: flags.carbonModifiers, display: display + characters)
    }
}

/// 可双击的修饰键
enum ModifierTap: String, Codable, CaseIterable {
    case option, command, control, shift

    var symbol: String {
        switch self {
        case .option: "⌥"
        case .command: "⌘"
        case .control: "⌃"
        case .shift: "⇧"
        }
    }

    var title: String { String(format: AppLanguage.localized("双击 %@"), symbol) }

    var flag: CGEventFlags {
        switch self {
        case .option: .maskAlternate
        case .command: .maskCommand
        case .control: .maskControl
        case .shift: .maskShift
        }
    }

    var nsFlag: NSEvent.ModifierFlags {
        switch self {
        case .option: .option
        case .command: .command
        case .control: .control
        case .shift: .shift
        }
    }
}

/// 唤起方式：组合键，或双击某个修饰键
enum HotKeyTrigger: Codable, Equatable {
    case combo(KeyCombo)
    case doubleTap(ModifierTap)

    /// 默认双击 ⌥（不占用任何按键组合，配合固定组合键也可任意改）
    static let `default` = HotKeyTrigger.doubleTap(.option)

    var display: String {
        switch self {
        case .combo(let combo): combo.display
        case .doubleTap(let modifier): modifier.title
        }
    }

    /// 双击修饰键需要 CGEvent tap（辅助功能 / 输入监控），组合键走 Carbon 不需要权限
    var needsEventTap: Bool {
        if case .doubleTap = self { return true }
        return false
    }

    var modifier: ModifierTap? {
        if case .doubleTap(let modifier) = self { return modifier }
        return nil
    }
}

/// 双击修饰键的判定：先「按下→松开」，再在 interval 内「按下」就算双击。
/// 运行时的事件监听和设置页录制共用这一套逻辑。
struct DoubleTapTracker {
    var interval: TimeInterval = 0.35
    private var down: Set<ModifierTap> = []
    /// 参与过「多修饰键同按」的修饰键：它随后的松开不算一次干净的单击（不然 ⌥⌘ 组合会误触发）
    private var chorded: Set<ModifierTap> = []
    private var lastRelease: (modifier: ModifierTap, at: TimeInterval)?

    /// 喂入当前按下的修饰键集合，返回是否构成双击
    mutating func update(down current: Set<ModifierTap>, at time: TimeInterval) -> Bool {
        let previous = down
        down = current
        defer { chorded.formIntersection(current) }   // 只记住还按着的修饰键

        // 同时按了多个修饰键（⌥⌘ 之类）不参与判定，免得正常组合键误触发
        if current.count > 1 {
            chorded.formUnion(current)
            lastRelease = nil
            return false
        }

        if let modifier = current.first {
            guard !previous.contains(modifier) else { return false }
            let fired = lastRelease.map { $0.modifier == modifier && time - $0.at <= interval } ?? false
            lastRelease = nil
            return fired
        }

        // 全部松开：记下时间，等下一次按下（刚从组合键里松开的除外）
        if previous.count == 1, let released = previous.first, !chorded.contains(released) {
            lastRelease = (released, time)
        }
        return false
    }

    mutating func reset() {
        down = []
        chorded = []
        lastRelease = nil
    }
}

/// 双击修饰键的全局监听（`.listenOnly`，不改写、不吞事件）。
///
/// 修饰键自身不产生 `keyDown`，只能靠 `flagsChanged`——这需要辅助功能/输入监控权限。
@MainActor
final class ModifierDoubleTapMonitor {
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var tracker = DoubleTapTracker()
    /// 被配置的那个修饰键：只有它的双击才触发
    private var modifier: ModifierTap?

    var onFire: (() -> Void)?
    private(set) var running = false

    @discardableResult
    func start(_ modifier: ModifierTap) -> Bool {
        stop()
        tracker.reset()
        self.modifier = modifier
        let mask = CGEventMask(1 << CGEventType.flagsChanged.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let monitor = Unmanaged<ModifierDoubleTapMonitor>.fromOpaque(refcon).takeUnretainedValue()
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
                    MainActor.assumeIsolated { monitor.reenable() }
                    return Unmanaged.passUnretained(event)
                }
                let flags = event.flags
                MainActor.assumeIsolated { monitor.handle(flags: flags) }
                return Unmanaged.passUnretained(event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        self.tap = tap
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        running = true
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        if let tap { CFMachPortInvalidate(tap) }
        tap = nil
        source = nil
        modifier = nil
        running = false
    }

    private func reenable() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
    }

    private func handle(flags: CGEventFlags) {
        let current = Set(ModifierTap.allCases.filter { flags.contains($0.flag) })
        // tracker 只判定「同一个修饰键在间隔内按了两次」，不认是哪一个：
        // 这里必须再确认就是被配置的那个键，否则双击 ⌘/⌃/⇧ 也会误触发（曾是实际 bug）
        guard tracker.update(down: current, at: ProcessInfo.processInfo.systemUptime),
              let modifier, current.contains(modifier)
        else { return }
        onFire?()
    }
}

extension NSEvent.ModifierFlags {
    /// 转成 Carbon 修饰符（RegisterEventHotKey 用）
    var carbonModifiers: UInt32 {
        var result: UInt32 = 0
        if contains(.command) { result |= UInt32(cmdKey) }
        if contains(.option) { result |= UInt32(optionKey) }
        if contains(.control) { result |= UInt32(controlKey) }
        if contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }
}

/// 全局快捷键。
///
/// 用 Carbon 的 `RegisterEventHotKey` —— 这是 macOS 上唯一**不需要辅助功能/输入监控权限**的
/// 全局热键方案（`NSEvent` 全局监听和 CGEvent 都需要授权）。
@MainActor
final class GlobalHotKey {
    private static let signature: OSType = 0x6D61_6371   // 'macq'
    private static var nextID: UInt32 = 1

    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private var registered: KeyCombo?
    /// 每个实例一个 id。以前全是 1：Carbon 任意热键按下会通知所有 handler，
    /// 于是按工具箱快捷键也会把截图拉起来。
    let id: UInt32

    /// 触发动作（工具实例构造完后再挂上）
    var onFire: (() -> Void)?

    init() {
        id = Self.nextID
        Self.nextID += 1
        installHandler()
    }

    var current: KeyCombo? { registered }

    @discardableResult
    func register(_ combo: KeyCombo?) -> Bool {
        unregister()
        guard let combo else { return true }
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(combo.keyCode, combo.carbonModifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        hotKeyRef = ref
        registered = combo
        return true
    }

    func unregister() {
        if let hotKeyRef { UnregisterEventHotKey(hotKeyRef) }
        hotKeyRef = nil
        registered = nil
    }

    private func installHandler() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, refcon in
            guard let refcon else { return OSStatus(eventNotHandledErr) }
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(refcon).takeUnretainedValue()
            var hkID = EventHotKeyID()
            let status = GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hkID
            )
            guard status == noErr, hkID.id == hotKey.id else { return OSStatus(eventNotHandledErr) }
            MainActor.assumeIsolated { hotKey.performAction() }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handlerRef)
    }

    /// 由 Carbon 回调触发（探针也用它验证接线，不必依赖合成按键）
    func performAction() { onFire?() }
}

/// 设置页里录制快捷键：截获下一个按键组合，或者双击某个修饰键（只在 app 活动时生效）
@MainActor
@Observable
final class HotKeyRecorder {
    private(set) var isRecording = false
    private var monitor: Any?
    private var tracker = DoubleTapTracker()

    func start(onRecord: @escaping (HotKeyTrigger) -> Void) {
        if isRecording { stop(); return }
        isRecording = true
        tracker.reset()
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            // NSEvent 不是 Sendable：先在这里取好需要的值，再进 MainActor（键码/字符/标志位都是值类型）
            if event.type == .flagsChanged {
                let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                let current = Set(ModifierTap.allCases.filter { flags.contains($0.nsFlag) })
                let now = ProcessInfo.processInfo.systemUptime
                let trigger: HotKeyTrigger? = MainActor.assumeIsolated {
                    guard self.tracker.update(down: current, at: now), let modifier = current.first else { return nil }
                    return .doubleTap(modifier)
                }
                MainActor.assumeIsolated {
                    if let trigger {
                        self.stop()
                        onRecord(trigger)
                    }
                }
                return nil
            }

            if event.keyCode == UInt16(kVK_Escape) {
                MainActor.assumeIsolated { self.stop() }
                return nil
            }
            guard let combo = KeyCombo(event: event) else {
                NSSound.beep()   // 必须带 ⌘/⌃/⌥（双击修饰键走 flagsChanged 分支）
                return nil
            }
            MainActor.assumeIsolated {
                self.stop()
                onRecord(.combo(combo))
            }
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        tracker.reset()
        isRecording = false
    }
}
