import AppKit

/// A visible popup owns the notch interaction until it actually finishes closing.
@MainActor
enum NotchPopupPresence {
    static let didChangeNotification = Notification.Name("NotchPopupPresenceDidChange")
    private static let owners = NSHashTable<AnyObject>.weakObjects()

    static var isPresenting: Bool { !owners.allObjects.isEmpty }

    static func setVisible(_ visible: Bool, owner: AnyObject) {
        let wasPresenting = isPresenting
        if visible { owners.add(owner) }
        else { owners.remove(owner) }
        if wasPresenting != isPresenting {
            NotificationCenter.default.post(name: didChangeNotification, object: nil)
        }
    }
}
