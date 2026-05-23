struct IslandPanelState {
    struct Transition: Equatable {
        fileprivate let id: Int
    }

    private enum Phase {
        case hidden
        case opening
        case shown
        case closing
    }

    private var phase: Phase = .hidden
    private var nextTransitionID = 0
    private var activeTransition: Transition?

    mutating func beginShowing() -> Transition? {
        switch phase {
        case .hidden, .closing:
            let transition = nextTransition()
            phase = .opening
            activeTransition = transition
            return transition
        case .opening, .shown:
            return nil
        }
    }

    @discardableResult
    mutating func finishShowing(_ transition: Transition) -> Bool {
        guard activeTransition == transition else { return false }

        phase = .shown
        activeTransition = nil
        return true
    }

    func isCurrentTransition(_ transition: Transition) -> Bool {
        activeTransition == transition
    }

    mutating func beginHiding() -> Transition {
        let transition = nextTransition()
        phase = .closing
        activeTransition = transition
        return transition
    }

    @discardableResult
    mutating func finishHiding(_ transition: Transition) -> Bool {
        guard activeTransition == transition else { return false }

        phase = .hidden
        activeTransition = nil
        return true
    }

    private mutating func nextTransition() -> Transition {
        nextTransitionID += 1
        return Transition(id: nextTransitionID)
    }
}
