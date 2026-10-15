import ApplicationServices
import CoreGraphics
import Foundation
import os

/// 平滑算法：把一次性到达的滚动量摊到后续若干帧里发出（指数衰减）。
/// 纯值类型，不依赖系统 API，便于自测。
struct ScrollSmoother {
    /// 一档滚轮 ≈ 多少像素。触摸板的连续事件不走这里，只影响物理滚轮一档的位移。
    /// ponytail: 固定 16px/行，手感不对时改成读系统「滚动速度」偏好。
    static let pixelsPerLine = 16.0
    /// 衰减时间常数（秒）。越小越跟手、越大越顺滑。
    static let tau = 0.06

    private var residual = 0.0
    private var pending = 0.0

    var isIdle: Bool { residual == 0 }

    /// 吸收一次输入（单位：像素）
    mutating func absorb(_ delta: Double) {
        residual += delta
    }

    /// 走一帧，返回本帧应发出的像素（小数部分由事件定点字段承载）
    mutating func step(dt: Double = 1.0 / 120, tau: Double = ScrollSmoother.tau) -> Double {
        guard residual != 0 else { return 0 }
        // 收尾：剩下不足 1px 就一次给完，避免尾巴拖很久
        if abs(residual) < 0.5 {
            let flush = residual + pending
            residual = 0
            pending = 0
            return flush
        }
        let move = residual * (1 - exp(-dt / tau))
        residual -= move
        pending += move
        let emit = pending.rounded(.towardZero)
        pending -= emit
        return emit
    }
}

/// 滚轮事件拦截/改写。需要「辅助功能」权限；无权限时 start() 返回 false。
///
/// 线程模型：start/stop/update 在主线程调用；事件回调与平滑定时器跑在自己的线程上。
/// 配置存在锁里，回调线程直接读：早期版本用 CFRunLoopPerformBlock 把改动投递到 tap 线程，
/// 但 tap 线程空闲时 run loop 正在休眠，CFRunLoopWakeUp 有概率丢失，配置要等到下一个滚轮事件
/// 才生效——表现为「改了设置要滚一下才起作用」。加锁比唤醒 run loop 便宜也更准。
final class ScrollTap: @unchecked Sendable {
    struct Config: Equatable {
        var smooth = false
        var speed = 1.0
        var invertVertical = false
        var invertHorizontal = false
    }

    /// 自己合成的事件打上标记，避免被本 tap 再次处理形成死循环
    private static let marker: Int64 = 0x6D61_6371

    /// 合成事件专用的私有事件源。
    /// 关键：CGEventSource 默认带一个「本地事件压制间隔」（约 0.25s）——
    /// 从该源投递事件后，这段时间内的真实硬件输入会被压制。
    /// 平滑以 120Hz 连续投递，等于整段动画期间都压着鼠标，
    /// 表现就是「鼠标有阻力、不跟手，动画结束才好」。所以必须显式清零。
    private let source: CGEventSource? = {
        let source = CGEventSource(stateID: .privateState)
        source?.localEventsSuppressionInterval = 0
        return source
    }()

    /// 仅供探针/排障：合成事件源当前的压制间隔，应为 0
    var eventSourceSuppressionInterval: CFTimeInterval? { source?.localEventsSuppressionInterval }

    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var timer: Timer?
    private let configLock = OSAllocatedUnfairLock(initialState: Config())

    /// 当前配置（任意线程可读）
    var currentConfig: Config { configLock.withLock { $0 } }
    private var smootherY = ScrollSmoother()
    private var smootherX = ScrollSmoother()
    private var lastFlags: CGEventFlags = []
    private var lastLocation = CGPoint.zero

    var isRunning: Bool { tap != nil }

    // MARK: - 生命周期

    /// 建立事件 tap。返回 false 表示没有权限或创建失败。
    func start() -> Bool {
        guard tap == nil else { return true }
        guard AXIsProcessTrusted() else { return false }
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                return Unmanaged<ScrollTap>.fromOpaque(refcon).takeUnretainedValue()
                    .handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else { return false }

        tap = port
        let thread = Thread { [weak self] in self?.run(port) }
        thread.name = "macq.scrollTap"
        thread.qualityOfService = .userInteractive
        thread.start()
        return true
    }

    func stop() {
        guard let port = tap else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        tap = nil
        if let runLoop {
            CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { [weak self] in
                self?.timer?.invalidate()
                self?.timer = nil
                self?.smootherX = ScrollSmoother()
                self?.smootherY = ScrollSmoother()
            }
            CFRunLoopStop(runLoop)
            CFRunLoopWakeUp(runLoop)
            self.runLoop = nil
        }
    }

    /// 设置变更后调用；配置在线程内更新，避免和回调竞态。
    func update(_ new: Config) {
        configLock.withLock { $0 = new }
    }

    // MARK: - tap 线程

    private func run(_ port: CFMachPort) {
        let runLoop = CFRunLoopGetCurrent()
        self.runLoop = runLoop
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        CFRunLoopRun()
        CGEvent.tapEnable(tap: port, enable: false)
        CFRunLoopRemoveSource(runLoop, source, .commonModes)
    }

    // MARK: - 事件处理

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // 回调太慢被系统临时关闭时，重新打开（必要时丢当前事件）
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        guard type == .scrollWheel else { return Unmanaged.passUnretained(event) }
        if event.getIntegerValueField(.eventSourceUserData) == Self.marker {
            return Unmanaged.passUnretained(event)
        }

        let config = currentConfig
        let flags = event.flags
        // 缩放/缩放类用途（⌘、⌃ 组合）原样放行，改了就破坏语义
        if flags.contains(.maskCommand) || flags.contains(.maskControl) {
            return Unmanaged.passUnretained(event)
        }

        let continuous = event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0

        // 物理滚轮（离散）且开了平滑：吞掉原事件，改为逐帧发出连续事件
        if config.smooth && !continuous && !momentum {
            let linesY = lineDelta(event, .scrollWheelEventDeltaAxis1,
                                   .scrollWheelEventPointDeltaAxis1, .scrollWheelEventFixedPtDeltaAxis1)
            let linesX = lineDelta(event, .scrollWheelEventDeltaAxis2,
                                   .scrollWheelEventPointDeltaAxis2, .scrollWheelEventFixedPtDeltaAxis2)
            var scale = config.speed * ScrollSmoother.pixelsPerLine
            if config.invertVertical { scale = -scale }
            smootherY.absorb(linesY * scale)
            var scaleX = config.speed * ScrollSmoother.pixelsPerLine
            if config.invertHorizontal { scaleX = -scaleX }
            smootherX.absorb(linesX * scaleX)
            lastFlags = flags
            lastLocation = CGEvent(source: nil)?.location ?? lastLocation
            ensureTimer()
            return nil
        }

        // 其余情况原地改写增量（触摸板连续滚动、惯性滚动、关闭平滑时）
        return scale(event: event, config: config, continuous: continuous)
    }

    /// 离散事件的一档增量（行数）。行字段是权威值，为 0 时退回定点/像素字段。
    private func lineDelta(_ event: CGEvent, _ line: CGEventField,
                           _ point: CGEventField, _ fixed: CGEventField) -> Double {
        let lines = event.getIntegerValueField(line)
        if lines != 0 { return Double(lines) }
        let fixedValue = event.getDoubleValueField(fixed)
        if fixedValue != 0 { return fixedValue }
        return Double(event.getIntegerValueField(point))
    }

    /// 按速度和翻转方向改写事件的三套增量字段（行 / 像素 / 定点小数）。
    /// 注意：这三套字段是同一份状态的不同视图，写其中一个会影响另外两个，
    /// 所以必须先全部读出来再写，否则会重复叠加缩放。
    /// 翻转只对物理滚轮（离散咔哒）生效：连续事件来自触摸板 / Magic Mouse 表面，
    /// 它们的方向语义系统已定，不应被鼠标工具翻转。
    private func scale(event: CGEvent, config: Config, continuous: Bool) -> Unmanaged<CGEvent>? {
        let factorY = config.speed * (!continuous && config.invertVertical ? -1 : 1)
        let factorX = config.speed * (!continuous && config.invertHorizontal ? -1 : 1)
        for (line, point, fixed, factor) in [
            (CGEventField.scrollWheelEventDeltaAxis1, CGEventField.scrollWheelEventPointDeltaAxis1,
             CGEventField.scrollWheelEventFixedPtDeltaAxis1, factorY),
            (CGEventField.scrollWheelEventDeltaAxis2, CGEventField.scrollWheelEventPointDeltaAxis2,
             CGEventField.scrollWheelEventFixedPtDeltaAxis2, factorX),
        ] {
            guard factor != 1 else { continue }
            let lines = event.getIntegerValueField(line)
            let points = event.getIntegerValueField(point)
            let fixedValue = event.getDoubleValueField(fixed)
            if lines != 0 {
                event.setIntegerValueField(line, value: Int64((Double(lines) * factor).rounded()))
            }
            if points != 0 {
                event.setIntegerValueField(point, value: Int64((Double(points) * factor).rounded()))
            }
            if fixedValue != 0 {
                event.setDoubleValueField(fixed, value: fixedValue * factor)
            }
        }
        return Unmanaged.passUnretained(event)
    }

    // MARK: - 平滑输出

    private func ensureTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 120, repeats: true) { [weak self] _ in self?.tick() }
        timer.tolerance = 0
        RunLoop.current.add(timer, forMode: .common)
        self.timer = timer
    }

    private func tick() {
        let dy = smootherY.step()
        let dx = smootherX.step()
        if dy != 0 || dx != 0 {
            post(dx: dx, dy: dy)
        }
        if smootherX.isIdle && smootherY.isIdle {
            timer?.invalidate()
            timer = nil
        }
    }

    private func post(dx: Double, dy: Double) {
        guard let event = CGEvent(
            scrollWheelEvent2Source: source,
            units: .pixel,
            wheelCount: 2,
            wheel1: Int32(dy.rounded()),
            wheel2: Int32(dx.rounded()),
            wheel3: 0
        ) else { return }
        event.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(dy.rounded(.towardZero)))
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(dx.rounded(.towardZero)))
        // 定点字段承载小数，才能真正逐像素平滑
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: dy)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: dx)
        event.flags = lastFlags
        // 位置要取投递当刻的光标位置：动画尾巴期间用户可能在移动鼠标，
        // 沿用滚动开始时的旧位置会把事件持续送往旧位置。
        event.location = CGEvent(source: nil)?.location ?? lastLocation
        event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        event.post(tap: .cgSessionEventTap)
    }
}
