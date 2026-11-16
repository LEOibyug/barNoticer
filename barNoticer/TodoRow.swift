import SwiftData
import SwiftUI

struct TodoRow: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var item: TodoItem
    let groups: [TodoGroup]

    @State private var editedTitle = ""
    @State private var editDraft = TodoItemEditDraft()
    @State private var isShowingSettings = false
    @State private var isNoteExpanded = false
    @State private var sheetErrorText: String?
    @State private var rowErrorText: String?
    @State private var conflictFields: [String]?
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
            syncEditState()
            syncTitleState()
        }
        .id(item.id)
        .onChange(of: item.id) { _, _ in
            syncTitleState()
            syncEditState()
            isNoteExpanded = false
        }
        .onChange(of: item.title) { _, newTitle in
            guard !isTitleFocused else { return }
            editedTitle = newTitle
        }
        .onChange(of: item.updatedAt) { _, _ in
            if !isShowingSettings { syncEditState() }
            if noteText == nil {
                isNoteExpanded = false
            }
        }
        .sheet(isPresented: Binding(
            get: { isShowingSettings },
            set: { isPresented in
                if !isPresented { commitOnDismiss() }
                isShowingSettings = isPresented
            }
        )) {
            settingsSheet
        }
        .alert(
            "保存失败",
            isPresented: Binding(
                get: { rowErrorText != nil },
                set: { if !$0 { rowErrorText = nil } }
            )
        ) {
            Button("好", role: .cancel) { rowErrorText = nil }
        } message: {
            Text(rowErrorText ?? "")
        }
    }

    private var completionButton: some View {
        Button {
            if item.scheduleKind == .recurring, !item.isCompleted {
                item.completeCurrentOccurrence()
            } else {
                item.updateCompletion(!item.isCompleted)
            }
            if let error = ModelContextPersistence.save(modelContext, category: "TodoRow", action: "更新事项完成状态") {
                rowErrorText = error
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
            syncEditState()
            syncTitleState()
            sheetErrorText = nil
            conflictFields = nil
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
                    TextField("待办标题", text: $editDraft.title)
                        .textFieldStyle(.roundedBorder)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("备注")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                        TextEditor(text: $editDraft.note)
                            .font(.body)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 78, maxHeight: 96)
                            .padding(7)
                            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 8, style: .continuous)
                                    .stroke(.quaternary, lineWidth: 1)
                            }
                    }

                    Picker("分组", selection: Binding(
                        get: { item.groupID ?? TodoGroup.defaultGroupID },
                        set: {
                            item.updateGroup($0)
                            if let error = ModelContextPersistence.save(modelContext, category: "TodoEdit", action: "修改事项分组") {
                                sheetErrorText = error
                            }
                        }
                    )) {
                        ForEach(groups) { group in
                            Text(group.name).tag(group.id)
                        }
                    }
                    .pickerStyle(.menu)

                    Picker("优先级", selection: Binding(
                        get: { item.priority },
                        set: {
                            item.priority = $0
                            if let error = ModelContextPersistence.save(modelContext, category: "TodoEdit", action: "修改事项优先级") {
                                sheetErrorText = error
                            }
                        }
                    )) {
                        ForEach(TodoPriority.allCases) { priority in
                            Label(priority.title, systemImage: priority.systemImage)
                                .tag(priority)
                        }
                    }
                    .pickerStyle(.segmented)
                }

                Section("时间计划") {
                    TodoScheduleEditor(draft: $editDraft.schedule, layout: .form)
                    if editDraft.schedule.supportsReminder {
                        TodoReminderEditor(minutesBefore: $editDraft.schedule.reminderMinutesBefore, isRecurring: editDraft.schedule.kind == .recurring)
                        if editDraft.schedule.kind == .recurring {
                            Text(editDraft.schedule.automaticallyCompletes
                                ? "到点自动完成并进入下一次，不累计逾期。提醒设置会持续沿用。"
                                : "每次按当前未完成的一次提醒，完成后自动延续，直到关闭提醒。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else if let minutes = editDraft.schedule.reminderMinutesBefore {
                            Text("提醒时间：\(editDraft.schedule.deadline.addingTimeInterval(-Double(minutes) * 60).formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let sheetErrorText {
                        Label(sheetErrorText, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    HStack {
                        Button(role: .destructive) {
                            deleteItem()
                        } label: {
                            Label("删除事项", systemImage: "trash")
                        }

                        Spacer()

                        Button("完成") {
                            finishEditing()
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
            syncEditState()
            syncTitleState()
        }
        .alert(
            "这项任务已更新。",
            isPresented: Binding(
                get: { conflictFields != nil },
                set: { if !$0 { conflictFields = nil } }
            )
        ) {
            Button("重新载入") {
                editDraft = TodoItemEditDraft(item: item)
                syncTitleState()
                sheetErrorText = nil
            }
            Button("覆盖保存") {
                finishEditing(force: true)
            }
            Button("取消", role: .cancel) { conflictFields = nil }
        } message: {
            Text("以下内容同时被修改：\(conflictFields?.joined(separator: "、") ?? "")。可以保留你的修改并覆盖，或重新载入最新内容。")
        }
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
                    if reduceMotion {
                        isNoteExpanded.toggle()
                    } else {
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.88)) {
                            isNoteExpanded.toggle()
                        }
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
            if let error = ModelContextPersistence.save(modelContext, category: "TodoRow", action: "保存标题") {
                rowErrorText = error
            }
        }
    }

    private func syncEditState() {
        editDraft = TodoItemEditDraft(item: item)
    }

    private func syncTitleState() {
        editedTitle = item.title
    }

    /// 显式“完成”：提交失败或冲突时保持窗口打开，给出反馈。
    private func finishEditing(force: Bool = false) {
        switch TodoEditCommitter.commit(&editDraft, into: item, context: modelContext, force: force) {
        case .saved:
            syncTitleState()
            sheetErrorText = nil
            conflictFields = nil
            isShowingSettings = false
        case let .conflict(fields):
            conflictFields = fields
        case .itemDeleted:
            sheetErrorText = "事项已被删除，修改无法保存。"
            conflictFields = nil
        case let .saveFailed(reason):
            try? AppDebugLogStore.shared.write(.error, category: "TodoEdit", message: "事项设置保存失败", metadata: ["error": reason, "itemID": item.id.uuidString])
            sheetErrorText = "未能保存。内容已保留，请重试。"
            conflictFields = nil
        }
    }

    /// 关闭设置时的自动提交保持既有语义；失败不阻断关闭，但记录并提示错误。
    private func commitOnDismiss() {
        guard !item.isDeleted, item.modelContext != nil else { return }
        switch TodoEditCommitter.commit(&editDraft, into: item, context: modelContext) {
        case .saved, .itemDeleted:
            break
        case let .conflict(fields):
            rowErrorText = "以下字段在编辑期间已被更新，本次关闭未覆盖：\(fields.joined(separator: "、"))。"
        case let .saveFailed(reason):
            try? AppDebugLogStore.shared.write(.error, category: "TodoEdit", message: "关闭事项设置保存失败", metadata: ["error": reason, "itemID": item.id.uuidString])
            rowErrorText = "保存修改失败：\(reason)"
        }
        syncTitleState()
    }

    private func deleteItem() {
        modelContext.delete(item)
        if let error = ModelContextPersistence.save(modelContext, category: "TodoEdit", action: "删除事项") {
            sheetErrorText = error
            return
        }
        isShowingSettings = false
    }
}
