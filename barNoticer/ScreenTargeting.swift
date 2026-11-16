import AppKit

enum ScreenTargeting {
    /// 纯几何屏幕选取，用于多显示器布局计算与测试验证。
    static func screenFrame(at point: CGPoint, in frames: [CGRect], fallback: CGRect? = nil) -> CGRect {
        if let matched = frames.first(where: { $0.contains(point) }) {
            return matched
        }
        return fallback ?? frames.first ?? .zero
    }

    static func screenNumber(of screen: NSScreen?) -> NSNumber? {
        screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber
    }

    static func screen(forScreenNumber number: NSNumber?, screens: [NSScreen] = NSScreen.screens) -> NSScreen? {
        guard let number else { return nil }
        return screens.first { screenNumber(of: $0) == number }
    }

    static func screen(
        at point: CGPoint,
        screens: [NSScreen] = NSScreen.screens,
        fallback: NSScreen? = NSScreen.main
    ) -> NSScreen? {
        screens.first { NSMouseInRect(point, $0.frame, false) } ?? fallback ?? screens.first
    }

    static func currentPointerScreen(
        screens: [NSScreen] = NSScreen.screens,
        fallback: NSScreen? = NSScreen.main
    ) -> NSScreen? {
        screen(at: NSEvent.mouseLocation, screens: screens, fallback: fallback)
    }

    static func resolvedScreen(
        pinnedNumber: inout NSNumber?,
        fallbackPoint: CGPoint? = nil,
        screens: [NSScreen] = NSScreen.screens
    ) -> NSScreen? {
        if let existing = screen(forScreenNumber: pinnedNumber, screens: screens) {
            return existing
        }
        let resolved = screen(at: fallbackPoint ?? NSEvent.mouseLocation, screens: screens)
        pinnedNumber = screenNumber(of: resolved)
        return resolved
    }
}
