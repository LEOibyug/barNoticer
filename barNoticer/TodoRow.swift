import SwiftData
import SwiftUI

struct TodoRow: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var item: TodoItem
    let groups: [TodoGroup]

    @State private var editedTitle = ""
    @State private var hasDeadline = false
    @State private var editedDeadline = Date().addingTimeInterval(3_600)
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
            deadlineEditor
            deleteButton
        }
        .padding(.vertical, 6)
        .onAppear {
            syncDeadlineState()
        }
        .onChange(of: item.deadlineAt) { _, _ in
            syncDeadlineState()
        }
    }

    private var completionButton: some View {
        Button {
            item.updateCompletion(!item.isCompleted)
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
            .onAppear {
                editedTitle = item.title
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

    private var deadlineEditor: some View {
        HStack(spacing: 6) {
            Toggle("", isOn: Binding(
                get: { hasDeadline },
                set: { enabled in
                    hasDeadline = enabled
                    item.updateDeadline(enabled ? editedDeadline : nil)
                }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .help("设置截止时间")

            if hasDeadline {
                DatePicker("", selection: Binding(
                    get: { editedDeadline },
                    set: { date in
                        editedDeadline = date
                        item.updateDeadline(date)
                    }
                ), displayedComponents: [.date, .hourAndMinute])
                .labelsHidden()
                .frame(width: 156)
            }
        }
    }

    private var metadata: some View {
        HStack(spacing: 8) {
            Text(TodoAgeFormatter.elapsedText(since: item.createdAt))
            Text(TodoGroupResolver.group(for: item, groups: groups).name)
            if let deadlineAt = item.deadlineAt {
                Text(TodoDeadlineFormatter.cardText(for: deadlineAt))
                    .foregroundStyle(deadlineAt < Date() ? .red : .secondary)
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
        if let deadlineAt = item.deadlineAt {
            hasDeadline = true
            editedDeadline = deadlineAt
        } else {
            hasDeadline = false
        }
    }
}
