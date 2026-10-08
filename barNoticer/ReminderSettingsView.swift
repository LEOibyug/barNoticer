import SwiftUI

struct ReminderSettingsView: View {
    @State private var settings = ReminderSettings(defaults: .standard)
    @State private var showsHaloBoundary = false

    var body: some View {
        SettingsPage(title: "提醒设置", subtitle: "任务定时提醒由本地触发，不依赖 AI。") {
            scheduledSection
            aiSection
            presentationSection
            haloSection
            panelSection
        }
        .onReceive(NotificationCenter.default.publisher(for: ReminderSettings.didChangeNotification)) { _ in
            settings = ReminderSettings(defaults: .standard)
        }
        .onChange(of: settings) { _, _ in
            if showsHaloBoundary { previewHaloBoundary() }
        }
        .onDisappear {
            showsHaloBoundary = false
            ReminderSettings.endPresentationPreview()
        }
    }

    private var scheduledSection: some View {
        SettingsSection(
            title: "任务定时提醒",
            footer: "在单次 DDL 或重复事项的新建或设置界面选择提前多久提醒。重复事项完成本次后会自动继承到下一次，直到关闭提醒。由本地定时触发，不依赖 AI 判断；关闭 AI 主动提醒不影响这里的功能。"
        ) {
            Toggle("使用 AI 编写定时提醒文案", isOn: binding(\.scheduledAIWordingEnabled))
        }
    }

    private var aiSection: some View {
        SettingsSection(
            title: "AI 主动提醒",
            footer: "开启后启用后台 AI 轮询和自动 DDL 判断，DDL 会在提前 1 天和提前 12 小时进入 AI 判断。关闭后仅停止 AI 轮询，任务中主动设置的定时提醒仍按时触发。"
        ) {
            Toggle("启用后台 AI 提醒判断", isOn: binding(\.aiPollingEnabled))

            Picker("轮询频率", selection: binding(\.pollingInterval)) {
                Text("15 分钟").tag(TimeInterval(900))
                Text("30 分钟").tag(TimeInterval(1_800))
                Text("1 小时").tag(TimeInterval(3_600))
                Text("2 小时").tag(TimeInterval(7_200))
            }
            .disabled(!settings.aiPollingEnabled)

            Picker("提醒风格", selection: binding(\.tone)) {
                ForEach(ReminderTone.allCases) { tone in
                    Text(tone.title).tag(tone)
                }
            }
        }
    }

    private var presentationSection: some View {
        SettingsSection(
            title: "提醒呈现",
            footer: "光晕从岛的边缘柔和扩散。开启“减少动态效果”后直接显示提醒。"
        ) {
            Toggle("发送系统通知", isOn: binding(\.systemNotificationsEnabled))

            Picker("重复提醒间隔", selection: binding(\.dedupeWindow)) {
                Text("15 分钟").tag(TimeInterval(900))
                Text("30 分钟").tag(TimeInterval(1_800))
                Text("1 小时").tag(TimeInterval(3_600))
                Text("2 小时").tag(TimeInterval(7_200))
            }

            Button {
                showsHaloBoundary = false
                ReminderSettings.endPresentationPreview()
                ReminderPresentationPreviewAction.trigger(hotZoneFlashExpansion: settings.hotZoneFlashExpansion)
            } label: {
                Label(ReminderPresentationPreviewAction.title, systemImage: "bell.badge")
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var haloSection: some View {
        SettingsSection(
            title: "光晕边界",
            footer: "参考线表示发光边缘，光会向两侧扩散。偏移以收起的岛为基准，正值向右、向下；可输入精确数值（pt）。调整后参考线会保持显示，关闭此页后自动隐藏。"
        ) {
            Toggle("显示边界参考线", isOn: Binding(
                get: { showsHaloBoundary },
                set: { show in
                    showsHaloBoundary = show
                    if show { previewHaloBoundary() }
                    else { ReminderSettings.endPresentationPreview() }
                }
            ))
            Toggle("自定义边界", isOn: Binding(
                get: { settings.haloBoundary.isCustom },
                set: { custom in
                    settings.haloBoundary.isCustom = custom
                    settings.save()
                    showsHaloBoundary = true
                    previewHaloBoundary()
                }
            ))

            if settings.haloBoundary.isCustom {
                HaloBoundaryControl("水平偏移", value: haloBinding(\.haloBoundary.offsetX), range: -420...420)
                HaloBoundaryControl("向下偏移", value: haloBinding(\.haloBoundary.offsetY), range: -160...300)
                HaloBoundaryControl("边界宽度", value: haloBinding(\.haloBoundary.width), range: 40...900)
                HaloBoundaryControl("边界高度", value: haloBinding(\.haloBoundary.height), range: 12...400)
                HaloBoundaryControl("边界圆角", value: haloBinding(\.haloBoundary.cornerRadius), range: 0...100)
            } else {
                HaloBoundaryControl("边界外扩", value: haloBinding(\.hotZoneFlashExpansion), range: 0...80)
            }

            Button("对齐收起的岛") { alignHaloToIsland(expansion: 0) }
                .buttonStyle(.bordered)
        }
    }

    private func alignHaloToIsland(expansion: Double) {
        let layout = IslandLayoutSettings(defaults: .standard)
        settings.haloBoundary = ReminderHaloBoundary(isCustom: true,
            offsetX: 0, offsetY: -expansion,
            width: layout.hotZoneWidth + 2 * expansion,
            height: layout.hotZoneHeight + 2 * expansion, cornerRadius: 24)
        settings.save()
        showsHaloBoundary = true
        previewHaloBoundary()
    }

    private func previewHaloBoundary() {
        ReminderSettings.requestBoundaryPreview(hotZoneFlashExpansion: settings.hotZoneFlashExpansion)
    }

    private func haloBinding(_ keyPath: WritableKeyPath<ReminderSettings, Double>) -> Binding<Double> {
        Binding(get: { settings[keyPath: keyPath] }, set: { value in
            guard value.isFinite else { return }
            settings[keyPath: keyPath] = value
            settings.save()
            showsHaloBoundary = true
            previewHaloBoundary()
        })
    }

    private var panelSection: some View {
        SettingsSection(
            title: "提醒窗口",
            footer: "调整时会直接显示提醒面板，方便对齐刘海延伸效果。AI 文案到点未生成或 AI 不可用时使用本地文案，不会延迟或取消提醒。"
        ) {
            ReminderSettingSlider("水平偏移", value: binding(\.reminderPanelOffsetX), range: -420...420, suffix: "px", preview: previewReminderPanel)
            ReminderSettingSlider("向下偏移", value: binding(\.reminderPanelOffsetY), range: -24...220, suffix: "px", preview: previewReminderPanel)
            ReminderSettingSlider("窗口宽度", value: binding(\.reminderPanelWidth), range: 320...680, suffix: "px", preview: previewReminderPanel)
            ReminderSettingSlider("顶部留白", value: binding(\.reminderPanelTopContentInset), range: 12...82, suffix: "px", preview: previewReminderPanel)
            ReminderSettingSlider("持续时间", value: binding(\.reminderPanelAutoCloseDelay), range: 1...15, suffix: "秒", preview: previewReminderPanel)
        }
    }

    private func previewReminderPanel() {
        showsHaloBoundary = false
        ReminderSettings.requestPanelPreview()
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

private struct HaloBoundaryControl: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>

    init(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) {
        self.title = title
        _value = value
        self.range = range
    }

    private var boundedValue: Binding<Double> {
        Binding(get: { value }, set: { number in
            guard number.isFinite else { return }
            value = min(range.upperBound, max(range.lowerBound, number))
        })
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(title).frame(width: 96, alignment: .leading)
            Slider(value: boundedValue, in: range, step: 1)
                .accessibilityLabel(title)
            TextField(title, value: boundedValue, format: .number.precision(.fractionLength(0)))
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.trailing)
                .monospacedDigit()
                .frame(width: 64)
            Stepper(title, value: boundedValue, in: range, step: 1)
                .labelsHidden()
        }
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
                .monospacedDigit()
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
