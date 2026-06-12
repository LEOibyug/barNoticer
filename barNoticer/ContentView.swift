import SwiftData
import SwiftUI

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var todoItems: [TodoItem]
    @Query private var storedGroups: [TodoGroup]

    @State private var draftGroupName = ""
    @State private var selection: SidebarSelection = .filter(.active)
    @State private var draggedGroupID: UUID?

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
        case .islandSettings, .aiSettings, .reminderSettings, .appSettings:
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
                    toolbar
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
            case .reminderSettings:
                ReminderSettingsView()
                    .frame(minWidth: 560, minHeight: 440)
            case .appSettings:
                AppSettingsView()
                    .frame(minWidth: 560, minHeight: 440)
            }
        }
    }

    private var sidebar: some View {
        List {
            Section("待办") {
                sidebarButton(.filter(.active), title: "进行中", systemImage: "circle")
                sidebarButton(.filter(.completed), title: "已完成", systemImage: "checkmark.circle")
                sidebarButton(.filter(.all), title: "全部", systemImage: "tray.full")
            }

            Section("分组") {
                ForEach(groups) { group in
                    sidebarGroupRow(group)
                }

                Color.clear
                    .frame(height: 6)
                    .dropDestination(for: String.self) { droppedIDs, _ in
                        return reorderGroupToEnd(from: droppedIDs)
                    }
            }

            Section("偏好") {
                sidebarButton(.islandSettings, title: "岛设置", systemImage: "slider.horizontal.3")
                sidebarButton(.aiSettings, title: "AI 设置", systemImage: "sparkles")
                sidebarButton(.reminderSettings, title: "提醒设置", systemImage: "bell.badge")
                sidebarButton(.appSettings, title: "应用设置", systemImage: "gearshape")
            }
        }
        .navigationTitle("barNoticer")
        .frame(minWidth: 150)
    }

    private func groupDragPreview(_ group: TodoGroup) -> some View {
        Label {
            Text(group.name)
        } icon: {
            Circle()
                .fill(group.color)
                .frame(width: 9, height: 9)
        }
        .font(.caption.weight(.medium))
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func sidebarGroupRow(_ group: TodoGroup) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(group.color)
                .frame(width: 9, height: 9)

            Text(group.name)
                .frame(maxWidth: .infinity, alignment: .leading)

            Image(systemName: "line.3.horizontal")
                .font(.caption.weight(.bold))
                .foregroundStyle(.secondary.opacity(0.9))
                .frame(width: 22, height: 22)
                .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                .contentShape(Rectangle())
                .draggable(group.id.uuidString) {
                    groupDragPreview(group)
                }
                .help("拖动改变分组顺序")
        }
        .frame(maxWidth: .infinity, minHeight: 28, alignment: .leading)
        .padding(.leading, 0)
        .padding(.trailing, 4)
        .padding(.vertical, 4)
        .background(sidebarGroupRowBackground(for: group), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            selection = .group(group.id)
        }
        .dropDestination(for: String.self) { droppedIDs, _ in
            return reorderGroup(from: droppedIDs, near: group)
        } isTargeted: { isTargeted in
            draggedGroupID = isTargeted ? group.id : nil
        }
        .listRowInsets(EdgeInsets(top: 2, leading: 6, bottom: 2, trailing: 12))
        .listRowBackground(Color.clear)
        .help("拖动改变分组顺序")
    }

    private func sidebarButton(_ target: SidebarSelection, title: String, systemImage: String) -> some View {
        sidebarButton(target) {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
        }
    }

    private func sidebarButton<Title: View, Icon: View>(
        _ target: SidebarSelection,
        @ViewBuilder title: () -> Title,
        @ViewBuilder icon: () -> Icon
    ) -> some View {
        Button {
            selection = target
        } label: {
            Label {
                title()
            } icon: {
                icon()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(sidebarRowBackground(for: target))
    }

    private func sidebarRowBackground(for target: SidebarSelection) -> Color {
        if selection == target {
            return Color.accentColor.opacity(0.16)
        }
        return Color.clear
    }

    private func sidebarGroupRowBackground(for group: TodoGroup) -> Color {
        if group.id == draggedGroupID {
            return Color.primary.opacity(0.09)
        }
        if selection == .group(group.id) {
            return Color.accentColor.opacity(0.16)
        }
        return Color.clear
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
                showTodoCreationPanel()
            } label: {
                Label("新建事项", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)

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

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
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
                _ = groupID
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

    private var trimmedDraftGroupName: String {
        draftGroupName.trimmingCharacters(in: .whitespacesAndNewlines)
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
    }

    private func reorderGroup(from droppedIDs: [String], near targetGroup: TodoGroup) -> Bool {
        guard let idString = droppedIDs.first,
              let movingID = UUID(uuidString: idString),
              movingID != targetGroup.id
        else {
            return false
        }

        withAnimation(.smooth(duration: 0.24)) {
            TodoGroupResolver.moveGroup(in: groups, moving: movingID, near: targetGroup.id)
        }
        try? modelContext.save()
        draggedGroupID = nil
        return true
    }

    private func reorderGroupToEnd(from droppedIDs: [String]) -> Bool {
        guard let idString = droppedIDs.first,
              let movingID = UUID(uuidString: idString)
        else {
            return false
        }

        withAnimation(.smooth(duration: 0.24)) {
            TodoGroupResolver.moveGroup(in: groups, moving: movingID, to: groups.count - 1)
        }
        try? modelContext.save()
        draggedGroupID = nil
        return true
    }

    private func showTodoCreationPanel() {
        NotificationCenter.default.post(name: TodoCreationSettings.showPanelNotification, object: nil)
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
