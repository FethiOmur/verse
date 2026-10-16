import AppKit
import SwiftUI
import VerseVoice

// The home window's colours and building blocks (spec 2 and 4; the approved mockups in design/mockups/.../Home.swift).
// Everything on the window glass is a fill, never another glass layer.

// MARK: - Environment

struct HomeInkKey: EnvironmentKey {
    static var defaultValue: VT.Window { VT.Window(dark: false) }
}

extension EnvironmentValues {
    /// The window colours for the current appearance, Increase Contrast and Reduce Transparency.
    var homeInk: VT.Window {
        get { self[HomeInkKey.self] }
        set { self[HomeInkKey.self] = newValue }
    }
}

/// Accessibility state forced by a render (`--render-home`); nil in the app, which reads the system settings.
struct HomeA11yOverride: Equatable, Sendable {
    var reduceTransparency = false
    var increaseContrast = false
}

// Tokens the shared file doesn't carry. Kept private to the home window.
extension VT.Window {
    /// Segmented control: the selected segment.
    var segmentSelected: Color { dark ? .white.opacity(0.18) : .white }
    /// Plain controls' hairline under Increase Contrast.
    var controlBorder: Color { separator }
}

// MARK: - Buttons

/// Dims a little while pressed; the look comes from the label.
struct HomePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.opacity(configuration.isPressed ? 0.7 : 1)
    }
}

/// The page's one primary action: mint fill, `onMint` label, 9 pt radius, 30 pt tall.
struct HomePrimaryButton: View {
    var title: String
    var hint: String?
    var shortcut: KeyboardShortcut?
    var action: () -> Void
    @Environment(\.isEnabled) private var enabled

    init(_ title: String, hint: String? = nil, shortcut: KeyboardShortcut? = nil, action: @escaping () -> Void) {
        self.title = title
        self.hint = hint
        self.shortcut = shortcut
        self.action = action
    }

    var body: some View {
        let button = Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                if let hint { Text(hint).opacity(0.55) }
            }
            .font(.system(size: 13, weight: .semibold)).foregroundStyle(VT.onMint)
            .padding(.horizontal, 14).frame(height: 30)
            .background(VT.mint, in: RoundedRectangle(cornerRadius: VT.Radius.control, style: .continuous))
            .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(HomePressStyle())
        if let shortcut { button.keyboardShortcut(shortcut) } else { button }
    }
}

/// Neutral secondary action.
struct HomeSecondaryButton: View {
    var title: String
    var symbol: String?
    var destructive = false
    var action: () -> Void
    @Environment(\.homeInk) private var ink
    @Environment(\.isEnabled) private var enabled

    init(_ title: String, symbol: String? = nil, destructive: Bool = false, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.destructive = destructive
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                if let symbol { Image(systemName: symbol) }
                Text(title)
            }
            .font(.system(size: 13, weight: .medium)).foregroundStyle(destructive ? VT.coral : ink.primary)
            .padding(.horizontal, 12).frame(height: 28)
            .background(ink.fill, in: RoundedRectangle(cornerRadius: VT.Radius.control, style: .continuous))
            .overlay {
                if ink.increaseContrast {
                    RoundedRectangle(cornerRadius: VT.Radius.control, style: .continuous).strokeBorder(ink.controlBorder)
                }
            }
            .opacity(enabled ? 1 : 0.4)
        }
        .buttonStyle(HomePressStyle())
    }
}

// MARK: - Groups and rows

/// Grouped rows on the window glass (System Settings pattern). `plate` is the reading plate for long text.
struct HomeGroup<Content: View>: View {
    var plate = false
    @ViewBuilder var content: Content
    @Environment(\.homeInk) private var ink

    init(plate: Bool = false, @ViewBuilder content: () -> Content) {
        self.plate = plate
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: VT.Radius.group, style: .continuous)
        VStack(alignment: .leading, spacing: 0) { content }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(plate ? ink.plate : ink.group, in: shape)
            .overlay { shape.strokeBorder(ink.groupEdge, lineWidth: 1) }
    }
}

struct HomeRowDivider: View {
    var inset: CGFloat = 14
    @Environment(\.homeInk) private var ink
    var body: some View { Rectangle().fill(ink.separator).frame(height: 1).padding(.leading, inset) }
}

/// Label left, value or control right, 40 pt minimum.
struct HomeRow<Trailing: View>: View {
    var label: String
    var detail: String?
    @ViewBuilder var trailing: Trailing
    @Environment(\.homeInk) private var ink

    init(_ label: String, detail: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.label = label
        self.detail = detail
        self.trailing = trailing()
    }

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(VT.Font.body).foregroundStyle(ink.primary)
                if let detail { Text(detail).font(VT.Font.callout).foregroundStyle(ink.secondary).fixedSize(horizontal: false, vertical: true) }
            }
            Spacer(minLength: 16)
            trailing
        }
        .padding(.horizontal, 14).padding(.vertical, detail == nil ? 0 : 8).frame(minHeight: 40)
    }
}

extension HomeRow where Trailing == Text {
    init(_ label: String, value: String) {
        self.init(label) { Text(value) }
    }
}

struct HomeSectionHeader: View {
    var text: String
    @Environment(\.homeInk) private var ink
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(ink.secondary)
            .padding(.leading, 4).padding(.top, 20).padding(.bottom, 7)
    }
}

/// A small note under a group.
struct HomeFootnote: View {
    var text: String
    @Environment(\.homeInk) private var ink
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(VT.Font.callout).foregroundStyle(ink.tertiary)
            .fixedSize(horizontal: false, vertical: true).padding(.leading, 4).padding(.top, 7)
    }
}

struct HomePageHeader<Actions: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var actions: Actions
    @Environment(\.homeInk) private var ink

    init(_ title: String, subtitle: String? = nil, @ViewBuilder actions: () -> Actions) {
        self.title = title
        self.subtitle = subtitle
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(VT.Font.largeTitle).tracking(VT.Font.largeTitleTracking).foregroundStyle(ink.primary)
                if let subtitle { Text(subtitle).font(VT.Font.body).foregroundStyle(ink.secondary) }
            }
            Spacer()
            HStack(spacing: 8) { actions }
        }
    }
}

extension HomePageHeader where Actions == EmptyView {
    init(_ title: String, subtitle: String? = nil) {
        self.init(title, subtitle: subtitle) { EmptyView() }
    }
}

// MARK: - Controls

/// The mockup's segmented control: neutral track, the selected segment lifted, no accent.
struct HomeSegmented<T: Hashable>: View {
    var items: [(label: String, value: T)]
    @Binding var selection: T
    @Environment(\.homeInk) private var ink

    init(_ items: [(label: String, value: T)], selection: Binding<T>) {
        self.items = items
        _selection = selection
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items.indices, id: \.self) { i in
                let on = items[i].value == selection
                Button { selection = items[i].value } label: {
                    Text(items[i].label).font(.system(size: 12, weight: on ? .semibold : .medium))
                        .foregroundStyle(on ? ink.primary : ink.secondary)
                        .padding(.horizontal, 11).frame(height: 24)
                        .background(on ? ink.segmentSelected : .clear, in: RoundedRectangle(cornerRadius: VT.Radius.chip, style: .continuous))
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(2)
        .background(ink.fill, in: RoundedRectangle(cornerRadius: VT.Radius.control, style: .continuous))
        .overlay {
            if ink.increaseContrast {
                RoundedRectangle(cornerRadius: VT.Radius.control, style: .continuous).strokeBorder(ink.controlBorder)
            }
        }
    }
}

/// One choice in a popup.
struct HomeOption<T: Hashable> {
    var label: String
    var value: T
    var enabled = true

    init(_ label: String, _ value: T, enabled: Bool = true) {
        self.label = label
        self.value = value
        self.enabled = enabled
    }
}

/// A value with up/down chevrons that opens a menu (the mockup's popup).
struct HomePopup<T: Hashable>: View {
    @Binding var selection: T
    var options: [HomeOption<T>]
    /// Shown when `selection` is none of the options.
    var fallback = ""
    @Environment(\.homeInk) private var ink

    init(selection: Binding<T>, options: [HomeOption<T>], fallback: String = "") {
        _selection = selection
        self.options = options
        self.fallback = fallback
    }

    var body: some View {
        Menu {
            Picker("", selection: $selection) {
                ForEach(options, id: \.value) { Text($0.label).tag($0.value).disabled(!$0.enabled) }
            }
            .pickerStyle(.inline).labelsHidden()
        } label: {
            HStack(spacing: 5) {
                Text(options.first { $0.value == selection }?.label ?? fallback).font(VT.Font.body).foregroundStyle(ink.primary)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(ink.secondary)
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
}

/// A field that reads as a value: right-aligned, no frame. `lines` lets it grow to a few lines.
struct HomeValueField: View {
    var prompt: String
    @Binding var text: String
    var lines: ClosedRange<Int> = 1...1
    var onSubmit: (() -> Void)?
    @Environment(\.homeInk) private var ink

    init(_ prompt: String, text: Binding<String>, lines: ClosedRange<Int> = 1...1, onSubmit: (() -> Void)? = nil) {
        self.prompt = prompt
        _text = text
        self.lines = lines
        self.onSubmit = onSubmit
    }

    var body: some View {
        TextField("", text: $text, prompt: Text(prompt).foregroundStyle(ink.tertiary), axis: lines.upperBound > 1 ? .vertical : .horizontal)
            .textFieldStyle(.plain).font(VT.Font.body).foregroundStyle(ink.secondary)
            .multilineTextAlignment(.trailing).lineLimit(lines)
            .onSubmit { onSubmit?() }
    }
}

/// A multi-line text area with a placeholder, transparent so it sits on a group or a plate.
struct HomeTextArea: View {
    @Binding var text: String
    var placeholder: String
    var minHeight: CGFloat = 60
    var font: Font = VT.Font.body
    var lineSpacing: CGFloat = 3
    @Environment(\.homeInk) private var ink

    var body: some View {
        TextEditor(text: $text)
            .font(font).lineSpacing(lineSpacing).foregroundStyle(ink.secondary)
            .scrollContentBackground(.hidden)
            .frame(minHeight: minHeight)
            .padding(.horizontal, -5).padding(.vertical, -4)
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder).font(font).foregroundStyle(ink.tertiary).allowsHitTesting(false)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
    }
}

/// The mockup's switch: mint when on, a neutral track when off. Drawn here (not `NSSwitch`) so it stays mint when the
/// window is not key; VoiceOver sees a normal toggle.
struct HomeSwitch: View {
    @Binding var isOn: Bool
    @Environment(\.homeInk) private var ink
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        Button { isOn.toggle() } label: {
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule().fill(isOn ? VT.mint : ink.fill).frame(width: 34, height: 20)
                    .overlay { if ink.increaseContrast { Capsule().strokeBorder(ink.controlBorder) } }
                Circle().fill(Color.white).frame(width: 16, height: 16).padding(2)
                    .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
            }
            .animation(.easeOut(duration: 0.12), value: isOn)
            .opacity(enabled ? 1 : 0.4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityRepresentation { Toggle("", isOn: $isOn).labelsHidden() }
    }
}

struct HomeToggleRow: View {
    var label: String
    var detail: String?
    @Binding var isOn: Bool

    init(_ label: String, detail: String? = nil, isOn: Binding<Bool>) {
        self.label = label
        self.detail = detail
        _isOn = isOn
    }

    var body: some View {
        HomeRow(label, detail: detail) { HomeSwitch(isOn: $isOn) }
            .accessibilityElement(children: .combine)
    }
}

/// The mockup's slider: a 5 pt track filled with mint and a white pill knob. Drawn here for the same reason as `HomeSwitch`.
struct HomeSlider: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double?
    var width: CGFloat = 220
    @Environment(\.homeInk) private var ink
    @Environment(\.isEnabled) private var enabled

    private var fraction: CGFloat { CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound)).clamped(to: 0...1) }

    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(ink.fill).frame(width: width, height: 5)
            Capsule().fill(VT.mint).frame(width: width * fraction, height: 5)
            Capsule().fill(Color.white).frame(width: 22, height: 15)
                .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
                .offset(x: width * fraction - 11)
        }
        .frame(width: width, height: 20)
        .contentShape(Rectangle())
        .opacity(enabled ? 1 : 0.4)
        .gesture(DragGesture(minimumDistance: 0).onChanged { g in
            guard enabled else { return }
            let f = Double((g.location.x / width).clamped(to: 0...1))
            var v = range.lowerBound + f * (range.upperBound - range.lowerBound)
            if let step { v = ((v / step).rounded() * step).clamped(to: range) }
            if v != value { value = v }
        })
        .accessibilityRepresentation { Slider(value: $value, in: range).labelsHidden() }
    }
}

struct HomeSliderRow: View {
    var label: String
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double?
    var text: String
    @Environment(\.homeInk) private var ink

    var body: some View {
        HomeRow(label) {
            HomeSlider(value: $value, range: range, step: step)
            Text(text).font(VT.Font.body).foregroundStyle(ink.secondary).monospacedDigit().frame(width: 54, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Status line such as "Saved" or an error.
struct HomeNote: View {
    var text: String
    var isError = false
    @Environment(\.homeInk) private var ink
    var body: some View {
        Text(text).font(VT.Font.callout).foregroundStyle(isError ? VT.coral : ink.secondary)
            .fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
    }
}

// MARK: - Scroll container for single-column pages

/// A single-column page: 28 pt side padding, 22 top, content at most 760 wide.
struct HomeColumnPage<Content: View>: View {
    @ViewBuilder var content: Content

    init(@ViewBuilder content: () -> Content) { self.content = content() }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) { content }
                .padding(.horizontal, 28).padding(.top, 22).padding(.bottom, 28)
                .frame(maxWidth: 760, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.automatic)
    }
}

// MARK: - Cloud voice keys

/// Which cloud voices have a key saved. Read once off the view update (a Keychain query inside a view body can re-enter
/// layout), then published.
@MainActor
final class HomeVoiceKeys: ObservableObject {
    @Published private(set) var saved: Set<VoiceKind> = []

    func refresh() {
        saved = Set([VoiceKind.elevenlabs, .openai].filter { VoiceKeys.hasKey($0) })
    }

    func isAvailable(_ kind: VoiceKind) -> Bool { SimSettings.isAvailable(kind, hasKey: { saved.contains($0) }) }
}
