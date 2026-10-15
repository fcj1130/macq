import SwiftUI
import UniformTypeIdentifiers

/// 开发者工具箱面板：左侧工具导航（可拖拽排序）+ 右侧操作区。
struct DevToolboxPanelView: View {
    let tool: DevToolbox
    let state: DevToolboxPanelState

    var body: some View {
        HStack(spacing: 0) {
            nav
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - 左侧导航

    private var nav: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(tool.order) { item in
                    navRow(item)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        // 拖拽排序随时可用（面板里没有编辑模式的概念）
                        .reorderable(id: item.rawValue, enabled: true,
                                     preview: Label(AppLanguage.localized(item.name), systemImage: item.icon))
                        .dropDestination(for: String.self) { dragged, _ in
                            guard let id = dragged.first, let from = DevTool(rawValue: id) else { return false }
                            withAnimation { tool.move(from, to: item) }
                            return true
                        }
                }
            }
            .padding(.vertical, 8)
        }
        .frame(width: 148)
        .background(.quinary)
    }

    private func navRow(_ item: DevTool) -> some View {
        let isSelected = state.selected == item
        return HStack(spacing: 7) {
            Image(systemName: item.icon)
                .frame(width: 18)
                .foregroundStyle(isSelected ? Color.accentColor : .secondary)
            Text(AppLanguage.localized(item.name))
                .font(.system(size: 12.5))
                .lineLimit(1)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .background(isSelected ? Color.accentColor.opacity(0.22) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture { state.selected = item }
    }

    // MARK: - 右侧操作区

    /// 所有工具常驻 ZStack，非选中的隐藏不可交互：视图不离开层级，切换后输入/结果不丢（用户要求状态保持）
    private var content: some View {
        ZStack(alignment: .topLeading) {
            LiveConverter(
                title: "JSON",
                directions: [("美化", DevToolboxCore.jsonPretty), ("压缩", DevToolboxCore.jsonMinify)],
                placeholder: "粘贴或输入 JSON…",
                emptyHint: "输入 JSON 后自动格式化；嵌套、数组、Unicode 都支持。"
            ).toolPane(.json, selected: state.selected)

            LiveConverter(
                title: "Base64",
                directions: [("编码", { $0.isEmpty ? nil : DevToolboxCore.base64Encode($0) }),
                             ("解码", DevToolboxCore.base64Decode)],
                placeholder: "输入文本或 Base64…",
                emptyHint: "UTF-8 编解码，输入即转换。"
            ).toolPane(.base64, selected: state.selected)

            LiveConverter(
                title: "URL 编码",
                directions: [("编码", { $0.isEmpty ? nil : DevToolboxCore.urlEncode($0) }),
                             ("解码", { $0.isEmpty ? nil : DevToolboxCore.urlDecode($0) })],
                placeholder: "输入文本或已编码的 URL…",
                emptyHint: "编码采用全量百分号编码（字母数字之外全部编码），适合放进 URL 参数。"
            ).toolPane(.url, selected: state.selected)

            LiveConverter(
                title: "HTML 编码",
                directions: [("编码", { $0.isEmpty ? nil : DevToolboxCore.htmlEncode($0) }),
                             ("解码", { $0.isEmpty ? nil : DevToolboxCore.htmlDecode($0) })],
                placeholder: "输入文本或 HTML…",
                emptyHint: "编码 & < > \" '；解码支持命名实体与数字实体。"
            ).toolPane(.html, selected: state.selected)

            TimestampTool().toolPane(.timestamp, selected: state.selected)
            UUIDTool().toolPane(.uuid, selected: state.selected)
            HashTool().toolPane(.hash, selected: state.selected)
            QRTool().toolPane(.qr, selected: state.selected)
            ColorPickTool().toolPane(.picker, selected: state.selected)
            PasswordTool(tool: tool).toolPane(.password, selected: state.selected)
        }
    }
}

private extension View {
    /// 非选中工具：透明 + 不可交互 + 无障碍隐藏；单链式表达式，避免多语句 ViewBuilder 复制视图（见项目记忆 #12）
    @ViewBuilder
    func toolPane(_ tool: DevTool, selected: DevTool) -> some View {
        let on = tool == selected
        self.opacity(on ? 1 : 0)
            .allowsHitTesting(on)
            .accessibilityHidden(!on)
    }
}

// MARK: - 通用：方向切换 + 输入即转 + 复制

/// 编码/解码类工具的统一外壳：分段选方向，左边输入右边输出，输入即转换（无按钮）
private struct LiveConverter: View {
    let title: String
    let directions: [(label: String, convert: (String) -> String?)]
    let placeholder: String
    let emptyHint: String

    @State private var direction = 0
    @State private var input = ""
    @State private var copied = false

    private var output: String? {
        guard !input.isEmpty else { return nil }
        return directions[direction].convert(input)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Picker("", selection: $direction) {
                    ForEach(directions.indices, id: \.self) { index in
                        Text(AppLanguage.localized(directions[index].label)).tag(index)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 170)
                Spacer()
                if input.isEmpty {
                    Text(AppLanguage.localized(title)).font(.headline)
                } else if let output {
                    Button(copied ? AppLanguage.localized("已复制 ✓") : AppLanguage.localized("复制结果")) { copy(output) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(output.isEmpty)
                } else {
                    Label(String(format: AppLanguage.localized("无法%@"), AppLanguage.localized(directions[direction].label)), systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            // 输入区常驻：空态提示放输出侧，绝不能拿提示换掉输入框
            // （否则没有任何地方能输入，永远到不了非空分支）
            HStack(spacing: 10) {
                editor(text: $input, placeholder: placeholder)
                Divider()
                ScrollView {
                    Text(outputPaneText)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(outputPaneColor)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                }
                .background(.quinary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        }
        .padding(14)
    }

    /// 输出侧三态：空输入 → 灰提示；转换失败 → 橙字；正常 → 结果
    private var outputPaneText: String {
        if input.isEmpty { return AppLanguage.localized(emptyHint) }
        if let output { return output.isEmpty ? AppLanguage.localized("（空结果）") : output }
        return String(format: AppLanguage.localized("输入无法%@"), AppLanguage.localized(directions[direction].label))
    }

    private var outputPaneColor: Color {
        input.isEmpty || output == nil ? .secondary : .primary
    }

    private func editor(text: Binding<String>, placeholder: String) -> some View {
        PlainTextView(text: text)
            .frame(minWidth: 120, minHeight: 80)
            .background(.quinary)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(alignment: .topLeading) {
                if text.wrappedValue.isEmpty {
                    Text(AppLanguage.localized(placeholder))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .padding(10)
                        .allowsHitTesting(false)
                }
            }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}

// MARK: - 时间戳

private struct TimestampTool: View {
    @State private var input = ""
    @State private var dateInput = ""
    @State private var copiedRow: String?

    /// TimelineView 只在可见时更新，窗口收起时不会空转
    private var info: DevToolboxCore.TimestampInfo? {
        DevToolboxCore.normalizeTimestamp(input).map { DevToolboxCore.timestampInfo(seconds: $0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TimelineView(.periodic(from: .now, by: 1)) { timeline in
                let now = DevToolboxCore.timestampInfo(seconds: Int(timeline.date.timeIntervalSince1970))
                HStack(spacing: 18) {
                    clockRow(label: AppLanguage.localized("当前秒"), value: "\(now.seconds)")
                    clockRow(label: AppLanguage.localized("当前毫秒"), value: "\(now.milliseconds)")
                    Spacer()
                }
                .padding(.bottom, 2)
            }

            Divider()

            HStack(alignment: .top, spacing: 14) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(AppLanguage.localized("时间戳 → 日期")).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    TextField(AppLanguage.localized("秒或毫秒，如 1760000000"), text: $input)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    if let info {
                        VStack(alignment: .leading, spacing: 3) {
                            copyableRow(AppLanguage.localized("本地日期"), info.localDash, "dash")
                            copyableRow(AppLanguage.localized("本地日期"), info.localSlash, "slash")
                            // 纯展示行才开 textSelection；可点击行开着会被文本选择吃掉点击
                            row("ISO 8601", info.iso8601).textSelection(.enabled)
                            row(AppLanguage.localized("相对"), info.relative).textSelection(.enabled)
                        }
                        .font(.system(size: 12, design: .monospaced))
                    } else if !input.isEmpty {
                        Text(AppLanguage.localized("不是有效的时间戳"))
                            .font(.caption).foregroundStyle(.orange)
                    }
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text(AppLanguage.localized("日期 → 时间戳")).font(.caption.weight(.medium)).foregroundStyle(.secondary)
                    TextField(AppLanguage.localized("粘贴或输入：2026-09-18 20:15:32"), text: $dateInput)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    if let date = DevToolboxCore.parseDate(dateInput) {
                        VStack(alignment: .leading, spacing: 3) {
                            copyableRow(AppLanguage.localized("秒级"), "\(DevToolboxCore.timestamp(from: date))", "date-sec")
                            copyableRow(AppLanguage.localized("毫秒级"), "\(DevToolboxCore.timestampMs(from: date))", "date-ms")
                        }
                        .font(.system(size: 12, design: .monospaced))
                    } else if !dateInput.isEmpty {
                        Text(AppLanguage.localized("无法解析（支持 2026-09-18 20:15:32 / 2026/09/18 / ISO8601）"))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(14)
    }

    private func clockRow(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 13, design: .monospaced).weight(.medium))
                .textSelection(.enabled)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            Text(value)
        }
    }

    /// 点击即复制的行（本地日期两种格式），带短暂的 ✓ 反馈
    private func copyableRow(_ label: String, _ value: String, _ id: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            Text(value)
            Spacer(minLength: 0)
            if copiedRow == id {
                Image(systemName: "checkmark").font(.caption).foregroundStyle(.green)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            copiedRow = id
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if copiedRow == id { copiedRow = nil } }
        }
    }

    private func copy(_ value: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
    }
}

// MARK: - UUID

private struct UUIDTool: View {
    @State private var items: [String] = []
    @State private var copiedIndex: Int?
    @State private var hovering: Int?

    /// 大小写（默认大写）/ 连字符（默认带）/ 每次生成条数（1…100）
    @State private var uppercase = true
    @State private var hyphenated = true
    @State private var countText = "1"

    private var count: Int {
        let parsed = Int(countText.trimmingCharacters(in: .whitespaces)) ?? 1
        return min(100, max(1, parsed))
    }

    private static let maxItems = 100

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Button {
                        generate()
                    } label: {
                        Label(AppLanguage.localized("生成"), systemImage: "arrow.clockwise")
                            .padding(.horizontal, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    HStack(spacing: 4) {
                        Text(AppLanguage.localized("数量")).font(.caption).foregroundStyle(.secondary)
                        TextField("1", text: $countText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 52)
                            .onSubmit { generate() }
                        Text("1–100").font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                HStack(spacing: 14) {
                    Toggle(AppLanguage.localized("大写"), isOn: $uppercase).toggleStyle(.switch).controlSize(.mini)
                    Toggle(AppLanguage.localized("连字符"), isOn: $hyphenated).toggleStyle(.switch).controlSize(.mini)
                }
                Text(AppLanguage.localized("生成 UUID v4，点击结果复制"))
                    .font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))

            if items.isEmpty {
                Text(AppLanguage.localized("生成 UUID v4，可选大小写与连字符"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
            } else {
                HStack {
                    Text(String(format: AppLanguage.localized("点击结果复制 · 最多保留 %d 条"), Self.maxItems))
                        .font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                    Button {
                        items.removeAll()
                        copiedIndex = nil
                        hovering = nil
                    } label: {
                        Label(AppLanguage.localized("清空"), systemImage: "trash")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 8)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(items.indices, id: \.self) { index in
                            HStack(spacing: 8) {
                                Text("#\(index + 1)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 30, alignment: .leading)
                                // 不开 textSelection：可选中文本会吃掉点击，点击复制就不灵了（点边距才灵）
                                Text(items[index])
                                    .font(.system(size: 12, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 6)
                                if copiedIndex == index {
                                    Image(systemName: "checkmark")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.green)
                                }
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 30)
                            .contentShape(Rectangle())
                            .background(hovering == index ? Color.accentColor.opacity(0.12) : .clear)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                            .onHover { if $0 { hovering = index } else if hovering == index { hovering = nil } }
                            .onTapGesture {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(items[index], forType: .string)
                                copiedIndex = index
                            }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func generate() {
        let batch = (0..<count).map { _ in
            DevToolboxCore.generateUUID(uppercase: uppercase, hyphenated: hyphenated)
        }
        items.insert(contentsOf: batch, at: 0)
        if items.count > Self.maxItems { items.removeLast(items.count - Self.maxItems) }
        // 列表整体右移了，旧下标的勾号会指到别的行，必须清掉
        copiedIndex = nil
    }
}

#Preview("面板") {
    DevToolboxPanelView(tool: .init(), state: DevToolboxPanelState())
        .frame(width: 720, height: 480)
}

// MARK: - Hash

/// 哈希工具：输入一次，四种算法摘要同屏展示，每行点击复制；大写开关默认小写
private struct HashTool: View {
    @State private var input = ""
    @State private var uppercase = false
    @State private var copiedAlgo: DevToolboxCore.HashAlgorithm?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Hash").font(.headline)
                Spacer()
                Toggle(AppLanguage.localized("大写"), isOn: $uppercase)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
            }

            PlainTextView(text: $input)
                .frame(minWidth: 120)
                .frame(height: 200)
                .background(.quinary)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .topLeading) {
                    if input.isEmpty {
                        Text(AppLanguage.localized("输入要计算摘要的文本…"))
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .padding(10)
                            .allowsHitTesting(false)
                    }
                }

            if input.isEmpty {
                Text(AppLanguage.localized("MD5 / SHA-1 / SHA-256 / SHA-512，输入即算，点击结果复制"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(DevToolboxCore.HashAlgorithm.allCases) { algorithm in
                        row(algorithm)
                    }
                }
                .font(.system(size: 12, design: .monospaced))
            }
        }
        .padding(14)
    }

    private func row(_ algorithm: DevToolboxCore.HashAlgorithm) -> some View {
        let digest = DevToolboxCore.hashHex(input, algorithm: algorithm, uppercase: uppercase)
        return HStack {
            Text(algorithm.name)
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .leading)
            Text(digest)
            Spacer(minLength: 0)
            if copiedAlgo == algorithm {
                Image(systemName: "checkmark").font(.caption).foregroundStyle(.green)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .background(hoveringAlgo == algorithm ? Color.accentColor.opacity(0.12) : .clear)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .onHover { if $0 { hoveringAlgo = algorithm } else if hoveringAlgo == algorithm { hoveringAlgo = nil } }
        .onTapGesture {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(digest, forType: .string)
            copiedAlgo = algorithm
        }
    }

    @State private var hoveringAlgo: DevToolboxCore.HashAlgorithm?
}

// MARK: - 二维码

/// 二维码生成：左侧输入，右侧预览；纠错级别可选，图片可复制可导出 PNG
private struct QRTool: View {
    @State private var input = ""
    @State private var level: DevToolboxCore.QRCorrectionLevel = .medium
    @State private var copied = false
    @State private var exported = false
    @State private var logo: NSImage?
    @State private var mode = 0
    @State private var decodeImage: NSImage?
    @State private var decodeResults: [String] = []
    @State private var copiedDecode: Int?
    @State private var hoverDecode: Int?

    private var png: Data? {
        DevToolboxCore.qrPNG(input, level: level, logo: logo)
    }

    var body: some View {
        VStack(spacing: 10) {
            Picker("", selection: $mode) {
                Text(AppLanguage.localized("生成")).tag(0)
                Text(AppLanguage.localized("解析")).tag(1)
            }
            .pickerStyle(.segmented)
            .frame(width: 170)

            if mode == 0 { generator } else { decoder }
        }
        .padding(14)
    }

    private var generator: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker(AppLanguage.localized("纠错"), selection: $level) {
                        ForEach(DevToolboxCore.QRCorrectionLevel.allCases) { item in
                            Text(item.rawValue).tag(item)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 180)
                    Text(String(format: AppLanguage.localized("纠错 %@，级别越高可容纳内容越少%@"), level.hint, logo != nil ? AppLanguage.localized("；已加 Logo 建议用 H") : ""))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                HStack(spacing: 6) {
                    if let logo {
                        Image(nsImage: logo)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 22, height: 22)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                        Button(AppLanguage.localized("移除 Logo")) { self.logo = nil }
                            .controlSize(.mini)
                    } else {
                        Button(AppLanguage.localized("添加 Logo…")) { pickLogo() }
                            .controlSize(.mini)
                    }
                }
                PlainTextView(text: $input)
                    .frame(minWidth: 120, minHeight: 120)
                    .background(.quinary)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .overlay(alignment: .topLeading) {
                        if input.isEmpty {
                            Text(AppLanguage.localized("输入要编码的内容（网址 / 文本 / 名片…）"))
                                .font(.system(size: 12, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .padding(10)
                                .allowsHitTesting(false)
                        }
                    }
                if !input.isEmpty && png == nil {
                    Label(AppLanguage.localized("无法生成：内容超出二维码容量"), systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            VStack(spacing: 8) {
                if let png, let image = NSImage(data: png) {
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.none)
                        .frame(width: 190, height: 190)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    Button(copied ? AppLanguage.localized("已复制 ✓") : AppLanguage.localized("复制图片")) { copyPNG(png) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    Button(exported ? AppLanguage.localized("已导出 ✓") : AppLanguage.localized("导出 PNG…")) { exportPNG(png) }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.quinary)
                        .frame(width: 190, height: 190)
                        .overlay {
                            Text(input.isEmpty ? AppLanguage.localized("预览") : AppLanguage.localized("超容量"))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                }
            }
        }
    }

    /// 解析：选图 / 读剪贴板 / 拖入图片 → 列出扫出的文本，点击复制
    private var decoder: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Button(AppLanguage.localized("选择图片…")) { pickDecodeImage() }
                        .controlSize(.mini)
                    Button(AppLanguage.localized("从剪贴板读取")) { readClipboardImage() }
                        .controlSize(.mini)
                }
                Text(AppLanguage.localized("支持选择、粘贴（先复制图片再点「从剪贴板读取」）或直接拖入图片"))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if let decodeImage {
                    Image(nsImage: decodeImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                } else {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.quinary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .overlay {
                            Text(AppLanguage.localized("拖入或选择图片"))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                }
            }
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                if decodeImage == nil {
                    Text(AppLanguage.localized("解析结果"))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                } else if decodeResults.isEmpty {
                    Label(AppLanguage.localized("未发现二维码"), systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            ForEach(decodeResults.indices, id: \.self) { index in
                                let value = decodeResults[index]
                                HStack {
                                    Text(value)
                                        .font(.system(size: 12, design: .monospaced))
                                        .lineLimit(3)
                                    Spacer(minLength: 0)
                                    if copiedDecode == index {
                                        Image(systemName: "checkmark").font(.caption).foregroundStyle(.green)
                                    }
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .contentShape(Rectangle())
                                .background(hoverDecode == index ? Color.accentColor.opacity(0.12) : .clear)
                                .clipShape(RoundedRectangle(cornerRadius: 5))
                                .onHover { if $0 { hoverDecode = index } else if hoverDecode == index { hoverDecode = nil } }
                                .onTapGesture {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(value, forType: .string)
                                    copiedDecode = index
                                }
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, let image = NSImage(contentsOf: url) else { return false }
            loadDecodeImage(image)
            return true
        }
    }

    private func loadDecodeImage(_ image: NSImage) {
        decodeImage = image
        decodeResults = DevToolboxCore.qrDecode(image)
    }

    private func pickDecodeImage() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else { return }
        loadDecodeImage(image)
    }

    private func readClipboardImage() {
        guard let image = NSPasteboard.general.readObjects(forClasses: [NSImage.self])?.first as? NSImage else { return }
        loadDecodeImage(image)
    }

    private func pickLogo() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        guard panel.runModal() == .OK, let url = panel.url, let image = NSImage(contentsOf: url) else { return }
        logo = image
    }

    private func copyPNG(_ data: Data) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setData(data, forType: .png)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }

    private func exportPNG(_ data: Data) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.nameFieldStringValue = "qrcode.png"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try data.write(to: url)
            exported = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { exported = false }
        } catch {
            NSAlert(error: error).runModal()
        }
    }
}

// MARK: - 取色器

/// 取色器：HSB 色区 + 屏幕取色 + HEX 反查；支持透明度
private struct ColorPickTool: View {
    @State private var color: NSColor = .systemBlue
    @State private var hexInput = ""
    @State private var copiedTag: String?

    @State private var padSize: CGSize = .zero

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 二维饱和度/明度色区：渐变独立于 GeometryReader 渲染，几何只用于游标定位
            ZStack {
                Rectangle()
                    .fill(Color(nsColor: NSColor(hue: CGFloat(hsb.h), saturation: 1, brightness: 1, alpha: 1)))
                LinearGradient(colors: [.white, .clear], startPoint: .leading, endPoint: .trailing)
                LinearGradient(colors: [.clear, .black], startPoint: .top, endPoint: .bottom)
                knob
                    .position(x: padSize.width * hsb.s, y: padSize.height * (1 - hsb.b))
            }
            .frame(height: 148)
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { padSize = geo.size }
                        .onChange(of: geo.size) { _, new in padSize = new }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let w = max(padSize.width, 1), h = max(padSize.height, 1)
                setHSB(s: clamp01(g.location.x / w), b: clamp01(1 - g.location.y / h))
            })

            // 色相条 + 透明度条
            HStack(spacing: 12) {
                strip(
                    background: AnyView(Capsule().fill(LinearGradient(
                        colors: (0...12).map { Color(hue: Double($0) / 12, saturation: 1, brightness: 1) },
                        startPoint: .leading, endPoint: .trailing))),
                    value: hsb.h,
                    onSet: { setHSB(h: $0) }
                )
                strip(
                    background: AnyView(ZStack {
                        checkerboard
                        Capsule().fill(LinearGradient(colors: [.clear, Color(nsColor: color)], startPoint: .leading, endPoint: .trailing))
                    }),
                    value: hsb.a,
                    onSet: { setHSB(a: $0) }
                )
            }
            .frame(height: 14)

            HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: color))
                    .frame(width: 34, height: 26)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                TextField(AppLanguage.localized("粘贴 HEX：#34ABCD / #34ABCD80 / #F90"), text: $hexInput)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit { applyHex() }
                Button(AppLanguage.localized("应用")) { applyHex() }
                    .controlSize(.small)
                if !hexInput.isEmpty && DevToolboxCore.color(fromHex: hexInput) == nil {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                Spacer(minLength: 8)
                Button(AppLanguage.localized("屏幕取色")) { sample() }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
            }

            VStack(alignment: .leading, spacing: 4) {
                copyable("HEX", DevToolboxCore.hexString(color), "hex")
                copyable(AppLanguage.localized("HEX+透明度"), DevToolboxCore.hexString(color, includeAlpha: true), "hexa")
                copyable("CSS", DevToolboxCore.cssRGBA(color), "css")
                plain(AppLanguage.localized("分量"), components)
            }
            .font(.system(size: 12, design: .monospaced))
        }
        .padding(14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    // MARK: 取色控件

    /// 圆形游标：白芯 + 灰描边，压在色区/色条上
    private var knob: some View {
        Circle()
            .fill(.white)
            .frame(width: 14, height: 14)
            .overlay(Circle().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1.5))
            .shadow(radius: 1)
    }

    /// 一维色条（色相/透明度共用）：拖动与点击直接改值
    private func strip(background: AnyView, value: Double, onSet: @escaping (Double) -> Void) -> some View {
        GeometryReader { geo in
            let w = max(geo.size.width, 1)
            ZStack {
                background
                knob
                    .frame(width: 12, height: 12)
                    .position(x: value * w, y: geo.size.height / 2)
            }
            .clipShape(Capsule())
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                onSet(clamp01(g.location.x / w))
            })
        }
    }

    /// 透明度条底下的棋盘格（透明区域的可视化）
    private var checkerboard: some View {
        Canvas { ctx, size in
            let side: CGFloat = 7
            for row in 0..<Int(ceil(size.height / side)) {
                for col in 0..<Int(ceil(size.width / side)) {
                    guard (row + col) % 2 == 0 else { continue }
                    let rect = CGRect(x: CGFloat(col) * side, y: CGFloat(row) * side, width: side, height: side)
                    ctx.fill(Path(rect), with: .color(Color(nsColor: .systemGray).opacity(0.35)))
                }
            }
        }
    }

    // MARK: 颜色 <-> HSB

    private struct HSB { var h = 0.58, s = 1.0, b = 1.0, a = 1.0 }

    private var hsb: HSB {
        let c = color.usingColorSpace(.sRGB) ?? color
        return HSB(h: Double(c.hueComponent), s: Double(c.saturationComponent), b: Double(c.brightnessComponent), a: Double(c.alphaComponent))
    }

    private func clamp01(_ v: CGFloat) -> Double { Double(min(max(v, 0), 1)) }

    /// 局部改 HSB 后写回 color（色区/色条拖动共用）
    private func setHSB(s: Double? = nil, b: Double? = nil, h: Double? = nil, a: Double? = nil) {
        var v = hsb
        if let s { v.s = s }
        if let b { v.b = b }
        if let h { v.h = h }
        if let a { v.a = a }
        color = NSColor(hue: CGFloat(v.h), saturation: CGFloat(v.s), brightness: CGFloat(v.b), alpha: CGFloat(v.a))
    }

    private var components: String {
        guard let c = color.usingColorSpace(.sRGB) else { return "" }
        func byte(_ v: CGFloat) -> Int { Int((v * 255).rounded()) }
        return "R \(byte(c.redComponent))  G \(byte(c.greenComponent))  B \(byte(c.blueComponent))  α \(Int((c.alphaComponent * 100).rounded()))%"
    }

    private func sample() {
        // 自研取色（ScreenEyedropper）：透明覆盖层+实时捕获，屏幕是活的，⌘Tab 可用。
        // NSColorSampler 的会话会锁死 ⌘Tab（实测），弃用。
        ScreenEyedropper.shared.pick { picked in
            color = picked
        }
    }

    private func applyHex() {
        if let parsed = DevToolboxCore.color(fromHex: hexInput) { color = parsed }
    }

    private func plain(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            Text(value).textSelection(.enabled)
        }
    }

    private func copyable(_ label: String, _ value: String, _ tag: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            Text(value)
            Spacer(minLength: 0)
            if copiedTag == tag {
                Image(systemName: "checkmark").font(.caption).foregroundStyle(.green)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
            copiedTag = tag
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { if copiedTag == tag { copiedTag = nil } }
        }
    }
}

/// 纯文本编辑器：关掉 NSTextView 出厂开启的自动替换（弯引号/破折号/文本替换/拼写纠正）。
/// 中文输入法下打 " 会被换成 “ ”，JSON 立刻非法——就是「输入被改了」的来源。
/// 同时不接受拖放：防止从输出区选文本时手滑把输入整段换掉（⌘V 粘贴不受影响）。
struct PlainTextView: NSViewRepresentable {
    @Binding var text: String

    func makeNSView(context: Context) -> NSScrollView {
        let tv = NSTextView()
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isAutomaticLinkDetectionEnabled = false
        tv.isAutomaticDataDetectionEnabled = false
        tv.registerForDraggedTypes([])
        tv.delegate = context.coordinator
        tv.string = text
        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let tv = scroll.documentView as? NSTextView, !context.coordinator.isEditing else { return }
        if tv.string != text { tv.string = text }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlainTextView
        var isEditing = false
        init(_ parent: PlainTextView) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            isEditing = true
            parent.text = tv.string
            isEditing = false
        }
    }
}

// MARK: - 密码

private struct PasswordTool: View {
    let tool: DevToolbox

    init(tool: DevToolbox) { self.tool = tool }

    @State private var items: [String] = []
    @State private var copiedIndex: Int?
    @State private var hovering: Int?
    @State private var lengthText: String = ""
    @State private var countText: String = ""

    private static let maxItems = 100

    private var length: Int {
        let parsed = Int(lengthText.trimmingCharacters(in: .whitespaces)) ?? 16
        return min(128, max(4, parsed))
    }

    private var count: Int {
        let parsed = Int(countText.trimmingCharacters(in: .whitespaces)) ?? 1
        return min(100, max(1, parsed))
    }

    private var poolEmpty: Bool { DevToolboxCore.PasswordGen.specialPool(tool.password).isEmpty && !tool.password.digits && !tool.password.lowercase && !tool.password.uppercase }

    var body: some View {
        @Bindable var tool = tool
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    Button {
                        generate()
                    } label: {
                        Label(AppLanguage.localized("生成"), systemImage: "arrow.clockwise")
                            .padding(.horizontal, 8)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    HStack(spacing: 4) {
                        Text(AppLanguage.localized("长度")).font(.caption).foregroundStyle(.secondary)
                        TextField("16", text: $lengthText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 46)
                            .onSubmit { generate() }
                        Text("4–128").font(.caption2).foregroundStyle(.tertiary)
                    }
                    HStack(spacing: 4) {
                        Text(AppLanguage.localized("数量")).font(.caption).foregroundStyle(.secondary)
                        TextField("1", text: $countText)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(width: 46)
                            .onSubmit { generate() }
                        Text("1–100").font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                HStack(spacing: 14) {
                    Toggle(AppLanguage.localized("数字"), isOn: $tool.password.digits).toggleStyle(.switch).controlSize(.mini)
                    Toggle(AppLanguage.localized("小写"), isOn: $tool.password.lowercase).toggleStyle(.switch).controlSize(.mini)
                    Toggle(AppLanguage.localized("大写"), isOn: $tool.password.uppercase).toggleStyle(.switch).controlSize(.mini)
                    Toggle(AppLanguage.localized("特殊字符"), isOn: $tool.password.special).toggleStyle(.switch).controlSize(.mini)
                }
                if tool.password.special {
                    HStack(spacing: 6) {
                        Text(AppLanguage.localized("字符集")).font(.caption).foregroundStyle(.secondary)
                        TextField("!@#$%^&*-_=+?", text: $tool.password.specialChars)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .frame(maxWidth: 220)
                        Text(AppLanguage.localized("已剔除 0 O i l I")).font(.caption2).foregroundStyle(.tertiary)
                    }
                }
                if poolEmpty {
                    Text(AppLanguage.localized("至少勾选一类字符，或补上特殊字符集")).font(.caption).foregroundStyle(.orange)
                }
            }
            .padding(12)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))

            if items.isEmpty {
                Text(AppLanguage.localized("随机密码生成器，四类字符各保底一个，其余从全池抽取"))
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else {
                HStack {
                    Text(String(format: AppLanguage.localized("点击结果复制 · 最多保留 %d 条"), Self.maxItems))
                        .font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                    Button {
                        items.removeAll()
                        copiedIndex = nil
                        hovering = nil
                    } label: {
                        Label(AppLanguage.localized("清空"), systemImage: "trash")
                            .font(.caption)
                    }
                    .buttonStyle(.borderless)
                    .controlSize(.small)
                    .foregroundStyle(.secondary)
                    .padding(.trailing, 8)
                }
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(items.indices, id: \.self) { i in
                            let pw = items[i]
                            HStack(spacing: 8) {
                                Text("#\(i + 1)")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 30, alignment: .leading)
                                Text(pw)
                                    .font(.system(size: 12, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.disabled)
                                Spacer(minLength: 6)
                                strengthBadge(pw)
                                if copiedIndex == i {
                                    Image(systemName: "checkmark")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.green)
                                }
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 30)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(hovering == i ? Color.accentColor.opacity(0.12) : Color.clear)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(pw, forType: .string)
                                copiedIndex = i
                            }
                            .onHover { h in hovering = h ? i : nil }
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            Spacer(minLength: 0)
        }
        .onAppear {
            lengthText = String(tool.password.length)
            countText = String(tool.password.count)
        }
    }

    /// 按当前字符池与长度估算熵，给个粗略强度指示
    private func strengthBadge(_ pw: String) -> some View {
        var pool = 0
        if tool.password.digits { pool += DevToolboxCore.PasswordGen.digitPool.count }
        if tool.password.lowercase { pool += DevToolboxCore.PasswordGen.lowerPool.count }
        if tool.password.uppercase { pool += DevToolboxCore.PasswordGen.upperPool.count }
        if tool.password.special { pool += DevToolboxCore.PasswordGen.specialPool(tool.password).count }
        let bits = Double(pw.count) * log2(Double(max(pool, 2)))
        let (label, color): (String, Color) = bits < 50 ? (AppLanguage.localized("弱"), .orange) : bits < 80 ? (AppLanguage.localized("中"), .yellow) : (AppLanguage.localized("强"), .green)
        return Text(label)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 7)
            .padding(.vertical, 1)
            .background(color.opacity(0.15), in: Capsule())
            .help(String(format: AppLanguage.localized("熵 ≈ %d bits"), Int(bits)))
    }

    private func generate() {
        var c = tool.password
        c.length = length
        c.count = count
        tool.password = c                    // 顺手把钳制后的值持久化
        var rng = SystemRandomNumberGenerator()
        let fresh = DevToolboxCore.PasswordGen.generate(c, rng: &rng)
        guard !fresh.isEmpty else { return }
        items.insert(contentsOf: fresh, at: 0)
        if items.count > Self.maxItems { items.removeLast(items.count - Self.maxItems) }
        copiedIndex = nil
    }
}
