import AppKit
import ApplicationServices

// 验证魔法鼠标的滚轮管线：真实建立 CGEventTap，投递合成的离散滚轮事件（打上 TEST 标记做隔离），
// 在 annotated session 层观察最终流向 app 的事件，检查拦截/倍速/翻转/平滑是否成立。
// 需要终端（父进程）已有「辅助功能」权限，否则 tapCreate 会失败。

final class Counter {
    var marked = 0          // 引擎合成的事件（带 MARKER）
    var markedPixels = 0.0
    var mine = 0            // 我们投递的输入事件（带 TEST_MARKER）透传出来
    var mineDelta = 0.0
    var noise = 0           // 别的来源（真实鼠标/触摸板），测试期间应为 0
    var noiseDelta = 0.0
}

let MARKER: Int64 = 0x6D61_6371        // 与 ScrollTap.marker 一致
let TEST_MARKER: Int64 = 0x5445_5354   // 本探针投递的输入
let counter = Counter()
let refcon = Unmanaged.passUnretained(counter).toOpaque()
let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)

var observerPort: CFMachPort?   // 回调里要重新启用 tap，而 tap 自身还在构造中，故用顶层变量承接
let observer = CGEvent.tapCreate(
    tap: .cgAnnotatedSessionEventTap,
    place: .tailAppendEventTap,
    options: .listenOnly,
    eventsOfInterest: mask,
    callback: { _, type, event, userInfo in
        let c = Unmanaged<Counter>.fromOpaque(userInfo!).takeUnretainedValue()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            let why = type == .tapDisabledByTimeout ? "回调超时" : "用户输入"
            print("  ⚠︎ 观察者 tap 被系统临时关闭（\(why)），已重开")
            if let observerPort { CGEvent.tapEnable(tap: observerPort, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let tag = event.getIntegerValueField(.eventSourceUserData)
        let delta = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        switch tag {
        case MARKER:
            c.marked += 1
            c.markedPixels += delta
        case TEST_MARKER:
            c.mine += 1
            c.mineDelta = delta
        default:
            c.noise += 1
            c.noiseDelta = delta
        }
        return Unmanaged.passUnretained(event)
    },
    userInfo: refcon)

func postWheel(lines: Int64) {
    guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1,
                          wheel1: Int32(lines), wheel2: 0, wheel3: 0) else { return }
    e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 0)   // 离散（物理滚轮）
    e.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: lines)
    e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: Double(lines))
    e.setIntegerValueField(.eventSourceUserData, value: TEST_MARKER)
    e.post(tap: .cghidEventTap)
}

/// 模拟触摸板 / Magic Mouse 表面的连续滚动（像素增量、isContinuous=1）
func postContinuous(points: Double) {
    guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1,
                          wheel1: Int32(points), wheel2: 0, wheel3: 0) else { return }
    e.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
    e.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: points)
    e.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(points))
    e.setIntegerValueField(.eventSourceUserData, value: TEST_MARKER)
    e.post(tap: .cghidEventTap)
}

func spin(_ seconds: Double) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

func reset() {
    counter.marked = 0; counter.markedPixels = 0
    counter.mine = 0; counter.mineDelta = 0
    counter.noise = 0; counter.noiseDelta = 0
}

print("辅助功能权限 = \(AXIsProcessTrusted())")
if let observer {
    CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, observer, 0), .commonModes)
    CGEvent.tapEnable(tap: observer, enable: true)
    observerPort = observer
} else {
    print("✗ 建立观察者 tap 失败（缺辅助功能权限）")
}

// 0) 平滑算法本身（纯逻辑，与系统无关）
var smoother = ScrollSmoother()
smoother.absorb(16)
var total = 0.0, frames = 0
while !smoother.isIdle && frames < 600 { total += smoother.step(); frames += 1 }
check(abs(total - 16) < 0.01 && frames < 60,
      "平滑算法：16px → \(frames) 帧共 \(String(format: "%.2f", total))px（约 \(Int(Double(frames) / 120 * 1000))ms）")

// 1) 真实事件 tap 管线
let tap = ScrollTap()
defer { tap.stop() }
tap.update(ScrollTap.Config(smooth: false, speed: 1, invertVertical: false, invertHorizontal: false))
print("建立事件 tap = \(tap.start())")
guard tap.isRunning else { print("✗ 事件 tap 未建立，后续管线检查跳过"); exit(0) }

// 事件源压制：CGEventSource 默认会压制一小段真实硬件输入，
// 平滑以 120Hz 连续投递时等于整段动画都压着鼠标（表现为「鼠标有阻力、不跟手」）。
let bare = CGEventSource(stateID: .privateState)
print("  ℹ︎ 默认私有事件源的本地输入压制间隔 = \(bare?.localEventsSuppressionInterval ?? -1)s")
check(tap.eventSourceSuppressionInterval == 0,
      "合成事件源的压制间隔已清零（实际 \(tap.eventSourceSuppressionInterval.map { "\($0)s" } ?? "无事件源")）")
spin(0.3)

func measure(_ label: String, expect: (Int, Double)?) {
    reset()
    postWheel(lines: 3)
    spin(0.35)
    report(label, expect: expect)
}

func measureContinuous(_ label: String, points: Double, expect: (Int, Double)?) {
    reset()
    postContinuous(points: points)
    spin(0.35)
    report(label, expect: expect)
}

func report(_ label: String, expect: (Int, Double)?) {
    let interference = counter.noise
    if interference > 0 {
        print("  ⚠︎ 测试期间检测到 \(interference) 个外部滚轮事件（\(counter.noiseDelta)px），结果可能被污染")
    }
    guard let expect else { return }
    let pass = counter.mine == expect.0 && abs(counter.mineDelta - expect.1) < 0.001
    check(pass,
          "\(label)：透传 \(counter.mine) 个事件，增量 \(counter.mineDelta)（期望 \(expect.1)）"
          + (pass ? "" : "  [诊断 引擎合成=\(counter.marked)/\(counter.markedPixels)px 未标记=\(counter.noise)/\(counter.noiseDelta)px]"))
}

/// 等到一个没有任何外部滚轮事件的窗口（真实设备动一下就会污染测量）
func waitQuiet(_ label: String, tries: Int = 8) -> Bool {
    for _ in 0..<tries {
        reset()
        spin(0.4)
        if counter.noise == 0 && counter.marked == 0 { return true }
    }
    print("  ⚠︎ \(label)：等不到安静的输入窗口，跳过本次测量")
    return false
}

measure("非平滑", expect: (1, 3))

tap.update(ScrollTap.Config(smooth: false, speed: 2, invertVertical: false, invertHorizontal: false))
spin(0.2)
measure("倍速 2x", expect: (1, 6))

tap.update(ScrollTap.Config(smooth: false, speed: 1, invertVertical: true, invertHorizontal: false))
spin(0.2)
measure("垂直翻转", expect: (1, -3))

// 翻转只对物理滚轮（离散）生效；连续事件（触摸板 / Magic Mouse）方向不变
measureContinuous("连续滚动（触摸板）不被翻转", points: 3, expect: (1, 3))
tap.update(ScrollTap.Config(smooth: false, speed: 2, invertVertical: true, invertHorizontal: false))
spin(0.2)
measureContinuous("连续滚动仍受倍速（速度照旧作用于触摸板）", points: 3, expect: (1, 6))
tap.update(ScrollTap.Config(smooth: false, speed: 1, invertVertical: true, invertHorizontal: false))
spin(0.2)
measureContinuous("连续滚动 ×1 速度", points: 3, expect: (1, 3))

tap.update(ScrollTap.Config(smooth: true, speed: 1, invertVertical: false, invertHorizontal: false))
spin(0.3)

// 平滑测量要等干净窗口：外部输入会被吸进平滑器，把总量算歪
var smooth: (events: Int, pixels: Double, swallowed: Bool)?
for attempt in 1...6 {
    guard waitQuiet("平滑") else { break }
    reset()
    postWheel(lines: 3)
    spin(0.8)
    if counter.noise > 0 {
        print("  ⚠︎ 平滑测量第 \(attempt) 次被外部输入打断（\(counter.noise) 个），重试")
        continue
    }
    smooth = (counter.marked, counter.markedPixels, counter.mine == 0)
    break
}

if let smooth {
    check(smooth.swallowed,
          "平滑：原始离散事件被吞掉，不重复滚动")
    check(smooth.events >= 10 && smooth.pixels >= 46 && smooth.pixels <= 52,
          "平滑：3 档摊成 \(smooth.events) 个连续事件、共 \(String(format: "%.1f", smooth.pixels))px（期望 ≈48px）")
} else {
    print("  ﹖ 平滑测量未能在无外部输入干扰下完成（不是代码问题）")
}

tap.stop()
check(!tap.isRunning, "stop() 后引擎停止")

// 停/启一轮之后引擎必须还能用。
// 这里查的是 stop() 里那个 CFRunLoopPerformBlock 的清理块有没有真的跑到：
// 跑不到的话 timer 会留在非 nil 状态，重新 start() 后 ensureTimer() 就不再建计时器，
// 结果「输入被吞掉、但一个合成事件都不发」——用户看到的是滚动彻底失灵。
if tap.start() {
    tap.update(ScrollTap.Config(smooth: true, speed: 1, invertVertical: false, invertHorizontal: false))
    spin(0.3)
    if waitQuiet("停/启后平滑") {
        reset()
        postWheel(lines: 3)
        spin(0.8)
        check(counter.marked >= 10 && abs(counter.markedPixels - 48) <= 2,
              "stop() → start() 后平滑仍工作（合成 \(counter.marked) 个事件、\(String(format: "%.1f", counter.markedPixels))px，期望 ≈48px）")
    }
    tap.stop()
}
