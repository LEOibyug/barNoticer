import AppKit
import Carbon.HIToolbox
import SwiftData
import SwiftUI

@MainActor
final class TodoCreationPanelController {
    private let modelContext: ModelContext
    private var panel: NSPanel?
    private var presentationGeneration = 0
    private var contentHeight: CGFloat = TodoCreationPanelChrome.baseHeight

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
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
        applyFrame(animated: false)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)

        NSAnimationContext.runAnimation(duration: 0.16, timing: CAMediaTimingFunction(name: .easeOut)) {
            panel.animator().alphaValue = 1
        }
    }

    func close() {
        guard let panel else { return }
        presentationGeneration += 1
        let generation = presentationGeneration
        // 关闭动画期间重新打开时，旧 completion 不得再隐藏新窗口。
        NSAnimationContext.runAnimation(duration: 0.12, timing: CAMediaTimingFunction(name: .easeIn)) {
            panel.animator().alphaValue = 0
        } completion: { [weak self, weak panel] in
            Task { @MainActor [weak self, weak panel] in
                guard self?.presentationGeneration == generation, let panel else { return }
                panel.orderOut(nil)
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
        })
        hostingView.wantsLayer = true
        hostingView.layer?.masksToBounds = true
        hostingView.layer?.cornerRadius = TodoCreationPanelChrome.cornerRadius
        hostingView.layer?.cornerCurve = .continuous
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hostingView
        return panel
    }

    private func applyFrame(animated: Bool) {
        guard let panel else { return }
        setContentHeight(contentHeight, on: panel, animated: animated, reposition: true)
    }

    /// 内容高度变化时按同一锚点（底边）向上扩展；四边限制在屏幕可用区域内。
    private func setContentHeight(_ height: CGFloat, on panel: NSPanel, animated: Bool, reposition: Bool = false) {
        let screenFrame = (panel.screen ?? NSScreen.main)?.visibleFrame
            ?? CGRect(x: 0, y: 0, width: 1_280, height: 800)
        let margin: CGFloat = 12
        let clampedHeight = min(max(height, 160), screenFrame.height - margin * 2)
        let width = min(TodoCreationPanelChrome.baseSize.width, screenFrame.width - margin * 2)

        // 首次定位：水平居中，底边位于可见高度 22% 处；之后高度变化保持底边锚点。
        let current = panel.frame
        let bottom: CGFloat
        if reposition || current.width == 0 {
            bottom = screenFrame.minY + screenFrame.height * 0.22
        } else {
            bottom = current.minY
        }

        let frame = CGRect(
            x: min(max(screenFrame.midX - width / 2, screenFrame.minX + margin), screenFrame.maxX - margin - width),
            y: min(max(bottom, screenFrame.minY + margin), screenFrame.maxY - margin - clampedHeight),
            width: width,
            height: clampedHeight
        )

        contentHeight = clampedHeight
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
    static let cornerRadius: CGFloat = 18
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

    private var groups: [TodoGroup] {
        TodoGroupResolver.normalizedGroups(storedGroups)
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        ScrollView {
            content
                .padding(18)
                .frame(maxWidth: TodoCreationPanelChrome.baseSize.width, alignment: .topLeading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.height
                } action: { _, height in
                    onContentHeightChange(height)
                }
        }
        .scrollIndicators(.never)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: TodoCreationPanelChrome.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: TodoCreationPanelChrome.cornerRadius, style: .continuous)
                .stroke(Color(nsColor: .separatorColor).opacity(0.6), lineWidth: 1)
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
            controls
            TodoScheduleEditor(draft: $scheduleDraft, layout: .compact)
            if scheduleDraft.kind == .singleDeadline {
                TodoReminderEditor(minutesBefore: $scheduleDraft.reminderMinutesBefore)
                    .frame(height: 30, alignment: .leading)
            }
            noteField
            if let saveErrorText {
                Label(saveErrorText, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
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
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("关闭")
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
        HStack(spacing: 10) {
            Picker("重要性", selection: $priority) {
                ForEach(TodoPriority.allCases) { priority in
                    Label(priority.title, systemImage: priority.systemImage)
                        .tag(priority)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 178)

            Picker("分组", selection: $groupID) {
                ForEach(groups) { group in
                    Text(group.name).tag(group.id)
                }
            }
            .frame(width: 140)

            Spacer(minLength: 0)
        }
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

            Spacer()

            Button {
                submit()
            } label: {
                Label("添加", systemImage: "return")
            }
            .buttonStyle(.borderedProminent)
            .disabled(trimmedTitle.isEmpty)
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
            reminderMinutesBefore: scheduleDraft.effectiveReminderMinutesBefore
        )
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
