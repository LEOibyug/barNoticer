import SwiftData
import SwiftUI

struct TodoRow: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var item: TodoItem
    let groups: [TodoGroup]

    @State private var editedTitle = ""
    @State private var hasDeadline = false
    @State private var editedDeadline = Date().addingTimeInterval(3_600)
    @State private var editedScheduleKind = TodoScheduleKind.none
    @State private var firstScheduledTime = Date().addingTimeInterval(3_600)
    @State private var secondScheduledTime = Date().addingTimeInterval(7_200)
    @State private var recurrenceRule = TodoRecurrenceRule.daily
    @State private var recurrenceAnchor = Date().addingTimeInterval(3_600)
    @FocusState private var isTitleFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            completionButton
            VStack(alignment: .leading, spacing: 4) {
                titleField
                metadata
            }
            groupPicker
            priorityPicker
            scheduleEditor
            deleteButton
        }
        .padding(.vertical, 6)
        .onAppear {
            syncDeadlineState()
            syncTitleState()
        }
        .id(item.id)
        .onChange(of: item.id) { _, _ in
            syncTitleState()
            syncDeadlineState()
        }
        .onChange(of: item.title) { _, newTitle in
            guard !isTitleFocused else { return }
            editedTitle = newTitle
        }
        .onChange(of: item.updatedAt) { _, _ in
            syncDeadlineState()
        }
    }

    private var completionButton: some View {
        Button {
            if item.scheduleKind == .recurring, !item.isCompleted {
                item.completeCurrentOccurrence()
            } else {
                item.updateCompletion(!item.isCompleted)
            }
        } label: {
            Image(systemName: item.isCompleted ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 18))
        }
        .buttonStyle(.plain)
        .foregroundStyle(item.isCompleted ? .green : .secondary)
        .help(item.isCompleted ? "标记为未完成" : "标记为完成")
    }

    private var titleField: some View {
        TextField("待办标题", text: $editedTitle)
            .textFieldStyle(.plain)
            .focused($isTitleFocused)
            .strikethrough(item.isCompleted)
            .foregroundStyle(item.isCompleted ? .secondary : .primary)
            .onSubmit(commitTitle)
            .onChange(of: isTitleFocused) { _, focused in
                if !focused {
                    commitTitle()
                }
            }
    }

    private var priorityPicker: some View {
        Picker("优先级", selection: Binding(
            get: { item.priority },
            set: { item.priority = $0 }
        )) {
            ForEach(TodoPriority.allCases) { priority in
                Label(priority.title, systemImage: priority.systemImage)
                    .tag(priority)
            }
        }
        .pickerStyle(.menu)
        .frame(width: 86)
        .tint(item.priority.color)
    }

    private var groupPicker: some View {
        Picker("分组", selection: Binding(
            get: { item.groupID ?? TodoGroup.defaultGroupID },
            set: { item.updateGroup($0) }
        )) {
            ForEach(groups) { group in
                Text(group.name).tag(group.id)
            }
        }
        .pickerStyle(.menu)
        .frame(width: 104)
    }

    private var scheduleEditor: some View {
        HStack(spacing: 6) {
            Picker("时间", selection: Binding(
                get: { editedScheduleKind },
                set: { kind in
                    editedScheduleKind = kind
                    applyScheduleEditor()
                }
            )) {
                Text("无时间").tag(TodoScheduleKind.none)
                Text("DDL").tag(TodoScheduleKind.singleDeadline)
                Text("多时间").tag(TodoScheduleKind.multipleTimes)
                Text("重复").tag(TodoScheduleKind.recurring)
            }
            .pickerStyle(.menu)
            .frame(width: 86)

            switch editedScheduleKind {
            case .none:
                EmptyView()
            case .singleDeadline:
                DatePicker("", selection: Binding(
                    get: { editedDeadline },
                    set: { date in
                        editedDeadline = date
                        applyScheduleEditor()
                    }
                ), displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
                .frame(width: 156)
            case .multipleTimes:
                DatePicker("", selection: Binding(
                    get: { firstScheduledTime },
                    set: { date in
                        firstScheduledTime = date
                        applyScheduleEditor()
                    }
                ), displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
                .frame(width: 132)

                DatePicker("", selection: Binding(
                    get: { secondScheduledTime },
                    set: { date in
                        secondScheduledTime = date
                        applyScheduleEditor()
                    }
                ), displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
                .frame(width: 132)
            case .recurring:
                Picker("重复", selection: Binding(
                    get: { recurrenceRule },
                    set: { rule in
                        recurrenceRule = rule
                        applyScheduleEditor()
                    }
                )) {
                    ForEach(TodoRecurrenceRule.allCases) { rule in
                        Text(rule.title).tag(rule)
                    }
                }
                .pickerStyle(.menu)
                .frame(width: 76)

                DatePicker("", selection: Binding(
                    get: { recurrenceAnchor },
                    set: { date in
                        recurrenceAnchor = date
                        applyScheduleEditor()
                    }
                ), displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
                .frame(width: 132)
            }
        }
    }

    private var metadata: some View {
        HStack(spacing: 8) {
            Text(TodoAgeFormatter.elapsedText(since: item.createdAt))
            Text(TodoGroupResolver.group(for: item, groups: groups).name)
            if let occurrence = item.nextOccurrence(), let scheduleText = TodoDeadlineFormatter.cardText(for: item) {
                Text(scheduleText)
                    .foregroundStyle(occurrence < Date() ? .red : .secondary)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private var deleteButton: some View {
        Button(role: .destructive) {
            modelContext.delete(item)
        } label: {
            Image(systemName: "trash")
        }
        .buttonStyle(.borderless)
        .help("删除")
    }

    private func commitTitle() {
        let trimmedTitle = editedTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTitle.isEmpty {
            editedTitle = item.title
            return
        }

        if trimmedTitle != item.title {
            item.updateTitle(trimmedTitle)
        }
    }

    private func syncDeadlineState() {
        editedScheduleKind = item.scheduleKind
        hasDeadline = item.hasSchedule
        if let deadlineAt = item.deadlineAt ?? item.nextOccurrence() {
            editedDeadline = deadlineAt
        }
        if let first = item.scheduledTimes.first {
            firstScheduledTime = first
        }
        if item.scheduledTimes.count > 1 {
            secondScheduledTime = item.scheduledTimes[1]
        } else if let first = item.scheduledTimes.first {
            secondScheduledTime = first.addingTimeInterval(3_600)
        }
        recurrenceRule = item.recurrenceRule ?? .daily
        recurrenceAnchor = item.recurrenceAnchor ?? item.nextOccurrence() ?? Date().addingTimeInterval(3_600)
    }

    private func syncTitleState() {
        editedTitle = item.title
    }

    private func applyScheduleEditor() {
        switch editedScheduleKind {
        case .none:
            item.clearSchedule()
        case .singleDeadline:
            item.updateSchedule(deadlineAt: editedDeadline)
        case .multipleTimes:
            item.updateSchedule(scheduledTimes: [firstScheduledTime, secondScheduledTime])
        case .recurring:
            item.updateSchedule(recurrenceRule: recurrenceRule, recurrenceAnchor: recurrenceAnchor)
        }
    }
}
