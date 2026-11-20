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
    /// ⌥⌘←: show the earlier answer in the notch.
    public static let earlierAnswer = HotKeySpec(keyCode: UInt32(kVK_LeftArrow), modifiers: UInt32(optionKey | cmdKey))
    /// ⌥⌘→: show the newer answer, then the live one again.
    public static let newerAnswer = HotKeySpec(keyCode: UInt32(kVK_RightArrow), modifiers: UInt32(optionKey | cmdKey))
    /// ⇧ and the key that types `<`: show the earlier answer too. The key differs per keyboard layout, so its code comes
    /// from `LessThanKey` when the session keys are registered.
    public static func shiftLessThan(keyCode: UInt32) -> HotKeySpec { HotKeySpec(keyCode: keyCode, modifiers: UInt32(shiftKey)) }
    /// ⇧ alone as the modifier: the ⇧< key, whichever key code it is.
    public var isShiftLessThan: Bool { modifiers == UInt32(shiftKey) }
}

/// Finds the key that types `<` with no modifier in a keyboard layout. On a Turkish Mac keyboard `<` and `>` share one key
/// (left of Z), on others it may sit elsewhere or nowhere, so no single key code is hard-coded.
public enum LessThanKey {
    /// Tried in order when no key of the layout types `<`: the ISO key (`kVK_ISO_Section`, 0x0A), then the grave key
    /// (`kVK_ANSI_Grave`, 0x32). The next one is used only when the system refuses the one before.
    public static let fallbacks: [UInt32] = [UInt32(kVK_ISO_Section), UInt32(kVK_ANSI_Grave)]

    /// The key codes to try for ⇧<, best first: the first key code (0...127) that `translate` says types "<" with no
    /// modifier, alone; otherwise `fallbacks`.
    public static func candidates(translate: (UInt16) -> String?) -> [UInt32] {
        for code in UInt16(0)..<128 where translate(code) == "<" { return [UInt32(code)] }
        return fallbacks
    }

    /// The same over a Unicode keyboard layout (`kTISPropertyUnicodeKeyLayoutData`); no layout data gives `fallbacks`.
    public static func candidates(layoutData: Data?, keyboardType: UInt32) -> [UInt32] {
        guard let layoutData, !layoutData.isEmpty else { return fallbacks }
        return candidates { code in
            layoutData.withUnsafeBytes { raw -> String? in
                guard let layout = raw.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
                var deadKeys: UInt32 = 0
                var chars = [UniChar](repeating: 0, count: 4)
                var length = 0
                let status = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), 0, keyboardType,
                                            OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
                guard status == noErr, length > 0 else { return nil }
                return String(utf16CodeUnits: chars, count: length)
            }
        }
    }

    /// For the keyboard layout in use now (Text Input Sources want the main thread).
    @MainActor
    public static func current() -> [UInt32] {
        candidates(layoutData: layoutData(TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue())
                       ?? layoutData(TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()),
                   keyboardType: UInt32(LMGetKbdType()))
    }

    private static func layoutData(_ source: TISInputSource?) -> Data? {
        guard let source, let ptr = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        return Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
    }
}

/// What registers a hot key with the system. Carbon in the app; a fake in tests.
@MainActor
public protocol HotKeyRegistrar: AnyObject {
    /// Returns a token for `unregister`, or nil when the system refused (the combination belongs to another app).
    func register(_ spec: HotKeySpec, id: UInt32, action: @escaping @MainActor () -> Void) -> Int?
    func unregister(_ token: Int)
}

/// The global hot keys of anytime calls. ⌥⌘V is registered at launch and stays on; ⌥⌘↩ (card now), ⌥⌘← / ⇧< (earlier
/// answer) and ⌥⌘→ (newer answer) only while a session runs, so they belong to other apps the rest of the time (the same
/// rule `SimHotKey` follows for ⌥Space). Carbon hot keys work whichever app is in front and need no Accessibility or Input
/// Monitoring permission.
@MainActor
public final class GlobalHotKeys {
    public static let startStopID: UInt32 = 1
    public static let cardNowID: UInt32 = 2
    public static let earlierAnswerID: UInt32 = 3
    public static let newerAnswerID: UInt32 = 4
    public static let earlierAnswerShiftID: UInt32 = 5

    private let registrar: any HotKeyRegistrar
    private let startSpec: HotKeySpec
    private let cardSpec: HotKeySpec
    private var startToken: Int?
    private var cardToken: Int?
    private let onStartStop: @MainActor () -> Void
    private let onCardNow: @MainActor () -> Void
    private let earlierSpec: HotKeySpec
    private let newerSpec: HotKeySpec
    private var earlierToken: Int?
    private var newerToken: Int?
    private let onEarlierAnswer: @MainActor () -> Void
    private let onNewerAnswer: @MainActor () -> Void
    /// The key codes to try for ⇧<, read when a session starts (`LessThanKey.current` in the app).
    private let lessThanKeyCodes: @MainActor () -> [UInt32]
    private var shiftToken: Int?
    /// The ⇧< combination of the running session: the registered one, or the first one tried when none was accepted.
    public private(set) var earlierAnswerShiftSpec: HotKeySpec?

    /// False when ⌥⌘V is taken by another app: the menu and the island still start Verse.
    public private(set) var startStopRegistered = false
    public var cardNowRegistered: Bool { cardToken != nil }
    public var earlierAnswerRegistered: Bool { earlierToken != nil }
    public var newerAnswerRegistered: Bool { newerToken != nil }
    public var earlierAnswerShiftRegistered: Bool { shiftToken != nil }
    /// The answer keys of the session that runs now that another app holds (empty when none, or when no session runs).
    public private(set) var unavailableAnswerKeys: [HotKeySpec] = []

    public init(registrar: (any HotKeyRegistrar)? = nil, startStop: HotKeySpec = .startStop, cardNow: HotKeySpec = .cardNow,
                earlierAnswer: HotKeySpec = .earlierAnswer, newerAnswer: HotKeySpec = .newerAnswer,
                onStartStop: @escaping @MainActor () -> Void, onCardNow: @escaping @MainActor () -> Void,
                onEarlierAnswer: @escaping @MainActor () -> Void = {}, onNewerAnswer: @escaping @MainActor () -> Void = {},
                lessThanKeyCodes: @escaping @MainActor () -> [UInt32] = { LessThanKey.current() }) {
        self.registrar = registrar ?? CarbonRegistrar()
        self.startSpec = startStop
        self.cardSpec = cardNow
        self.earlierSpec = earlierAnswer
        self.newerSpec = newerAnswer
        self.onStartStop = onStartStop
        self.onCardNow = onCardNow
        self.onEarlierAnswer = onEarlierAnswer
        self.onNewerAnswer = onNewerAnswer
        self.lessThanKeyCodes = lessThanKeyCodes
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

    /// ⌥⌘↩, ⌥⌘←, ⌥⌘→ and ⇧< exist only while a session runs. A key another app holds is left out and listed in
    /// `unavailableAnswerKeys` (⌥⌘↩ stays as it was: `cardNowRegistered`). ⇧< is looked up in the keyboard layout of that
    /// moment; its fallback key codes are tried in order.
    public func setSessionRunning(_ running: Bool) {
        if running {
            if cardToken == nil { cardToken = registrar.register(cardSpec, id: Self.cardNowID, action: onCardNow) }
            if earlierToken == nil { earlierToken = registrar.register(earlierSpec, id: Self.earlierAnswerID, action: onEarlierAnswer) }
            if newerToken == nil { newerToken = registrar.register(newerSpec, id: Self.newerAnswerID, action: onNewerAnswer) }
            if shiftToken == nil { registerShiftLessThan() }
            unavailableAnswerKeys = (earlierToken == nil ? [earlierSpec] : []) + (newerToken == nil ? [newerSpec] : [])
                + (shiftToken == nil ? [earlierAnswerShiftSpec].compactMap { $0 } : [])
        } else {
            releaseSessionKeys()
        }
    }

    private func registerShiftLessThan() {
        let specs = lessThanKeyCodes().map(HotKeySpec.shiftLessThan)
        earlierAnswerShiftSpec = specs.first
        for spec in specs {
            if let t = registrar.register(spec, id: Self.earlierAnswerShiftID, action: onEarlierAnswer) {
                shiftToken = t
                earlierAnswerShiftSpec = spec
                return
            }
        }
    }

    private func releaseSessionKeys() {
        for t in [cardToken, earlierToken, newerToken, shiftToken].compactMap({ $0 }) { registrar.unregister(t) }
        cardToken = nil
        earlierToken = nil
        newerToken = nil
        shiftToken = nil
        earlierAnswerShiftSpec = nil
        unavailableAnswerKeys = []
    }

    public func unregisterAll() {
        if let t = startToken { registrar.unregister(t) }
        startToken = nil
        releaseSessionKeys()
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
