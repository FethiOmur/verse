import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// The API key row: save / replace / remove. The key is never shown back, only "saved" and its last 4 characters.
struct APIKeySection: View {
    @State private var draft = ""
    @State private var hasKey = KeychainStore.hasKey
    @State private var last4 = KeychainStore.last4
    @State private var message: String?
    @State private var confirmRemove = false

    var body: some View {
        Section {
            LabeledContent("Status") {
                if hasKey {
                    Label(last4.map { "Saved · ends in \($0)" } ?? "Saved", systemImage: "checkmark.seal.fill")
                        .foregroundStyle(.secondary)
                } else {
                    Label("No key", systemImage: "key").foregroundStyle(.secondary)
                }
            }
            SecureField(hasKey ? "New key to replace the saved one" : "sk-ant-…", text: $draft)
                .textContentType(.password)
                .onSubmit(save)
            HStack {
                Button(hasKey ? "Replace" : "Save", action: save)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if hasKey {
                    Button("Remove…", role: .destructive) { confirmRemove = true }
                }
                Spacer()
                if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
            }
            .confirmationDialog("Remove the API key from the Keychain?", isPresented: $confirmRemove) {
                Button("Remove", role: .destructive, action: remove)
            } message: {
                Text("Verse can't call Claude until a key is saved again.")
            }
        } header: {
            Text("Anthropic API key")
        } footer: {
            Text("Uses your Anthropic API key. Kept only in the login Keychain; the brain reads it there.")
        }
    }

    private func save() {
        let k = draft
        draft = ""
        do {
            try KeychainStore.save(k)
            message = "Saved"
        } catch {
            message = "\(error)"
        }
        refresh()
    }

    private func remove() {
        do { try KeychainStore.remove(); message = "Removed" } catch { message = "\(error)" }
        refresh()
    }

    private func refresh() {
        hasKey = KeychainStore.hasKey
        last4 = KeychainStore.last4
    }
}

public struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var controller: VerseController

    public init(settings: AppSettings, controller: VerseController) {
        self.settings = settings
        self.controller = controller
    }

    private static let usd: FloatingPointFormatStyle<Double>.Currency = .currency(code: "USD").precision(.fractionLength(2...4))

    public var body: some View {
        Form {
            APIKeySection()

            Section("You") {
                TextField("Name", text: $settings.ownerName)
                TextField("Other spellings", text: $settings.ownerAliases, prompt: Text("e.g. Fetti, Fati"))
                TextField("Other participants", text: $settings.otherParticipants, prompt: Text("e.g. Marco, Ingrid Solberg"))
                Picker("Meeting language", selection: $settings.language) {
                    Text("English").tag("en")
                    Text("Italian").tag("it")
                    Text("Turkish").tag("tr")
                }
            }

            Section("Listening") {
                Stepper(value: $settings.cueEndpointMs, in: 150...1500, step: 50) {
                    LabeledContent("Question end wait", value: "\(settings.cueEndpointMs) ms")
                }
                Stepper(value: $settings.plainEndpointMs, in: 300...2500, step: 50) {
                    LabeledContent("Other turn end wait", value: "\(settings.plainEndpointMs) ms")
                }
                LabeledContent("Answer bank match") {
                    HStack {
                        Slider(value: $settings.matchThreshold, in: 0.3...0.9, step: 0.01)
                        Text(settings.matchThreshold, format: .number.precision(.fractionLength(2))).monospacedDigit().frame(width: 36)
                    }
                }
            }

            Section("Overlay") {
                Picker("Text size", selection: $settings.textScale) {
                    ForEach(TextScale.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                Stepper(value: $settings.cardTimeout, in: 10...180, step: 5) {
                    LabeledContent("Card stays for", value: "\(Int(settings.cardTimeout)) s")
                }
                LabeledContent("Card width", value: "\(Int(settings.cardWidth)) pt (drag the card's bottom edge)")
            }

            Section {
                LabeledContent("This session", value: controller.sessionSpend, format: Self.usd)
                LabeledContent("This month", value: controller.monthSpend, format: Self.usd)
            } header: {
                Text("Spend")
            } footer: {
                Text("From the brain's per-call cost; each session's total is kept in its spend.json.")
            }

            Section("Testing") {
                Toggle("Fake brain (canned replies, no API calls)", isOn: $settings.fakeBrain)
                LabeledContent("Audio file instead of live") {
                    HStack {
                        Text(settings.testAudioPath.isEmpty ? "None (live)" : (settings.testAudioPath as NSString).lastPathComponent)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Button("Choose…", action: chooseFile)
                        if !settings.testAudioPath.isEmpty { Button("Clear") { settings.testAudioPath = "" } }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 520)
        .frame(minHeight: 560)
    }

    private func chooseFile() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.audio]
        p.allowsMultipleSelection = false
        if p.runModal() == .OK, let u = p.url { settings.testAudioPath = u.path }
    }
}
