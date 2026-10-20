import AppKit
import Carbon.HIToolbox

/// What a prompter shortcut does.
public enum PrompterCommand: UInt32, CaseIterable, Sendable {
    case toggle = 1, previousPage, nextPage, slower, faster, restart, close

    /// Every shortcut is ⌃⌥ plus a letter: ⌥Space belongs to the practice interview, and the arrow and bracket keys are
    /// taken by window managers and differ between keyboard layouts. Letters are physical key positions, so the same
    /// keys work on the Italian and Turkish layouts.
    public var keyCode: Int {
        switch self {
        case .toggle: return kVK_ANSI_P
        case .previousPage: return kVK_ANSI_B
        case .nextPage: return kVK_ANSI_N
        case .slower: return kVK_ANSI_A
        case .faster: return kVK_ANSI_S
        case .restart: return kVK_ANSI_H
        case .close: return kVK_ANSI_X
        }
    }

    public var keyLabel: String {
        switch self {
        case .toggle: return "P"
        case .previousPage: return "B"
        case .nextPage: return "N"
        case .slower: return "A"
        case .faster: return "S"
        case .restart: return "H"
        case .close: return "X"
        }
    }

    public var shortcut: String { "⌃⌥" + keyLabel }

    public var title: String {
        switch self {
        case .toggle: return L10n.tr("Start / pause")
        case .previousPage: return L10n.tr("Previous page")
        case .nextPage: return L10n.tr("Next page")
        case .slower: return L10n.tr("Slower (−10 wpm)")
        case .faster: return L10n.tr("Faster (+10 wpm)")
        case .restart: return L10n.tr("Back to the top of the page")
        case .close: return L10n.tr("Close the prompter")
        }
    }
}

/// Global shortcuts for the open prompter. A Carbon hot key works whichever app is in front (the meeting app keeps
/// focus; the panel never becomes key) and needs no Accessibility permission. Registered only while the prompter is open.
@MainActor
final class PrompterHotKeys {
    private var hotKeys: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?
    /// The C callback cannot capture; one prompter, so one static action.
    nonisolated(unsafe) private static var action: (@MainActor (PrompterCommand) -> Void)?
    private static let signature = OSType(0x5652_5054) // 'VRPT'

    /// Returns the commands whose key combination another app already holds (their buttons on the panel still work).
    @discardableResult
    func register(_ action: @escaping @MainActor (PrompterCommand) -> Void) -> [PrompterCommand] {
        unregister()
        Self.action = action
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let installed = InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == PrompterHotKeys.signature, let command = PrompterCommand(rawValue: id.id) else {
                return OSStatus(eventNotHandledErr)
            }
            DispatchQueue.main.async { MainActor.assumeIsolated { PrompterHotKeys.action?(command) } }
            return noErr
        }, 1, &spec, nil, &handler)
        guard installed == noErr else { return PrompterCommand.allCases }
        var failed: [PrompterCommand] = []
        for command in PrompterCommand.allCases {
            var ref: EventHotKeyRef?
            let id = EventHotKeyID(signature: Self.signature, id: command.rawValue)
            let status = RegisterEventHotKey(UInt32(command.keyCode), UInt32(controlKey | optionKey), id,
                                             GetApplicationEventTarget(), 0, &ref)
            if status == noErr, let ref { hotKeys.append(ref) } else { failed.append(command) }
        }
        return failed
    }

    func unregister() {
        for ref in hotKeys { UnregisterEventHotKey(ref) }
        hotKeys = []
        if let handler { RemoveEventHandler(handler) }
        handler = nil
        Self.action = nil
    }
}
