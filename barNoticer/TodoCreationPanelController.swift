import AppKit
import Carbon.HIToolbox
import SwiftData
import SwiftUI

@MainActor
final class TodoCreationPanelController: NSObject {
    private let modelContext: ModelContext
    private var panel: NSPanel?
    private var presentationGeneration = 0
    private var contentHeight: CGFloat = TodoCreationPanelChrome.baseHeight
    private var presentationScreenNumber: NSNumber?
    private var isClosing = false

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screenParametersChanged), name: IslandLayoutSettings.didChangeNotification, object: nil)
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        Task { @MainActor [panel] in
            panel?.orderOut(nil)
        }
    }

    func toggle() {
        if panel?.isVisible == true {
            close()
        } else {
            show()
        }
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        presentationGeneration += 1
        let generation = presentationGeneration
        isClosing = false
        let screen = ScreenTargeting.currentPointerScreen()
        presentationScreenNumber = ScreenTargeting.screenNumber(of: screen)
        applyFrame(animated: false)
        let expandedFrame = panel.frame
        if !MotionPreferences.reduceMotion {
            panel.setFrame(TodoCreationPanelChrome.collapsedFrame(for: expandedFrame), display: true)
        }
        panel.alphaValue = 0
        NotchPopupPresence.setVisible(true, owner: self)
        panel.makeKeyAndOrderFront(nil)

        NSAnimationContext.runAnimation(duration: 0.22, timing: CAMediaTimingFunction(name: .easeOut)) {
            panel.animator().setFrame(expandedFrame, display: true)
            panel.animator().alphaValue = 1
        } completion: { [weak self, weak panel] in
            Task { @MainActor [weak self, weak panel] in
                guard let self, let panel, self.presentationGeneration == generation, !self.isClosing else { return }
                self.setContentHeight(self.contentHeight, on: panel, animated: false)
            }
        }
    }

    func close() {
        guard let panel, panel.isVisible, !isClosing else { return }
        isClosing = true
        presentationGeneration += 1
        let generation = presentationGeneration
        // 关闭动画期间重新打开时，旧 completion 不得再隐藏新窗口。
        NSAnimationContext.runAnimation(duration: 0.14, timing: CAMediaTimingFunction(name: .easeIn)) {
            if !MotionPreferences.reduceMotion {
                panel.animator().setFrame(TodoCreationPanelChrome.collapsedFrame(for: panel.frame), display: true)
            }
            panel.animator().alphaValue = 0
        } completion: { [weak self, weak panel] in
            Task { @MainActor [weak self, weak panel] in
                guard let self, self.presentationGeneration == generation, let panel else { return }
                panel.orderOut(nil)
                self.isClosing = false
                NotchPopupPresence.setVisible(false, owner: self)
            }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = FocusableTodoCreationPanel(
            contentRect: CGRect(origin: .zero, size: TodoCreationPanelChrome.baseSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        panel.onResignFocus = { [weak self] in
            self?.close()
        }
        panel.onCancel = { [weak self] in
            self?.close()
        }
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        // 系统窗口阴影作为唯一阴影来源，内容层不再叠加 SwiftUI 阴影。
        panel.hasShadow = true
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true

        let hostingView = NSHostingView(rootView: TodoCreationPanelView(modelContext: modelContext, onContentHeightChange: { [weak self, weak panel] height in
            guard let self, let panel else { return }
            self.setContentHeight(height, on: panel, animated: true)
        }) { [weak self] in
            self?.close()
        }.environment(\.modelContext, modelContext))
        hostingView.wantsLayer = true
        hostingView.layer?.masksToBounds = true
        hostingView.layer?.cornerRadius = TodoCreationPanelChrome.cornerRadius
        hostingView.layer?.cornerCurve = .continuous
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hostingView
        return panel
    }

    @objc private func screenParametersChanged() {
        guard panel?.isVisible == true, !isClosing else { return }
        applyFrame(animated: false)
    }

    private func applyFrame(animated: Bool) {
        guard let panel else { return }
        setContentHeight(contentHeight, on: panel, animated: animated)
    }

    /// Keep the notch-side top edge fixed as schedule fields expand downward.
    private func setContentHeight(_ height: CGFloat, on panel: NSPanel, animated: Bool) {
        contentHeight = height
        guard !isClosing else { return }
        let screen = ScreenTargeting.resolvedScreen(pinnedNumber: &presentationScreenNumber)
        let fallback = CGRect(x: 0, y: 0, width: 1_280, height: 800)
        let frame = TodoCreationPanelChrome.frame(
            contentHeight: height,
            screenFrame: screen?.frame ?? fallback,
            visibleFrame: screen?.visibleFrame ?? fallback,
            safeAreaTopInset: screen?.safeAreaInsets.top ?? 0,
            settings: IslandLayoutSettings(defaults: .standard)
        )

        if animated, panel.isVisible {
            NSAnimationContext.runAnimation(duration: 0.2, timing: CAMediaTimingFunction(name: .easeInEaseOut)) {
                panel.animator().setFrame(frame, display: true)
            }
        } else {
            panel.setFrame(frame, display: true)
        }
    }
}

enum TodoCreationPanelChrome {
    static let baseSize = CGSize(width: 640, height: 300)
    static let baseHeight: CGFloat = 300
    static let cornerRadius: CGFloat = 24

    static func frame(
        contentHeight: CGFloat,
        screenFrame: CGRect,
        visibleFrame: CGRect,
        safeAreaTopInset: CGFloat,
        settings: IslandLayoutSettings
    ) -> CGRect {
        let margin = min(12, min(visibleFrame.width, visibleFrame.height) / 4)
        let available = visibleFrame.insetBy(dx: margin, dy: margin)
        let hotZone = settings.hotZoneFrame(in: screenFrame)
        let safeTop = min(available.maxY, screenFrame.maxY - safeAreaTopInset - 8)
        let top = min(safeTop, max(hotZone.minY - 8, available.minY + min(160, available.height)))
        let width = min(baseSize.width, available.width)
        let height = min(max(contentHeight, 160), top - available.minY)
        return CGRect(
            x: min(max(hotZone.midX - width / 2, available.minX), available.maxX - width),
            y: top - height,
            width: width,
            height: height
        )
    }

    static func collapsedFrame(for frame: CGRect) -> CGRect {
        let height = min(48, frame.height)
        return CGRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height)
    }
}

private final class FocusableTodoCreationPanel: NSPanel {
    var onResignFocus: (() -> Void)?
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }

    override func resignKey() {
        super.resignKey()
        onResignFocus?()
    }

    override func resignMain() {
        super.resignMain()
        onResignFocus?()
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            onCancel?()
            return
        }

        super.keyDown(with: event)
    }
}

private struct TodoCreationPanelView: View {
    let modelContext: ModelContext
    let onContentHeightChange: (CGFloat) -> Void
    let close: () -> Void

    @Query private var storedGroups: [TodoGroup]
    @State private var title = ""
    @State private var note = ""
    @State private var priority: TodoPriority = .medium
    @State private var groupID = TodoGroup.defaultGroupID
    @State private var scheduleDraft = TodoScheduleDraft()
    @State private var saveErrorText: String?
    @FocusState private var isTitleFocused: Bool
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var groups: [TodoGroup] {
        TodoGroupResolver.normalizedGroups(storedGroups)
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ScrollView {
            content
                .fixedSize(horizontal: false, vertical: true)
                .padding(20)
                .frame(maxWidth: TodoCreationPanelChrome.baseSize.width, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { _, height in
                    onContentHeightChange(height)
                }
        }
        .scrollIndicators(.automatic)
        .background {
            if reduceTransparency {
                RoundedRectangle(cornerRadius: TodoCreationPanelChrome.cornerRadius, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
            } else {
                RoundedRectangle(cornerRadius: TodoCreationPanelChrome.cornerRadius, style: .continuous)
                    .fill(.regularMaterial)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: TodoCreationPanelChrome.cornerRadius, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.45), lineWidth: 0.5)
        }
        .onAppear {
            groupID = groups.first?.id ?? TodoGroup.defaultGroupID
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isTitleFocused = true
            }
        }
    }

    /// 任务内容 → 可选安排 → 提交；标题独占主要横向空间。
    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            titleField
            metadataRow
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                controls
                TodoScheduleEditor(draft: $scheduleDraft, layout: .compact)
                if scheduleDraft.supportsReminder {
                    TodoReminderEditor(minutesBefore: $scheduleDraft.reminderMinutesBefore, isRecurring: scheduleDraft.kind == .recurring)
                        .frame(height: 30, alignment: .leading)
                }
            }
            noteField
            if let saveErrorText {
                Label(saveErrorText, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
    }

    private var header: some View {
        HStack {
            Label("新建事项", systemImage: "plus.circle.fill")
                .font(.headline)
                .foregroundStyle(.primary)

            Spacer()

            Button {
                close()
            } label: {
                HStack(spacing: 6) {
                    Text("esc")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                }
                .padding(7)
                .background(.quinary, in: Capsule())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .accessibilityLabel("关闭")
            .help("关闭（Esc）")
        }
    }

    private var titleField: some View {
        TextField("输入待办标题", text: $title)
            .font(.system(size: 16, weight: .semibold))
            .textFieldStyle(.plain)
            .foregroundStyle(.primary)
            .focused($isTitleFocused)
            .onSubmit(submit)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.quinary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isTitleFocused ? Color.accentColor.opacity(0.55) : Color(nsColor: .separatorColor).opacity(0.5), lineWidth: 1)
            }
    }

    private var metadataRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                priorityPicker
                groupPicker
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 8) {
                priorityPicker
                groupPicker
            }
        }
    }

    private var priorityPicker: some View {
        Picker("重要性", selection: $priority) {
            ForEach(TodoPriority.allCases) { priority in
                Label(priority.title, systemImage: priority.systemImage)
                    .tag(priority)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 178)
    }

    private var groupPicker: some View {
        Picker("分组", selection: $groupID) {
            ForEach(groups) { group in
                Text(group.name).tag(group.id)
            }
        }
        .frame(maxWidth: 140)
    }

    private var noteField: some View {
        TextEditor(text: $note)
            .font(.system(size: 13))
            .foregroundStyle(.primary)
            .scrollContentBackground(.hidden)
            .frame(height: 52)
            .padding(7)
            .background(.quinary.opacity(0.7), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor).opacity(0.4), lineWidth: 1)
            }
            .overlay(alignment: .topLeading) {
                if note.isEmpty {
                    Text("备注，可选")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 13)
                        .padding(.vertical, 14)
                        .allowsHitTesting(false)
                }
            }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            // 不固定宽度，完整显示“无时间 / 多个时间点”等日程类型名称。
            Picker("时间计划", selection: $scheduleDraft.kind) {
                ForEach(TodoScheduleKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.menu)
            .fixedSize()
            Spacer(minLength: 0)
        }
        .controlSize(.small)
    }

    private var footer: some View {
        HStack {
            Spacer(minLength: 0)
            Button {
                submit()
            } label: {
                HStack(spacing: 8) {
                    Text("添加")
                    Text("⌘↩")
                        .font(.system(size: 11, weight: .medium))
                        .opacity(0.8)
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.regular)
            .help("添加（标题中按 Return，或 ⌘Return）")
            .disabled(trimmedTitle.isEmpty)
            .accessibilityLabel("添加")
            .keyboardShortcut(.return, modifiers: .command)
        }
    }

    private func submit() {
        guard !trimmedTitle.isEmpty else { return }

        var deadlineAt: Date?
        var scheduledTimes: [Date] = []
        var recurrenceRule: TodoRecurrenceRule?
        var recurrenceAnchor: Date?
        switch scheduleDraft.effectivePayload {
        case .none:
            break
        case let .single(deadline):
            deadlineAt = deadline
        case let .multiple(times):
            scheduledTimes = times
        case let .recurring(rule, anchor):
            recurrenceRule = rule
            recurrenceAnchor = anchor
        }

        let item = TodoItem(
            title: trimmedTitle,
            note: note,
            priority: priority,
            groupID: groupID,
            deadlineAt: deadlineAt,
            scheduledTimes: scheduledTimes,
            recurrenceRule: recurrenceRule,
            recurrenceAnchor: recurrenceAnchor,
            reminderMinutesBefore: scheduleDraft.effectiveReminderMinutesBefore,
            automaticallyCompletes: scheduleDraft.effectiveAutomaticCompletion
        )
        item.advanceAutomaticOccurrences()
        modelContext.insert(item)
        do {
            try modelContext.save()
            saveErrorText = nil
            close()
        } catch {
            // 撤回本次插入：输入保留在面板里，重试只插入一个草稿对象。
            modelContext.delete(item)
            try? AppDebugLogStore.shared.write(.error, category: "TodoCreation", message: "保存新事项失败", metadata: ["error": error.localizedDescription])
            saveErrorText = "未能保存。内容已保留，请重试。"
        }
    }
}
