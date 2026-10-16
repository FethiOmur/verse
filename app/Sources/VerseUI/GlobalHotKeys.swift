import AppKit
import Carbon.HIToolbox

/// One global key: a virtual key code and Carbon modifier flags.
public struct HotKeySpec: Sendable, Equatable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// ⌥⌘V: start Verse now, or (twice) stop it.
    public static let startStop = HotKeySpec(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(optionKey | cmdKey))
    /// ⌥⌘↩: answer the latest thing the other person said, now.
    public static let cardNow = HotKeySpec(keyCode: UInt32(kVK_Return), modifiers: UInt32(optionKey | cmdKey))
}

/// What registers a hot key with the system. Carbon in the app; a fake in tests.
@MainActor
public protocol HotKeyRegistrar: AnyObject {
    /// Returns a token for `unregister`, or nil when the system refused (the combination belongs to another app).
    func register(_ spec: HotKeySpec, id: UInt32, action: @escaping @MainActor () -> Void) -> Int?
    func unregister(_ token: Int)
}

/// The global hot keys of anytime calls. ⌥⌘V is registered at launch and stays on; ⌥⌘↩ only while a session runs, so
/// ⌥⌘↩ belongs to other apps the rest of the time (the same rule `SimHotKey` follows for ⌥Space). Carbon hot keys work
/// whichever app is in front and need no Accessibility permission.
@MainActor
public final class GlobalHotKeys {
    public static let startStopID: UInt32 = 1
    public static let cardNowID: UInt32 = 2

    private let registrar: any HotKeyRegistrar
    private let startSpec: HotKeySpec
    private let cardSpec: HotKeySpec
    private var startToken: Int?
    private var cardToken: Int?
    private let onStartStop: @MainActor () -> Void
    private let onCardNow: @MainActor () -> Void

    /// False when ⌥⌘V is taken by another app: the menu and the island still start Verse.
    public private(set) var startStopRegistered = false
    public var cardNowRegistered: Bool { cardToken != nil }

    public init(registrar: (any HotKeyRegistrar)? = nil, startStop: HotKeySpec = .startStop, cardNow: HotKeySpec = .cardNow,
                onStartStop: @escaping @MainActor () -> Void, onCardNow: @escaping @MainActor () -> Void) {
        self.registrar = registrar ?? CarbonRegistrar()
        self.startSpec = startStop
        self.cardSpec = cardNow
        self.onStartStop = onStartStop
        self.onCardNow = onCardNow
    }

    /// Registers ⌥⌘V (launch). Returns whether the system accepted it.
    @discardableResult
    public func registerStartStop() -> Bool {
        if startToken == nil {
            startToken = registrar.register(startSpec, id: Self.startStopID, action: onStartStop)
        }
        startStopRegistered = startToken != nil
        return startStopRegistered
    }

    /// ⌥⌘↩ exists only while a session runs.
    public func setSessionRunning(_ running: Bool) {
        if running {
            if cardToken == nil { cardToken = registrar.register(cardSpec, id: Self.cardNowID, action: onCardNow) }
        } else if let t = cardToken {
            registrar.unregister(t)
            cardToken = nil
        }
    }

    public func unregisterAll() {
        if let t = startToken { registrar.unregister(t) }
        if let t = cardToken { registrar.unregister(t) }
        startToken = nil
        cardToken = nil
        startStopRegistered = false
    }
}

/// The Carbon implementation (the pattern of `SimHotKey`): one application event handler for every key, dispatching by the
/// hot key's id. The C callback cannot capture, so the actions live in a static table.
@MainActor
final class CarbonRegistrar: HotKeyRegistrar {
    nonisolated(unsafe) private static var actions: [UInt32: @MainActor () -> Void] = [:]
    nonisolated(unsafe) private static var handler: EventHandlerRef?
    nonisolated(unsafe) private static var handlerUsers = 0
    private static let signature = OSType(0x5652_4851) /* 'VRHQ' */

    private var refs: [Int: EventHotKeyRef] = [:]
    private var ids: [Int: UInt32] = [:]
    private var nextToken = 1

    func register(_ spec: HotKeySpec, id: UInt32, action: @escaping @MainActor () -> Void) -> Int? {
        guard Self.installHandler() else { return nil }
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(spec.keyCode, spec.modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            Self.releaseHandler()
            return nil
        }
        Self.actions[id] = action
        let token = nextToken
        nextToken += 1
        refs[token] = ref
        ids[token] = id
        return token
    }

    func unregister(_ token: Int) {
        guard let ref = refs.removeValue(forKey: token) else { return }
        UnregisterEventHotKey(ref)
        if let id = ids.removeValue(forKey: token) { Self.actions[id] = nil }
        Self.releaseHandler()
    }

    private static func installHandler() -> Bool {
        if handlerUsers == 0 {
            var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                // Only our own keys: another handler (SimHotKey's ⌥Space) must still get its events.
                var hk = EventHotKeyID()
                let got = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                            nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
                guard got == noErr, hk.signature == CarbonRegistrar.signature else { return OSStatus(eventNotHandledErr) }
                let id = hk.id
                DispatchQueue.main.async { MainActor.assumeIsolated { CarbonRegistrar.actions[id]?() } }
                return noErr
            }, 1, &spec, nil, &handler)
            guard status == noErr else { return false }
        }
        handlerUsers += 1
        return true
    }

    private static func releaseHandler() {
        handlerUsers = max(0, handlerUsers - 1)
        if handlerUsers == 0, let h = handler {
            RemoveEventHandler(h)
            handler = nil
        }
    }
}
