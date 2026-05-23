import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var todoItems: [TodoItem]
    @Query private var storedGroups: [TodoGroup]

    @State private var draftTitle = ""
    @State private var draftPriority: TodoPriority = .medium
    @State private var draftGroupID: UUID = TodoGroup.defaultGroupID
    @State private var draftHasDeadline = false
    @State private var draftDeadline = Date().addingTimeInterval(3_600)
    @State private var draftGroupName = ""
    @State private var selection: SidebarSelection = .filter(.active)

    private var groups: [TodoGroup] {
        TodoGroupResolver.normalizedGroups(storedGroups)
    }

    private var sortedItems: [TodoItem] {
        let filtered: [TodoItem]
        switch selection {
        case let .filter(filter):
            switch filter {
            case .active:
                filtered = todoItems.filter { !$0.isCompleted }
            case .completed:
                filtered = todoItems.filter(\.isCompleted)
            case .all:
                filtered = todoItems
            }
        case let .group(groupID):
            filtered = todoItems.filter { TodoGroupResolver.group(for: $0, groups: groups).id == groupID }
        case .islandSettings, .aiSettings, .appSettings:
            filtered = todoItems
        }
        return TodoSorter.sorted(filtered, groups: groups)
    }

    private var selectedFilter: TodoFilter {
        if case let .filter(filter) = selection {
            return filter
        }

        return .active
    }

    private var selectedGroup: TodoGroup? {
        if case let .group(groupID) = selection {
            return groups.first(where: { $0.id == groupID })
        }
        return nil
    }

    private var detailTitle: String {
        if let selectedGroup {
            return selectedGroup.name
        }
        switch selectedFilter {
        case .active:
            return "待办管理"
        case .completed:
            return "已完成"
        case .all:
            return "全部事项"
        }
    }

    private var detailSubtitle: String {
        if selectedGroup != nil {
            return "\(sortedItems.count) 项属于此分组"
        }
        return activeCount == 0 ? "当前没有进行中的事项" : "\(activeCount) 项正在进行"
    }

    private var activeCount: Int {
        todoItems.filter { !$0.isCompleted }.count
    }

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            switch selection {
            case .filter, .group:
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
            case .appSettings:
                AppSettingsView()
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

            Section("分组") {
                ForEach(groups) { group in
                    Label {
                        Text(group.name)
                    } icon: {
                        Circle()
                            .fill(group.color)
                            .frame(width: 9, height: 9)
                    }
                    .tag(SidebarSelection.group(group.id))
                }
            }

            Section("偏好") {
                Label("岛设置", systemImage: "slider.horizontal.3")
                    .tag(SidebarSelection.islandSettings)
                Label("AI 设置", systemImage: "sparkles")
                    .tag(SidebarSelection.aiSettings)
                Label("应用设置", systemImage: "gearshape")
                    .tag(SidebarSelection.appSettings)
            }
        }
        .navigationTitle("barNoticer")
        .frame(minWidth: 150)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 6) {
                Text(detailTitle)
                    .font(.system(size: 28, weight: .semibold))
                Text(detailSubtitle)
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
        VStack(alignment: .leading, spacing: 12) {
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

            HStack(spacing: 12) {
                Picker("分组", selection: $draftGroupID) {
                    ForEach(groups) { group in
                        Text(group.name).tag(group.id)
                    }
                }
                .frame(width: 180)

                Toggle("DDL", isOn: $draftHasDeadline)
                    .toggleStyle(.checkbox)

                if draftHasDeadline {
                    DatePicker("", selection: $draftDeadline, displayedComponents: [.date, .hourAndMinute])
                        .labelsHidden()
                        .frame(width: 190)
                }

                Spacer()

                groupCreator
            }

            if let selectedGroup {
                selectedGroupEditor(selectedGroup)
            }
        }
        .padding(24)
        .onChange(of: selection) { _, newSelection in
            if case let .group(groupID) = newSelection {
                draftGroupID = groupID
            }
        }
    }

    private var groupCreator: some View {
        HStack(spacing: 8) {
            TextField("新分组", text: $draftGroupName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 120)
                .onSubmit(addGroup)

            Button {
                addGroup()
            } label: {
                Label("分组", systemImage: "folder.badge.plus")
            }
            .disabled(trimmedDraftGroupName.isEmpty)
        }
    }

    private func selectedGroupEditor(_ group: TodoGroup) -> some View {
        HStack(spacing: 10) {
            Text("当前分组")
                .font(.caption)
                .foregroundStyle(.secondary)

            TextField("分组名称", text: Binding(
                get: { group.name },
                set: { group.update(name: $0) }
            ))
            .textFieldStyle(.roundedBorder)
            .frame(width: 160)
            .disabled(!group.canDelete)

            Picker("颜色", selection: Binding(
                get: { group.colorHex },
                set: { group.update(colorHex: $0) }
            )) {
                ForEach(TodoGroup.presetColorHexes, id: \.self) { hex in
                    Label(hex, systemImage: "circle.fill")
                        .foregroundStyle(Color(hex: hex) ?? .secondary)
                        .tag(hex)
                }
            }
            .frame(width: 112)
            .disabled(!group.canDelete)

            Spacer()

            if group.canDelete {
                Button(role: .destructive) {
                    deleteGroup(group)
                } label: {
                    Label("删除分组", systemImage: "trash")
                }
            }
        }
    }

    private var todoList: some View {
        Group {
            if sortedItems.isEmpty {
                emptyState
            } else {
                List {
                    ForEach(sortedItems) { item in
                        TodoRow(item: item, groups: groups)
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

    private var trimmedDraftGroupName: String {
        draftGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func addTodo() {
        let title = trimmedDraftTitle
        guard !title.isEmpty else { return }

        modelContext.insert(TodoItem(
            title: title,
            priority: draftPriority,
            groupID: draftGroupID,
            deadlineAt: draftHasDeadline ? draftDeadline : nil
        ))
        draftTitle = ""
        draftPriority = .medium
        draftHasDeadline = false
    }

    private func addGroup() {
        let name = trimmedDraftGroupName
        guard !name.isEmpty else { return }

        let group = TodoGroup(
            name: name,
            colorHex: TodoGroupResolver.nextColorHex(for: groups),
            sortOrder: TodoGroupResolver.nextSortOrder(in: groups)
        )
        modelContext.insert(group)
        draftGroupName = ""
        selection = .group(group.id)
        draftGroupID = group.id
    }

    private func deleteItems(at offsets: IndexSet) {
        for index in offsets {
            modelContext.delete(sortedItems[index])
        }
    }

    private func deleteGroup(_ group: TodoGroup) {
        guard group.canDelete else { return }
        for item in todoItems where item.groupID == group.id {
            item.updateGroup(nil)
        }
        modelContext.delete(group)
        selection = .filter(.active)
        draftGroupID = TodoGroup.defaultGroupID
    }

    private func seedExamplesIfNeeded() {
        guard todoItems.isEmpty else { return }

        let work = TodoGroup(name: "工作", colorHex: "#3B82F6", sortOrder: TodoGroupResolver.nextSortOrder(in: groups))
        modelContext.insert(work)
        modelContext.insert(TodoItem(title: "整理今天最重要的三件事", priority: .high, deadlineAt: Date().addingTimeInterval(7_200)))
        modelContext.insert(TodoItem(title: "回复项目进展消息", priority: .medium, groupID: work.id))
        modelContext.insert(TodoItem(title: "清理桌面临时文件", priority: .low))
    }
}

#Preview {
    ContentView()
        .modelContainer(for: [TodoItem.self, TodoGroup.self, DailySummary.self], inMemory: true)
}
