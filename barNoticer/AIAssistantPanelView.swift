import SwiftUI

enum AIAssistantPanelStyle {
    enum ProgressPlacement {
        case promptOverlay
    }

    static let progressPlacement: ProgressPlacement = .promptOverlay
    static let promptFieldHeight: CGFloat = 28
    static let panelBackgroundOpacity = 0.94
    static let inputBackgroundOpacity = 0.72
    static let responseBackgroundOpacity = 0.72
    static let proposalBackgroundOpacity = 0.62
    static let todoCardBackgroundOpacity = 0.56
    static let completedTodoCardBackgroundOpacity = 0.62
    static let primaryTextOpacity = 0.98
    static let secondaryTextOpacity = 0.88
    static let tertiaryTextOpacity = 0.78
    static let subtleTextOpacity = 0.74
    static let borderOpacity = 0.32
    static let resetsResponseScrollOnContentChange = true
}

struct AIAssistantPanelView: View {
    @ObservedObject var model: AIAssistantModel
    var close: () -> Void

    private var hasVisibleResponse: Bool {
        AIVisibleResponse.hasVisibleContent(model.response)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "sparkles")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.94))

                ZStack(alignment: .leading) {
                    if !model.progress.displayText.isEmpty {
                        Text(model.progress.displayText)
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.white.opacity(AIAssistantPanelStyle.primaryTextOpacity))
                            .transition(.opacity.combined(with: .scale(scale: 0.98)))
                            .allowsHitTesting(false)
                    } else if model.prompt.isEmpty {
                        Text("询问 AI，或写下当日总结")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(.white.opacity(AIAssistantPanelStyle.secondaryTextOpacity))
                            .allowsHitTesting(false)
                    }

                    TransparentPromptEditor(
                        text: $model.prompt,
                        focusRequestID: model.focusRequestID,
                        onSubmit: model.submit
                    )
                    .opacity(model.progress.displayText.isEmpty ? 1 : 0.04)
                }
                .frame(height: AIAssistantPanelStyle.promptFieldHeight)
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background(.black.opacity(AIAssistantPanelStyle.inputBackgroundOpacity), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(.white.opacity(AIAssistantPanelStyle.borderOpacity), lineWidth: 1)
            }
            .animation(.easeInOut(duration: 0.18), value: model.progress)

            if !model.proposals.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("待确认操作")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white.opacity(AIAssistantPanelStyle.secondaryTextOpacity))

                        Spacer()

                        Button("全部忽略") {
                            model.dismissAllProposals()
                        }
                        .buttonStyle(.plain)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(AIAssistantPanelStyle.secondaryTextOpacity))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(.white.opacity(0.12), in: Capsule())

                        Button("全部执行") {
                            model.applyAllProposals()
                        }
                        .buttonStyle(.borderedProminent)
                        .font(.caption.weight(.semibold))
                    }

                    ForEach(model.proposals) { proposal in
                        AIProposalRow(proposal: proposal, model: model)
                    }
                }
            }

            if hasVisibleResponse {
                Divider().overlay(.white.opacity(0.2))
                AIAssistantResponseView(model: model)
                    .id(model.response)
            }

            if case let .failed(message) = model.state {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.red.opacity(0.95))
            }
        }
        .padding(16)
        .frame(width: 720, alignment: .topLeading)
        .animation(.smooth(duration: 0.28), value: hasVisibleResponse)
        .animation(.smooth(duration: 0.24), value: model.state)
        .background(.black.opacity(AIAssistantPanelStyle.panelBackgroundOpacity), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(.white.opacity(AIAssistantPanelStyle.borderOpacity), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.38), radius: 34, y: 18)
        .environment(\.colorScheme, .dark)
        .onAppear {
            focusInput()
        }
        .onExitCommand {
            close()
        }
    }

    private func focusInput() {
        DispatchQueue.main.async {
            model.requestInputFocus()
        }
    }
}

private struct AIAssistantResponseView: View {
    @ObservedObject var model: AIAssistantModel

    var body: some View {
        ScrollView {
            AIAssistantMessageContent(text: model.response, model: model)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(1)
        }
        .frame(maxHeight: 170)
        .scrollIndicators(.hidden)
        .padding(12)
        .background(.black.opacity(AIAssistantPanelStyle.responseBackgroundOpacity), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(.white.opacity(AIAssistantPanelStyle.borderOpacity), lineWidth: 1)
        }
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
                            .foregroundStyle(.white.opacity(AIAssistantPanelStyle.primaryTextOpacity))
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
    @ObservedObject var model: AIAssistantModel

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 7) {
                Text(proposalTitle)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.white.opacity(AIAssistantPanelStyle.secondaryTextOpacity))

                if let todoID = proposal.referencedTodoID {
                    AITodoReferenceCard(todo: model.referencedTodo(id: todoID))
                } else {
                    Text(proposal.summary)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.white.opacity(AIAssistantPanelStyle.primaryTextOpacity))
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 4)

            Button("忽略") {
                model.dismiss(proposal)
            }
            .buttonStyle(.plain)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white.opacity(AIAssistantPanelStyle.secondaryTextOpacity))
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.white.opacity(0.16), in: Capsule())

            Button("执行") {
                model.apply(proposal)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(10)
        .background(.black.opacity(AIAssistantPanelStyle.proposalBackgroundOpacity), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(AIAssistantPanelStyle.borderOpacity), lineWidth: 1)
        }
    }

    private var proposalTitle: String {
        switch proposal {
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
        case .saveDailySummary:
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
                .foregroundStyle(todo.isCompleted ? .green.opacity(0.94) : .white.opacity(AIAssistantPanelStyle.secondaryTextOpacity))

            Capsule()
                .fill(todo.priority.islandColor.opacity(todo.exists ? 1 : 0.38))
                .frame(width: 4, height: 20)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: todo.priority.systemImage)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(todo.priority.islandColor.opacity(todo.exists ? 1 : 0.72))

                    Text(todo.exists ? "\(todo.priority.title)重要性" : "事项不存在")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(todo.exists ? todo.priority.islandColor : .white.opacity(AIAssistantPanelStyle.subtleTextOpacity))
                }

                Text(todo.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(todo.exists ? .white.opacity(AIAssistantPanelStyle.primaryTextOpacity) : .white.opacity(AIAssistantPanelStyle.secondaryTextOpacity))
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
                    .foregroundStyle(.white.opacity(AIAssistantPanelStyle.tertiaryTextOpacity))
                    .lineLimit(1)
                }
            }

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.black.opacity(todo.isCompleted ? AIAssistantPanelStyle.completedTodoCardBackgroundOpacity : AIAssistantPanelStyle.todoCardBackgroundOpacity), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(todo.priority.islandColor.opacity(todo.exists ? 0.48 : 0.18), lineWidth: 1)
        }
    }
}
