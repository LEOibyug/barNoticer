import Foundation

struct AIAssistantReply {
    let sessionID: UUID
    let message: String
    let pendingActionCount: Int
    let isFailure: Bool

    var title: String { isFailure ? "AI 请求失败" : "AI 回复" }
    var openButtonTitle: String { pendingActionCount > 0 ? "查看待确认操作" : "继续对话" }
}

@MainActor
protocol AIAssistantReplyPresenting: AnyObject {
    func presentAssistantReply(_ reply: AIAssistantReply, onOpenChat: @escaping () -> Void)
    func dismissAssistantReply()
}
