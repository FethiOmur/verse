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
        case .apple: return "Apple voice (on this Mac)"
        case .elevenlabs: return "ElevenLabs"
        case .openai: return "OpenAI"
        case .text: return "Written questions (no voice)"
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
        LabeledContent("\(name) key") {
            if hasKey {
                Label(last4.map { "Saved · ends in \($0)" } ?? "Saved", systemImage: "checkmark.seal.fill").foregroundStyle(.secondary)
            } else {
                Label("No key", systemImage: "key").foregroundStyle(.secondary)
            }
        }
        SecureField(hasKey ? "New \(name) key to replace the saved one" : "\(name) API key", text: $draft)
            .textContentType(.password)
            .onSubmit(save)
        HStack {
            Button(hasKey ? "Replace" : "Save", action: save)
                .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            if hasKey { Button("Remove…", role: .destructive) { confirmRemove = true } }
            Spacer()
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .onAppear(perform: refresh)
        .confirmationDialog("Remove the \(name) key from the Keychain?", isPresented: $confirmRemove) {
            Button("Remove", role: .destructive, action: remove)
        } message: {
            Text("Practice interviews fall back to the Apple voice until a key is saved again.")
        }
    }

    private func save() {
        let k = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        draft = ""
        do {
            try VoiceKeys.save(k, for: kind)
            message = "Saved"
        } catch {
            message = (error as? VoiceKeyError)?.description ?? "Could not save the key."
        }
        refresh()
    }

    private func remove() {
        do { try VoiceKeys.remove(kind); message = "Removed" } catch { message = "Could not remove the key." }
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
            Picker("Interviewer voice", selection: $sim.voice) {
                ForEach([VoiceKind.apple, .elevenlabs, .openai, .text], id: \.self) { k in
                    Text(SimSettings.label(k) + (SimSettings.isAvailable(k) ? "" : " · needs a key"))
                        .tag(k.rawValue)
                        .selectionDisabled(!SimSettings.isAvailable(k))
                }
            }
            .id(keysChanged)
            Picker("Apple voice", selection: $sim.appleVoiceID) {
                Text("Best installed").tag("")
                ForEach(appleVoices) { v in Text("\(v.name) · \(v.detail)").tag(v.id) }
            }
            Picker("OpenAI voice", selection: $sim.openAIVoiceID) {
                Text("Default (\(OpenAIVoice.defaultVoice.capitalized))").tag("")
                ForEach(OpenAIVoice.availableVoices()) { v in Text(v.detail.isEmpty ? v.name : "\(v.name) · \(v.detail)").tag(v.id) }
            }
            LabeledContent("ElevenLabs voice") {
                HStack {
                    Picker("", selection: $sim.elevenLabsVoiceID) {
                        Text("Default").tag("")
                        ForEach(elevenVoices) { v in Text(v.name).tag(v.id) }
                        if !sim.elevenLabsVoiceID.isEmpty, !elevenVoices.contains(where: { $0.id == sim.elevenLabsVoiceID }) {
                            Text("Saved voice").tag(sim.elevenLabsVoiceID)
                        }
                    }
                    .labelsHidden()
                    Button("Load my voices", action: loadEleven)
                        .disabled(!VoiceKeys.hasKey(.elevenlabs))
                }
            }
            if let elevenMessage { Text(elevenMessage).font(.caption).foregroundStyle(.secondary) }
            Toggle("Show the interviewer's line as a caption", isOn: $sim.showCaption)
            VoiceKeyRow(kind: .elevenlabs, onChange: { keysChanged += 1 })
            VoiceKeyRow(kind: .openai, onChange: { keysChanged += 1 })
        } header: {
            Text("Practice interview")
        } footer: {
            Text("Cloud voices are billed by ElevenLabs or OpenAI to your own key and are labelled \"AI-generated voice\" while they speak. "
                 + "Keys stay in the login Keychain. Better Apple voices: System Settings › Accessibility › Spoken Content › Manage Voices.")
        }
    }

    private func loadEleven() {
        elevenMessage = "Loading…"
        Task { @MainActor in
            do {
                elevenVoices = try await ElevenLabsVoice.listVoices()
                elevenMessage = "\(elevenVoices.count) voices"
            } catch {
                elevenMessage = (error as? VoiceError)?.description ?? "Could not load the voices."
            }
        }
    }
}
