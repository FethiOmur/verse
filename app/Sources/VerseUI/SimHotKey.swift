import AppKit
import Carbon.HIToolbox

/// ⌥Space, "done answering", while a practice interview runs. A Carbon hot key works whichever app is in front and
/// needs no Accessibility permission (a global `NSEvent` key monitor would). Registered only during the interview, so
/// ⌥Space belongs to other apps the rest of the time.
@MainActor
final class SimHotKey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    /// The C callback cannot capture; one hot key per app, so one static action.
    nonisolated(unsafe) private static var action: (@MainActor () -> Void)?
    /// 'VRSE': the signature of this key. Every hot key of the app reaches the one application event handler, so the
    /// handler has to leave the other ones (⌥⌘V, ⌥⌘↩ of `GlobalHotKeys`) to their own handler.
    static let signature = OSType(0x5652_5345)

    /// Is the hot key event ⌥Space's? Anything else must pass through (`eventNotHandledErr`), or ⌥⌘V stops working while a
    /// practice interview runs.
    static func isOwn(_ id: EventHotKeyID) -> Bool { id.signature == signature && id.id == 1 }

    /// Returns false when ⌥Space is taken by another app (the panel's Done button still works).
    @discardableResult
    func register(_ action: @escaping @MainActor () -> Void) -> Bool {
        unregister()
        Self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hk = EventHotKeyID()
            let got = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                        nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            guard got == noErr, SimHotKey.isOwn(hk) else { return OSStatus(eventNotHandledErr) }
            DispatchQueue.main.async { MainActor.assumeIsolated { SimHotKey.action?() } }
            return noErr
        }, 1, &spec, nil, &handler)
        guard installed == noErr else { return false }
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), id, GetApplicationEventTarget(), 0, &hotKey)
        return status == noErr
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
        Self.action = nil
    }
}
