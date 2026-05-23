import SwiftData
import SwiftUI

struct IslandSummaryView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var contentVisibility: IslandContentVisibilityModel
    @Query private var todoItems: [TodoItem]

    var openMainWindow: () -> Void = {}

    @State private var quickAddDraft = IslandQuickAddDraft()
    @State private var layoutVersion = 0
    @AppStorage(IslandDisplayMode.storageKey) private var modeRawValue = IslandDisplayMode.standard.rawValue

    private var mode: IslandDisplayMode {
        IslandDisplayMode(rawValue: modeRawValue) ?? .standard
    }

    private var layoutSettings: IslandLayoutSettings {
        _ = layoutVersion
        return IslandLayoutSettings(defaults: .standard, mode: mode)
    }

    private var activeItems: [TodoItem] {
        TodoSorter.sorted(todoItems).filter { !$0.isCompleted }
    }

    private var standardVisibleItems: [TodoItem] {
        Array(activeItems.prefix(4))
    }

    private var visibleGroups: [TodoPriorityGroup] {
        TodoSorter.priorityGroups(standardVisibleItems)
    }

    private var topBridgeHeight: CGFloat {
        16 + layoutSettings.islandTopContentInset
    }

    var body: some View {
        GeometryReader { proxy in
            islandContent
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
                .clipShape(TopAttachedIslandShape(cornerRadius: 30))
                .background {
                    TopAttachedIslandShape(cornerRadius: 30)
                        .fill(.black)
                }
                .overlay {
                    TopAttachedIslandShape(cornerRadius: 30)
                        .stroke(.white.opacity(0.12), lineWidth: 1)
                }
                .shadow(color: .black.opacity(0.48), radius: 30, y: 18)
        }
        .onReceive(NotificationCenter.default.publisher(for: IslandLayoutSettings.didChangeNotification)) { _ in
            layoutVersion += 1
        }
    }

    private var islandContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .frame(height: topBridgeHeight)

            VStack(alignment: .leading, spacing: 11) {
                header
                quickAdd
                Group {
                    if mode == .wide {
                        wideTodoContent
                    } else {
                        standardTodoContent
                    }
                }
                .frame(maxHeight: .infinity, alignment: .top)
                footer
            }
            .padding(.horizontal, mode == .wide ? 18 : 15)
            .padding(.bottom, 15)
            .opacity(contentVisibility.isVisible ? 1 : 0)
            .allowsHitTesting(contentVisibility.isVisible)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("待办岛")
                    .font(.headline)
                    .foregroundStyle(.white)
                Text(activeItems.isEmpty ? "没有进行中的事项" : "\(activeItems.count) 项进行中")
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.6))
            }

            Spacer()

            modeToggle

            if let first = activeItems.first {
                Label(first.priority.title, systemImage: first.priority.systemImage)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(first.priority.islandColor)
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(first.priority.islandColor.opacity(0.14), in: Capsule())
            }
        }
    }

    private var modeToggle: some View {
        Button {
            modeRawValue = mode == .standard ? IslandDisplayMode.wide.rawValue : IslandDisplayMode.standard.rawValue
            IslandLayoutSettings.notifyLayoutChanged()
        } label: {
            Image(systemName: mode.systemImage)
                .font(.caption.weight(.semibold))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.82))
        .background(.white.opacity(0.1), in: Circle())
        .help(mode == .standard ? "切换到宽体模式" : "切换到普通模式")
    }

    private var quickAdd: some View {
        HStack(spacing: 8) {
            Menu {
                ForEach(TodoPriority.allCases) { priority in
                    Button {
                        quickAddDraft.priority = priority
                    } label: {
                        Label(priority.title, systemImage: priority.systemImage)
                    }
                }
            } label: {
                Label(quickAddDraft.priority.title, systemImage: quickAddDraft.priority.systemImage)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(quickAddDraft.priority.islandColor)
                    .labelStyle(.iconOnly)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(width: 26, height: 24)
            .help("选择重要性")

            ZStack(alignment: .leading) {
                if quickAddDraft.title.isEmpty {
                    Text("输入新待办，回车添加")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                        .allowsHitTesting(false)
                }

                TextField("", text: $quickAddDraft.title)
                    .textFieldStyle(.plain)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white)
                    .tint(.white)
                    .onSubmit(addTodo)
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .frame(height: 34)
        .background(.white.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.white.opacity(0.22), lineWidth: 1)
        }
    }

    private var emptyState: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .foregroundStyle(.green.opacity(0.95))
            Text("今天的队列是空的")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.68))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    }

    private var standardTodoContent: some View {
        Group {
            if visibleGroups.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical) {
                    VStack(spacing: 8) {
                        ForEach(visibleGroups) { group in
                            IslandPrioritySection(group: group)
                        }
                    }
                    .padding(.vertical, 1)
                }
                .scrollIndicators(.never)
            }
        }
    }

    private var wideTodoContent: some View {
        HStack(alignment: .top, spacing: 10) {
            ForEach(TodoPriority.allCases) { priority in
                IslandPriorityColumn(priority: priority, items: wideItems(for: priority))
            }
        }
    }

    private var footer: some View {
        HStack {
            if let footerText {
                Text(footerText)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.58))
                    .lineLimit(1)
            }

            Spacer()

            Button {
                openMainWindow()
            } label: {
                Label("管理", systemImage: "arrow.up.right")
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.white.opacity(0.86))
            .controlSize(.small)
        }
    }

    private var footerText: String? {
        if mode == .wide {
            return nil
        }

        return activeItems.count > standardVisibleItems.count ? "还有 \(activeItems.count - standardVisibleItems.count) 项未显示" : "顶部中央悬停可快速查看"
    }

    private var trimmedDraftTitle: String {
        quickAddDraft.trimmedTitle
    }

    private func addTodo() {
        let title = trimmedDraftTitle
        guard !title.isEmpty else { return }

        modelContext.insert(TodoItem(title: title, priority: quickAddDraft.priority))
        quickAddDraft.clearTitle()
    }

    private func wideItems(for priority: TodoPriority) -> [TodoItem] {
        Array(activeItems.filter { $0.priority == priority }.prefix(7))
    }
}

private struct IslandPriorityColumn: View {
    let priority: TodoPriority
    let items: [TodoItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: priority.systemImage)
                    .font(.caption.weight(.semibold))
                Text("\(priority.title)重要性")
                    .font(.caption.weight(.semibold))
                Text("\(items.count)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.black.opacity(0.82))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(priority.islandColor, in: Capsule())
                Spacer(minLength: 0)
            }
            .foregroundStyle(priority.islandColor)

            if items.isEmpty {
                Text("暂无")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.44))
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        IslandTodoLine(item: item)

                        if index < items.count - 1 {
                            Divider()
                                .overlay(.white.opacity(0.08))
                                .padding(.leading, 29)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(priority.islandColor.opacity(0.18), lineWidth: 1)
        }
    }
}

private struct IslandPrioritySection: View {
    let group: TodoPriorityGroup

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Image(systemName: group.priority.systemImage)
                    .font(.caption.weight(.semibold))

                Text("\(group.priority.title)重要性")
                    .font(.caption.weight(.semibold))

                Text("\(group.items.count)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.black.opacity(0.82))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(group.priority.islandColor, in: Capsule())

                Spacer(minLength: 8)
            }
            .foregroundStyle(group.priority.islandColor)

            VStack(spacing: 0) {
                ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                    IslandTodoLine(item: item)

                    if index < group.items.count - 1 {
                        Divider()
                            .overlay(.white.opacity(0.08))
                            .padding(.leading, 29)
                    }
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(.white.opacity(0.075), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(group.priority.islandColor.opacity(0.18), lineWidth: 1)
        }
    }
}

private struct IslandTodoLine: View {
    @Bindable var item: TodoItem

    var body: some View {
        HStack(spacing: 10) {
            Button {
                item.updateCompletion(true)
            } label: {
                Image(systemName: "circle")
                    .font(.system(size: 15, weight: .medium))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white.opacity(0.72))
            .help("完成")

            Capsule()
                .fill(item.priority.islandColor)
                .frame(width: 4, height: 18)

            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.92))
                    .lineLimit(1)

                Text(TodoAgeFormatter.elapsedText(since: item.createdAt))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(0.46))
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
        }
        .padding(.vertical, 6)
    }
}

private struct TopAttachedIslandShape: Shape {
    var cornerRadius: CGFloat

    func path(in rect: CGRect) -> Path {
        var path = Path()
        let radius = min(cornerRadius, min(rect.width, rect.height) / 2)

        path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + radius),
            control: CGPoint(x: rect.maxX, y: rect.minY)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
            control: CGPoint(x: rect.maxX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX, y: rect.maxY - radius),
            control: CGPoint(x: rect.minX, y: rect.maxY)
        )
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(
            to: CGPoint(x: rect.minX + radius, y: rect.minY),
            control: CGPoint(x: rect.minX, y: rect.minY)
        )
        path.closeSubpath()

        return path
    }
}

#Preview {
    IslandSummaryView()
        .modelContainer(for: TodoItem.self, inMemory: true)
}
