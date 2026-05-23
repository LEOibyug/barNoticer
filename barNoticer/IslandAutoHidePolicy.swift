struct IslandAutoHidePolicy {
    struct Decision: Equatable {
        let shouldHide: Bool
        let shouldEndEditing: Bool
    }

    static func decision(
        pointerInIsland: Bool,
        pointerInHotZone: Bool,
        isPreviewingIsland: Bool
    ) -> Decision {
        guard !pointerInIsland, !pointerInHotZone, !isPreviewingIsland else {
            return Decision(shouldHide: false, shouldEndEditing: false)
        }

        return Decision(shouldHide: true, shouldEndEditing: true)
    }
}
