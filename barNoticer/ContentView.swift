import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var todoItems: [TodoItem]

    @State private var draftTitle = ""
    @State private var draftPriority: TodoPriority = .medium
    @State private var selection: SidebarSelection = .filter(.active)

    private var sortedItems: [TodoItem] {
        switch selectedFilter {
        case .active:
            TodoSorter.sorted(todoItems).filter { !$0.isCompleted }
        case .completed:
            TodoSorter.sorted(todoItems).filter(\.isCompleted)
        case .all:
            TodoSorter.sorted(todoItems)
        }
    }

    private var selectedFilter: TodoFilter {
        if case let .filter(filter) = selection {
            return filter
        }

        return .active
    }

    private var activeCount: Int {
        todoItems.filter { !$0.isCompleted }.count
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            switch selection {
            case .filter:
                VStack(spacing: 0) {
                    header
                    Divider()
                    editor
                    Divider()
                    todoList
                }
                .frame(minWidth: 560, minHeight: 440)
            case .islandSettings:
                IslandSettingsView()
                    .frame(minWidth: 560, minHeight: 440)
            case .aiSettings:
                AISettingsView()
                    .frame(minWidth: 560, minHeight: 440)
            }
        }
    }

    private var sidebar: some View {
        List(selection: $selection) {
            Section("待办") {
                Label("进行中", systemImage: "circle")
                    .tag(SidebarSelection.filter(.active))
                Label("已完成", systemImage: "checkmark.circle")
                    .tag(SidebarSelection.filter(.completed))
                Label("全部", systemImage: "tray.full")
                    .tag(SidebarSelection.filter(.all))
            }

            Section("偏好") {
                Label("岛设置", systemImage: "slider.horizontal.3")
                    .tag(SidebarSelection.islandSettings)
                Label("AI 设置", systemImage: "sparkles")
                    .tag(SidebarSelection.aiSettings)
            }
        }
        .navigationTitle("barNoticer")
        .frame(minWidth: 150)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Text("待办管理")
                    .font(.system(size: 28, weight: .semibold))
                Text(activeCount == 0 ? "当前没有进行中的事项" : "\(activeCount) 项正在进行")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                seedExamplesIfNeeded()
            } label: {
                Label("示例", systemImage: "sparkles")
            }
            .buttonStyle(.bordered)
            .disabled(!todoItems.isEmpty)
            .help("添加几条示例待办")
        }
        .padding(24)
    }

    private var editor: some View {
        HStack(spacing: 12) {
            TextField("添加待办", text: $draftTitle)
                .textFieldStyle(.roundedBorder)
                .onSubmit(addTodo)

            Picker("优先级", selection: $draftPriority) {
                ForEach(TodoPriority.allCases) { priority in
                    Label(priority.title, systemImage: priority.systemImage)
                        .tag(priority)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 180)

            Button(action: addTodo) {
                Label("添加", systemImage: "plus")
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(trimmedDraftTitle.isEmpty)
        }
        .padding(24)
    }

    private var todoList: some View {
        Group {
            if sortedItems.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(sortedItems) { item in
                        TodoRow(item: item)
                    }
                    .onDelete(perform: deleteItems)
                }
                .listStyle(.inset)
            }
        }
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: selectedFilter == .completed ? "checkmark.seal" : "text.badge.plus")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text(selectedFilter.emptyTitle)
                .font(.headline)
            Text(selectedFilter.emptyMessage)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var trimmedDraftTitle: String {
        draftTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func addTodo() {
        let title = trimmedDraftTitle
        guard !title.isEmpty else { return }

        modelContext.insert(TodoItem(title: title, priority: draftPriority))
        draftTitle = ""
        draftPriority = .medium
    }

    private func deleteItems(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(sortedItems[index])
        }
    }

    private func seedExamplesIfNeeded() {
        guard todoItems.isEmpty else { return }

        modelContext.insert(TodoItem(title: "整理今天最重要的三件事", priority: .high))
        modelContext.insert(TodoItem(title: "回复项目进展消息", priority: .medium))
        modelContext.insert(TodoItem(title: "清理桌面临时文件", priority: .low))
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [TodoItem.self, DailySummary.self], inMemory: true)
}
