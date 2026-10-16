import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VerseTurns
import VerseVoice

/// The home window's Practice page: the posting (link or paste, with a preview to confirm), experience sources, the
/// interview's shape, then Prepare (S1 prep) and Start. It replaces the "Practice interview…" window.
public struct SimSetupView: View {
    @ObservedObject var sim: SimController
    @ObservedObject var meeting: VerseController
    @StateObject private var voiceKeys = HomeVoiceKeys()
    @Environment(\.homeInk) private var ink

    public init(sim: SimController, meeting: VerseController) {
        self.sim = sim
        self.meeting = meeting
    }

    private var locked: Bool { sim.phase == .preparing || sim.phase == .running }

    public var body: some View {
        HomeColumnPage {
            HomePageHeader("Practice", subtitle: "A spoken mock interview, built from the posting.")
            HomeSectionHeader("Job posting")
            postingGroup.disabled(locked)
            HomeFootnote("Read the preview before you confirm it: the interview is built from this text only.")
            HomeSectionHeader("Interview")
            interviewGroup.disabled(locked)
            HomeSectionHeader("Your experience")
            experienceGroup.disabled(locked)
            runArea.padding(.top, 16)
        }
        .onAppear { voiceKeys.refresh() }
        .accessibilityIdentifier("verse.home.practice")
    }

    // MARK: posting

    private var postingGroup: some View {
        HomeGroup {
            HomeRow("Link") {
                HomeValueField("LinkedIn, Ashby, Greenhouse, Lever or any job page", text: $sim.postingLink, onSubmit: sim.fetchPosting)
                if sim.fetching { ProgressView().controlSize(.small) }
                HomeSecondaryButton("Fetch", symbol: "link", action: sim.fetchPosting)
                    .disabled(sim.fetching || sim.postingLink.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let m = sim.fetchMessage { HomeNote(text: m).padding(.horizontal, 14).padding(.bottom, 10) }
            if sim.posting == nil {
                HomeRowDivider()
                HomeRow("Posting text") {
                    HomeValueField("Or paste the posting text", text: $sim.pasteText, lines: 1...4)
                    HomeSecondaryButton("Use pasted text", action: sim.usePastedText)
                        .disabled(sim.pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if let p = sim.posting {
                HomeRowDivider()
                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(p.title.isEmpty ? "Posting" : p.title).font(VT.Font.bodyEmph).foregroundStyle(ink.primary).lineLimit(2)
                        Text([p.company, p.source == .pasted ? nil : p.source.rawValue].compactMap { $0 }.joined(separator: " · "))
                            .font(VT.Font.callout).foregroundStyle(ink.tertiary).lineLimit(1)
                        Spacer()
                        if sim.postingConfirmed {
                            Label("Confirmed", systemImage: "checkmark").font(VT.Font.callout).foregroundStyle(ink.secondary)
                        } else {
                            HomeSecondaryButton("Use this posting", action: sim.confirmPosting)
                        }
                        HomeSecondaryButton("Clear", action: sim.clearPosting)
                    }
                    if sim.postingConfirmed {
                        Text(p.text).font(VT.Font.body).foregroundStyle(ink.secondary).lineSpacing(3).lineLimit(2)
                    } else {
                        ScrollView {
                            Text(p.text).font(VT.Font.callout).foregroundStyle(ink.secondary).textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 150)
                    }
                    Text("\(p.text.count.formatted()) characters").font(VT.Font.caption).foregroundStyle(ink.tertiary)
                }
                .padding(14)
            }
        }
    }

    // MARK: experience

    private var experienceGroup: some View {
        HomeGroup {
            HomeRow("CV") {
                Text(sim.setup.cv?.lastPathComponent ?? "None").font(VT.Font.body).foregroundStyle(ink.secondary).lineLimit(1)
                HomeSecondaryButton("Choose…", action: chooseCV)
                if sim.setup.cv != nil { HomeSecondaryButton("Clear") { sim.setup.cv = nil } }
            }
            HomeRowDivider()
            VStack(alignment: .leading, spacing: 6) {
                Text("About me (optional)").font(VT.Font.body).foregroundStyle(ink.primary)
                HomeTextArea(text: $sim.setup.note, placeholder: "Anything the interviewer should know about you.", minHeight: 40)
            }
            .padding(14)
            HomeRowDivider()
            HomeToggleRow("Use my vault", isOn: $sim.setup.useVault)
            HomeRowDivider()
            HomeRow("Repositories") {
                VStack(alignment: .trailing, spacing: 4) {
                    ForEach(sim.setup.repos, id: \.self) { r in
                        HStack(spacing: 6) {
                            Text((r as NSString).abbreviatingWithTildeInPath).font(VT.Font.body).foregroundStyle(ink.secondary)
                                .lineLimit(1).truncationMode(.middle)
                            Button { sim.setup.repos.removeAll { $0 == r } } label: {
                                Image(systemName: "minus.circle").foregroundStyle(ink.tertiary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(r)")
                        }
                    }
                    HomeSecondaryButton("Add folder…", action: addRepo)
                }
                .padding(.vertical, sim.setup.repos.isEmpty ? 0 : 8)
            }
        }
    }

    // MARK: interview

    private var interviewGroup: some View {
        HomeGroup {
            HomeRow("Company") { HomeValueField("read from the posting", text: $sim.setup.company) }
            HomeRowDivider()
            HomeRow("Type") {
                HomeSegmented([("Screening", SimSetup.InterviewType.screening), ("Hiring manager", .manager),
                               ("Technical", .technical), ("Mixed", .mixed)], selection: $sim.setup.type)
            }
            HomeRowDivider()
            HomeRow("Difficulty") {
                HomeSegmented(SimSetup.Difficulty.allCases.map { ($0.rawValue.capitalized, $0) }, selection: $sim.setup.difficulty)
            }
            HomeRowDivider()
            HomeRow("Length") {
                HomePopup(selection: $sim.setup.lengthMin, options: [HomeOption("15 min · 5 questions", 15), HomeOption("30 min · 8 questions", 30),
                                                                      HomeOption("45 min · 11 questions", 45)])
            }
            HomeRowDivider()
            HomeRow("Feedback") {
                HomeSegmented([("Coach after each answer", SimMode.coach), ("Report at the end", SimMode.realistic)], selection: $sim.setup.mode)
            }
            HomeRowDivider()
            HomeRow("Interviewer voice", detail: voiceNote) {
                HomePopup(selection: $sim.setup.voice, options: [VoiceKind.apple, .elevenlabs, .openai, .text].map { k in
                    HomeOption(SimSettings.label(k) + (voiceKeys.isAvailable(k) ? "" : " · add a key in Settings"), k, enabled: voiceKeys.isAvailable(k))
                })
            }
            HomeRowDivider()
            HomeToggleRow("Hints during practice", detail: "Shows the normal Verse card under the notch.", isOn: $sim.setup.hints)
        }
    }

    private var voiceNote: String? {
        !voiceKeys.isAvailable(.elevenlabs) || !voiceKeys.isAvailable(.openai)
            ? "ElevenLabs and OpenAI voices need your own key (Settings › Practice interview)." : nil
    }

    // MARK: prepare / start

    @ViewBuilder private var runArea: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch sim.phase {
            case .setup:
                HStack(spacing: 8) {
                    VStack(alignment: .leading, spacing: 3) {
                        if !sim.postingConfirmed { HomeNote(text: "Confirm the posting first.") }
                        if meeting.running { HomeNote(text: "A meeting is running; stop it first.") }
                        if let n = sim.expectedFolderName { Text(n).font(VT.Font.caption).foregroundStyle(ink.tertiary).lineLimit(1) }
                    }
                    Spacer()
                    HomePrimaryButton("Prepare interview", hint: "⌘↩", shortcut: KeyboardShortcut(.return, modifiers: .command), action: sim.prepare)
                        .disabled(!sim.canPrepare)
                }
                if let e = sim.prepError { HomeNote(text: e, isError: true) }
            case .preparing:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    if let t0 = sim.prepStartedAt {
                        TimelineView(.periodic(from: t0, by: 1)) { ctx in
                            Text("Preparing · \(SimOverlay.elapsed(from: t0, now: ctx.date))")
                                .font(VT.Font.bodyEmph).foregroundStyle(ink.primary).monospacedDigit()
                        }
                    }
                    Spacer()
                    HomeSecondaryButton("Cancel", action: sim.cancelPrep)
                }
                if let l = sim.prepLines.last { Text(l).font(VT.Font.callout).foregroundStyle(ink.secondary).lineLimit(2) }
            case .prepared, .running, .finished:
                if let s = sim.summary {
                    HomeGroup {
                        HomeRow("Interview", value: "\(s.company) · \(s.role)")
                        HomeRowDivider()
                        HomeRow("Plan", value: "\(s.questions) questions · \(s.evidence) evidence items from your sources")
                    }
                    ForEach(s.warnings, id: \.self) { w in
                        Label(w, systemImage: "exclamationmark.triangle").font(VT.Font.callout).foregroundStyle(ink.secondary)
                    }
                }
                HStack(spacing: 8) {
                    if sim.phase == .prepared {
                        Text("Answer out loud. Your answer ends after 2 seconds of silence, or ⌥Space.")
                            .font(VT.Font.callout).foregroundStyle(ink.secondary)
                    } else if sim.phase == .running {
                        Text("Running · under the notch").font(VT.Font.callout).foregroundStyle(ink.secondary)
                    }
                    Spacer()
                    if sim.lastReport != nil { HomeSecondaryButton("Open last report", action: sim.openLastReport) }
                    switch sim.phase {
                    case .running:
                        HomeSecondaryButton("End interview", action: sim.endInterview)
                    case .finished:
                        HomePrimaryButton("New interview", action: sim.newInterview)
                    default:
                        HomeSecondaryButton("Change setup", action: sim.newInterview)
                        HomePrimaryButton("Start practice", hint: "⌘↩", shortcut: KeyboardShortcut(.return, modifiers: .command), action: sim.start)
                            .disabled(!sim.canStart)
                    }
                }
            }
            if sim.fake { HomeNote(text: "Fake brain is on (Settings › Testing): canned questions, no API calls.") }
        }
    }

    private func chooseCV() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.pdf, .plainText] + [UTType(filenameExtension: "md")].compactMap { $0 }
        p.allowsMultipleSelection = false
        if p.runModal() == .OK, let u = p.url { sim.setup.cv = u }
    }

    private func addRepo() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = true
        if p.runModal() == .OK {
            for u in p.urls where !sim.setup.repos.contains(u.path) { sim.setup.repos.append(u.path) }
        }
    }
}
