import AppKit
import ApplicationServices
import Foundation

/// What the keyboard focus looked like at one moment, as far as the Accessibility API tells (gap G2). Only shapes and counts,
/// never the text itself: the character count, the selection and a length are enough to see that a paste changed the field.
public struct DictationFocusSnapshot: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// The Accessibility API did not answer (no front app, timeout, the app does not support it).
        case unreadable
        /// The front app answered and has no focused element.
        case noFocusedElement
        /// A focused element (see the other fields).
        case element
    }

    public var kind: Kind
    public var role: String?
    public var subrole: String?
    /// A text role (`AXTextField`, `AXTextArea`, `AXComboBox`, `AXSearchField`) or an element whose value can be set.
    public var editable = false
    /// Inside web content (the element carries WebKit's or Chromium's DOM attributes, or is the web area itself).
    public var web = false
    /// The front app is a terminal: a paste goes to the shell, the field shows it only when the shell echoes it.
    public var terminal = false
    /// The front app embeds Chromium (a browser or an Electron app): with its accessibility tree off it reports no focus.
    public var chromium = false
    /// The focused element's identity (`CFHash`), to see the focus move.
    public var identity: Int?
    public var characterCount: Int?
    public var selectionLocation: Int?
    public var selectionLength: Int?
    /// The value's length, read only when the character count is not available.
    public var valueLength: Int?

    public init(kind: Kind, role: String? = nil, subrole: String? = nil, editable: Bool = false, web: Bool = false,
                terminal: Bool = false, chromium: Bool = false, identity: Int? = nil, characterCount: Int? = nil,
                selectionLocation: Int? = nil, selectionLength: Int? = nil, valueLength: Int? = nil) {
        self.kind = kind
        self.role = role
        self.subrole = subrole
        self.editable = editable
        self.web = web
        self.terminal = terminal
        self.chromium = chromium
        self.identity = identity
        self.characterCount = characterCount
        self.selectionLocation = selectionLocation
        self.selectionLength = selectionLength
        self.valueLength = valueLength
    }

    public static let unreadable = DictationFocusSnapshot(kind: .unreadable)

    /// Something about the field can be compared before and after.
    public var isReadable: Bool { characterCount != nil || selectionLocation != nil || valueLength != nil }
}

/// Reads the focused element. The app's is `SystemFocusProbe`; tests script it.
@MainActor
public protocol DictationFocusProbing: AnyObject {
    func snapshot() -> DictationFocusSnapshot
}

/// Whether a paste landed (gap G2, after TypeWhisper's paste verification: 10 polls at 50 ms after ⌘V).
///
/// - delivered: a readable field changed after the paste (or the focus moved, which only an app reacting to it does);
/// - missed: nothing editable had the focus, or a readable text field did not change within the polls;
/// - unverifiable: web content, terminals, fields that cannot be read, roles that may be custom text views, and any
///   Accessibility failure. Never treated as a failure: behaves as delivered.
///
/// "Missed" is kept narrow on purpose: a false miss costs the owner his previous clipboard and shows a wrong notice, a missed
/// miss only leaves things as they were before this check existed.
public enum DictationPasteCheck {
    public static let attempts = 10
    public static let interval: Duration = .milliseconds(50)

    public enum Reason: String, Sendable, Equatable {
        case changed
        case noFocusedTextElement
        case focusedTextUnchanged
        case webContent
        case terminal
        case chromiumNoFocus
        case unreadableField
        case secureField
        case unknownRole
        case accessibilityUnavailable
    }

    public enum Verdict: Sendable, Equatable {
        case delivered
        case missed(Reason)
        case unverifiable(Reason)

        public var isMissed: Bool { if case .missed = self { return true }; return false }

        /// For the log: the kind and the reason, never the text.
        public var label: String {
            switch self {
            case .delivered: return "delivered"
            case .missed(let r): return "missed (\(r.rawValue))"
            case .unverifiable(let r): return "unverifiable (\(r.rawValue))"
            }
        }
    }

    /// What the snapshot before the paste already decides.
    public enum Precheck: Sendable, Equatable {
        case decided(Verdict)
        /// A readable text field: poll after the paste for a change.
        case poll
    }

    /// Roles that are text input.
    static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"]
    /// Roles that are clearly not text input. Anything not here and not a text role (AXGroup, AXScrollArea, AXUnknown, a
    /// window) may be a custom text view: unverifiable. Tables, cells, rows, lists, outlines and static text are left out on
    /// purpose: a spreadsheet takes a paste into a selected cell, and some custom editors report static text for their surface.
    static let nonTextRoles: Set<String> = [
        "AXButton", "AXCheckBox", "AXRadioButton", "AXBrowser", "AXImage", "AXSlider",
        "AXPopUpButton", "AXMenuButton", "AXTabGroup", "AXToolbar", "AXLink",
        "AXDisclosureTriangle", "AXIncrementor", "AXColorWell", "AXSegmentedControl", "AXMenu", "AXMenuItem", "AXMenuBar",
        "AXMenuBarItem", "AXDockItem",
    ]

    public static func precheck(_ before: DictationFocusSnapshot) -> Precheck {
        if before.kind == .unreadable { return .decided(.unverifiable(.accessibilityUnavailable)) }
        if before.terminal { return .decided(.unverifiable(.terminal)) }
        if before.kind == .noFocusedElement {
            return .decided(before.chromium ? .unverifiable(.chromiumNoFocus) : .missed(.noFocusedTextElement))
        }
        if before.web || before.role == "AXWebArea" { return .decided(.unverifiable(.webContent)) }
        let role = before.role ?? ""
        if before.editable || textRoles.contains(role) {
            if before.subrole == "AXSecureTextField" { return .decided(.unverifiable(.secureField)) }
            return before.isReadable ? .poll : .decided(.unverifiable(.unreadableField))
        }
        if nonTextRoles.contains(role) {
            return .decided(before.chromium ? .unverifiable(.chromiumNoFocus) : .missed(.noFocusedTextElement))
        }
        return .decided(.unverifiable(.unknownRole))
    }

    /// The field after the paste differs from before: the focus moved or went, or a readable number changed.
    public static func changed(from before: DictationFocusSnapshot, to after: DictationFocusSnapshot) -> Bool {
        if after.kind != .element { return true }
        if let a = before.identity, let b = after.identity, a != b { return true }
        func differs(_ x: Int?, _ y: Int?) -> Bool { if let x, let y { return x != y }; return false }
        return differs(before.characterCount, after.characterCount)
            || differs(before.selectionLocation, after.selectionLocation)
            || differs(before.selectionLength, after.selectionLength)
            || differs(before.valueLength, after.valueLength)
    }

    /// The verdict from the snapshot before the paste and the polls after it, in order (the inserter stops polling at the first
    /// change or the first unreadable one; a full list without a change is a miss).
    public static func verdict(before: DictationFocusSnapshot, after: [DictationFocusSnapshot]) -> Verdict {
        switch precheck(before) {
        case .decided(let v): return v
        case .poll:
            for a in after {
                if a.kind == .unreadable { return .unverifiable(.accessibilityUnavailable) }
                if changed(from: before, to: a) { return .delivered }
            }
            return after.count >= attempts ? .missed(.focusedTextUnchanged) : .unverifiable(.unreadableField)
        }
    }
}

/// The Accessibility API's view of the focused element, every call bounded by a short messaging timeout so a hung app cannot
/// hold the main actor: at the first error the snapshot stops and reports `.unreadable`.
@MainActor
final class SystemFocusProbe: DictationFocusProbing {
    /// Seconds per Accessibility message. A healthy app answers in a few milliseconds.
    static let timeout: Float = 0.1
    /// Seconds for a whole snapshot: an app that answers each message just under the timeout makes the snapshot
    /// `.unreadable` (unverifiable, and polling stops) instead of holding the main actor for every attribute.
    static let budget: TimeInterval = 0.25

    static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal", "com.googlecode.iterm2", "dev.warp.Warp-Stable", "net.kovidgoyal.kitty", "org.alacritty",
        "io.alacritty", "com.mitchellh.ghostty", "co.zeit.hyper", "com.github.wez.wezterm", "dev.commandline.waveterm",
    ]

    private var chromiumByBundle: [String: Bool] = [:]
    private var deadline: TimeInterval = 0
    private var overBudget = false

    func snapshot() -> DictationFocusSnapshot {
        deadline = ProcessInfo.processInfo.systemUptime + Self.budget
        overBudget = false
        var s = probe()
        if overBudget { s.kind = .unreadable }
        return s
    }

    private func probe() -> DictationFocusSnapshot {
        guard let app = NSWorkspace.shared.frontmostApplication else { return .unreadable }
        var s = DictationFocusSnapshot(kind: .unreadable)
        s.terminal = app.bundleIdentifier.map { Self.terminalBundleIDs.contains($0) } ?? false
        s.chromium = isChromium(app)
        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, Self.timeout)

        var ref: CFTypeRef?
        switch AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &ref) {
        case .success: break
        case .noValue:
            s.kind = .noFocusedElement
            return s
        default: return s
        }
        guard let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return s }
        let el = ref as! AXUIElement   // checked above
        AXUIElementSetMessagingTimeout(el, Self.timeout)
        s.kind = .element
        s.identity = Int(bitPattern: UInt(CFHash(el)))

        guard let role = read(el, kAXRoleAttribute) else { s.kind = .unreadable; return s }
        s.role = role as? String
        guard let sub = read(el, kAXSubroleAttribute) else { s.kind = .unreadable; return s }
        s.subrole = sub as? String

        var names: CFArray?
        if AXUIElementCopyAttributeNames(el, &names) == .success, let list = names as? [String] {
            s.web = list.contains("AXDOMClassList") || list.contains("AXDOMIdentifier")
        }
        if DictationPasteCheck.textRoles.contains(s.role ?? "") {
            s.editable = true
        } else {
            var settable = DarwinBoolean(false)
            if AXUIElementIsAttributeSettable(el, kAXValueAttribute as CFString, &settable) == .success { s.editable = settable.boolValue }
        }
        guard s.editable, !s.web, !s.terminal, s.subrole != "AXSecureTextField" else { return s }

        if let n = read(el, kAXNumberOfCharactersAttribute) as? NSNumber { s.characterCount = n.intValue }
        if let v = read(el, kAXSelectedTextRangeAttribute), CFGetTypeID(v) == AXValueGetTypeID() {
            var range = CFRange()
            if AXValueGetValue(v as! AXValue, .cfRange, &range) {   // type checked above
                s.selectionLocation = range.location
                s.selectionLength = range.length
            }
        }
        if s.characterCount == nil, let value = read(el, kAXValueAttribute) as? String { s.valueLength = value.utf16.count }
        return s
    }

    /// One attribute: its value, `kCFNull` when the element has none, nil when the call failed (timeout, app gone) or the
    /// snapshot ran over its budget.
    private func read(_ el: AXUIElement, _ attribute: String) -> CFTypeRef? {
        guard ProcessInfo.processInfo.systemUptime < deadline else { overBudget = true; return nil }
        var ref: CFTypeRef?
        switch AXUIElementCopyAttributeValue(el, attribute as CFString, &ref) {
        case .success: return ref ?? kCFNull
        case .noValue, .attributeUnsupported: return kCFNull
        default: return nil
        }
    }

    /// Chromium browsers and Electron apps, by the frameworks in their bundle (read once per app).
    private func isChromium(_ app: NSRunningApplication) -> Bool {
        guard let url = app.bundleURL else { return false }
        if let known = chromiumByBundle[url.path] { return known }
        let found = Self.embedsChromium(bundleURL: url)
        chromiumByBundle[url.path] = found
        return found
    }

    /// Whether the bundle at `bundleURL` embeds Chromium: an Electron or CEF framework, an Electron renderer helper next to
    /// the frameworks, or a Chrome-family browser's "<Name> Framework.framework" with a renderer helper inside (Chrome, Brave,
    /// Edge, Vivaldi, Opera and the like name the framework after themselves).
    nonisolated static func embedsChromium(bundleURL: URL, fileManager: FileManager = .default) -> Bool {
        let dir = bundleURL.appendingPathComponent("Contents/Frameworks")
        let entries = (try? fileManager.contentsOfDirectory(atPath: dir.path)) ?? []
        func isRenderer(_ name: String) -> Bool { name.hasSuffix("Helper (Renderer).app") }
        if entries.contains(where: { $0.contains("Electron") || $0.contains("Chromium") || $0.contains("Chrome Framework") || isRenderer($0) }) {
            return true
        }
        for framework in entries where framework.hasSuffix(" Framework.framework") {
            let base = dir.appendingPathComponent(framework)
            for helpers in ["Helpers", "Versions/Current/Helpers"] {
                let names = (try? fileManager.contentsOfDirectory(atPath: base.appendingPathComponent(helpers).path)) ?? []
                if names.contains(where: isRenderer) { return true }
            }
        }
        return false
    }
}
