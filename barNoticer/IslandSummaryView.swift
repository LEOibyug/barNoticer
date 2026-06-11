import Combine
import SwiftData
import SwiftUI

enum IslandSummaryStyle {
    static let secondaryTextOpacity = 0.78
    static let tertiaryTextOpacity = 0.68
    static let subtleTextOpacity = 0.64
    static let itemBackgroundOpacity = 0.12
    static let dividerOpacity = 0.14
}

enum IslandSummaryRefreshPolicy {
    static let timelineInterval: TimeInterval = 60
}

struct IslandSummaryView: View {
    @Environment(\.modelContext) private var modelContext
    @EnvironmentObject private var contentVisibility: IslandContentVisibilityModel
    @Query private var todoItems: [TodoItem]
    @Query private var storedGroups: [TodoGroup]

    var openMainWindow: () -> Void = {}

    @State private var layoutVersion = 0
    @State private var now = Date()
    @AppStorage(IslandDisplayMode.storageKey) private var modeRawValue = IslandDisplayMode.standard.rawValue
    @AppStorage(IslandGroupingMode.storageKey) private var groupingModeRawValue = IslandGroupingMode.defaultMode.rawValue

    private var mode: IslandDisplayMode {
        IslandDisplayMode(rawValue: modeRawValue) ?? .standard
    }

    private var groupingMode: IslandGroupingMode {
        IslandGroupingMode(rawValue: groupingModeRawValue) ?? .defaultMode
    }

    private var layoutSettings: IslandLayoutSettings {
        _ = layoutVersion
        return IslandLayoutSettings(defaults: .standard, mode: mode)
    }

    private var activeItems: [TodoItem] {
        TodoSorter.sorted(todoItems, groups: groups, now: now).filter { !$0.isCompleted }
    }

    private var groups: [TodoGroup] {
        TodoGroupResolver.normalizedGroups(storedGroups)
    }

    private var visibleDisplayGroups: [TodoDisplayGroup] {
        TodoSorter.displayGroups(items: IslandStandardTodoPolicy.items(from: activeItems), groups: groups, now: now)
    }

    private var visiblePriorityGroups: [TodoPriorityGroup] {
        TodoSorter.priorityGroups(IslandStandardTodoPolicy.items(from: activeItems), now: now)
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
        .onAppear {
            now = Date()
        }
        .onReceive(Timer.publish(every: IslandSummaryRefreshPolicy.timelineInterval, on: .main, in: .common).autoconnect()) { date in
            now = date
        }
    }

    private var islandContent: some View {
        VStack(alignment: .leading, spacing: 0) {
            Color.clear
                .frame(height: topBridgeHeight)

            VStack(alignment: .leading, spacing: 11) {
                header
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
                    .foregroundStyle(.white.opacity(IslandSummaryStyle.secondaryTextOpacity))
            }

            Spacer()

            createTodoButton
            groupingToggle
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

    private var createTodoButton: some View {
        Button {
            NotificationCenter.default.post(name: TodoCreationSettings.showPanelNotification, object: nil)
        } label: {
            Image(systemName: "plus")
                .font(.caption.weight(.semibold))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.86))
        .background(.white.opacity(0.1), in: Circle())
        .help("新建事项")
    }

    private var modeToggle: some View {
        Button {
            withAnimation(.smooth(duration: IslandAnimationTimings.modeSwitchDuration)) {
                modeRawValue = mode == .standard ? IslandDisplayMode.wide.rawValue : IslandDisplayMode.standard.rawValue
            }
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

    private var groupingToggle: some View {
        Button {
            withAnimation(.smooth(duration: IslandAnimationTimings.modeSwitchDuration)) {
                groupingModeRawValue = groupingMode == .priority ? IslandGroupingMode.group.rawValue : IslandGroupingMode.priority.rawValue
            }
        } label: {
            Image(systemName: groupingMode.systemImage)
                .font(.caption.weight(.semibold))
                .frame(width: 24, height: 24)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white.opacity(0.82))
        .background(.white.opacity(0.1), in: Circle())
        .help(groupingMode == .priority ? "按分类分组" : "按重要性分组")
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
            if activeItems.isEmpty {
                emptyState
            } else {
                ScrollView(.vertical) {
                    Group {
                        if groupingMode == .priority {
                            VStack(spacing: 8) {
                                ForEach(visiblePriorityGroups) { priorityGroup in
                                    IslandPrioritySection(priority: priorityGroup.priority, items: priorityGroup.items, groups: groups, now: now)
                                }
                            }
                        } else {
                            VStack(spacing: 8) {
                                ForEach(visibleDisplayGroups) { displayGroup in
                                    IslandDisplayGroupSection(displayGroup: displayGroup, groups: groups, now: now)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 1)
                    .transition(.asymmetric(
                        insertion: .opacity.combined(with: .move(edge: .trailing)),
                        removal: .opacity.combined(with: .move(edge: .leading))
                    ))
                    .id(groupingMode)
                }
                .scrollIndicators(.never)
            }
        }
    }

    private var wideTodoContent: some View {
        Group {
            if activeItems.isEmpty {
                emptyState
            } else if groupingMode == .priority {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(TodoPriority.allCases) { priority in
                        IslandPriorityColumn(priority: priority, items: wideItems(for: priority), groups: groups, now: now)
                    }
                }
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .trailing)),
                    removal: .opacity.combined(with: .move(edge: .leading))
                ))
                .id(groupingMode)
            } else {
                GeometryReader { proxy in
                    let columnWidth = IslandWideGroupLayoutPolicy.columnWidth(availableWidth: proxy.size.width)
                    let contentWidth = IslandWideGroupLayoutPolicy.contentWidth(
                        groupCount: visibleDisplayGroups.count,
                        availableWidth: proxy.size.width
                    )

                    ScrollView(.horizontal) {
                        HStack(alignment: .top, spacing: IslandWideGroupLayoutPolicy.columnSpacing) {
                            ForEach(visibleDisplayGroups) { displayGroup in
                                IslandDisplayGroupColumn(displayGroup: displayGroup, groups: groups, now: now)
                                    .frame(width: columnWidth)
                                    .frame(maxHeight: .infinity)
                            }
                        }
                        .frame(width: contentWidth, height: proxy.size.height, alignment: .topLeading)
                        .padding(.horizontal, 1)
                    }
                    .scrollIndicators(.never)
                }
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .trailing)),
                    removal: .opacity.combined(with: .move(edge: .leading))
                ))
                .id(groupingMode)
            }
        }
    }

    private var footer: some View {
        HStack {
            if let footerText {
                Text(footerText)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(IslandSummaryStyle.tertiaryTextOpacity))
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
        "顶部中央悬停可快速查看"
    }

    private func wideItems(for priority: TodoPriority) -> [TodoItem] {
        IslandWideTodoPolicy.items(for: priority, from: activeItems)
    }
}

enum IslandWideTodoPolicy {
    static func items(for priority: TodoPriority, from items: [TodoItem]) -> [TodoItem] {
        items.filter { $0.priority == priority }
    }
}

enum IslandStandardTodoPolicy {
    static func items(from items: [TodoItem]) -> [TodoItem] {
        items
    }
}

enum IslandGroupingMode: String, CaseIterable, Identifiable {
    case priority
    case group

    static let storageKey = "island.groupingMode"
    static let defaultMode = Self.priority

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .priority: "exclamationmark.3"
        case .group: "folder"
        }
    }
}

enum IslandWideGroupLayoutPolicy {
    static let maxVisibleColumns = 3
    static let columnSpacing: CGFloat = 10
    static let allowsVerticalColumnScroll = true

    static func needsHorizontalScroll(groupCount: Int) -> Bool {
        groupCount > maxVisibleColumns
    }

    static func columnWidth(availableWidth: CGFloat) -> CGFloat {
        let totalSpacing = columnSpacing * CGFloat(maxVisibleColumns - 1)
        return max(0, (availableWidth - totalSpacing) / CGFloat(maxVisibleColumns))
    }

    static func contentWidth(groupCount: Int, availableWidth: CGFloat) -> CGFloat {
        guard needsHorizontalScroll(groupCount: groupCount) else {
            return availableWidth
        }

        let columnsWidth = columnWidth(availableWidth: availableWidth) * CGFloat(groupCount)
        let spacingWidth = columnSpacing * CGFloat(max(0, groupCount - 1))
        return columnsWidth + spacingWidth
    }
}

private struct IslandPriorityColumn: View {
    let priority: TodoPriority
    let items: [TodoItem]
    let groups: [TodoGroup]
    let now: Date

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
                    .foregroundStyle(.white.opacity(IslandSummaryStyle.subtleTextOpacity))
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .center)
            } else {
                ScrollView(.vertical) {
                    IslandTodoLineList(items: items, groups: groups, now: now)
                }
                .scrollIndicators(.never)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(.white.opacity(IslandSummaryStyle.itemBackgroundOpacity), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(priority.islandColor.opacity(0.18), lineWidth: 1)
        }
    }
}

private struct IslandPrioritySection: View {
    let priority: TodoPriority
    let items: [TodoItem]
    let groups: [TodoGroup]
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
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

                Spacer(minLength: 8)
            }
            .foregroundStyle(priority.islandColor)

            IslandTodoLineList(items: items, groups: groups, now: now)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(.white.opacity(IslandSummaryStyle.itemBackgroundOpacity), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(priority.islandColor.opacity(0.22), lineWidth: 1)
        }
    }
}

private struct IslandDisplayGroupColumn: View {
    let displayGroup: TodoDisplayGroup
    let groups: [TodoGroup]
    let now: Date

    var body: some View {
        IslandDisplayGroupSection(displayGroup: displayGroup, groups: groups, now: now, allowsVerticalScroll: IslandWideGroupLayoutPolicy.allowsVerticalColumnScroll)
            .frame(maxHeight: .infinity, alignment: .top)
    }
}

private struct IslandDisplayGroupSection: View {
    let displayGroup: TodoDisplayGroup
    let groups: [TodoGroup]
    let now: Date
    var allowsVerticalScroll = false

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 7) {
                Circle()
                    .fill(displayGroup.group.color)
                    .frame(width: 8, height: 8)

                Text(displayGroup.group.name)
                    .font(.caption.weight(.semibold))

                Text("\(displayGroup.items.count)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.black.opacity(0.82))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(displayGroup.group.color, in: Capsule())

                Spacer(minLength: 8)
            }
            .foregroundStyle(displayGroup.group.color)

            if allowsVerticalScroll {
                ScrollView(.vertical) {
                    IslandTodoLineList(items: displayGroup.items, groups: groups, now: now)
                }
                .scrollIndicators(.never)
                .frame(maxHeight: .infinity, alignment: .top)
            } else {
                IslandTodoLineList(items: displayGroup.items, groups: groups, now: now)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(.white.opacity(IslandSummaryStyle.itemBackgroundOpacity), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(displayGroup.group.color.opacity(0.26), lineWidth: 1)
        }
    }
}

private struct IslandTodoLineList: View {
    let items: [TodoItem]
    let groups: [TodoGroup]
    let now: Date
    @State private var expandedItemID: UUID?

    var body: some View {
        VStack(spacing: 0) {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                IslandTodoLine(
                    item: item,
                    groups: groups,
                    now: now,
                    isExpanded: expandedItemID == item.id
                ) {
                    guard item.note?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return }
                    withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                        expandedItemID = expandedItemID == item.id ? nil : item.id
                    }
                }

                if index < items.count - 1 {
                    Divider()
                        .overlay(.white.opacity(IslandSummaryStyle.dividerOpacity))
                        .padding(.leading, 29)
                }
            }
        }
    }
}

private struct IslandTodoLine: View {
    @Bindable var item: TodoItem
    let groups: [TodoGroup]
    let now: Date
    let isExpanded: Bool
    let toggleExpansion: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 10) {
                Button {
                    if item.scheduleKind == .recurring {
                        item.completeCurrentOccurrence()
                    } else {
                        item.updateCompletion(true)
                    }
                } label: {
                    Image(systemName: "circle")
                        .font(.system(size: 15, weight: .medium))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.72))
                .help("完成")

                Capsule()
                    .fill(item.priority.islandColor)
                    .frame(width: 4, height: isExpanded ? 28 : 18)

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(item.title)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.92))
                            .lineLimit(1)

                        if item.note?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
                            Image(systemName: isExpanded ? "chevron.up" : "note.text")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.54))
                        }
                    }

                    HStack(spacing: 6) {
                        Text(TodoAgeFormatter.elapsedText(since: item.createdAt, now: now))
                        Text(TodoGroupResolver.group(for: item, groups: groups).name)
                        if let occurrence = item.nextOccurrence(after: now),
                           let scheduleText = TodoDeadlineFormatter.cardText(for: item, now: now) {
                            Text(scheduleText)
                                .foregroundStyle(occurrence < now ? .red.opacity(0.92) : .white.opacity(IslandSummaryStyle.tertiaryTextOpacity))
                        }
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.white.opacity(IslandSummaryStyle.tertiaryTextOpacity))
                    .lineLimit(1)
                }

                Spacer(minLength: 8)
            }

            if isExpanded, let noteText {
                ScrollView(.vertical) {
                    Text(noteText)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.82))
                        .lineSpacing(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.disabled)
                }
                .scrollIndicators(.never)
                .frame(maxHeight: 48, alignment: .top)
                .padding(.leading, 43)
                .transition(.asymmetric(
                    insertion: .opacity.combined(with: .move(edge: .top)),
                    removal: .opacity
                ))
            }
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture(perform: toggleExpansion)
    }

    private var noteText: String? {
        guard let note = item.note?.trimmingCharacters(in: .whitespacesAndNewlines), !note.isEmpty else {
            return nil
        }
        return note
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
        .modelContainer(for: [TodoItem.self, TodoGroup.self, DailySummary.self], inMemory: true)
}
