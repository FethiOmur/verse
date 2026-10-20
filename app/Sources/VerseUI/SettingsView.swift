import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VerseVoice

/// A key row group: status, a secure field, Save / Replace / Remove. The key is never shown back, only "saved" and its
/// last 4 characters. Used for the Anthropic key and the cloud voice keys.
struct HomeKeyRows: View {
    var name: String
    var placeholder: String
    var removeNote: String
    var status: () -> (has: Bool, last4: String?)
    var save: (String) throws -> Void
    var remove: () throws -> Void
    var onChange: () -> Void = {}

    @State private var draft = ""
    @State private var hasKey = false
    @State private var last4: String?
    @State private var message: String?
    @State private var messageIsError = false
    @State private var confirmRemove = false
    @State private var editing = false
    @Environment(\.homeInk) private var ink

    var body: some View {
        HomeRow(verbatim: name) {
            if hasKey {
                Text(verbatim: last4.map { L10n.tr("Saved in Keychain · ends in \($0)") } ?? L10n.tr("Saved in Keychain")).font(VT.Font.body).foregroundStyle(ink.secondary)
                HomeSecondaryButton("Replace…") { editing = true }
                HomeSecondaryButton("Remove…", destructive: true) { confirmRemove = true }
            } else {
                Label { Text("No key", bundle: .module) } icon: { Image(systemName: "key") }.font(VT.Font.body).foregroundStyle(ink.secondary)
            }
        }
        .onAppear(perform: refresh)
        .confirmationDialog(Text("Remove the \(name) from the Keychain?", bundle: .module), isPresented: $confirmRemove) {
            Button(role: .destructive, action: removeKey) { Text("Remove", bundle: .module) }
        } message: {
            Text(verbatim: removeNote)
        }
        if !hasKey || editing {
            HomeRowDivider()
            HomeRow(hasKey ? "New key" : "Add key") {
                SecureField("", text: $draft, prompt: Text(verbatim: hasKey ? L10n.tr("Replaces the saved key") : placeholder).foregroundStyle(ink.tertiary))
                    .textFieldStyle(.plain).font(VT.Font.body).foregroundStyle(ink.secondary).multilineTextAlignment(.trailing)
                    .textContentType(.password)
                    .onSubmit(saveDraft)
                HomeSecondaryButton(hasKey ? "Replace" : "Save", action: saveDraft)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if hasKey { HomeSecondaryButton("Cancel") { draft = ""; editing = false } }
            }
        }
        if let message {
            HomeRowDivider()
            HomeNote(verbatim: message, isError: messageIsError).padding(14)
        }
    }

    private func saveDraft() {
        let k = draft
        draft = ""
        do { try save(k); message = L10n.tr("Saved"); messageIsError = false; editing = false } catch {
            message = (error as? VoiceKeyError).map(L10n.message(for:)) ?? "\(error)"
            messageIsError = true
        }
        refresh()
    }

    private func removeKey() {
        do { try remove(); message = L10n.tr("Removed"); messageIsError = false } catch { message = "\(error)"; messageIsError = true }
        refresh()
    }

    private func refresh() {
        let s = status()
        hasKey = s.has
        last4 = s.last4
        onChange()
    }
}

/// The Anthropic key: save / replace / remove.
struct APIKeySection: View {
    var body: some View {
        HomeGroup {
            HomeKeyRows(name: L10n.tr("Anthropic API key"), placeholder: "sk-ant-…",
                        removeNote: L10n.tr("Verse can't call Claude until a key is saved again."),
                        status: { (KeychainStore.hasKey, KeychainStore.last4) },
                        save: { try KeychainStore.save($0) },
                        remove: { try KeychainStore.remove() })
        }
        HomeFootnote("Uses your Anthropic API key. Kept only in the login Keychain; the brain reads it there.")
    }
}

/// The home window's Settings page: Appearance first, then Meetings, the Claude key and the rest. It replaces the
/// "Verse Settings" window.
public struct SettingsView: View {
    @ObservedObject var settings: AppSettings
    @ObservedObject var controller: VerseController
    @ObservedObject var simSettings: SimSettings
    /// Render only (`--render-home`): the page header and the Meetings group, so that group can be looked at whole.
    var meetingsOnly = false
    @Environment(\.homeInk) private var ink
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    public init(settings: AppSettings, controller: VerseController, simSettings: SimSettings) {
        self.settings = settings
        self.controller = controller
        self.simSettings = simSettings
    }

    init(settings: AppSettings, controller: VerseController, simSettings: SimSettings, meetingsOnly: Bool) {
        self.init(settings: settings, controller: controller, simSettings: simSettings)
        self.meetingsOnly = meetingsOnly
    }

    private static var usd: FloatingPointFormatStyle<Double>.Currency { .currency(code: "USD").precision(.fractionLength(2...4)).locale(Locale(identifier: L10n.code == "en" ? "en_US" : L10n.formatLocale.identifier)) }

    private func percent(_ v: Double) -> String { L10n.percent(v) }

    public var body: some View {
        HomeColumnPage {
            HomePageHeader("Settings")
            if !meetingsOnly { appearanceSection }

            HomeSectionHeader("Meetings")
            SettingsMeetingSection(meeting: controller.meeting, settings: settings)

            if !meetingsOnly { remainingSections }
        }
        .accessibilityIdentifier("verse.home.settings")
    }

    /// System (<the language it resolves to>), then the three languages by their own names.
    private static var languageOptions: [HomeOption<InterfaceLanguage>] {
        let resolved = L10n.endonym(of: InterfaceLanguage.systemLanguage())
        return [HomeOption(verbatim: L10n.tr("System (\(resolved))"), .system)]
            + [InterfaceLanguage.en, .it, .tr].map { HomeOption(verbatim: $0.endonym ?? $0.rawValue, $0) }
    }

    @ViewBuilder private var appearanceSection: some View {
            HomeSectionHeader("Appearance")
            HomeGroup {
                HomeRow("Language") {
                    HomePopup(selection: $settings.interfaceLanguage, options: Self.languageOptions)
                }
                HomeRowDivider()
                HomeSliderRow(label: "Island opacity", value: $settings.islandOpacity, range: AppSettings.islandOpacityRange,
                              step: 0.01, text: percent(settings.islandOpacity))
                    .disabled(ink.reduceTransparency || reduceTransparency)
                HomeRowDivider()
                HomeSliderRow(label: "Window opacity", value: $settings.windowOpacity, range: AppSettings.windowOpacityRange,
                              step: 0.01, text: percent(settings.windowOpacity))
                HomeRowDivider()
                HomeRow("Text size") { HomeSegmented(verbatim: TextScale.allCases.map { ($0.rawValue, $0) }, selection: $settings.textScale) }
                HomeRowDivider()
                HomeSliderRow(label: "Card width", value: $settings.cardWidth, range: AppSettings.cardWidthRange, step: 10,
                              text: L10n.tr("\(Int(settings.cardWidth)) pt"))
                HomeRowDivider()
                HomeRow("Card closes after") {
                    HomePopup(selection: $settings.cardTimeout,
                              options: [HomeOption("Never", 0.0)] + [30.0, 45.0, 60.0, 90.0, 120.0, 180.0].map { HomeOption(verbatim: L10n.tr("\(Int($0)) s"), $0) })
                }
            }
            HomeFootnote("Reduce Transparency and Increase Contrast (System Settings › Accessibility › Display) override these.")
    }

    @ViewBuilder private var remainingSections: some View {
            HomeSectionHeader("Claude")
            APIKeySection()

            HomeSectionHeader("You")
            HomeGroup {
                HomeRow("Name") { HomeValueField("Alex", text: $settings.ownerName) }
                HomeRowDivider()
                HomeRow("Other spellings") { HomeValueField("e.g. Fetti, Fati", text: $settings.ownerAliases) }
                HomeRowDivider()
                HomeRow("Other participants") { HomeValueField("e.g. Marco, Ingrid Solberg", text: $settings.otherParticipants) }
                HomeRowDivider()
                HomeRow("Meeting language") {
                    HomePopup(selection: $settings.language, options: [HomeOption("English", "en"), HomeOption("Italian", "it"), HomeOption("Turkish", "tr")])
                }
            }

            HomeSectionHeader("Listening")
            HomeGroup {
                HomeRow("Question end wait") {
                    Text("\(settings.cueEndpointMs) ms", bundle: .module).font(VT.Font.body).foregroundStyle(ink.secondary).monospacedDigit()
                    Stepper("", value: $settings.cueEndpointMs, in: 150...1500, step: 50).labelsHidden()
                }
                HomeRowDivider()
                HomeRow("Other turn end wait") {
                    Text("\(settings.plainEndpointMs) ms", bundle: .module).font(VT.Font.body).foregroundStyle(ink.secondary).monospacedDigit()
                    Stepper("", value: $settings.plainEndpointMs, in: 300...2500, step: 50).labelsHidden()
                }
                HomeRowDivider()
                HomeSliderRow(label: "Answer bank match", value: $settings.matchThreshold, range: 0.3...0.9, step: 0.01,
                              text: settings.matchThreshold.formatted(.number.precision(.fractionLength(2))))
            }

            HomeSectionHeader("Practice interview")
            HomePracticeVoiceSection(sim: simSettings)

            HomeSectionHeader("Teleprompter")
            PrompterSettingsSection(settings: controller.prompter.settings)

            HomeSectionHeader("Spend")
            HomeGroup {
                HomeRow("This session", value: controller.sessionSpend.formatted(Self.usd))
                HomeRowDivider()
                HomeRow("This month", value: controller.monthSpend.formatted(Self.usd))
            }
            HomeFootnote("From the brain's per-call cost; each session's total is kept in its spend.json.")

            HomeSectionHeader("Testing")
            HomeGroup {
                HomeToggleRow("Fake brain (canned replies, no API calls)", isOn: $settings.fakeBrain)
                HomeRowDivider()
                HomeRow("Audio file instead of live") {
                    Text(verbatim: settings.testAudioPath.isEmpty ? L10n.tr("None (live)") : (settings.testAudioPath as NSString).lastPathComponent)
                        .font(VT.Font.body).foregroundStyle(ink.secondary).lineLimit(1)
                    HomeSecondaryButton("Choose…", action: chooseFile)
                    if !settings.testAudioPath.isEmpty { HomeSecondaryButton("Clear") { settings.testAudioPath = "" } }
                }
            }
    }

    private func chooseFile() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.audio]
        p.allowsMultipleSelection = false
        if p.runModal() == .OK, let u = p.url { settings.testAudioPath = u.path }
    }
}

/// Settings > Practice interview: the default interviewer voice, the voice per engine, and the cloud keys. The same
/// settings and key calls as `SimVoiceSettingsSection` (SimSettings.swift), in the home window's rows.
struct HomePracticeVoiceSection: View {
    @ObservedObject var sim: SimSettings
    @State private var keysChanged = 0
    @State private var elevenVoices: [VoiceOption] = []
    @State private var elevenMessage: String?
    @StateObject private var voiceKeys = HomeVoiceKeys()
    @Environment(\.homeInk) private var ink

    private var appleVoices: [VoiceOption] { AppleVoice.availableVoices(lang: "en") }

    var body: some View {
        HomeGroup {
            HomeRow("Interviewer voice") {
                HomePopup(selection: $sim.voice, options: [VoiceKind.apple, .elevenlabs, .openai, .text].map { k in
                    HomeOption(verbatim: voiceKeys.isAvailable(k) ? SimSettings.label(k) : L10n.tr("\(SimSettings.label(k)) · needs a key"), k.rawValue, enabled: voiceKeys.isAvailable(k))
                })
                .id(keysChanged)
            }
            HomeRowDivider()
            HomeRow("Apple voice") {
                HomePopup(selection: $sim.appleVoiceID, options: [HomeOption("Best installed", "")] + appleVoices.map { HomeOption(verbatim: "\($0.name) · \($0.detail)", $0.id) },
                          fallback: "Saved voice")
            }
            HomeRowDivider()
            HomeRow("OpenAI voice") {
                HomePopup(selection: $sim.openAIVoiceID,
                          options: [HomeOption(verbatim: L10n.tr("Default (\(OpenAIVoice.defaultVoice.capitalized))"), "")]
                              + OpenAIVoice.availableVoices().map { HomeOption(verbatim: $0.detail.isEmpty ? $0.name : "\($0.name) · \($0.detail)", $0.id) },
                          fallback: "Saved voice")
            }
            HomeRowDivider()
            HomeRow("ElevenLabs voice", verbatimDetail: elevenMessage) {
                HomePopup(selection: $sim.elevenLabsVoiceID,
                          options: [HomeOption("Default", "")] + elevenVoices.map { HomeOption(verbatim: $0.name, $0.id) }
                              + (!sim.elevenLabsVoiceID.isEmpty && !elevenVoices.contains { $0.id == sim.elevenLabsVoiceID }
                                 ? [HomeOption("Saved voice", sim.elevenLabsVoiceID)] : []))
                HomeSecondaryButton("Load my voices", action: loadEleven).disabled(!voiceKeys.isAvailable(.elevenlabs))
            }
            HomeRowDivider()
            HomeToggleRow("Show the interviewer's line as a caption", isOn: $sim.showCaption)
            HomeRowDivider()
            voiceKey(.elevenlabs, name: L10n.tr("ElevenLabs key"))
            HomeRowDivider()
            voiceKey(.openai, name: L10n.tr("OpenAI key"))
        }
        .onAppear { voiceKeys.refresh() }
        HomeFootnote("Cloud voices are billed by ElevenLabs or OpenAI to your own key and are labelled “AI-generated voice” while they speak. Keys stay in the login Keychain. Better Apple voices: System Settings › Accessibility › Spoken Content › Manage Voices.")
    }

    private func voiceKey(_ kind: VoiceKind, name: String) -> some View {
        HomeKeyRows(name: name, placeholder: L10n.tr("\(kind == .elevenlabs ? "ElevenLabs" : "OpenAI") API key"),
                    removeNote: L10n.tr("Practice interviews fall back to the Apple voice until a key is saved again."),
                    status: { (VoiceKeys.hasKey(kind), VoiceKeys.last4(kind)) },
                    save: { try VoiceKeys.save($0, for: kind) },
                    remove: { try VoiceKeys.remove(kind) },
                    onChange: { keysChanged += 1; voiceKeys.refresh() })
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
