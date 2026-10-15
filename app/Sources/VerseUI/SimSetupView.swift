import AppKit
import SwiftUI
import UniformTypeIdentifiers
import VerseTurns
import VerseVoice

/// The "Practice interview…" window: posting (link or paste, with a preview to confirm), experience sources, the
/// interview's shape, then Prepare (S1 prep) and Start.
public struct SimSetupView: View {
    @ObservedObject var sim: SimController
    @ObservedObject var meeting: VerseController

    public init(sim: SimController, meeting: VerseController) {
        self.sim = sim
        self.meeting = meeting
    }

    private var locked: Bool { sim.phase == .preparing || sim.phase == .running }

    public var body: some View {
        Form {
            postingSection
            experienceSection
            interviewSection
            runSection
        }
        .formStyle(.grouped)
        .frame(width: 600)
        .frame(minHeight: 640)
    }

    // MARK: posting

    private var postingSection: some View {
        Section {
            HStack {
                TextField("Link", text: $sim.postingLink, prompt: Text("LinkedIn, Ashby, Greenhouse, Lever or any job page"))
                    .onSubmit(sim.fetchPosting)
                if sim.fetching { ProgressView().controlSize(.small) }
                Button("Fetch", action: sim.fetchPosting)
                    .disabled(sim.fetching || sim.postingLink.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            if let m = sim.fetchMessage { Text(m).font(.callout).foregroundStyle(.secondary) }
            VStack(alignment: .leading, spacing: 6) {
                Text("Or paste the posting text").font(.callout).foregroundStyle(.secondary)
                TextEditor(text: $sim.pasteText)
                    .font(.body)
                    .frame(height: 80)
                    .scrollContentBackground(.hidden)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
                Button("Use pasted text", action: sim.usePastedText)
                    .disabled(sim.pasteText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let p = sim.posting {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(p.title.isEmpty ? "Posting" : p.title).font(.headline).lineLimit(2)
                        Spacer()
                        Text([p.company, p.source.rawValue].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    ScrollView {
                        Text(p.text)
                            .font(.callout)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(height: 170)
                    HStack {
                        if sim.postingConfirmed {
                            Label("Using this posting", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
                        } else {
                            Button("Use this posting", action: sim.confirmPosting).keyboardShortcut(.defaultAction)
                        }
                        Button("Clear", action: sim.clearPosting)
                        Spacer()
                        Text("\(p.text.count) characters").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Job posting")
        } footer: {
            Text("Read the preview before you confirm it: the interview is built from this text only.")
        }
        .disabled(locked)
    }

    // MARK: experience

    private var experienceSection: some View {
        Section("Your experience") {
            LabeledContent("CV") {
                HStack {
                    Text(sim.setup.cv?.lastPathComponent ?? "None").foregroundStyle(.secondary).lineLimit(1)
                    Button("Choose…", action: chooseCV)
                    if sim.setup.cv != nil { Button("Clear") { sim.setup.cv = nil } }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("About me (optional)").font(.callout).foregroundStyle(.secondary)
                TextEditor(text: $sim.setup.note)
                    .font(.body)
                    .frame(height: 60)
                    .scrollContentBackground(.hidden)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .textBackgroundColor)))
            }
            Toggle("Use my vault", isOn: $sim.setup.useVault)
            LabeledContent("Repositories") {
                VStack(alignment: .trailing, spacing: 4) {
                    ForEach(sim.setup.repos, id: \.self) { r in
                        HStack {
                            Text((r as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                            Button(action: { sim.setup.repos.removeAll { $0 == r } }) { Image(systemName: "minus.circle") }
                                .buttonStyle(.borderless)
                                .accessibilityLabel("Remove \(r)")
                        }
                    }
                    Button("Add folder…", action: addRepo)
                }
            }
        }
        .disabled(locked)
    }

    // MARK: interview

    private var interviewSection: some View {
        Section("Interview") {
            TextField("Company", text: $sim.setup.company, prompt: Text("read from the posting"))
            Picker("Type", selection: $sim.setup.type) {
                Text("Screening (HR)").tag(SimSetup.InterviewType.screening)
                Text("Hiring manager").tag(SimSetup.InterviewType.manager)
                Text("Technical").tag(SimSetup.InterviewType.technical)
                Text("Mixed").tag(SimSetup.InterviewType.mixed)
            }
            Picker("Difficulty", selection: $sim.setup.difficulty) {
                ForEach(SimSetup.Difficulty.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Length", selection: $sim.setup.lengthMin) {
                Text("15 min · 5 questions").tag(15)
                Text("30 min · 8 questions").tag(30)
                Text("45 min · 11 questions").tag(45)
            }
            Picker("Feedback", selection: $sim.setup.mode) {
                Text("Coach (a note after each answer)").tag(SimMode.coach)
                Text("Realistic (report at the end)").tag(SimMode.realistic)
            }
            Picker("Interviewer voice", selection: $sim.setup.voice) {
                ForEach([VoiceKind.apple, .elevenlabs, .openai, .text], id: \.self) { k in
                    Text(SimSettings.label(k) + (SimSettings.isAvailable(k) ? "" : " · add a key in Settings"))
                        .tag(k)
                        .selectionDisabled(!SimSettings.isAvailable(k))
                }
            }
            if !SimSettings.isAvailable(.elevenlabs) || !SimSettings.isAvailable(.openai) {
                Text("ElevenLabs and OpenAI voices need your own key (Settings › Practice interview).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Toggle("Hints during practice (the normal Verse card)", isOn: $sim.setup.hints)
        }
        .disabled(locked)
    }

    // MARK: prepare / start

    private var runSection: some View {
        Section {
            switch sim.phase {
            case .setup:
                HStack {
                    Button("Prepare interview", action: sim.prepare)
                        .keyboardShortcut(.defaultAction)
                        .disabled(!sim.canPrepare)
                    Spacer()
                    if let n = sim.expectedFolderName { Text(n).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                }
                if !sim.postingConfirmed { Text("Confirm the posting first.").font(.caption).foregroundStyle(.secondary) }
                if meeting.running { Text("A meeting is running; stop it first.").font(.caption).foregroundStyle(.secondary) }
                if let e = sim.prepError { Text(e).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            case .preparing:
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    if let t0 = sim.prepStartedAt {
                        TimelineView(.periodic(from: t0, by: 1)) { ctx in
                            Text("Preparing · \(SimOverlay.elapsed(from: t0, now: ctx.date))").monospacedDigit()
                        }
                    }
                    Spacer()
                    Button("Cancel", action: sim.cancelPrep)
                }
                if let l = sim.prepLines.last { Text(l).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
            case .prepared, .running, .finished:
                if let s = sim.summary {
                    LabeledContent("Interview", value: "\(s.company) · \(s.role)")
                    LabeledContent("Plan", value: "\(s.questions) questions · \(s.evidence) evidence items from your sources")
                    ForEach(s.warnings, id: \.self) { w in
                        Label(w, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    switch sim.phase {
                    case .running:
                        Text("Running · under the notch").foregroundStyle(.secondary)
                        Spacer()
                        Button("End interview", action: sim.endInterview)
                    case .finished:
                        Button("New interview", action: sim.newInterview)
                        Spacer()
                    default:
                        Button("Start", action: sim.start)
                            .keyboardShortcut(.defaultAction)
                            .disabled(!sim.canStart)
                        Button("Change setup", action: sim.newInterview)
                        Spacer()
                    }
                    if sim.lastReport != nil { Button("Open last report", action: sim.openLastReport) }
                }
                if sim.phase == .prepared {
                    Text("Answer out loud. Your answer ends after 2 seconds of silence, or press ⌥Space.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Run")
        } footer: {
            if sim.fake { Text("Fake brain is on (Settings › Testing): canned questions, no API calls.") }
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
