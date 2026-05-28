import Foundation

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
    private var transitionStartedAt: Date?

    mutating func beginShowing(now: Date = Date()) -> Transition? {
        switch phase {
        case .hidden, .closing:
            let transition = nextTransition(now: now)
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
        transitionStartedAt = nil
        return true
    }

    func isCurrentTransition(_ transition: Transition) -> Bool {
        activeTransition == transition
    }

    mutating func beginHiding(now: Date = Date()) -> Transition {
        let transition = nextTransition(now: now)
        phase = .closing
        activeTransition = transition
        return transition
    }

    @discardableResult
    mutating func finishHiding(_ transition: Transition) -> Bool {
        guard activeTransition == transition else { return false }

        phase = .hidden
        activeTransition = nil
        transitionStartedAt = nil
        return true
    }

    mutating func recoverIfTransitionTimedOut(now: Date = Date(), timeout: TimeInterval = 2) {
        guard let transitionStartedAt, now.timeIntervalSince(transitionStartedAt) >= timeout else {
            return
        }

        switch phase {
        case .opening, .closing:
            phase = .hidden
            activeTransition = nil
            self.transitionStartedAt = nil
        case .hidden, .shown:
            return
        }
    }

    mutating func reconcile(isPanelVisible: Bool) {
        guard !isPanelVisible else { return }

        switch phase {
        case .opening, .shown, .closing:
            phase = .hidden
            activeTransition = nil
            transitionStartedAt = nil
        case .hidden:
            return
        }
    }

    private mutating func nextTransition(now: Date) -> Transition {
        nextTransitionID += 1
        transitionStartedAt = now
        return Transition(id: nextTransitionID)
    }
}
