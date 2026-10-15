import SwiftUI

/// 魔法剪贴板设置页
struct MagicClipboardView: View {
    let tool: MagicClipboard
    @State private var confirmingClear = false
    @AppStorage(AppLanguage.storageKey) private var languageRaw = AppLanguage.systemLanguage.rawValue

    private func tr(_ key: String) -> String { AppLanguage.localized(key, languageRaw: languageRaw) }

    var body: some View {
        @Bindable var tool = tool
        Form {
            Section {
                Toggle(tr("启用魔法剪贴板"), isOn: $tool.enabled)
            } footer: {
                Text(String(format: tr("自动记录剪贴板历史，%@ 唤起历史窗口。"), tool.trigger.display))
            }

            Section {
                HStack {
                    Text(tr("唤起窗口"))
                    Spacer()
                    Text(tool.recorder.isRecording ? tr("按下组合键或双击修饰键…") : tool.trigger.display)
                        .font(.system(.body, design: .rounded).weight(.medium))
                        .foregroundStyle(tool.recorder.isRecording ? .secondary : .primary)
                    Button(tool.recorder.isRecording ? tr("取消") : tr("录制")) {
                        if tool.recorder.isRecording {
                            tool.recorder.stop()
                        } else {
                            tool.recorder.start { trigger in tool.trigger = trigger }
                        }
                    }
                    Button(tr("重置")) { tool.resetTrigger() }
                }
                if let failure = tool.triggerFailure {
                    Text(failure)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                Text(tr("快捷键"))
            } footer: {
                Text(tr("组合键（至少一个 ⌘ / ⌃ / ⌥）不需要任何系统权限；双击单个修饰键需要辅助功能与输入监控权限。"))
            }

            if tool.trigger.needsEventTap && tool.triggerFailure != nil {
                permissionSection(tool)
            }

            Section {
                Picker(tr("占用上限"), selection: $tool.maxBytes) {
                    ForEach(MagicClipboard.sizePresets, id: \.bytes) { preset in
                        Text(tr(preset.title)).tag(preset.bytes)
                    }
                }
                Picker(tr("保留时间"), selection: $tool.retention) {
                    ForEach(ClipRetention.allCases) { retention in
                        Text(tr(retention.title)).tag(retention)
                    }
                }
                LabeledContent(tr("当前占用")) {
                    Text(String(format: tr("%d 条 · %@"), tool.store.items.count, ClipboardPickerView.size(tool.store.storedBytes)))
                }
            } header: {
                Text(tr("存储"))
            } footer: {
                Text(tr("超出占用上限或保留时间后，从最早的记录开始自动删除。文件和视频只记录引用，不复制内容。"))
            }

            Section {
                Button(tr("打开剪贴板窗口")) { tool.showPicker() }
                Button(tr("清空历史"), role: .destructive) { confirmingClear = true }
                    .disabled(tool.store.items.isEmpty)
            }
        }
        .formStyle(.grouped)
        .onAppear { tool.refreshPermission() }
        .clearHistoryConfirmation(isPresented: $confirmingClear, count: tool.store.items.count, languageRaw: languageRaw) { tool.clear() }
    }
}

extension View {
    /// 「清空历史」二次确认：点按钮只置标志，确认后才真清空（列表窗与设置页共用，文案与行为不分叉）
    func clearHistoryConfirmation(isPresented: Binding<Bool>, count: Int, languageRaw: String = AppLanguage.stored.rawValue, clear: @escaping () -> Void) -> some View {
        let tr = { AppLanguage.localized($0, languageRaw: languageRaw) }
        return confirmationDialog(tr("清空全部剪贴板历史？"), isPresented: isPresented, titleVisibility: .visible) {
            Button(String(format: tr("清空 %d 条记录"), count), role: .destructive, action: clear)
            Button(tr("取消"), role: .cancel) {}
        } message: {
            Text(tr("删除后无法恢复，占用上限与保留时间设置不受影响。"))
        }
    }
}

#Preview {
    MagicClipboardView(tool: .shared)
        .frame(width: 520, height: 520)
}
