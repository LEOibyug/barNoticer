import SwiftData
import SwiftUI

struct TodoRow: View {
    @Environment(\.modelContext) private var modelContext
    @Bindable var item: TodoItem

    @State private var editedTitle = ""
    @FocusState private var isTitleFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            completionButton
            VStack(alignment: .leading, spacing: 4) {
                titleField
                Text(TodoAgeFormatter.elapsedText(since: item.createdAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            priorityPicker
            deleteButton
        }
        .padding(.vertical, 6)
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
}
