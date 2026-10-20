import Combine
import SwiftUI
import VerseVoice

/// Practice-interview preferences (S4), in the same `UserDefaults` suite as `AppSettings`. The voice keys are not here:
/// they live only in the Keychain (`VoiceKeys`).
@MainActor
public final class SimSettings: ObservableObject {
    private let defaults: UserDefaults

    /// The default interviewer voice (`VoiceKind` raw value).
    @Published public var voice: String { didSet { defaults.set(voice, forKey: "simVoice") } }
    @Published public var appleVoiceID: String { didSet { defaults.set(appleVoiceID, forKey: "simAppleVoiceID") } }
    @Published public var elevenLabsVoiceID: String { didSet { defaults.set(elevenLabsVoiceID, forKey: "simElevenLabsVoiceID") } }
    @Published public var openAIVoiceID: String { didSet { defaults.set(openAIVoiceID, forKey: "simOpenAIVoiceID") } }
    /// The interviewer's line as a caption in voice modes.
    @Published public var showCaption: Bool { didSet { defaults.set(showCaption, forKey: "simShowCaption") } }

    public init(defaults: UserDefaults? = nil) {
        let d = defaults ?? (Bundle.main.bundleIdentifier == AppSettings.suiteName ? .standard
            : UserDefaults(suiteName: AppSettings.suiteName) ?? .standard)
        self.defaults = d
        voice = d.string(forKey: "simVoice") ?? VoiceKind.apple.rawValue
        appleVoiceID = d.string(forKey: "simAppleVoiceID") ?? ""
        elevenLabsVoiceID = d.string(forKey: "simElevenLabsVoiceID") ?? ""
        openAIVoiceID = d.string(forKey: "simOpenAIVoiceID") ?? ""
        showCaption = d.object(forKey: "simShowCaption") as? Bool ?? true
    }

    public var voiceKind: VoiceKind { VoiceKind(rawValue: voice) ?? .apple }

    /// The engine-specific voice for `kind`; nil picks the engine's default.
    public func voiceID(for kind: VoiceKind) -> String? {
        let v: String
        switch kind {
        case .apple: v = appleVoiceID
        case .elevenlabs: v = elevenLabsVoiceID
        case .openai: v = openAIVoiceID
        case .text: v = ""
        }
        return v.isEmpty ? nil : v
    }

    /// A cloud voice can be chosen only with its key saved.
    public static func isAvailable(_ kind: VoiceKind, hasKey: (VoiceKind) -> Bool = VoiceKeys.hasKey) -> Bool {
        switch kind {
        case .apple, .text: return true
        case .elevenlabs, .openai: return hasKey(kind)
        }
    }

    public static func label(_ kind: VoiceKind) -> String {
        switch kind {
        case .apple: return L10n.tr("Apple voice (on this Mac)")
        case .elevenlabs: return "ElevenLabs"
        case .openai: return "OpenAI"
        case .text: return L10n.tr("Written questions (no voice)")
        }
    }
}

/// One cloud voice key row: save / replace / remove. The key is never shown back, only its last 4 characters.
struct VoiceKeyRow: View {
    let kind: VoiceKind
    var onChange: () -> Void = {}
    @State private var draft = ""
    @State private var hasKey = false
    @State private var last4: String?
    @State private var message: String?
    @State private var confirmRemove = false

    private var name: String { kind == .elevenlabs ? "ElevenLabs" : "OpenAI" }

    var body: some View {
        LabeledContent {
            if hasKey {
                Label { Text(verbatim: last4.map { L10n.tr("Saved · ends in \($0)") } ?? L10n.tr("Saved")) } icon: { Image(systemName: "checkmark.seal.fill") }.foregroundStyle(.secondary)
            } else {
                Label { Text("No key", bundle: .module) } icon: { Image(systemName: "key") }.foregroundStyle(.secondary)
            }
        } label: { Text("\(name) key", bundle: .module) }
        SecureField(hasKey ? L10n.tr("New \(name) key to replace the saved one") : L10n.tr("\(name) API key"), text: $draft)
            .textContentType(.password)
            .onSubmit(save)
        HStack {
            Button(action: save) { if hasKey { Text("Replace", bundle: .module) } else { Text("Save", bundle: .module) } }
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if hasKey { Button(role: .destructive) { confirmRemove = true } label: { Text("Remove…", bundle: .module) } }
            Spacer()
            if let message { Text(verbatim: message).font(.caption).foregroundStyle(.secondary) }
        }
        .onAppear(perform: refresh)
        .confirmationDialog(Text("Remove the \(name) key from the Keychain?", bundle: .module), isPresented: $confirmRemove) {
            Button(role: .destructive, action: remove) { Text("Remove", bundle: .module) }
        } message: {
            Text("Practice interviews fall back to the Apple voice until a key is saved again.", bundle: .module)
        }
    }

    private func save() {
        let k = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        do {
            try VoiceKeys.save(k, for: kind)
            message = L10n.tr("Saved")
        } catch {
            message = (error as? VoiceKeyError).map(L10n.message(for:)) ?? L10n.tr("Could not save the key.")
        }
        refresh()
    }

    private func remove() {
        do { try VoiceKeys.remove(kind); message = L10n.tr("Removed") } catch { message = L10n.tr("Could not remove the key.") }
        refresh()
    }

    private func refresh() {
        hasKey = VoiceKeys.hasKey(kind)
        last4 = VoiceKeys.last4(kind)
        onChange()
    }
}

/// Settings > Practice interview: the default interviewer voice, the voice per engine, and the cloud keys.
struct SimVoiceSettingsSection: View {
    @ObservedObject var sim: SimSettings
    @State private var keysChanged = 0
    @State private var elevenVoices: [VoiceOption] = []
    @State private var elevenMessage: String?

    private var appleVoices: [VoiceOption] { AppleVoice.availableVoices(lang: "en") }

    var body: some View {
        Section {
            Picker(selection: $sim.voice) {
                ForEach([VoiceKind.apple, .elevenlabs, .openai, .text], id: \.self) { k in
                    Text(verbatim: SimSettings.isAvailable(k) ? SimSettings.label(k) : L10n.tr("\(SimSettings.label(k)) · needs a key"))
                        .tag(k.rawValue)
                        .selectionDisabled(!SimSettings.isAvailable(k))
                }
            } label: { Text("Interviewer voice", bundle: .module) }
            .id(keysChanged)
            Picker(selection: $sim.appleVoiceID) {
                Text("Best installed", bundle: .module).tag("")
                ForEach(appleVoices) { v in Text(verbatim: "\(v.name) · \(v.detail)").tag(v.id) }
            } label: { Text("Apple voice", bundle: .module) }
            Picker(selection: $sim.openAIVoiceID) {
                Text("Default (\(OpenAIVoice.defaultVoice.capitalized))", bundle: .module).tag("")
                ForEach(OpenAIVoice.availableVoices()) { v in Text(verbatim: v.detail.isEmpty ? v.name : "\(v.name) · \(v.detail)").tag(v.id) }
            } label: { Text("OpenAI voice", bundle: .module) }
            LabeledContent {
                HStack {
                    Picker("", selection: $sim.elevenLabsVoiceID) {
                        Text("Default", bundle: .module).tag("")
                        ForEach(elevenVoices) { v in Text(verbatim: v.name).tag(v.id) }
                        if !sim.elevenLabsVoiceID.isEmpty, !elevenVoices.contains(where: { $0.id == sim.elevenLabsVoiceID }) {
                            Text("Saved voice", bundle: .module).tag(sim.elevenLabsVoiceID)
                        }
                    }
                    .labelsHidden()
                    Button(action: loadEleven) { Text("Load my voices", bundle: .module) }
                        .disabled(!VoiceKeys.hasKey(.elevenlabs))
                }
            } label: { Text("ElevenLabs voice", bundle: .module) }
            if let elevenMessage { Text(verbatim: elevenMessage).font(.caption).foregroundStyle(.secondary) }
            Toggle(isOn: $sim.showCaption) { Text("Show the interviewer's line as a caption", bundle: .module) }
            VoiceKeyRow(kind: .elevenlabs, onChange: { keysChanged += 1 })
            VoiceKeyRow(kind: .openai, onChange: { keysChanged += 1 })
        } header: {
            Text("Practice interview", bundle: .module)
        } footer: {
            Text("Cloud voices are billed by ElevenLabs or OpenAI to your own key and are labelled \"AI-generated voice\" while they speak. Keys stay in the login Keychain. Better Apple voices: System Settings › Accessibility › Spoken Content › Manage Voices.", bundle: .module)
        }
    }

    private func loadEleven() {
        elevenMessage = L10n.tr("Loading…")
        Task { @MainActor in
            do {
                elevenVoices = try await ElevenLabsVoice.listVoices()
                elevenMessage = L10n.tr("\(elevenVoices.count) voices")
            } catch {
                elevenMessage = (error as? VoiceError).map(L10n.message(for:)) ?? L10n.tr("Could not load the voices.")
            }
        }
    }
}

/// The voice module is below the catalog, so its error texts are localized here.
extension L10n {
    static func message(for error: VoiceKeyError) -> String {
        switch error {
        case .invalidKey: tr("That does not look like an API key (letters, digits, - and _ only).")
        case .notApplicable: tr("This voice does not use a key.")
        case .failed(let m): m
        }
    }

    static func message(for error: VoiceError) -> String {
        switch error {
        case .missingKey: tr("No API key for this voice.")
        case .network(let m): tr("Voice service error: \(m)")
        case .audio(let m): tr("Audio error: \(m)")
        }
    }
}
