import SwiftUI

struct ReminderSettingsView: View {
    @State private var settings = ReminderSettings(defaults: .standard)

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                SettingsSection(title: "AI 主动提醒", subtitle: "关闭后停止 AI 轮询和自动 DDL 判断，不影响任务中主动设置的定时提醒。") {
                    Toggle("启用后台 AI 提醒判断", isOn: binding(\.aiPollingEnabled))
                    Picker("轮询频率", selection: binding(\.pollingInterval)) {
                        Text("15 分钟").tag(TimeInterval(900))
                        Text("30 分钟").tag(TimeInterval(1_800))
                        Text("1 小时").tag(TimeInterval(3_600))
                        Text("2 小时").tag(TimeInterval(7_200))
                    }
                    Picker("提醒风格", selection: binding(\.tone)) {
                        ForEach(ReminderTone.allCases) { tone in
                            Text(tone.title).tag(tone)
                        }
                    }
                }

                SettingsSection(title: "任务定时提醒", subtitle: "在单次 DDL 任务的新建或设置界面选择提前多久提醒。由本地定时触发，不依赖 AI 判断。") {
                    Toggle("使用 AI 编写定时提醒文案", isOn: binding(\.scheduledAIWordingEnabled))
                    Text("开启后会提前调用 AI 生成文案。到点时文案尚未生成或 AI 不可用，会使用本地文案；不会延迟或取消提醒。应用需保持运行，休眠期间错过的提醒会在唤醒后补发一次。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                SettingsSection(title: "提醒呈现", subtitle: "测试提醒会展示完整热区闪烁和提醒面板；调整外扩时只显示范围边界。") {
                    Toggle("发送系统通知", isOn: binding(\.systemNotificationsEnabled))
                    Picker("重复提醒间隔", selection: binding(\.dedupeWindow)) {
                        Text("15 分钟").tag(TimeInterval(900))
                        Text("30 分钟").tag(TimeInterval(1_800))
                        Text("1 小时").tag(TimeInterval(3_600))
                        Text("2 小时").tag(TimeInterval(7_200))
                    }

                    ReminderSettingSlider(
                        "热区闪烁外扩",
                        value: binding(\.hotZoneFlashExpansion),
                        range: 0...80,
                        suffix: "px",
                        preview: { ReminderSettings.requestBoundaryPreview(hotZoneFlashExpansion: settings.hotZoneFlashExpansion) }
                    )

                    Button {
                        ReminderPresentationPreviewAction.trigger(hotZoneFlashExpansion: settings.hotZoneFlashExpansion)
                    } label: {
                        Label(ReminderPresentationPreviewAction.title, systemImage: "bell.badge")
                    }
                    .buttonStyle(.borderedProminent)
                }

                SettingsSection(title: "提醒窗口", subtitle: "调整时会直接显示提醒面板，方便对齐刘海延伸效果。") {
                    ReminderSettingSlider("水平偏移", value: binding(\.reminderPanelOffsetX), range: -420...420, suffix: "px", preview: ReminderSettings.requestPanelPreview)
                    ReminderSettingSlider("向下偏移", value: binding(\.reminderPanelOffsetY), range: -24...220, suffix: "px", preview: ReminderSettings.requestPanelPreview)
                    ReminderSettingSlider("窗口宽度", value: binding(\.reminderPanelWidth), range: 320...680, suffix: "px", preview: ReminderSettings.requestPanelPreview)
                    ReminderSettingSlider("顶部留白", value: binding(\.reminderPanelTopContentInset), range: 12...82, suffix: "px", preview: ReminderSettings.requestPanelPreview)
                    ReminderSettingSlider("持续时间", value: binding(\.reminderPanelAutoCloseDelay), range: 1...15, suffix: "秒", preview: ReminderSettings.requestPanelPreview)
                }

                Text("启用 AI 主动提醒时，DDL 会在提前 1 天和提前 12 小时进入 AI 判断。任务主动设置的提醒按各自时间独立触发。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: 680, alignment: .leading)
        }
        .navigationTitle("提醒设置")
        .onReceive(NotificationCenter.default.publisher(for: ReminderSettings.didChangeNotification)) { _ in
            settings = ReminderSettings(defaults: .standard)
        }
        .onDisappear {
            ReminderSettings.endPresentationPreview()
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<ReminderSettings, Value>) -> Binding<Value> {
        Binding(
            get: { settings[keyPath: keyPath] },
            set: { newValue in
                settings[keyPath: keyPath] = newValue
                settings.save()
            }
        )
    }
}

private struct ReminderSettingSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let suffix: String
    var preview: () -> Void
    @State private var isEditing = false

    init(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        suffix: String,
        preview: @escaping () -> Void
    ) {
        self.title = title
        _value = value
        self.range = range
        self.suffix = suffix
        self.preview = preview
    }

    var body: some View {
        HStack(spacing: 14) {
            Text(title)
                .frame(width: 96, alignment: .leading)

            Slider(
                value: $value,
                in: range,
                step: 1,
                onEditingChanged: { editing in
                    isEditing = editing
                    if editing {
                        preview()
                    } else {
                        ReminderSettings.endPresentationPreview()
                    }
                }
            )

            Text("\(Int(value))\(suffix)")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
        }
        .onChange(of: value) { _, _ in
            if isEditing {
                preview()
            }
        }
    }
}

#Preview {
    ReminderSettingsView()
}
