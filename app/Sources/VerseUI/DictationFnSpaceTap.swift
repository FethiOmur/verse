import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// What the Fn + Space tap does with one keyboard event.
public enum FnSpaceDecision: Sendable, Equatable {
    /// Not ours: the event goes on to the app in front unchanged.
    case pass
    /// Fn + Space went down: dictation starts or stops, and the event is dropped (no space is typed).
    case toggle
    /// A repeat or the key-up of a Space that toggled (or of an Esc that cancelled): dropped, nothing else happens.
    case swallow
    /// Esc went down while a dictation is under way (`cancelArmed`): the dictation is cancelled and the event dropped.
    case cancel
}

/// The pure decision of the Fn + Space shortcut. Fn (Globe) is not a Carbon modifier, so `RegisterEventHotKey` cannot hold it;
/// an event tap reads each key event's flags instead and asks this filter. It looks at the Space key only (every other key is
/// `.pass` at once) and keeps one bit of state: whether the Space key-down that is held now was a toggle, so its auto-repeats
/// and its key-up are dropped too.
///
/// Esc (gap G7): only while `cancelArmed` (the controller arms it while a dictation records or finishes) a plain Esc key-down
/// cancels; its repeats and key-up are dropped the same way. Disarmed, or with ⇧ ⌃ ⌥ ⌘ held (⌥⌘Esc is Force Quit), Esc
/// passes untouched. A single press, no confirmation: nothing is lost that a second dictation could not redo.
public struct FnSpaceFilter: Sendable, Equatable {
    /// `kVK_Space`.
    public static let spaceKeyCode = Int64(kVK_Space)
    /// `kVK_Escape`.
    public static let escapeKeyCode = Int64(kVK_Escape)
    /// The modifiers that make it a different combination. Caps Lock and the numeric-pad flag do not count.
    public static let otherModifiers: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand]

    /// The held Space key toggled: its repeats and key-up are swallowed.
    public private(set) var swallowing = false
    /// A dictation is recording or finishing: Esc cancels it.
    public var cancelArmed = false
    /// The held Esc cancelled: its repeats and key-up are swallowed.
    public private(set) var swallowingEscape = false

    public init() {}

    public mutating func decide(type: CGEventType, keyCode: Int64, flags: CGEventFlags, isRepeat: Bool) -> FnSpaceDecision {
        if keyCode == Self.escapeKeyCode { return decideEscape(type: type, flags: flags, isRepeat: isRepeat) }
        guard keyCode == Self.spaceKeyCode else { return .pass }
        switch type {
        case .keyDown:
            // A held key repeats; only the first key-down toggles.
            if isRepeat { return swallowing ? .swallow : .pass }
            if flags.contains(.maskSecondaryFn), flags.isDisjoint(with: Self.otherModifiers) {
                swallowing = true
                return .toggle
            }
            swallowing = false
            return .pass
        case .keyUp:
            guard swallowing else { return .pass }
            swallowing = false
            return .swallow
        default:
            return .pass
        }
    }

    private mutating func decideEscape(type: CGEventType, flags: CGEventFlags, isRepeat: Bool) -> FnSpaceDecision {
        switch type {
        case .keyDown:
            if isRepeat { return swallowingEscape ? .swallow : .pass }
            if cancelArmed, flags.isDisjoint(with: Self.otherModifiers) {
                swallowingEscape = true
                return .cancel
            }
            swallowingEscape = false
            return .pass
        case .keyUp:
            guard swallowingEscape else { return .pass }
            swallowingEscape = false
            return .swallow
        default:
            return .pass
        }
    }
}

/// The system side of Fn + Space: an event tap. The app's is `FnSpaceEventTap`; tests use a fake.
@MainActor
public protocol DictationKeyTap: AnyObject {
    /// Installs the tap; false when the permission it needs is missing or the system refused. Never shows a permission prompt.
    /// `onCancel`: Esc was pressed while the tap was armed (`setCancelArmed`). Called synchronously, before the Esc is dropped,
    /// so the dictation is cancelled in the same step that swallows the key (`FnSpaceTapBox`).
    func install(onToggle: @escaping @MainActor @Sendable () -> Void, onCancel: @escaping @MainActor @Sendable () -> Void) -> Bool
    /// Esc is captured only while armed (a dictation is recording or finishing); otherwise it passes. Kept across installs.
    func setCancelArmed(_ armed: Bool)
    /// Removes the tap (no-op when none is installed).
    func remove()
}

/// Fn + Space through an active `CGEventTap` on the session.
///
/// Why this mechanism: the space must not reach the app in front, so the tap has to be able to drop events. A listen-only tap
/// or an `NSEvent` global monitor can only watch (and a listen-only keyboard tap needs Input Monitoring). An active tap can
/// drop events and needs the Accessibility permission, the one dictation already needs to paste its text, so Fn + Space asks for
/// nothing more. The tap is created only when `AXIsProcessTrusted()` (which never prompts) says the permission is there; without
/// it `install` returns false and ⌃⌥⌘D (Carbon, no permission) still works.
///
/// Cheap and safe: the callback reads the key code, the flags and the repeat bit of key-down/key-up events, decides with
/// `FnSpaceFilter` and returns; nothing is logged or stored. When the system disables the tap (it took too long, or user input
/// such as secure text entry), the callback enables it again. The same tap sees Esc, which it takes only while a dictation is
/// under way (`setCancelArmed`); without the tap (no Accessibility permission, ⌃⌥⌘D only) Esc cannot cancel a dictation.
@MainActor
final class FnSpaceEventTap: DictationKeyTap {
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var box: FnSpaceTapBox?
    private var cancelArmed = false

    func setCancelArmed(_ armed: Bool) {
        cancelArmed = armed
        box?.filter.cancelArmed = armed
    }

    func install(onToggle: @escaping @MainActor @Sendable () -> Void, onCancel: @escaping @MainActor @Sendable () -> Void) -> Bool {
        if port != nil { return true }
        guard AXIsProcessTrusted() else { return false }
        let box = FnSpaceTapBox(onToggle: onToggle, onCancel: onCancel)
        box.filter.cancelArmed = cancelArmed
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        guard let port = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
                                           eventsOfInterest: mask, callback: fnSpaceTapCallback,
                                           userInfo: Unmanaged.passUnretained(box).toOpaque()) else { return false }
        box.port = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        self.box = box
        self.port = port
        self.source = source
        return true
    }

    func remove() {
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        CFMachPortInvalidate(port)
        self.port = nil
        source = nil
        box = nil
    }
}

/// What the C callback reaches through its `userInfo`. The tap's run loop source is on the main run loop, so the callback runs
/// on the main thread, one event at a time.
///
/// Esc (gap G7) is handled inside the callback, not after a hop: the event is dropped in the same main-thread step that
/// cancels the dictation, so a swallowed Esc and the cancel can never come apart. With an asynchronous hop the engine could
/// return in between, the controller would insert the text (the cancel then finds nothing to cancel) and the app in front
/// would never get its Esc either. The tap is armed only while the controller is recording or finishing, and it disarms
/// synchronously when the phase changes, so an Esc the filter takes always finds a dictation to cancel. The toggle may hop:
/// a late toggle is just a later press.
final class FnSpaceTapBox: @unchecked Sendable {
    var filter = FnSpaceFilter()
    var port: CFMachPort?
    let onToggle: @MainActor @Sendable () -> Void
    let onCancel: @MainActor @Sendable () -> Void
    init(onToggle: @escaping @MainActor @Sendable () -> Void, onCancel: @escaping @MainActor @Sendable () -> Void) {
        self.onToggle = onToggle
        self.onCancel = onCancel
    }

    /// One key-down or key-up on the main thread: decides, acts, and returns true when the event is dropped.
    func handle(type: CGEventType, keyCode: Int64, flags: CGEventFlags, isRepeat: Bool) -> Bool {
        switch filter.decide(type: type, keyCode: keyCode, flags: flags, isRepeat: isRepeat) {
        case .pass:
            return false
        case .swallow:
            return true
        case .toggle:
            let action = onToggle
            DispatchQueue.main.async { MainActor.assumeIsolated { action() } }
            return true
        case .cancel:
            // Synchronous: the cancel lands before the event is dropped (see the type's comment).
            MainActor.assumeIsolated { onCancel() }
            return true
        }
    }
}

private func fnSpaceTapCallback(proxy: CGEventTapProxy, type: CGEventType, event: CGEvent,
                                userInfo: UnsafeMutableRawPointer?) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let box = Unmanaged<FnSpaceTapBox>.fromOpaque(userInfo).takeUnretainedValue()
    switch type {
    case .tapDisabledByTimeout, .tapDisabledByUserInput:
        if let port = box.port { CGEvent.tapEnable(tap: port, enable: true) }
        return Unmanaged.passUnretained(event)
    case .keyDown, .keyUp:
        break
    default:
        return Unmanaged.passUnretained(event)
    }
    let drop = box.handle(type: type, keyCode: event.getIntegerValueField(.keyboardEventKeycode), flags: event.flags,
                          isRepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0)
    return drop ? nil : Unmanaged.passUnretained(event)
}
