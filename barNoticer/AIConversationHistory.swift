import Foundation

struct AIConversationHistory: Equatable {
    private(set) var messages: [AIChatMessage] = []
    var maxTurns: Int

    init(maxTurns: Int = 4) {
        self.maxTurns = max(1, maxTurns)
    }

    var hasVisibleContent: Bool {
        messages.contains { $0.role == "assistant" && !($0.content ?? "").isEmpty }
    }

    var visibleEntries: [AIConversationEntry] {
        messages.enumerated().compactMap { index, message in
            guard (message.role == "user" || message.role == "assistant"),
                  let content = message.content?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !content.isEmpty
            else {
                return nil
            }

            return AIConversationEntry(id: "\(index)-\(message.role)-\(content.hashValue)", role: message.role == "user" ? .user : .assistant, content: content)
        }
    }

    mutating func appendUser(_ content: String) {
        append(AIChatMessage(role: "user", content: content))
    }

    mutating func appendAssistant(_ content: String) {
        append(AIChatMessage(role: "assistant", content: content))
    }

    mutating func appendAssistant(_ message: AIChatMessage) {
        append(message)
    }

    mutating func replaceLastAssistantContent(with content: String) {
        guard let index = messages.lastIndex(where: { $0.role == "assistant" }) else {
            appendAssistant(content)
            return
        }
        messages[index].content = content
    }

    mutating func reset() {
        messages = []
    }

    private mutating func append(_ message: AIChatMessage) {
        messages.append(message)
        trim()
    }

    private mutating func trim() {
        let maxMessages = maxTurns * 2 + 1
        if messages.count > maxMessages {
            messages.removeFirst(messages.count - maxMessages)
        }
    }
}

struct AIConversationEntry: Equatable, Identifiable {
    enum Role: Equatable {
        case user
        case assistant
    }

    let id: String
    let role: Role
    let content: String

    init(id: String = UUID().uuidString, role: Role, content: String) {
        self.id = id
        self.role = role
        self.content = content
    }
}

enum AITodoReferencePart: Equatable, Identifiable {
    case text(String)
    case todo(UUID)

    var id: String {
        switch self {
        case let .text(text):
            return "text-\(text.hashValue)"
        case let .todo(id):
            return "todo-\(id.uuidString)"
        }
    }
}

enum AITodoReferenceParser {
    static func parse(_ text: String) -> [AITodoReferencePart] {
        let text = AIPlainResponseSanitizer.sanitize(text)
        let pattern = #"\[\[todo:([0-9a-fA-F-]{36})\]\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return [.text(text)]
        }

        let nsText = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: nsText.length))
        guard !matches.isEmpty else { return [.text(text)] }

        var parts: [AITodoReferencePart] = []
        var cursor = 0

        for match in matches {
            if match.range.location > cursor {
                appendText(nsText.substring(with: NSRange(location: cursor, length: match.range.location - cursor)), to: &parts)
            }

            let idString = nsText.substring(with: match.range(at: 1))
            if let id = UUID(uuidString: idString) {
                parts.append(.todo(id))
            } else {
                parts.append(.text(nsText.substring(with: match.range)))
            }

            cursor = match.range.location + match.range.length
        }

        if cursor < nsText.length {
            appendText(nsText.substring(from: cursor), to: &parts)
        }

        return parts
    }

    private static func appendText(_ text: String, to parts: inout [AITodoReferencePart]) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if case .todo = parts.last, trimmed.isTodoReferenceSeparator {
            return
        }
        parts.append(.text(trimmed))
    }
}

private extension String {
    var isTodoReferenceSeparator: Bool {
        let separators = CharacterSet(charactersIn: "、,，;；")
        return unicodeScalars.allSatisfy { separators.contains($0) }
    }
}

enum AIPlainResponseSanitizer {
    static func sanitize(_ text: String) -> String {
        let lines = text
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "__", with: "")
            .split(whereSeparator: \.isNewline)
            .compactMap { rawLine -> String? in
                var line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
                line = stripListPrefix(from: line)
                line = stripReferenceTrailingMetadata(from: line)
                return line.isEmpty ? nil : line
            }

        return lines.joined(separator: "\n")
    }

    private static func stripListPrefix(from line: String) -> String {
        var line = line
        while line.hasPrefix("-") || line.hasPrefix("•") {
            line.removeFirst()
            line = line.trimmingCharacters(in: .whitespaces)
        }

        if let match = line.range(of: #"^\d+\.\s+"#, options: .regularExpression) {
            line.removeSubrange(match)
        }

        return line.trimmingCharacters(in: .whitespaces)
    }

    private static func stripReferenceTrailingMetadata(from line: String) -> String {
        let pattern = #"\[\[todo:[0-9a-fA-F-]{36}\]\]\s*[\(（][^）)]*[\)）]\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return line }
        let nsLine = line as NSString
        let range = NSRange(location: 0, length: nsLine.length)
        guard let match = regex.firstMatch(in: line, range: range) else { return line }
        let matched = nsLine.substring(with: match.range)
        guard let referenceRange = matched.range(of: #"\[\[todo:[0-9a-fA-F-]{36}\]\]"#, options: .regularExpression) else {
            return line
        }
        let reference = String(matched[referenceRange])
        return nsLine.replacingCharacters(in: match.range, with: reference).trimmingCharacters(in: .whitespaces)
    }
}

enum AIVisibleResponse {
    static func sanitized(_ text: String) -> String {
        AIPlainResponseSanitizer.sanitize(text).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func hasVisibleContent(_ text: String) -> Bool {
        !sanitized(text).isEmpty
    }

    static func fallbackText(toolCallCount: Int, proposalCount: Int) -> String {
        fallbackText(toolNames: Array(repeating: "", count: toolCallCount), proposalCount: proposalCount)
    }

    static func fallbackText(toolNames: [String], proposalCount: Int) -> String {
        if proposalCount > 0 {
            return "已整理出 \(proposalCount) 项待确认操作。"
        }

        if toolNames.contains("get_completion_stats") {
            return "已读取今日任务统计。"
        }

        if toolNames.contains("list_completed_todos") {
            return "已读取已完成事项。"
        }

        if toolNames.contains("list_active_todos") {
            return "已读取未完成事项。"
        }

        if !toolNames.isEmpty {
            return "已读取事项并完成处理。"
        }

        return "已完成。"
    }
}
