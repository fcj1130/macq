import AppKit
import Foundation

// 魔法右键探针：菜单逻辑 + 跨进程配置 + 扩展状态与产物 + 设置页
//   ./Scripts/uidbg/probe.sh Scripts/uidbg/probe-rightclick.swift
//
// 探针验不了的（必须你在访达里真点一次右键）：
//   · 菜单是否真的出现在访达右键菜单里
//   · 点「复制路径」后剪贴板内容 / 点「进入终端」后终端是否进到该目录
//   · 「显示/隐藏隐藏文件」这类需要重启访达的动作（本工具未实现）

var passed = 0, failed = 0

func expect(_ ok: Bool, _ label: String, _ detail: String = "") {
    if ok {
        passed += 1
        print("✓ \(label)")
    } else {
        failed += 1
        print("✗ \(label)\(detail.isEmpty ? "" : "  → \(detail)")")
    }
}

/// 跑一条命令拿输出（探针进程不在沙箱里）
func shell(_ launchPath: String, _ arguments: [String]) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: launchPath)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    guard (try? process.run()) != nil else { return "" }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
}

@MainActor
func runProbe() {
    // 工具实例初始化会写真实的共享配置：先备份，结束时还原
    // （exit() 不会跑 defer，所以末尾显式还原）
    let realConfigURL = RightClickSharedConfig.configURL
    let configBackup = try? Data(contentsOf: realConfigURL)
    func restoreRealConfig() {
        if let configBackup {
            try? configBackup.write(to: realConfigURL)
        } else {
            try? FileManager.default.removeItem(at: realConfigURL)
        }
    }

    print("── 菜单项 ──")
    expect(RightClickItem.allCases == [.copyPath, .openTerminal, .newFile], "三个菜单项，顺序固定")
    for item in RightClickItem.allCases {
        expect(!item.title.isEmpty && !item.summary.isEmpty, "「\(item.title)」有标题和说明")
        expect(
            NSImage(systemSymbolName: item.icon, accessibilityDescription: nil) != nil,
            "「\(item.title)」的图标 \(item.icon) 是合法 SF Symbol"
        )
    }

    print("\n── 开关决定扩展画什么菜单 ──")
    let bothOn = RightClickSharedConfig(
        enabled: true,
        items: [RightClickItem.copyPath.rawValue: true, RightClickItem.openTerminal.rawValue: true, RightClickItem.newFile.rawValue: true]
    )
    expect(bothOn.visibleItems == [.copyPath, .openTerminal, .newFile], "全开 → 三项都出现")
    var onlyCopy = bothOn
    onlyCopy.items[RightClickItem.openTerminal.rawValue] = false
    onlyCopy.items[RightClickItem.newFile.rawValue] = false
    expect(onlyCopy.visibleItems == [.copyPath], "只开复制路径 → 只出现复制路径")
    var off = bothOn
    off.enabled = false
    expect(off.visibleItems.isEmpty, "总开关关闭 → 即使单项开着也不出现")
    expect(RightClickSharedConfig.disabled.visibleItems.isEmpty, "读不到配置时的默认值：什么都不显示")

    print("\n── 主程序没运行时不给「进入终端」 ──")
    HostApp.runningOverride = false
    expect(bothOn.visibleItems == [.copyPath, .newFile], "MacQ 未运行 → 「进入终端」不出现，「复制路径」「新建文件」照旧（扩展内就能完成）")
    var onlyTerminal = bothOn
    onlyTerminal.items[RightClickItem.copyPath.rawValue] = false
    onlyTerminal.items[RightClickItem.newFile.rawValue] = false
    expect(onlyTerminal.visibleItems.isEmpty, "MacQ 未运行且只开了「进入终端」→ 菜单整体为空，不留空条目")
    HostApp.runningOverride = true
    expect(bothOn.visibleItems == [.copyPath, .openTerminal, .newFile], "MacQ 运行中 → 三项都出现")
    HostApp.runningOverride = nil
    let hostRunning = NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == HostApp.bundleID }
    expect(HostApp.isRunning == hostRunning, "自动检测与系统进程列表一致（MacQ 在运行=\(hostRunning)）")
    // 写错这个 id，扩展会永远认为主程序没在运行 → 菜单永远不出现（且下面那条产物断言也会红）
    expect(
        HostApp.bundleID == RightClickSharedConfig.extensionBundleID.replacingOccurrences(of: ".FinderRightClick", with: ""),
        "HostApp.bundleID 是扩展 bundle id 的主程序部分（\(HostApp.bundleID)）"
    )
    expect(!bothOn.isOn(.copyPath) == false, "isOn 读得到开着的项")
    expect(
        !RightClickSharedConfig(enabled: true, items: [:]).isOn(.copyPath),
        "缺键按关闭处理（不是默认开）"
    )

    print("\n── URL 通道（扩展 → 主程序）──")
    // 扩展是沙箱进程，自己开不了终端，只能把请求编码成 URL 交给系统，由主程序执行
    let routed = URL(fileURLWithPath: "/tmp/macq-rightclick-probe/sub")
    if let url = AppURL.url(for: .openTerminal(folder: routed)) {
        expect(url.scheme == "macq", "生成的 URL 用 macq scheme：\(url.absoluteString)")
        expect(AppURL.request(from: url) == .openTerminal(folder: routed), "往返解析回同一个文件夹")
    } else {
        expect(false, "生成 URL 失败")
    }
    let weird = URL(fileURLWithPath: "/tmp/macq-rightclick-probe/带 空格 中文")
    if let url = AppURL.url(for: .openTerminal(folder: weird)) {
        expect(AppURL.request(from: url) == .openTerminal(folder: weird), "中文 + 空格路径往返一致")
    } else {
        expect(false, "中文路径生成 URL 失败")
    }
    expect(AppURL.request(from: URL(string: "macq://unknown?path=/tmp")!) == nil, "未知 action → 不认")
    expect(AppURL.request(from: URL(string: "https://example.com/?path=/tmp")!) == nil, "别的 scheme → 不认")
    expect(AppURL.request(from: URL(string: "macq://terminal")!) == nil, "缺 path → 不认")
    expect(AppURL.request(from: URL(string: "macq://terminal?path=")!) == nil, "空 path → 不认")
    // 主程序侧的存在性校验（URL 来自扩展，但按不可信输入处理）
    let urlProbeRoot = URL(fileURLWithPath: "/tmp/macq-rightclick-urlprobe")
    let urlProbeDir = urlProbeRoot.appending(path: "子目录")
    let urlProbeFile = urlProbeRoot.appending(path: "文件.txt")
    try? FileManager.default.createDirectory(at: urlProbeDir, withIntermediateDirectories: true)
    try? Data("x".utf8).write(to: urlProbeFile)
    expect(AppURL.existingFolder(at: urlProbeDir.path) != nil, "存在的文件夹 → 接受")
    expect(AppURL.existingFolder(at: urlProbeFile.path) == nil, "文件（不是文件夹）→ 拒绝")
    expect(AppURL.existingFolder(at: "/tmp/macq-rightclick-urlprobe/不存在") == nil, "不存在的路径 → 拒绝")
    expect(AppURL.existingFolder(at: "") == nil, "空路径 → 拒绝")
    try? FileManager.default.removeItem(at: urlProbeRoot)

    print("\n── 路径推导 ──")
    // 用真实存在的路径：目录判定会退回文件系统，虚拟路径测不出真实行为
    let root = URL(fileURLWithPath: "/tmp/macq-rightclick-probe")
    let dir = root.appending(path: "中文 目录")
    let file1 = root.appending(path: "a.txt")
    let file2 = dir.appending(path: "b.txt")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    for url in [file1, file2] { try? Data("x".utf8).write(to: url) }

    expect(
        RightClickPaths.copyTargets(selected: [file1, dir], targeted: nil) == [file1.path, dir.path],
        "选中文件+文件夹 → 各自绝对路径"
    )
    expect(
        RightClickPaths.copyTargets(selected: [], targeted: dir) == [dir.path],
        "空白处右键 → 当前文件夹路径"
    )
    expect(RightClickPaths.copyTargets(selected: [], targeted: nil).isEmpty, "无选中也无目标 → 空（按钮置灰）")
    expect(RightClickPaths.terminalFolder(selected: [file2], targeted: nil)?.path == dir.path, "选文件 → 进它所在文件夹")
    expect(RightClickPaths.terminalFolder(selected: [dir], targeted: nil)?.path == dir.path, "选文件夹 → 进该文件夹")
    expect(
        RightClickPaths.terminalFolder(selected: [URL(fileURLWithPath: dir.path + "/")], targeted: nil)?.path == dir.path,
        "带斜杠的目录 URL（访达给的形态）→ 进该文件夹"
    )
    expect(
        RightClickPaths.terminalFolder(selected: [file1, file2], targeted: nil)?.path == root.path,
        "多选时以第一个为准"
    )
    expect(RightClickPaths.terminalFolder(selected: [], targeted: dir)?.path == dir.path, "空白处 → 当前文件夹")
    expect(RightClickPaths.terminalFolder(selected: [], targeted: nil) == nil, "无目标 → 没有可进目录")
    expect(TerminalApp.installed().contains { $0.id == TerminalApp.systemBundleID }, "认得出系统终端")

    print("\n── 跨进程配置（主程序写 / 扩展读）──")
    let tempURL = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "macq-rightclick-probe.json")
    try? FileManager.default.removeItem(at: tempURL)
    expect(bothOn.write(to: tempURL) == tempURL, "写到指定位置成功")
    expect(RightClickSharedConfig.read(from: tempURL) == bothOn, "读回来与写入完全一致（字段不丢）")
    expect(RightClickSharedConfig.read(from: tempURL)?.visibleItems == [.copyPath, .openTerminal, .newFile], "读回来的配置能算出菜单项")
    expect(RightClickSharedConfig.read(from: URL(fileURLWithPath: "/nonexistent/none.json")) == nil, "文件不存在 → nil（不崩）")
    let garbage = URL(fileURLWithPath: NSTemporaryDirectory()).appending(path: "macq-rightclick-garbage.json")
    try? Data("这不是 json".utf8).write(to: garbage)
    expect(RightClickSharedConfig.read(from: garbage) == nil, "内容损坏 → nil，扩展退回默认值")
    expect(bothOn.write(to: URL(fileURLWithPath: "/System/macq-should-fail.json")) == nil, "写不进去时返回 nil（不崩）")
    try? FileManager.default.removeItem(at: tempURL)
    try? FileManager.default.removeItem(at: garbage)

    print("\n── 总开关 → 扩展实际读到的内容 ──")
    let tool = MagicRightClick.shared
    tool.enabled = true
    tool.copyPath = true
    tool.openTerminal = false
    if let written = RightClickSharedConfig.read(from: realConfigURL) {
        // tool.newFile 默认开；这里保持默认值，断言里预期它出现
        expect(written.enabled, "总开关开 → 配置文件 enabled=true")
        expect(written.visibleItems == [.copyPath, .newFile], "扩展显示「复制路径」+「新建文件」（进入终端关着）")
    } else {
        expect(false, "配置文件没写出来", realConfigURL.path)
    }
    tool.enabled = false
    expect(
        RightClickSharedConfig.read(from: realConfigURL)?.visibleItems.isEmpty == true,
        "总开关关 → 扩展什么都不显示"
    )

    print("\n── 扩展产物与注册状态 ──")
    let appPath = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        .appending(path: "build/Build/Products/Debug/MacQ.app")
    let appex = appPath.appending(path: "Contents/PlugIns/\(RightClickSharedConfig.extensionName)")
    expect(FileManager.default.fileExists(atPath: appex.path), "扩展已嵌进 app", appex.path)

    if let plist = NSDictionary(contentsOf: appex.appending(path: "Contents/Info.plist")) {
        let extensionInfo = plist["NSExtension"] as? [String: Any]
        expect(
            extensionInfo?["NSExtensionPointIdentifier"] as? String == "com.apple.FinderSync",
            "扩展点的类型是访达同步扩展（FinderSync）"
        )
        expect(extensionInfo?["NSExtensionPrincipalClass"] is String, "扩展声明了主体类")
        expect(plist["CFBundleIdentifier"] as? String == RightClickSharedConfig.extensionBundleID, "扩展 bundle id 正确")
    } else {
        expect(false, "读不到扩展 Info.plist")
    }
    expect(
        FileManager.default.fileExists(atPath: appex.appending(path: "Contents/MacOS/MagicRightClickFinder").path),
        "扩展可执行文件存在"
    )

    let entitlements = shell("/usr/bin/codesign", ["-d", "--entitlements", "-", appex.path])
    expect(entitlements.contains("com.apple.security.app-sandbox"), "扩展声明了沙箱（访达扩展的硬要求）")
    expect(
        entitlements.contains("com.apple.security.temporary-exception.files.home-relative-path.read-only"),
        "扩展声明了配置目录只读例外"
    )
    expect(entitlements.contains("/Library/Application Support/macq/"), "例外路径指向主程序的数据目录")

    let status = MagicRightClick.queryExtensionStatus(appexPath: appex)
    print("  pluginkit 状态 = \(status.title)")
    expect(status == .enabled, "扩展已注册且已启用（实际：\(status.title)）")
    let registration = shell("/usr/bin/pluginkit", ["-m", "-v", "-p", "com.apple.FinderSync", "-i", RightClickSharedConfig.extensionBundleID])
    // 系统里可能同时存在多份副本（build/ 与 Xcode 的 DerivedData），访达用哪份取决于最后启动的是哪个 app。
    // 这里只断言「注册的是 MacQ 的扩展、且这份副本真的在磁盘上」，具体是哪一份打出来供排查。
    // pluginkit 输出为「+ id(版本)\tUUID\t时间\t路径」多行，末尾还有一行汇总，这里取含路径的那一行
    let registeredLine = registration.split(separator: "\n").first { $0.contains("/Contents/PlugIns/") }.map(String.init) ?? ""
    let registeredAppex = registeredLine.split(separator: "\t").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
    print("  已注册的扩展副本 = \(registeredAppex)")
    expect(
        registeredAppex.hasSuffix("/Contents/PlugIns/MagicRightClickFinder.appex"),
        "系统注册的扩展是 MacQ 的 appex（实际：\(registeredAppex.isEmpty ? "无" : registeredAppex)）"
    )
    expect(FileManager.default.fileExists(atPath: registeredAppex), "已注册的那份副本在磁盘上存在")

    print("\n── 设置页 ──")
    let page = host(MagicRightClickView(tool: tool), width: 720, height: 1000)
    guard let window = page.window, let rep = render(page) else {
        expect(false, "离屏窗口没建起来")
        restoreRealConfig()
        exit(1)
    }
    let joined = ocr(rep, "魔法右键设置页").joined(separator: " | ")
    for needle in ["开启魔法右键", "菜单项", "复制路径", "进入终端", "打开终端", "访达扩展"] {
        expect(joined.contains(needle), "设置页有「\(needle)」")
    }
    // 探针进程的 Bundle.main 不是 app 包，所以这一页在探针里永远看不到扩展（显示「构建产物里没有扩展」）。
    // 扩展是否真在、是否真已启用，由上面「扩展产物与注册状态」一节用真实路径验证。
    let pageStatus = tool.extensionStatus.title
    expect(joined.contains(pageStatus), "设置页显示了工具当前的扩展状态（探针内为「\(pageStatus)」）")
    expect(joined.contains(tool.terminalOptions.first?.name ?? "终端"), "设置页列出可选终端")

    let scale = CGFloat(rep.pixelsWide) / max(page.bounds.width, 1)
    if let box = ocrBoxes(rep).first(where: { $0.text.contains("进入终端") }) {
        let band = CGRect(
            x: 0,
            y: box.rect.minY / scale - 24,
            width: page.bounds.width,
            height: box.rect.height / scale + 48
        )
        if let point = controlCenter(page, classContains: "Switch", in: band) {
            let before = tool.openTerminal
            click(point, in: window, settle: 0.8)
            expect(tool.openTerminal != before, "点「进入终端」开关 → 设置值翻转（\(before) → \(tool.openTerminal)）")
            let onDisk = RightClickSharedConfig.read(from: realConfigURL)
            expect(onDisk?.isOn(.openTerminal) == tool.openTerminal, "共享配置文件同步为最新值")
            expect(onDisk?.enabled == tool.enabled, "总开关也同步到配置文件")
            tool.openTerminal = before
        } else {
            expect(false, "「进入终端」那一行里找不到开关控件")
        }
    } else {
        expect(false, "OCR 没找到「进入终端」")
    }
    window.orderOut(nil)

    // —— 新建文件 ——
    expect(RightClickItem.newFile.containerMenuOnly, "新建文件标记为仅空白处菜单")
    expect(!RightClickItem.copyPath.containerMenuOnly, "复制路径不受容器菜单过滤限制")

    let allOn = RightClickSharedConfig(enabled: true, items: [
        RightClickItem.copyPath.rawValue: true,
        RightClickItem.openTerminal.rawValue: true,
        RightClickItem.newFile.rawValue: true,
    ])
    HostApp.runningOverride = true
    expect(allOn.visibleItems(isContainerMenu: true).contains(.newFile), "空白处菜单包含新建文件")
    expect(!allOn.visibleItems(isContainerMenu: false).contains(.newFile), "右键文件菜单不含新建文件")
    expect(allOn.visibleItems(isContainerMenu: false).contains(.copyPath), "右键文件菜单仍有复制路径")
    HostApp.runningOverride = nil

    expect(RightClickPaths.newFileName(existing: []) == "未命名.txt", "空目录首个文件名是 未命名.txt")
    expect(RightClickPaths.newFileName(existing: ["未命名.txt"]) == "未命名 2.txt", "重名跳到 2")
    expect(RightClickPaths.newFileName(existing: ["未命名.txt", "未命名 2.txt", "未命名 3.txt"]) == "未命名 4.txt", "连号后取下一个")
    expect(RightClickPaths.newFileName(existing: [], baseName: "Untitled") == "Untitled.txt", "英文名首个是 Untitled.txt")
    expect(RightClickPaths.newFileName(existing: ["Untitled.txt"], baseName: "Untitled") == "Untitled 2.txt", "英文名重名连号")
    expect(RightClickPaths.newFileName(existing: ["未命名.txt"], baseName: "Untitled") == "Untitled.txt", "中英基础名互不干扰")

    let urlRT = AppURL.url(for: .newFile(folder: URL(fileURLWithPath: "/tmp/新建 目录")))
    expect(urlRT?.host == "newfile", "新建文件 URL host 是 newfile")
    expect(AppURL.request(from: urlRT!) == .newFile(folder: URL(fileURLWithPath: "/tmp/新建 目录")), "URL 编解码往返一致（含中文与空格）")

    let nfDir = root.appending(path: "nf")
    try? FileManager.default.createDirectory(at: nfDir, withIntermediateDirectories: true)
    let nf1 = RightClickPaths.createNewFile(in: nfDir)
    expect(nf1?.lastPathComponent == "未命名.txt", "真实建文件：第一个是 未命名.txt")
    let nf2 = RightClickPaths.createNewFile(in: nfDir)
    expect(nf2?.lastPathComponent == "未命名 2.txt", "真实建文件：第二个自动加序号")
    let nfDirEn = root.appending(path: "nfen")
    try? FileManager.default.createDirectory(at: nfDirEn, withIntermediateDirectories: true)
    let nfEn = RightClickPaths.createNewFile(in: nfDirEn, baseName: "Untitled")
    expect(nfEn?.lastPathComponent == "Untitled.txt", "真实建文件：英文基础名生效")
    expect(FileManager.default.fileExists(atPath: nf2!.path), "文件真的落盘了")

    let plainScript = RightClickPaths.renameAppleScript(for: "/tmp/新建 目录/未命名.txt")
    expect(plainScript.contains(#"POSIX file "/tmp/新建 目录/未命名.txt" as alias"#), "重命名脚本：路径带双引号")
    expect(plainScript.contains("key code 36"), "重命名脚本：回车键码 36")
    let tricky = RightClickPaths.renameAppleScript(for: "/tmp/a\"b\\c.txt")
    expect(tricky.contains(#"POSIX file "/tmp/a\"b\\c.txt" as alias"#), "重命名脚本：路径里的引号和反斜杠被转义")

    var withBase = allOn
    withBase.newFileBaseName = "Untitled"
    let json = withBase.write(to: root.appending(path: "rc.json"))
    expect(json != nil, "含 newFile 的配置能写盘")
    expect(RightClickSharedConfig.read(from: json!)?.isOn(.newFile) == true, "读回来的配置里 newFile 为开")
    expect(RightClickSharedConfig.read(from: json!)?.newFileBaseName == "Untitled", "读回来的基础名不丢")

    try? FileManager.default.removeItem(at: root)
    restoreRealConfig()
    print("\n结果：\(passed) ✓  \(failed) ✗")
    exit(failed == 0 ? 0 : 1)
}

MainActor.assumeIsolated { runProbe() }
