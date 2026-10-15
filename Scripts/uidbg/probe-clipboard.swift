// 魔法剪贴板探针：存储逻辑 + 真实剪贴板端到端 + 快捷键解析
// 跑法：./Scripts/uidbg/probe.sh Scripts/uidbg/probe-clipboard.swift
// 注意：会临时改写系统剪贴板，结束时恢复原内容（probe.sh 会先停掉运行中的 macq，避免污染真实历史）
import AppKit
import Carbon.HIToolbox
import ImageIO
import UniformTypeIdentifiers

var passed = 0
var failed = 0

@MainActor
func expect(_ condition: Bool, _ label: String, _ detail: String = "") {
    if condition {
        passed += 1
        print("  ✓ \(label)\(detail.isEmpty ? "" : "：\(detail)")")
    } else {
        failed += 1
        print("  ✗ \(label)\(detail.isEmpty ? "" : "：\(detail)")")
    }
}

@MainActor
func settle(_ seconds: TimeInterval) {
    RunLoop.current.run(until: Date().addingTimeInterval(seconds))
}

let probeBase = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("macq-clip-probe-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: probeBase) }

@MainActor
func makePayload(_ store: ClipboardStore, kind: ClipKind, bytes: Int) -> String {
    let name = "\(UUID().uuidString).bin"
    try? Data(repeating: 0x41, count: bytes).write(to: store.root.appendingPathComponent(name))
    return name
}

@MainActor
func makeItem(_ store: ClipboardStore, kind: ClipKind, text: String, bytes: Int, usedAt: Date) -> ClipItem {
    ClipItem(id: UUID(), kind: kind, usedAt: usedAt, size: bytes,
             characters: kind == .text ? text.count : 0,
             preview: text, searchText: text,
             payload: makePayload(store, kind: kind, bytes: bytes),
             paths: [], pasteboardType: UTType.data.identifier,
             fingerprint: "fp-\(text)-\(bytes)")
}

@MainActor
func makeFileItem(_ store: ClipboardStore, name: String, kind: ClipKind, bytes: Int, usedAt: Date) -> ClipItem {
    ClipItem(id: UUID(), kind: kind, usedAt: usedAt, size: bytes, characters: 0,
             preview: name, searchText: name, payload: nil,
             paths: ["/tmp/\(name)"], pasteboardType: nil,
             fingerprint: "file-\(name)-\(bytes)")
}

func makePNG(width: Int, height: Int) -> Data? {
    guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.setFillColor(CGColor(red: 0.2, green: 0.6, blue: 0.9, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let image = context.makeImage() else { return nil }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { return nil }
    return data as Data
}

let bigLimit = 1024 * 1024 * 1024

/// 顶层语句在 swiftc 默认语言模式下不是 MainActor 隔离的，统一裹一层（探针本来就跑在主线程）
@MainActor
func runProbe() {
// ── 1. 存储逻辑 ───────────────────────────────────────────────
print("── 存储逻辑")
let store = ClipboardStore(root: probeBase.appendingPathComponent("store"))
let now = Date()
let old = makeItem(store, kind: .text, text: "苹果 apple", bytes: 100, usedAt: now.addingTimeInterval(-300))
let big = makeItem(store, kind: .image, text: "图片", bytes: 1024 * 1024, usedAt: now.addingTimeInterval(-200))
let fresh = makeItem(store, kind: .text, text: "香蕉 Banana", bytes: 50, usedAt: now.addingTimeInterval(-100))
let reference = makeFileItem(store, name: "视频.mov", kind: .video, bytes: 5_000_000_000, usedAt: now.addingTimeInterval(-250))
for item in [old, big, fresh, reference] {
    store.insert(item, maxBytes: bigLimit, retention: .forever)
}
expect(store.items.count == 4, "插入 4 条", "共 \(store.items.count) 条")
expect(store.items.first?.id == fresh.id, "列表按时间倒序", "首条 = 最新的文本")
expect(store.storedBytes == 100 + 1024 * 1024 + 50, "占用只算落盘载荷", "\(store.storedBytes) 字节（不含 5GB 文件引用）")

// 去重：同内容再次复制 → 不新增，时间刷新并置顶
var repeated = old
repeated.usedAt = Date()
store.insert(repeated, maxBytes: bigLimit, retention: .forever)
expect(store.items.count == 4, "重复内容不新增条目", "仍 \(store.items.count) 条")
expect(store.items.first?.id == old.id, "重复内容置顶为最新")

// 查询
expect(store.query(kind: .text).count == 2, "按类型过滤", "文本 2 条")
expect(store.query(text: "apple").count == 1, "关键字搜索（小写）")
expect(store.query(text: "APPLE").count == 1, "关键字搜索（大写，大小写不敏感）")
expect(store.query(kind: .text, text: "banana").count == 1, "类型 + 关键字组合")
expect(store.query(text: "不存在的词").isEmpty, "无命中返回空")
expect(store.query(limit: 2).count == 2, "limit 分页")

// 占用上限：超限从最旧开始删，且文件引用不受牵连
let bigPayloadURL = store.root.appendingPathComponent(big.payload!)
store.enforce(maxBytes: 200_000, retention: .forever)
expect(!store.items.contains { $0.id == big.id }, "超占用上限后删除最旧的落盘条目")
expect(!FileManager.default.fileExists(atPath: bigPayloadURL.path), "被删条目的载荷文件也清理了")
expect(store.items.contains { $0.id == reference.id }, "文件/视频引用不受占用上限牵连")

// 保留期：按 usedAt 淘汰
let ancient = makeItem(store, kind: .text, text: "十天前", bytes: 10, usedAt: Date().addingTimeInterval(-10 * 86400))
store.insert(ancient, maxBytes: bigLimit, retention: .forever)
store.enforce(maxBytes: bigLimit, retention: .week)
expect(!store.items.contains { $0.id == ancient.id }, "超过保留期（1 周）的记录被删除")
expect(store.items.contains { $0.id == fresh.id }, "保留期内的记录保留")
store.enforce(maxBytes: bigLimit, retention: .forever)
expect(store.items.count == 3, "保留期设为无限制时不按时间淘汰", "\(store.items.count) 条")

// 持久化：flush 后重新加载同一目录，索引与磁盘一致
let orphan = store.root.appendingPathComponent("orphan-\(UUID().uuidString).bin")
try? Data(repeating: 0x42, count: 16).write(to: orphan)
store.flush()
let reloaded = ClipboardStore(root: store.root)
expect(reloaded.items.count == store.items.count, "重新加载后条目数一致", "\(reloaded.items.count) 条")
expect(reloaded.items.first?.id == store.items.first?.id, "重新加载后顺序一致")
expect(!FileManager.default.fileExists(atPath: orphan.path), "重新加载时清理孤儿载荷")

// ── 1.5 索引格式：带版本号 + 容错解码 ─────────────────────────────
// 目的：以后给 ClipItem 加字段、或结构变化时，旧索引不能让历史被清空
print("── 索引格式与兼容")
let idxURL = store.root.appendingPathComponent("index.json")
if let raw = try? Data(contentsOf: idxURL),
   let obj = try? JSONSerialization.jsonObject(with: raw) as? [String: Any] {
    expect(obj["version"] as? Int == ClipboardStore.indexVersion,
           "索引带版本号", "version=\(obj["version"] ?? "nil") 期望 \(ClipboardStore.indexVersion)")
    expect(obj["items"] is [Any], "索引条目在 items 下")
} else {
    expect(false, "索引是带版本的对象", "读不到 index.json 或不是对象")
}

// 旧版格式（裸数组）仍能读
func loadItems(_ json: String, label: String) -> [ClipItem] {
    let dir = probeBase.appendingPathComponent("idx-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try? Data(json.utf8).write(to: dir.appendingPathComponent("index.json"))
    return ClipboardStore(root: dir).items
}
let oneItem: [String: Any] = [
    "id": UUID().uuidString, "kind": "text", "usedAt": "2024-01-01T00:00:00Z",
    "size": 11, "characters": 11, "preview": "你好", "searchText": "你好",
    "paths": [String](), "fingerprint": "abc",
]
let bareJSON = String(data: try! JSONSerialization.data(withJSONObject: [oneItem]), encoding: .utf8)!
expect(loadItems(bareJSON, label: "裸数组").count == 1, "兼容旧版裸数组索引")

// 缺字段（未来新增字段的反向情形）不应导致整份索引被丢
var missing = oneItem
missing.removeValue(forKey: "characters")
missing.removeValue(forKey: "searchText")
let missingJSON = String(data: try! JSONSerialization.data(withJSONObject: ["version": 1, "items": [missing]]), encoding: .utf8)!
let tolerant = loadItems(missingJSON, label: "缺字段")
expect(tolerant.count == 1, "缺字段仍能解出条目", "\(tolerant.count) 条")
expect(tolerant.first?.characters == 0, "缺字段用默认值", "characters=\(tolerant.first?.characters ?? -1)")
expect(tolerant.first?.searchText == "你好", "缺 searchText 时回退到 preview")

// 多出未知字段（配置/数据缩减的反向情形）也不应为难
var extra = oneItem
extra["futureField"] = "whatever"
let extraJSON = String(data: try! JSONSerialization.data(withJSONObject: ["version": 1, "items": [extra]]), encoding: .utf8)!
expect(loadItems(extraJSON, label: "未知字段").count == 1, "未知字段被忽略而不是报错")
expect(loadItems("这不是 json", label: "损坏").isEmpty, "真正损坏时从空历史开始")

// ── 2. 真实剪贴板端到端 ───────────────────────────────────────
print("── 真实剪贴板")
let pasteboard = NSPasteboard.general
// 快照当前剪贴板（按类型存原始数据；NSPasteboardItem 不支持 copy()）
var backupData: [NSPasteboard.PasteboardType: Data] = [:]
for type in pasteboard.types ?? [] {
    if let data = pasteboard.data(forType: type) { backupData[type] = data }
}

let liveStore = ClipboardStore(root: probeBase.appendingPathComponent("live"))
let monitor = ClipboardMonitor(store: liveStore)
monitor.limits = { (bigLimit, .forever) }
monitor.start()

// 文本
pasteboard.clearContents()
pasteboard.setString("hello macq 剪贴板", forType: .string)
settle(0.6)
let textItem = liveStore.items.first
let sampleText = "hello macq 剪贴板"
expect(textItem?.kind == .text, "捕获文本", textItem.map { "kind=\($0.kind.rawValue)" } ?? "无")
expect(textItem?.characters == sampleText.count, "文本长度", "\(textItem?.characters ?? -1) 字")
expect(textItem?.size == Data(sampleText.utf8).count, "文本大小按 UTF-8 字节", "\(textItem?.size ?? -1) 字节")
expect(textItem?.preview == sampleText, "文本预览", textItem?.preview ?? "无")
expect(textItem.flatMap { liveStore.payloadURL($0) }.map { FileManager.default.fileExists(atPath: $0.path) } == true,
      "文本载荷已落盘")

// 图片
let png = makePNG(width: 32, height: 16)!
pasteboard.clearContents()
pasteboard.setData(png, forType: .png)
settle(0.6)
let imageItem = liveStore.items.first
expect(imageItem?.kind == .image, "捕获图片", imageItem.map { "kind=\($0.kind.rawValue)" } ?? "无")
expect(imageItem?.preview == "32 × 16", "图片尺寸识别", imageItem?.preview ?? "无")
expect(imageItem?.size == png.count, "图片大小", "\(imageItem?.size ?? -1) 字节")

// 普通文件
let textFile = probeBase.appendingPathComponent("记录.txt")
try? Data("file body".utf8).write(to: textFile)
pasteboard.clearContents()
pasteboard.writeObjects([textFile as NSURL])
settle(0.6)
let fileItem = liveStore.items.first
expect(fileItem?.kind == .file, "捕获文件", fileItem.map { "kind=\($0.kind.rawValue)" } ?? "无")
expect(fileItem?.paths == [textFile.path], "文件记录路径引用", fileItem?.paths.first ?? "无")
expect(fileItem?.payload == nil, "文件不复制内容", "payload=\(fileItem?.payload ?? "nil")")
expect(fileItem?.size == 9, "文件大小取引用文件大小", "\(fileItem?.size ?? -1) 字节")

// 视频文件（按扩展名归类）
let videoFile = probeBase.appendingPathComponent("片段.mov")
try? Data(repeating: 0, count: 32).write(to: videoFile)
pasteboard.clearContents()
pasteboard.writeObjects([videoFile as NSURL])
settle(0.6)
expect(liveStore.items.first?.kind == .video, "视频文件归类为视频", liveStore.items.first.map { "kind=\($0.kind.rawValue)" } ?? "无")

// 密码管理器标记的剪贴板不记录
let before = liveStore.items.count
pasteboard.clearContents()
pasteboard.declareTypes([.string, NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")], owner: nil)
pasteboard.setString("super-secret", forType: .string)
settle(0.6)
expect(liveStore.items.count == before, "机密标记的剪贴板不记录", "\(before) → \(liveStore.items.count) 条")

// 复用：写回剪贴板 + 刷新时间为最新 + 不产生新条目
guard let reuseTarget = liveStore.items.first(where: { $0.kind == .text }) else {
    print("  ✗ 复用测试缺少文本条目")
    exit(1)
}
let countBeforeReuse = liveStore.items.count
let stampBeforeReuse = reuseTarget.usedAt
pasteboard.clearContents()
let reused = monitor.reuse(reuseTarget)
settle(0.6)
expect(reused, "复用写回成功")
expect(pasteboard.string(forType: .string) == sampleText, "剪贴板内容已恢复",
      pasteboard.string(forType: .string) ?? "nil")
expect(liveStore.items.first?.id == reuseTarget.id, "复用后该条置顶为最新")
expect((liveStore.items.first?.usedAt ?? .distantPast) >= stampBeforeReuse, "复用刷新了时间")
expect(liveStore.items.count == countBeforeReuse, "复用不产生新条目", "\(liveStore.items.count) 条")

// 图片复用
if let imageItemNow = liveStore.items.first(where: { $0.kind == .image }) {
    pasteboard.clearContents()
    _ = monitor.reuse(imageItemNow)
    settle(0.3)
    expect(pasteboard.data(forType: .png)?.count == png.count, "图片复用写回相同字节")
}

monitor.stop()
expect(!monitor.isRunning, "停止监听")

pasteboard.clearContents()
if !backupData.isEmpty {
    pasteboard.declareTypes(Array(backupData.keys), owner: nil)
    for (type, data) in backupData { pasteboard.setData(data, forType: type) }
}
print("  ℹ︎ 已恢复探针开始前的剪贴板内容（\(backupData.count) 个类型）")

// ── 3. 快捷键 ────────────────────────────────────────────────
print("── 快捷键")
let flagEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.option, .command],
                                 timestamp: 0, windowNumber: 0, context: nil,
                                 characters: "v", charactersIgnoringModifiers: "v",
                                 isARepeat: false, keyCode: UInt16(kVK_ANSI_V))
let parsed = flagEvent.flatMap { KeyCombo(event: $0) }
expect(parsed?.display == "⌥⌘V", "解析 ⌥⌘V", parsed?.display ?? "nil")
expect(parsed?.carbonModifiers == UInt32(optionKey | cmdKey), "转成 Carbon 修饰符", "\(parsed?.carbonModifiers ?? 0)")

let plainEvent = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                  timestamp: 0, windowNumber: 0, context: nil,
                                  characters: "v", charactersIgnoringModifiers: "v",
                                  isARepeat: false, keyCode: UInt16(kVK_ANSI_V))
expect(plainEvent.flatMap { KeyCombo(event: $0) } == nil, "无 ⌘/⌃/⌥ 的组合被拒绝")

let hotKey = GlobalHotKey()
let hotKeyB = GlobalHotKey()
expect(hotKey.id != hotKeyB.id, "两个热键实例 id 不同", "\(hotKey.id) vs \(hotKeyB.id)")
var fired = 0
var firedB = 0
hotKey.onFire = { fired += 1 }
hotKeyB.onFire = { firedB += 1 }
let registered = hotKey.register(.default)
expect(registered, "注册全局快捷键 ⌥⌘V", registered ? "成功" : "失败（可能被其它 app 占用）")

hotKey.performAction()
expect(fired == 1, "回调接线正确", "触发 \(fired) 次")
expect(firedB == 0, "A 触发不影响 B")
hotKey.unregister()
expect(fired == 1, "注销后不再有注册的快捷键")

// 合成按键能否触发 Carbon 热键（信息性：真实触发请用 app 内的日志验证）
hotKey.onFire = { fired += 1 }
_ = hotKey.register(.default)
let source = CGEventSource(stateID: .privateState)
if let down = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: true),
   let up = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(kVK_ANSI_V), keyDown: false) {
    down.flags = [.maskCommand, .maskAlternate]
    up.flags = [.maskCommand, .maskAlternate]
    down.post(tap: .cghidEventTap)
    up.post(tap: .cghidEventTap)
    settle(0.5)
    print("  ℹ︎ 合成按键触发 Carbon 热键：\(fired > 1 ? "是" : "否")（命令行进程可能不派发 Carbon 事件，以 app 运行日志为准）")
}
hotKey.unregister()

// ── 双击修饰键 ─────────────────────────────────────────────
print("── 双击修饰键")
expect(HotKeyTrigger.default.display == "双击 ⌥", "默认唤起方式是双击 ⌥", HotKeyTrigger.default.display)
expect(HotKeyTrigger.combo(.default).display == "⌥⌘V", "组合键展示", HotKeyTrigger.combo(.default).display)
let triggerRoundTrip = (try? JSONEncoder().encode(HotKeyTrigger.combo(.default)))
    .flatMap { try? JSONDecoder().decode(HotKeyTrigger.self, from: $0) }
expect(triggerRoundTrip == .combo(.default), "唤起方式可持久化")
expect(HotKeyTrigger.combo(.default).needsEventTap == false, "组合键不需要事件 tap")
expect(HotKeyTrigger.default.needsEventTap, "双击修饰键需要事件 tap")
expect(ModifierTap.option.symbol == "⌥" && ModifierTap.allCases.count == 4, "四种修饰键", ModifierTap.allCases.map(\.symbol).joined())

// 纯逻辑：先「按下→松开」，再在窗口内「按下」即触发
var tracker = DoubleTapTracker()
expect(tracker.update(down: [.option], at: 0) == false, "第一次按下不触发")
expect(tracker.update(down: [], at: 0.05) == false, "第一次松开不触发")
expect(tracker.update(down: [.option], at: 0.2), "窗口内第二次按下触发")
expect(tracker.update(down: [], at: 0.3) == false, "触发后回到待命")
var slow = DoubleTapTracker()
_ = slow.update(down: [.option], at: 0); _ = slow.update(down: [], at: 0.05)
expect(slow.update(down: [.option], at: 0.5) == false, "超过 350ms 不触发", "间隔 450ms")
var chord = DoubleTapTracker()
_ = chord.update(down: [.option], at: 0)          // ⌥ 按下
_ = chord.update(down: [.option, .command], at: 0.05)   // 加按 ⌘ → 组合键
_ = chord.update(down: [.option], at: 0.1)         // 松开 ⌘
_ = chord.update(down: [], at: 0.15)               // 松开 ⌥
expect(chord.update(down: [.option], at: 0.2) == false, "⌥⌘ 组合之后紧接的单击不触发")
var hold = DoubleTapTracker()
_ = hold.update(down: [.option], at: 0)
expect(hold.update(down: [.option], at: 0.1) == false, "按住不松不触发")

// 真事件链路：建 flagsChanged tap，投递合成修饰键事件
let doubleTap = ModifierDoubleTapMonitor()
var taps = 0
doubleTap.onFire = { taps += 1 }
let tapStarted = doubleTap.start(.option)
expect(tapStarted, "建立双击监听", tapStarted ? "成功" : SystemPermissions.failureHint)
if tapStarted {
    let tapSource = CGEventSource(stateID: .privateState)
    func postModifier(_ modifier: ModifierTap, down: Bool, with extras: CGEventFlags = []) {
        let key: CGKeyCode
        switch modifier {
        case .option: key = CGKeyCode(kVK_Option)
        case .command: key = CGKeyCode(kVK_Command)
        case .control: key = CGKeyCode(kVK_Control)
        case .shift: key = CGKeyCode(kVK_Shift)
        }
        guard let event = CGEvent(keyboardEventSource: tapSource, virtualKey: key, keyDown: down) else { return }
        event.type = .flagsChanged
        event.flags = down ? modifier.flag.union(extras) : []
        event.post(tap: .cghidEventTap)
    }

    // 每组之间先等 >350ms：否则上一组的松开会把下一组的第一次按下算成双击
    settle(0.5)
    postModifier(.option, down: true); settle(0.05)
    postModifier(.option, down: false); settle(0.05)
    postModifier(.option, down: true); settle(0.15)
    postModifier(.option, down: false); settle(0.15)
    expect(taps == 1, "真事件：快速双击 ⌥ 触发一次", "触发 \(taps) 次")

    settle(0.5)
    postModifier(.option, down: true); settle(0.05)
    postModifier(.option, down: false); settle(0.6)
    postModifier(.option, down: true); settle(0.05)
    postModifier(.option, down: false); settle(0.2)
    expect(taps == 1, "真事件：两下间隔 600ms 不触发", "共触发 \(taps) 次")

    settle(0.5)
    postModifier(.option, down: true, with: []); settle(0.05)
    postModifier(.command, down: true, with: [.maskAlternate]); settle(0.05)
    postModifier(.command, down: false, with: [.maskAlternate]); settle(0.05)
    postModifier(.option, down: false); settle(0.05)
    postModifier(.option, down: true); settle(0.15)
    postModifier(.option, down: false); settle(0.15)
    expect(taps == 1, "真事件：⌥⌘ 组合不触发", "共触发 \(taps) 次")

    // 配置的是 ⌥：双击别的修饰键不该触发（用户实测双击 ⌘ 也会弹窗）
    settle(0.5)
    postModifier(.command, down: true); settle(0.05)
    postModifier(.command, down: false); settle(0.05)
    postModifier(.command, down: true); settle(0.15)
    postModifier(.command, down: false); settle(0.15)
    expect(taps == 1, "真事件：配置 ⌥ 时双击 ⌘ 不触发", "共触发 \(taps) 次")

    settle(0.5)
    postModifier(.control, down: true); settle(0.05)
    postModifier(.control, down: false); settle(0.05)
    postModifier(.control, down: true); settle(0.15)
    postModifier(.control, down: false); settle(0.15)
    expect(taps == 1, "真事件：配置 ⌥ 时双击 ⌃ 不触发", "共触发 \(taps) 次")

    doubleTap.stop()
    expect(doubleTap.running == false, "停止后不再监听")
    settle(0.5)
    postModifier(.option, down: true); settle(0.05)
    postModifier(.option, down: false); settle(0.05)
    postModifier(.option, down: true); settle(0.15)
    postModifier(.option, down: false); settle(0.15)
    expect(taps == 1, "停止后投递事件不再触发", "共触发 \(taps) 次")
}

// ── 工具门面：唤起方式接线 ──────────────────────────
print("── 工具门面接线")
let tool = MagicClipboard(store: ClipboardStore(root: probeBase.appendingPathComponent("tool-store")))
expect(tool.trigger == .doubleTap(.option), "工具默认唤起方式＝双击 ⌥", tool.trigger.display)
expect(tool.triggerFailure == nil, "未启用时不注册")
tool.enabled = true
expect(tool.triggerFailure == nil, "启用后双击监听注册成功", tool.triggerFailure ?? "正常")
tool.trigger = .combo(.default)
expect(tool.triggerFailure == nil, "切成组合键 ⌥⌘V 注册成功", tool.triggerFailure ?? "正常")
tool.trigger = .doubleTap(.option)
expect(tool.triggerFailure == nil, "切回双击 ⌥ 注册成功", tool.triggerFailure ?? "正常")
tool.enabled = false

// ── 关闭开关后不应再被唤起（用户报的 bug）──────────────
print("── 关闭开关后的唤起")
let toolSource = CGEventSource(stateID: .privateState)
func postOption(_ down: Bool) {
    guard let event = CGEvent(keyboardEventSource: toolSource, virtualKey: CGKeyCode(kVK_Option), keyDown: down) else { return }
    event.type = .flagsChanged
    event.flags = down ? .maskAlternate : []
    event.post(tap: .cghidEventTap)
}
func doubleTapOption() {
    settle(0.5)                      // 每组之间留 >350ms 间隔
    postOption(true); settle(0.05)
    postOption(false); settle(0.05)
    postOption(true); settle(0.15)
    postOption(false); settle(0.2)
}

tool.enabled = true
doubleTapOption()
expect(tool.isPickerVisible, "开启时双击 ⌥ 会唤起窗口", tool.isPickerVisible ? "窗口已打开" : "没弹出")
tool.hidePicker()
settle(0.3)

tool.enabled = false
doubleTapOption()
expect(!tool.isPickerVisible, "关闭开关后双击 ⌥ 不再唤起窗口", tool.isPickerVisible ? "仍然弹出了窗口" : "正确：没有弹出")

// ── 工具必须是进程级单例（否则多窗口各自注册一次监听，双击一次弹两个窗）──
print("── 工具单例与窗口独立性")
let modelA = AppModel()
let modelB = AppModel()
expect(modelA.magicClipboard === modelB.magicClipboard, "多个 AppModel 共用一个剪贴板实例",
       modelA.magicClipboard === MagicClipboard.shared ? "同一实例" : "不同实例")
expect(modelA.magicMouse === modelB.magicMouse, "多个 AppModel 共用一个魔法鼠标实例")
MagicClipboard.shared.enabled = false   // 别把探针进程的共享实例留在开启状态

tool.enabled = true
// 探针进程得先自己激活：非激活面板只有在进程本身活跃时才能拿键盘焦点。
// 真机上这一步是用户点按/系统给的，不是 app 抢的。
NSApp.activate(ignoringOtherApps: true)
settle(0.3)
tool.showPicker()
settle(0.5)
let panels = NSApp.windows.filter { $0.title == "剪贴板历史" }
let panel = panels.first
expect(panels.count == 1, "唤起得到唯一一个剪贴板窗口", "共 \(panels.count) 个")
expect(panel?.styleMask.contains(.nonactivatingPanel) == true, "剪贴板窗口是非激活面板（不抢 app 激活）")
expect(panel?.isFloatingPanel == true, "剪贴板窗口是浮动面板")
expect(panel?.parent == nil && panel?.sheetParent == nil, "剪贴板窗口不挂在主窗口下（互相独立）")
tool.showPicker()
settle(0.3)
expect(NSApp.windows.filter { $0.title == "剪贴板历史" }.count == 1, "重复唤起不会多出窗口")

expect(panel?.isKeyWindow == true, "唤起后窗口拿到键盘焦点（可输入）")
panel?.resignKey()
settle(0.4)
expect(panel?.isVisible == false, "失焦后自动收起（浮层语义）")
expect(tool.isPickerVisible == false, "失焦收起后工具状态同步")
tool.hidePicker()
settle(0.3)
expect(panel?.isVisible == false, "收起后不可见")
tool.enabled = false

// ── 唤起重置 / 选中第一条 / 方向键与回车（用户要求）──────────────
print("── 历史窗口的重置与键盘")
// 单独一个工具实例：这样窗口、状态、复用/收起都是同一条链路（tool.picker 与它自己的面板对应）
let winTool = MagicClipboard(store: ClipboardStore(root: probeBase.appendingPathComponent("win-store")))
for (index, text) in ["第一条", "第二条", "第三条"].enumerated() {
    let item = makeItem(winTool.store, kind: .text, text: text, bytes: 64,
                        usedAt: Date().addingTimeInterval(-Double(60 * (index + 1))))
    winTool.store.insert(item, maxBytes: 1 << 30, retention: .forever)
}
winTool.showPicker()
settle(0.3)
guard let win = winTool.picker else { print("  ✗ 窗口没建起来"); exit(1) }
let state = win.state
expect(state.query.isEmpty && state.kind == nil && state.limit == 200, "唤起时状态是干净的")
expect(state.selected == 0, "唤起时选中第一条", "selected=\(state.selected)")
let firstPresentation = state.presentation

// 把状态弄脏，再次唤起必须回到干净状态（不能残留上次的搜索/类型/选中）
state.query = "残留"; state.kind = .text; state.selected = 3; state.limit = 600
winTool.showPicker()
settle(0.2)
expect(state.query.isEmpty, "再次唤起清空搜索框")
expect(state.kind == nil, "再次唤起类型重置为全部")
expect(state.selected == 0, "再次唤起选中回到第一条")
expect(state.limit == 200, "再次唤起分页重置")
expect(state.presentation > firstPresentation, "每次唤起都发出重置信号", "第 \(state.presentation) 次")

/// 构造 keyDown 事件：真实按键在 CLI 探针进程里到不了窗口（没有事件循环在拉事件队列），
/// 所以探针直接构造 NSEvent 驱动 `handle`。窗口号必须对，否则 handle 的窗口校验会直接放行。
func press(_ code: UInt16, _ chars: String = "", flags: NSEvent.ModifierFlags = []) -> Bool {
    guard let event = NSEvent.keyEvent(
        with: .keyDown, location: .zero, modifierFlags: flags,
        timestamp: ProcessInfo.processInfo.systemUptime,
        windowNumber: win.windowNumber, context: nil,
        characters: chars, charactersIgnoringModifiers: chars,
        isARepeat: false, keyCode: code
    ) else { return false }
    return win.handle(event)
}
let itemCount = winTool.store.query(kind: nil, text: "").count
expect(itemCount == 3, "探针数据就绪", "\(itemCount) 条")

// 焦点在列表上：直接打字就是搜索（不用先点输入框）
expect(press(0, "第"), "无修饰键字符被消费（当搜索输入）")
expect(state.query == "第", "直接打字即搜索", "query=\(state.query)")
expect(state.selected == 0, "改搜索词后选中回到第一条")
_ = press(51)
expect(state.query.isEmpty, "⌫ 删除搜索词")

expect(press(125), "↓ 被消费")
_ = press(125)
expect(state.selected == 2, "↓↓ 移到第三条", "selected=\(state.selected)")
for _ in 0..<5 { _ = press(125) }
expect(state.selected == itemCount - 1, "↓ 到底就停住，不越界", "selected=\(state.selected)")
for _ in 0..<5 { _ = press(126) }
expect(state.selected == 0, "↑ 到顶就停住，不越界", "selected=\(state.selected)")
_ = press(126)
expect(state.selected == 0, "已在第一条再按 ↑ 仍是第一条")

// ⌘/⌃ 组合键不能被当成搜索输入（⌘Q、⌘W 要照常工作）
expect(!press(0, "q", flags: .command), "⌘Q 不被消费，交给系统")
expect(state.query.isEmpty, "⌘Q 不会污染搜索词", "query=\(state.query)")
expect(press(53), "esc 被消费")
settle(0.3)
expect(winTool.isPickerVisible == false, "esc 收起窗口")

// ── ⏎＝粘贴（复用＝复制 + 投递 ⌘V）────────────────────────────
print("── 回车粘贴")
final class KeyCollector {
    var pressed: [(CGKeyCode, CGEventFlags)] = []
    func add(_ event: CGEvent) {
        pressed.append((CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode)), event.flags))
    }
}
let keys = KeyCollector()
let keyMask = CGEventMask(1 << CGEventType.keyDown.rawValue)
let keyTap = CGEvent.tapCreate(
    tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
    eventsOfInterest: keyMask,
    callback: { _, _, event, userInfo in
        Unmanaged<KeyCollector>.fromOpaque(userInfo!).takeUnretainedValue().add(event)
        return Unmanaged.passUnretained(event)
    },
    userInfo: Unmanaged.passUnretained(keys).toOpaque()
)
if let keyTap {
    let keySource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, keyTap, 0)
    CFRunLoopAddSource(CFRunLoopGetMain(), keySource, .commonModes)
    CGEvent.tapEnable(tap: keyTap, enable: true)

    winTool.showPicker()
    settle(0.3)
    keys.pressed.removeAll()
    let target = winTool.store.query(kind: nil, text: "")[safe: state.selected]
    _ = press(36)
    settle(0.6)
    expect(winTool.isPickerVisible == false, "⏎ 之后窗口收起")
    let pasted = NSPasteboard.general.string(forType: .string)
    // makeItem 生成的载荷是 64 个 A（preview 只是标签），所以比的是载荷内容
    let payload = target.flatMap { winTool.store.payloadURL($0) }.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    expect(pasted == payload, "⏎ 把选中记录的载荷写回剪贴板", "剪贴板=\(pasted?.prefix(12) ?? "nil") / 载荷=\(payload?.prefix(12) ?? "nil")")
    expect(winTool.store.items.first?.id == target?.id, "复用后被置顶到第一条")
    expect((winTool.store.items.first?.usedAt ?? .distantPast) > (target?.usedAt ?? .distantFuture), "复用后时间刷新为最新")
    let combo = keys.pressed.first { $0.0 == CGKeyCode(kVK_ANSI_V) }
    expect(combo != nil, "⏎ 之后投递了 ⌘V（真的粘贴）", keys.pressed.isEmpty ? "没抓到按键" : "抓到 \(keys.pressed.count) 个")
    expect(combo?.1.contains(.maskCommand) == true, "⌘V 带 ⌘ 修饰键")

    CGEvent.tapEnable(tap: keyTap, enable: false)
    CFRunLoopRemoveSource(CFRunLoopGetMain(), keySource, .commonModes)
    CFMachPortInvalidate(keyTap)
} else {
    expect(false, "建立按键观察 tap", SystemPermissions.failureHint)
}

// ── 收起时把焦点还给唤起前的 app（用鼠标点窗口会让系统把 macq 激活，原 app 掉焦点）──
print("── 焦点交还")
let me = ProcessInfo.processInfo.processIdentifier
expect(ClipboardPickerWindow.restorationTarget(previous: 999, current: me, own: me) == 999,
       "我们自己抢到最前台时，把焦点交还给唤起前的 app")
expect(ClipboardPickerWindow.restorationTarget(previous: 999, current: 888, own: me) == nil,
       "用户开着浮层又切到别的 app：收起时不抢他的焦点")
expect(ClipboardPickerWindow.restorationTarget(previous: me, current: me, own: me) == nil,
       "唤起前就是 macq：不需要交还")
expect(ClipboardPickerWindow.restorationTarget(previous: nil, current: me, own: me) == nil,
       "没记下目标：不动作")
winTool.showPicker()
settle(0.3)
let previous = winTool.picker?.previousAppPID
expect(previous != nil || NSWorkspace.shared.frontmostApplication == nil,
       "唤起时记下了唤起前的最前台 app",
       "pid=\(previous.map(String.init) ?? "nil") / 当前=\(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)")
winTool.hidePicker()
settle(0.2)
}

MainActor.assumeIsolated { runProbe() }
print("")
print(failed == 0 ? "全部通过：\(passed) 项" : "失败 \(failed) 项 / 通过 \(passed) 项")
exit(failed == 0 ? 0 : 1)
