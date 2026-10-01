#if os(macOS)
import Carbon
import Foundation

@MainActor
final class GlobalShortcut {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private static let hotKeyID = EventHotKeyID(signature: 0x4753594E, id: 1) // GSYN

    func setEnabled(_ enabled: Bool) throws {
        if !enabled {
            if let hotKey { UnregisterEventHotKey(hotKey) }
            hotKey = nil
            if let handler { RemoveEventHandler(handler) }
            handler = nil
            return
        }
        guard hotKey == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == 0x4753594E, id.id == 1 else {
                return OSStatus(eventNotHandledErr)
            }
            // Carbon dispatches application events on the main thread.
            MainActor.assumeIsolated { MenuBarRuntime.openMainApplication() }
            return noErr
        }, 1, &eventType, nil, &handler)
        guard status == noErr else { throw RegistrationError(status: status) }
        let registration = RegisterEventHotKey(UInt32(kVK_ANSI_Grave), UInt32(cmdKey | optionKey),
                                               Self.hotKeyID, GetApplicationEventTarget(),
                                               OptionBits(kEventHotKeyExclusive), &hotKey)
        guard registration == noErr else {
            RemoveEventHandler(handler)
            handler = nil
            throw RegistrationError(status: registration)
        }
    }

    deinit {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
    }

    private struct RegistrationError: LocalizedError {
        let status: OSStatus
        var errorDescription: String? {
            "Could not register ⌘⌥` (error \(status)). Another app may be using this shortcut."
        }
    }
}
#endif
