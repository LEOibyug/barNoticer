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
    @State private var customRecurrenceDays = 2
    @State private var recurrenceAnchor = Date().addingTimeInterval(3_600)
    @State private var editedNote = ""
    @State private var isShowingSettings = false
    @State private var isNoteExpanded = false
    @FocusState private var isTitleFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 14) {
                completionButton
                VStack(alignment: .leading, spacing: 4) {
                    titleField
                    metadata
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                settingsButton
            }

            if isNoteExpanded, let noteText {
                expandedNotePanel(noteText)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .top)),
                        removal: .opacity
                    ))
            }
        }
        .padding(.vertical, 8)
        .onAppear {
            syncDeadlineState()
            syncTitleState()
            syncNoteState()
        }
        .id(item.id)
        .onChange(of: item.id) { _, _ in
            syncTitleState()
            syncNoteState()
            syncDeadlineState()
            isNoteExpanded = false
        }
        .onChange(of: item.title) { _, newTitle in
            guard !isTitleFocused else { return }
            editedTitle = newTitle
        }
        .onChange(of: item.updatedAt) { _, _ in
            syncDeadlineState()
            if noteText == nil {
                isNoteExpanded = false
            }
        }
        .sheet(isPresented: $isShowingSettings) {
            settingsSheet
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

    private var settingsButton: some View {
        Button {
            syncDeadlineState()
            syncTitleState()
            syncNoteState()
            isShowingSettings = true
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 15, weight: .medium))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("设置事项")
    }

    private var settingsSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("事项设置")
                        .font(.title3.weight(.semibold))
                    Text(item.title)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                Button {
                    isShowingSettings = false
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 18))
                        .symbolRenderingMode(.hierarchical)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("关闭")
            }
            .padding(.horizontal, 22)
            .padding(.top, 20)
            .padding(.bottom, 14)

            Divider()

            Form {
                Section("基础信息") {
                    TextField("待办标题", text: $editedTitle)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(commitTitle)
                        .onDisappear {
                            commitTitle()
                        }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("备注")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        TextEditor(text: $editedNote)
                            .font(.body)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 78, maxHeight: 96)
                            .padding(7)
                            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(.quaternary, lineWidth: 1)
                            }
                            .onChange(of: editedNote) { _, newValue in
                                item.updateNote(newValue)
                            }
                    }

                    Picker("分组", selection: Binding(
                        get: { item.groupID ?? TodoGroup.defaultGroupID },
                        set: { item.updateGroup($0) }
                    )) {
                        ForEach(groups) { group in
                            Text(group.name).tag(group.id)
                        }
                    }
                    .pickerStyle(.menu)

                    Picker("优先级", selection: Binding(
                        get: { item.priority },
                        set: { item.priority = $0 }
                    )) {
                        ForEach(TodoPriority.allCases) { priority in
                            Label(priority.title, systemImage: priority.systemImage)
                                .tag(priority)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("时间计划") {
                    scheduleEditor
                }

                Section {
                    HStack {
                        Button(role: .destructive) {
                            modelContext.delete(item)
                            isShowingSettings = false
                        } label: {
                            Label("删除事项", systemImage: "trash")
                        }

                        Spacer()

                        Button("完成") {
                            commitTitle()
                            commitNote()
                            isShowingSettings = false
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .padding(.horizontal, 10)
            .padding(.vertical, 12)
        }
        .frame(width: 430)
        .presentationSizing(.fitted)
        .onAppear {
            syncDeadlineState()
            syncTitleState()
            syncNoteState()
        }
    }

    private var scheduleEditor: some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
            GridRow {
                Text("类型")
                    .foregroundStyle(.secondary)
                scheduleKindPicker
            }

            switch editedScheduleKind {
            case .none:
                EmptyView()
            case .singleDeadline:
                GridRow {
                    Text("DDL")
                        .foregroundStyle(.secondary)
                    DatePicker("", selection: Binding(
                        get: { editedDeadline },
                        set: { date in
                            editedDeadline = date
                            applyScheduleEditor()
                        }
                    ), displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                }
            case .multipleTimes:
                GridRow {
                    Text("时间 1")
                        .foregroundStyle(.secondary)
                    DatePicker("", selection: Binding(
                        get: { firstScheduledTime },
                        set: { date in
                            firstScheduledTime = date
                            applyScheduleEditor()
                        }
                    ), displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                }

                GridRow {
                    Text("时间 2")
                        .foregroundStyle(.secondary)
                    DatePicker("", selection: Binding(
                        get: { secondScheduledTime },
                        set: { date in
                            secondScheduledTime = date
                            applyScheduleEditor()
                        }
                    ), displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                }
            case .recurring:
                GridRow {
                    Text("周期")
                        .foregroundStyle(.secondary)
                    HStack(spacing: 10) {
                        recurrencePicker
                        if case .everyNDays = recurrenceRule {
                            Stepper(
                                value: Binding(
                                    get: { customRecurrenceDays },
                                    set: { days in
                                        customRecurrenceDays = max(1, days)
                                        recurrenceRule = .everyNDays(customRecurrenceDays)
                                        applyScheduleEditor()
                                    }
                                ),
                                in: 1...365
                            ) {
                                Text("\(customRecurrenceDays)天")
                                    .frame(width: 44, alignment: .leading)
                            }
                        }
                    }
                }

                GridRow {
                    Text("开始")
                        .foregroundStyle(.secondary)
                    DatePicker("", selection: Binding(
                        get: { recurrenceAnchor },
                        set: { date in
                            recurrenceAnchor = date
                            applyScheduleEditor()
                        }
                    ), displayedComponents: [.date, .hourAndMinute])
                    .labelsHidden()
                }
            }
        }
    }

    private var scheduleKindPicker: some View {
        Picker("时间", selection: Binding(
            get: { editedScheduleKind },
            set: { kind in
                editedScheduleKind = kind
                applyScheduleEditor()
            }
        )) {
            Text("无时间").tag(TodoScheduleKind.none)
            Text("单次 DDL").tag(TodoScheduleKind.singleDeadline)
            Text("多个时间点").tag(TodoScheduleKind.multipleTimes)
            Text("重复事项").tag(TodoScheduleKind.recurring)
        }
        .pickerStyle(.menu)
        .frame(width: 150, alignment: .leading)
    }

    private var recurrencePicker: some View {
        Picker("重复", selection: Binding(
            get: { recurrenceRule },
            set: { rule in
                recurrenceRule = rule
                if let days = rule.intervalDays {
                    customRecurrenceDays = days
                }
                applyScheduleEditor()
            }
        )) {
            ForEach(recurrencePickerRules) { rule in
                Text(rule.title).tag(rule)
            }
        }
        .pickerStyle(.menu)
        .frame(width: 118, alignment: .leading)
    }

    private func expandedNotePanel(_ note: String) -> some View {
        ScrollView(.vertical) {
            Text(note)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineSpacing(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
        }
        .scrollIndicators(.visible)
        .frame(height: 72, alignment: .top)
        .background(.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(.quaternary, lineWidth: 1)
        }
        .padding(.leading, 32)
        .padding(.trailing, 28)
        .padding(.top, 2)
    }

    private var metadata: some View {
        HStack(spacing: 8) {
            Text(TodoAgeFormatter.elapsedText(since: item.createdAt))
            Text(TodoGroupResolver.group(for: item, groups: groups).name)
            if noteText != nil {
                Button {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                        isNoteExpanded.toggle()
                    }
                } label: {
                    Label(isNoteExpanded ? "收起备注" : "查看备注", systemImage: isNoteExpanded ? "chevron.up" : "note.text")
                        .labelStyle(.titleAndIcon)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help(isNoteExpanded ? "收起备注" : "查看备注")
            }
            if let occurrence = item.nextOccurrence(), let scheduleText = TodoDeadlineFormatter.cardText(for: item) {
                Text(scheduleText)
                    .foregroundStyle(occurrence < Date() ? .red : .secondary)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .lineLimit(1)
    }

    private var recurrencePickerRules: [TodoRecurrenceRule] {
        [.daily, .weekly, .monthly, .everyNDays(customRecurrenceDays)]
    }

    private var noteText: String? {
        guard let note = item.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty else {
            return nil
        }
        return note
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

    private func commitNote() {
        item.updateNote(editedNote)
        syncNoteState()
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
        customRecurrenceDays = item.recurrenceRule?.intervalDays ?? customRecurrenceDays
        recurrenceAnchor = item.recurrenceAnchor ?? item.nextOccurrence() ?? Date().addingTimeInterval(3_600)
    }

    private func syncTitleState() {
        editedTitle = item.title
    }

    private func syncNoteState() {
        editedNote = item.note ?? ""
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
