import SwiftUI

enum AIAssistantPanelStyle {
    static let promptFieldHeight: CGFloat = 28
    static let activityHeight: CGFloat = 54
}

struct AIAssistantPanelView: View {
    @ObservedObject var model: AIAssistantModel
    var close: () -> Void
    var newConversation: (() -> Void)? = nil
    var escape: (() -> Void)? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private func handleEscape() {
        guard !model.isComposingPromptText, !model.isChoosingImages,
              model.memoryClearConfirmation == nil else { return }
        if let escape { escape() }
        else if model.isConversationEmpty { close() }
        else if let newConversation { newConversation() }
        else { model.startNewConversation() }
    }

    private var hasVisibleResponse: Bool {
        AIVisibleResponse.hasVisibleContent(model.response)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("AI 助手")
                    .font(.caption.weight(.semibold))
                if model.state == .loading {
                    Text("关闭窗口后会继续处理")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    if let newConversation { newConversation() }
                    else { model.startNewConversation() }
                } label: {
                    Label("新对话", systemImage: "square.and.pencil")
                }
                .buttonStyle(.plain)
                .font(.caption.weight(.medium))
                .help(model.state == .loading ? "停止当前请求并开始新对话，已执行的操作会保留" : "清空当前上下文并开始新对话")
                Button(action: close) {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("隐藏聊天窗口")
                .help("隐藏窗口，保留会话并继续后台处理")
            }
            .foregroundStyle(.secondary)

            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.secondary)

                TransparentPromptEditor(
                    text: $model.prompt,
                    isComposingText: $model.isComposingPromptText,
                    focusRequestID: model.focusRequestID,
                    onSubmit: model.submit,
                    onPasteImages: model.pasteImages,
                    onEscape: handleEscape
                )
                .disabled(model.state == .loading)
                .frame(height: AIAssistantPanelStyle.promptFieldHeight)

                Button(action: model.chooseImages) {
                    Image(systemName: "photo.badge.plus")
                        .font(.system(size: 18))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(model.state == .loading || model.images.count >= AIImageAttachment.maxCount)
                .help("添加图片，也可用 ⌘V 粘贴截图（最多 4 张）")
                .accessibilityLabel("添加图片")

                Button(action: model.submit) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 23))
                }
                .buttonStyle(.plain)
                .foregroundStyle(model.canSubmit ? Color.accentColor : .secondary.opacity(0.5))
                .disabled(!model.canSubmit)
                .help("发送文字和图片")
                .accessibilityLabel("发送")
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(.fill.quinary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))

            if !model.images.isEmpty {
                HStack(spacing: 10) {
                    ForEach(model.images) { attachment in
                        ZStack(alignment: .topTrailing) {
                            if let preview = attachment.preview {
                                Image(nsImage: preview)
                                    .resizable()
                                    .scaledToFit()
                                    .frame(width: 88, height: 64)
                                    .background(.fill.quaternary, in: RoundedRectangle(cornerRadius: 8))
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .help(attachment.name)
                                    .accessibilityLabel(attachment.name)
                            }
                            Button { model.removeImage(id: attachment.id) } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .symbolRenderingMode(.palette)
                                    .foregroundStyle(.primary, .quaternary)
                            }
                            .buttonStyle(.plain)
                            .help("移除 \(attachment.name)")
                            .accessibilityLabel("移除 \(attachment.name)")
                            .padding(3)
                        }
                    }
                    Spacer(minLength: 0)
                    Text("\(model.images.count)/4")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if let error = model.imageInputError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }

            if model.state == .loading || !model.activityLines.isEmpty {
                AIAssistantActivityView(model: model)
            }

            if hasVisibleResponse && model.hasSummaryPreview {
                Divider()
                AIAssistantResponseView(model: model)
            }

            if !model.proposals.isEmpty {
                let summariesOnly = model.proposals.allSatisfy { proposal in
                    if case .saveSummary = proposal { return true }
                    return false
                }
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text(summariesOnly ? "保存确认" : "待确认操作")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)

                        Spacer()

                        if !summariesOnly {
                            Button("全部忽略") {
                                model.dismissAllProposals()
                            }
                            .disabled(model.state == .loading)
                            .buttonStyle(.bordered)
                            .controlSize(.small)

                            Button("全部执行") {
                                model.applyAllProposals()
                            }
                            .disabled(model.state == .loading)
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                        }
                    }

                    // 多条待确认操作使用独立受限滚动区，底部操作始终可达。
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            ForEach(model.proposals) { proposal in
                                AIProposalRow(proposal: proposal, sessionID: model.sessionID, model: model)
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                    .scrollIndicators(.automatic)
                }
            }

            if hasVisibleResponse && !model.hasSummaryPreview {
                Divider()
                AIAssistantResponseView(model: model)
            }

            if case let .failed(message) = model.state {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .padding(16)
        .frame(maxWidth: 720, alignment: .topLeading)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .animation(reduceMotion ? nil : .smooth(duration: 0.28), value: hasVisibleResponse)
        .animation(reduceMotion ? nil : .smooth(duration: 0.24), value: model.state)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: AIAssistantPanelChrome.cornerRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: AIAssistantPanelChrome.cornerRadius, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.35), lineWidth: 0.5)
        }
        .onAppear {
            focusInput()
        }
        .onExitCommand(perform: handleEscape)
        .alert("清空全部记忆？", isPresented: Binding(
            get: { model.memoryClearConfirmation != nil },
            set: { if !$0 { model.hideMemoryClearConfirmation() } }
        ), presenting: model.memoryClearConfirmation) { request in
            Button("取消", role: .cancel) { model.cancelMemoryClearConfirmation() }
            Button("清空记忆", role: .destructive) { model.confirmMemoryClear(request) }
        } message: { request in
            Text("将删除 \(request.entryCount) 条记忆，无法恢复。待办和聊天记录会保留。")
        }
    }

    private func focusInput() {
        DispatchQueue.main.async {
            model.requestInputFocus()
        }
    }
}

private struct AIAssistantActivityView: View {
    @ObservedObject var model: AIAssistantModel

    private var lines: [String] {
        var lines = model.activityLines
        if model.state == .loading {
            let status = model.progress.displayText
            if !status.isEmpty, lines.last != status {
                lines.append(status)
            } else if lines.isEmpty {
                lines.append("正在等待模型回复…")
            }
        }
        return lines
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(lines.indices, id: \.self) { index in
                        Text(lines[index])
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Color.clear
                        .frame(height: 0)
                        .id("activity-end")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.horizontal, 1)
            }
            .frame(height: AIAssistantPanelStyle.activityHeight)
            .scrollIndicators(.automatic)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("模型与工具活动")
            .onAppear { proxy.scrollTo("activity-end", anchor: .bottom) }
            .onChange(of: lines) { _, _ in
                proxy.scrollTo("activity-end", anchor: .bottom)
            }
        }
    }
}

private struct AIAssistantResponseView: View {
    @ObservedObject var model: AIAssistantModel

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Group {
                        if model.hasSummaryPreview {
                            Text(model.response)
                                .textSelection(.enabled)
                        } else {
                            AIAssistantMessageContent(text: model.response, model: model)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    .padding(1)
                    Color.clear
                        .frame(height: 0)
                        .id("response-end")
                }
            }
            .frame(minHeight: 44, maxHeight: 170)
            .scrollIndicators(.automatic)
            .onAppear { proxy.scrollTo("response-end", anchor: .bottom) }
            .onChange(of: model.response) { _, _ in
                proxy.scrollTo("response-end", anchor: .bottom)
            }
        }
        .padding(12)
        .background(.fill.quinary.opacity(0.4), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct AIAssistantMessageContent: View {
    let text: String
    @ObservedObject var model: AIAssistantModel

    private var parts: [AITodoReferencePart] {
        AITodoReferenceParser.parse(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(parts.enumerated()), id: \.offset) { _, part in
                switch part {
                case let .text(text):
                    if !text.isEmpty {
                        Text(text)
                            .font(.system(size: 15, weight: .regular))
                            .lineSpacing(3)
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                case let .todo(id):
                    AITodoReferenceButton(todoID: id, model: model)
                }
            }
        }
    }
}

private struct AITodoReferenceButton: View {
    let todoID: UUID
    @ObservedObject var model: AIAssistantModel

    var body: some View {
        let todo = model.referencedTodo(id: todoID)
        Button {
            guard todo.exists, !todo.isCompleted else { return }
            model.completeReferencedTodo(id: todoID)
        } label: {
            AITodoReferenceCard(todo: todo)
        }
        .buttonStyle(.plain)
        .disabled(!todo.exists || todo.isCompleted)
        .help(todo.isCompleted ? "已完成" : "点击标记为完成")
        .id(model.todoReferenceRefreshID)
    }
}

private struct AIProposalRow: View {
    let proposal: AIActionProposal
    let sessionID: UUID
    @ObservedObject var model: AIAssistantModel

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 7) {
                Text(proposalTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                if let todoID = proposal.referencedTodoID {
                    AITodoReferenceCard(todo: model.referencedTodo(id: todoID))
                    if let changeSummary = proposal.changeSummary {
                        Text(changeSummary)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else if case let .saveSummary(_, title, start, end, _) = proposal {
                    Text(title)
                        .font(.subheadline.weight(.medium))
                    Text(SavedSummary.periodDescription(start: start, end: end))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(proposal.summary)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 4)

            Button(isSummary ? "不保存" : "忽略") {
                model.dismiss(proposal, sessionID: sessionID)
            }
            .disabled(model.state == .loading)
            .buttonStyle(.bordered)
            .controlSize(.small)

            Button(actionTitle) {
                model.apply(proposal, sessionID: sessionID)
            }
            .disabled(model.state == .loading)
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(10)
        .background(.fill.quinary.opacity(0.5), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var isSummary: Bool {
        if case .saveSummary = proposal { return true }
        return false
    }

    private var actionTitle: String {
        switch proposal {
        case .saveSummary: return "保存总结"
        case .clearGlobalMemory: return "清空记忆…"
        default: return "执行"
        }
    }

    private var proposalTitle: String {
        switch proposal {
        case .clearGlobalMemory:
            return "清空全局记忆"
        case .completeTodo:
            return "完成事项"
        case .deleteTodo:
            return "删除事项"
        case .updateTodo:
            return "修改事项"
        case .createTodo:
            return "新增事项"
        case .createGroup:
            return "新增分组"
        case .updateGroup:
            return "修改分组"
        case .deleteGroup:
            return "删除分组"
        case .saveSummary:
            return "保存总结"
        }
    }
}

private struct AITodoReferenceCard: View {
    let todo: AIReferencedTodo

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: todo.isCompleted ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(todo.isCompleted ? .green : .secondary)

            Capsule()
                .fill(todo.priority.color.opacity(todo.exists ? 1 : 0.38))
                .frame(width: 4, height: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: todo.priority.systemImage)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(todo.priority.color.opacity(todo.exists ? 1 : 0.72))

                    Text(todo.exists ? "\(todo.priority.title)重要性" : "事项不存在")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(todo.exists ? AnyShapeStyle(todo.priority.color) : AnyShapeStyle(.secondary))
                        .accessibilityLabel(todo.exists ? "\(todo.priority.title)重要性" : "事项不存在")
                }

                Text(todo.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(todo.exists ? .primary : .secondary)
                    .lineLimit(1)

                if todo.exists {
                    HStack(spacing: 6) {
                        Text(todo.ageText)
                        if let groupName = todo.groupName {
                            Text(groupName)
                        }
                        if let scheduleText = todo.scheduleText {
                            Text(scheduleText)
                        }
                    }
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.fill.quinary.opacity(0.6), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(todo.priority.color.opacity(todo.exists ? 0.4 : 0.15), lineWidth: 1)
        }
    }
}
