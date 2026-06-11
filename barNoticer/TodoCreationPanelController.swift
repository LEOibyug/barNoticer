import AppKit
import Carbon.HIToolbox
import SwiftData
import SwiftUI

@MainActor
final class TodoCreationPanelController {
    private let modelContext: ModelContext
    private var panel: NSPanel?

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
        center(panel)
        panel.alphaValue = 0
        panel.makeKeyAndOrderFront(nil)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    func close() {
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: { [weak panel] in
            panel?.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = FocusableTodoCreationPanel(
            contentRect: CGRect(origin: .zero, size: TodoCreationPanelChrome.size),
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
        panel.appearance = NSAppearance(named: .aqua)
        panel.hasShadow = false
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true

        let hostingView = NSHostingView(rootView: TodoCreationPanelView(modelContext: modelContext) { [weak self] in
            self?.close()
        })
        hostingView.wantsLayer = true
        hostingView.layer?.masksToBounds = true
        hostingView.layer?.cornerRadius = TodoCreationPanelChrome.cornerRadius
        hostingView.layer?.cornerCurve = .continuous
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView.appearance = NSAppearance(named: .aqua)
        panel.contentView = hostingView
        return panel
    }

    private func center(_ panel: NSPanel) {
        let screenFrame = NSScreen.main?.visibleFrame ?? .zero
        let size = panel.frame.size
        panel.setFrameOrigin(CGPoint(
            x: screenFrame.midX - size.width / 2,
            y: screenFrame.minY + screenFrame.height * 0.22
        ))
    }
}

enum TodoCreationPanelChrome {
    static let size = CGSize(width: 640, height: 258)
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
    let close: () -> Void

    @Query private var storedGroups: [TodoGroup]
    @State private var title = ""
    @State private var note = ""
    @State private var priority: TodoPriority = .medium
    @State private var groupID = TodoGroup.defaultGroupID
    @State private var scheduleKind = TodoScheduleKind.none
    @State private var deadline = Date().addingTimeInterval(3_600)
    @State private var firstScheduledTime = Date().addingTimeInterval(3_600)
    @State private var secondScheduledTime = Date().addingTimeInterval(7_200)
    @State private var recurrenceRule = TodoRecurrenceRule.daily
    @State private var customRecurrenceDays = 2
    @State private var recurrenceAnchor = Date().addingTimeInterval(3_600)
    @FocusState private var isTitleFocused: Bool

    private var groups: [TodoGroup] {
        TodoGroupResolver.normalizedGroups(storedGroups)
    }

    private var trimmedTitle: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            primaryRow
            controls
            scheduleRow
            noteField
        }
        .padding(18)
        .frame(width: TodoCreationPanelChrome.size.width, height: TodoCreationPanelChrome.size.height, alignment: .topLeading)
        .background(.white.opacity(0.86), in: RoundedRectangle(cornerRadius: TodoCreationPanelChrome.cornerRadius, style: .continuous))
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: TodoCreationPanelChrome.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: TodoCreationPanelChrome.cornerRadius, style: .continuous)
                .stroke(.black.opacity(0.10), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.20), radius: 24, y: 12)
        .onAppear {
            groupID = groups.first?.id ?? TodoGroup.defaultGroupID
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                isTitleFocused = true
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

    private var primaryRow: some View {
        HStack(spacing: 10) {
            titleField

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
            .frame(width: 120)
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
            .background(.white.opacity(0.78), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(isTitleFocused ? Color.accentColor.opacity(0.55) : .black.opacity(0.10), lineWidth: 1)
            }
    }

    private var noteField: some View {
        TextEditor(text: $note)
            .font(.system(size: 13))
            .foregroundStyle(.primary)
            .scrollContentBackground(.hidden)
            .frame(height: 52)
            .padding(7)
            .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(.black.opacity(0.08), lineWidth: 1)
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
            Picker("时间计划", selection: $scheduleKind) {
                ForEach(TodoScheduleKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 132)

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

    @ViewBuilder
    private var scheduleRow: some View {
        HStack(spacing: 10) {
            switch scheduleKind {
            case .none:
                Label("不设置提醒时间", systemImage: "calendar.badge.minus")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .singleDeadline:
                compactDatePicker("DDL", selection: $deadline)
            case .multipleTimes:
                compactDatePicker("时间 1", selection: $firstScheduledTime)
                compactDatePicker("时间 2", selection: $secondScheduledTime)
            case .recurring:
                Picker("周期", selection: $recurrenceRule) {
                    ForEach(recurrencePickerRules) { rule in
                        Text(rule.title).tag(rule)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 112)

                if case .everyNDays = recurrenceRule {
                    Stepper(
                        value: Binding(
                            get: { customRecurrenceDays },
                            set: { days in
                                customRecurrenceDays = max(1, days)
                                recurrenceRule = .everyNDays(customRecurrenceDays)
                            }
                        ),
                        in: 1...365
                    ) {
                        Text("\(customRecurrenceDays)天")
                            .font(.caption)
                            .frame(width: 42, alignment: .leading)
                    }
                    .frame(width: 98)
                }

                compactDatePicker("开始", selection: $recurrenceAnchor)
            }

            Spacer(minLength: 0)
        }
        .frame(height: 30, alignment: .leading)
        .animation(.easeInOut(duration: 0.16), value: scheduleKind)
    }

    private var recurrencePickerRules: [TodoRecurrenceRule] {
        [.daily, .weekly, .monthly, .everyNDays(customRecurrenceDays)]
    }

    private func compactDatePicker(_ title: String, selection: Binding<Date>) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            DatePicker("", selection: selection, displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
        }
    }

    private func submit() {
        guard !trimmedTitle.isEmpty else { return }

        let schedule = selectedSchedule()
        let item = TodoItem(
            title: trimmedTitle,
            note: note,
            priority: priority,
            groupID: groupID,
            deadlineAt: schedule.deadlineAt,
            scheduledTimes: schedule.scheduledTimes,
            recurrenceRule: schedule.recurrenceRule,
            recurrenceAnchor: schedule.recurrenceAnchor
        )
        modelContext.insert(item)
        try? modelContext.save()
        close()
    }

    private func selectedSchedule() -> (deadlineAt: Date?, scheduledTimes: [Date], recurrenceRule: TodoRecurrenceRule?, recurrenceAnchor: Date?) {
        switch scheduleKind {
        case .none:
            return (nil, [], nil, nil)
        case .singleDeadline:
            return (deadline, [], nil, nil)
        case .multipleTimes:
            return (nil, [firstScheduledTime, secondScheduledTime], nil, nil)
        case .recurring:
            return (nil, [], recurrenceRule, recurrenceAnchor)
        }
    }
}
