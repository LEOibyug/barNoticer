import AppKit
import SwiftUI

struct IslandSettingsView: View {
    @AppStorage(IslandDisplayMode.storageKey) private var modeRawValue = IslandDisplayMode.standard.rawValue
    @State private var draft = IslandLayoutDraft.load(mode: .standard)

    private var selectedMode: IslandDisplayMode {
        IslandDisplayMode(rawValue: modeRawValue) ?? .standard
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                modeSection
                hotZoneSection
                islandSection
                debugSection
                resetButton
            }
            .padding(24)
            .frame(maxWidth: 680, alignment: .leading)
        }
        .onAppear {
            draft = IslandLayoutDraft.load(mode: selectedMode)
        }
        .onDisappear {
            IslandLayoutSettings.notifyChanged(previewKind: nil)
        }
        .onChange(of: modeRawValue) { _, _ in
            draft = IslandLayoutDraft.load(mode: selectedMode)
            IslandLayoutSettings.notifyLayoutChanged()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("岛设置")
                .font(.system(size: 28, weight: .semibold))
            Text("调整当前模式的鼠标唤起区域和展开面板位置。普通和宽体模式各自保存一套配置。")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var modeSection: some View {
        SettingsSection(title: "显示模式", subtitle: "宽体模式会把岛扩展为三倍宽，并按重要性分三列展示。") {
            Picker("显示模式", selection: $modeRawValue) {
                ForEach(IslandDisplayMode.allCases) { mode in
                    Label(mode.title, systemImage: mode.systemImage)
                        .tag(mode.rawValue)
                }
            }
            .pickerStyle(.segmented)
        }
    }

    private var hotZoneSection: some View {
        SettingsSection(title: "唤起区域", subtitle: "调整时会在屏幕顶部显示高亮边缘。") {
            SettingSlider("水平偏移", value: binding(\.hotZoneOffsetX), range: -360...360, previewKind: .hotZone, suffix: "px")
            SettingSlider("向下偏移", value: binding(\.hotZoneOffsetY), range: -24...180, previewKind: .hotZone, suffix: "px")
            SettingSlider("区域宽度", value: binding(\.hotZoneWidth), range: 120...520, previewKind: .hotZone, suffix: "px")
            SettingSlider("区域高度", value: binding(\.hotZoneHeight), range: 20...120, previewKind: .hotZone, suffix: "px")
        }
    }

    private var islandSection: some View {
        SettingsSection(title: "展开区域", subtitle: "调整时会直接显示实际岛面板。") {
            SettingSlider("水平偏移", value: binding(\.islandOffsetX), range: -640...640, previewKind: .island, suffix: "px")
            SettingSlider("向下偏移", value: binding(\.islandOffsetY), range: -24...220, previewKind: .island, suffix: "px")
            SettingSlider("顶部留白", value: binding(\.islandTopContentInset), range: 12...82, previewKind: .island, suffix: "px")
        }
    }

    private var resetButton: some View {
        Button {
            reset()
        } label: {
            Label("恢复默认", systemImage: "arrow.counterclockwise")
        }
        .buttonStyle(.bordered)
    }

    private var debugSection: some View {
        SettingsSection(title: "调试日志", subtitle: "应用会写入轻量调试日志，并自动清理过大的旧日志。") {
            VStack(alignment: .leading, spacing: 10) {
                Text(AppDebugLogStore.shared.logFileURL.path)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                Button {
                    openLogDirectory()
                } label: {
                    Label("打开日志位置", systemImage: "folder")
                }
                .buttonStyle(.bordered)
            }
        }
    }

    private func reset() {
        IslandLayoutDraft.reset(mode: selectedMode)
        draft = IslandLayoutDraft.load(mode: selectedMode)
        IslandLayoutSettings.notifyChanged(previewKind: nil)
    }

    private func binding(_ keyPath: WritableKeyPath<IslandLayoutDraft, Double>) -> Binding<Double> {
        Binding(
            get: { draft[keyPath: keyPath] },
            set: { newValue in
                draft[keyPath: keyPath] = newValue
                draft.save(mode: selectedMode)
            }
        )
    }

    private func openLogDirectory() {
        try? FileManager.default.createDirectory(at: AppDebugLogStore.shared.directory, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([AppDebugLogStore.shared.logFileURL])
    }
}

struct SettingsSection<Content: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 12) {
                content()
            }
        }
        .padding(16)
        .background(.quaternary.opacity(0.42), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

private struct SettingSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let previewKind: IslandLayoutSettings.PreviewKind
    let suffix: String
    @State private var isEditing = false

    init(
        _ title: String,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        previewKind: IslandLayoutSettings.PreviewKind,
        suffix: String
    ) {
        self.title = title
        _value = value
        self.range = range
        self.previewKind = previewKind
        self.suffix = suffix
    }

    var body: some View {
        HStack(spacing: 14) {
            Text(title)
                .frame(width: 76, alignment: .leading)

            Slider(
                value: $value,
                in: range,
                step: 1,
                onEditingChanged: { editing in
                    isEditing = editing
                    IslandLayoutSettings.notifyChanged(previewKind: editing ? previewKind : nil)
                }
            )

            Text("\(Int(value))\(suffix)")
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 64, alignment: .trailing)
        }
        .onChange(of: value) { _, _ in
            if isEditing {
                IslandLayoutSettings.notifyChanged(previewKind: previewKind)
            } else {
                IslandLayoutSettings.notifyLayoutChanged()
            }
        }
    }
}

#Preview {
    IslandSettingsView()
}
