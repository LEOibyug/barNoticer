import AppKit

/// 统一的辅助功能动效策略：SwiftUI 与 AppKit/Core Animation 动画共用同一判断，
/// 系统偏好运行中切换即时生效。
@MainActor
enum MotionPreferences {
    static var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }
}

/// NSAnimationContext 便捷封装：减少动态效果时不播放动画，
/// duration 归零使 animator 调用立即应用最终值。
extension NSAnimationContext {
    @MainActor
    static func runAnimation(
        duration: TimeInterval,
        timing: CAMediaTimingFunction? = nil,
        animations: () -> Void,
        completion: (() -> Void)? = nil
    ) {
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = MotionPreferences.reduceMotion ? 0 : duration
            context.timingFunction = timing
            animations()
        }, completionHandler: completion.map { handler in { handler() } })
    }
}
