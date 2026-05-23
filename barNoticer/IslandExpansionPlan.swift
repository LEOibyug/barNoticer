import CoreGraphics
import Foundation

struct IslandExpansionPlan {
    let startFrame: CGRect
    let endFrame: CGRect
    let duration: TimeInterval
    let contentFadeDelay: TimeInterval
    let contentFadeDuration: TimeInterval

    init(
        settings: IslandLayoutSettings,
        screenFrame: CGRect,
        duration: TimeInterval = 0.62,
        contentFadeDelay: TimeInterval = 0.16,
        contentFadeDuration: TimeInterval = 0.26
    ) {
        self.startFrame = settings.collapsedIslandFrame(in: screenFrame)
        self.endFrame = settings.islandFrame(in: screenFrame)
        self.duration = duration
        self.contentFadeDelay = contentFadeDelay
        self.contentFadeDuration = contentFadeDuration
    }
}
