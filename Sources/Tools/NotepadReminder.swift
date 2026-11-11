import AppKit
import SwiftUI

/// 记事本提醒：到点未处理的记录在屏幕右上角浮出便签（层级最高、不抢焦点）。
///
/// 便签右上角 ×：确认「是否已处理」，确认后标记已处理，便签消失；
/// 点便签主体：弹出开发者工具箱并跳到记事本。
@MainActor
final class NotepadReminder {
    private let store: NotepadStore
    /// 点便签主体 → 唤起工具箱记事本
    var onOpen: ((UUID) -> Void)?

    private var panel: StickyPanel?
    /// 跟随工具箱开关：工具关了不出便签
    var active = false { didSet { refresh() } }

    /// 便签尺寸（单张）
    static let cardWidth: CGFloat = 260
    static let cardHeight: CGFloat = 92
    static let maxCards = 5

    init(store: NotepadStore) {
        self.store = store
        store.onChange = { [weak self] in self?.refresh() }
        refresh()
    }

    /// 按 store 当前的到点集合重排便签（关掉不再到点的，补上新到点的）
    func refresh() {
        let due = store.dueNotes
        guard active, !due.isEmpty else {
            panel?.orderOut(nil)
            return
        }
        let shown = Array(due.prefix(Self.maxCards))
        let size = NSSize(
            width: Self.cardWidth + 16,
            height: CGFloat(shown.count) * (Self.cardHeight + 8) - 8 + 16
        )
        let panel = self.panel ?? StickyPanel(size: size)
        self.panel = panel
        panel.setContentSize(size)
        panel.set(
            rootView: StickyList(notes: shown, overflow: due.count - shown.count,
                                 onOpen: { [weak self] id in self?.onOpen?(id) },
                                 onHandle: { [weak self] id in self?.store.markHandled(id) }),
            size: size
        )
        panel.positionTopRight()
        panel.orderFrontRegardless()
    }

    /// × 的确认框：LSUIElement app 不激活的话模态框会落在别的 app 后面
    fileprivate static func confirmHandled(_ note: NotepadNote, onConfirm: @escaping () -> Void) {
        let alert = NSAlert()
        alert.messageText = AppLanguage.localized("这条提醒处理完了？")
        alert.informativeText = note.text
        alert.alertStyle = .informational
        alert.addButton(withTitle: AppLanguage.localized("已处理"))
        alert.addButton(withTitle: AppLanguage.localized("取消"))
        alert.window.level = .screenSaver   // 盖在便签上面
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn { onConfirm() }
    }
}

// MARK: - 窗口

/// 右上角便签窗：置顶、不激活 app、所有空间可见
final class StickyPanel: NSPanel {
    init(size: NSSize) {
        super.init(contentRect: NSRect(origin: .zero, size: size),
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .screenSaver
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false          // 每张便签自己有投影，整窗不要再叠一层
        isMovableByWindowBackground = false
        animationBehavior = .none
        hidesOnDeactivate = false
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private var hosting: NSHostingView<StickyList>?

    func set(rootView: StickyList, size: NSSize) {
        if let hosting {
            hosting.rootView = rootView
        } else {
            let host = NSHostingView(rootView: rootView)
            host.sizingOptions = []
            host.frame = NSRect(origin: .zero, size: size)
            host.autoresizingMask = [.width, .height]
            contentView = host
            hosting = host
        }
    }

    /// 屏幕右上角（菜单栏下方），多显示器用主屏
    func positionTopRight() {
        guard let screen = NSScreen.main else { return }
        let visible = screen.visibleFrame
        setFrameOrigin(NSPoint(x: visible.maxX - frame.width - 16,
                               y: visible.maxY - frame.height - 16))
    }
}

// MARK: - 便签内容

struct StickyList: View {
    let notes: [NotepadNote]
    let overflow: Int
    let onOpen: (UUID) -> Void
    let onHandle: (UUID) -> Void

    var body: some View {
        VStack(spacing: 8) {
            ForEach(notes) { note in
                StickyCard(note: note,
                           onOpen: { onOpen(note.id) },
                           onClose: {
                               NotepadReminder.confirmHandled(note) { onHandle(note.id) }
                           })
            }
            if overflow > 0 {
                Text(String(format: AppLanguage.localized("还有 %d 条到点提醒"), overflow))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

private struct StickyCard: View {
    let note: NotepadNote
    let onOpen: () -> Void
    let onClose: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(note.text)
                        .font(.system(size: 12.5))
                        .foregroundStyle(.black.opacity(0.85))
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Spacer(minLength: 0)
                    if let remindAt = note.remindAt {
                        Label(NotepadNote.timeFormatter.string(from: remindAt), systemImage: "alarm")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.red)
                    }
                }
                .padding(10)
                .frame(width: NotepadReminder.cardWidth, height: NotepadReminder.cardHeight, alignment: .topLeading)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(Color(red: 1, green: 0.93, blue: 0.55))   // 便签黄
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(.black.opacity(0.08)))
                        .shadow(color: .black.opacity(0.25), radius: 8, y: 2)
                )
                .contentShape(RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.black.opacity(0.5))
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(AppLanguage.localized("处理完了"))
        }
    }
}
