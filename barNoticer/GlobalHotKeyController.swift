import Carbon.HIToolbox
import Foundation

@MainActor
final class GlobalHotKeyController {
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?
    private let onPressed: () -> Void
    private let hotKeyID: UInt32

    init(id: UInt32 = 1, onPressed: @escaping () -> Void) {
        hotKeyID = id
        self.onPressed = onPressed
    }

    deinit {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
        }
    }

    func register(shortcut: AIKeyboardShortcut) {
        unregister()

        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPointer = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData, let event else { return noErr }
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )

                let controller = Unmanaged<GlobalHotKeyController>.fromOpaque(userData).takeUnretainedValue()
                guard hotKeyID.signature == GlobalHotKeyController.signature,
                      hotKeyID.id == controller.hotKeyID else { return noErr }
                Task { @MainActor in
                    controller.onPressed()
                }
                return noErr
            },
            1,
            &eventType,
            selfPointer,
            &eventHandler
        )

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: hotKeyID)
        RegisterEventHotKey(
            shortcut.keyCode,
            shortcut.carbonModifiers,
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
        if let eventHandler {
            RemoveEventHandler(eventHandler)
            self.eventHandler = nil
        }
    }

    private static let signature: OSType = 0x626E6169
}
