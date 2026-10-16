import SwiftUI

/// The practice-interview panel under the band (spec 3.2, states 6 and 6b): what the interviewer said (always in text
/// mode, as a caption when the toggle is on), what Verse hears, the coach note, the AI-voice note, and the controls.
/// Same surface, type and single accent as the meeting card; text is never animated.
struct SimPanelView: View {
    var sim: SimOverlay
    var scale: CGFloat
    var onAction: (SimUIAction) -> Void

    private func size(_ s: CGFloat) -> CGFloat { (s * scale).rounded() }

    private var stateLine: String {
        if sim.closing { return "Writing your report…" }
        if sim.listening { return sim.answer.isEmpty ? "Your turn · ⌥Space when done" : "Listening · ⌥Space when done" }
        if sim.speaking { return "Interviewer speaking" }
        if sim.qTotal == 0 { return "Starting the interview…" }
        return "Interviewer thinking…"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // A coach note says it all; the state line comes back with the next question.
            if sim.coach.isEmpty || sim.showsAIDisclosure || sim.voiceFellBack {
            HStack(spacing: 8) {
                if sim.coach.isEmpty { Text(stateLine).font(VT.Font.meta).foregroundStyle(VT.Island.tertiary) }
                Spacer(minLength: 0)
                if sim.showsAIDisclosure {
                    Label("AI-generated voice", systemImage: "waveform")
                        .font(VT.Font.caption)
                        .foregroundStyle(VT.Island.secondary)
                        .padding(.horizontal, 7)
                        .frame(height: 20)
                        .background(VT.Island.fill, in: RoundedRectangle(cornerRadius: VT.Radius.chip, style: .continuous))
                        .accessibilityIdentifier("verse.sim.aiVoice")
                }
                if sim.voiceFellBack {
                    Text("Apple voice used").font(VT.Font.caption).foregroundStyle(VT.Island.tertiary)
                }
            }
            }

            if sim.showsLine {
                HStack(alignment: .top, spacing: 12) {
                    Capsule().fill(VT.mint).frame(width: 3).padding(.vertical, 4)
                    Text(sim.line)
                        .font(sim.textMode ? VT.Font.say(scale) : .system(size: size(15), weight: .medium))
                        .tracking(sim.textMode ? VT.Font.sayTracking : 0)
                        .foregroundStyle(VT.Island.primary)
                        .lineLimit(sim.textMode ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            if sim.listening, !sim.answer.isEmpty {
                Text(sim.answer)
                    .font(.system(size: size(13)))
                    .foregroundStyle(VT.Island.tertiary)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .padding(.leading, 15)
            }

            if !sim.coach.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Coach").font(VT.Font.meta).foregroundStyle(VT.Island.tertiary)
                    ForEach(Array(sim.coach.map(Self.unbullet).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: size(16), weight: .medium))
                            .foregroundStyle(VT.Island.primary)
                            .lineSpacing(2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !sim.listening {
                        Text("⌥Space for the next question").font(VT.Font.meta).foregroundStyle(VT.Island.quaternary)
                    }
                }
            }

            HStack(spacing: 6) {
                Button("Done  ⌥Space") { onAction(.doneAnswering) }
                    .buttonStyle(OverlayButtonStyle(prominent: sim.listening))
                    .disabled(!sim.listening)
                    .opacity(sim.listening ? 1 : 0.45)
                Button("Repeat") { onAction(.repeat) }
                    .buttonStyle(OverlayButtonStyle(prominent: false))
                Button("Skip") { onAction(.skip) }
                    .buttonStyle(OverlayButtonStyle(prominent: false))
                Spacer(minLength: 0)
                if !sim.textMode {
                    Button(action: { onAction(.toggleCaption) }) {
                        Image(systemName: sim.showCaption ? "captions.bubble.fill" : "captions.bubble")
                    }
                    .buttonStyle(OverlayButtonStyle(prominent: false))
                    .help(sim.showCaption ? "Hide the caption" : "Show the interviewer's line")
                    .accessibilityLabel("Caption")
                }
                Button("End") { onAction(.end) }
                    .buttonStyle(OverlayButtonStyle(prominent: false))
            }
            .disabled(sim.closing)
        }
        .padding(.horizontal, VT.islandCardInset)
        .padding(.top, 10)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .transaction { $0.animation = nil }
        .accessibilityIdentifier("verse.sim")
    }

    /// Coach lines come as "- text"; the panel draws its own layout.
    static func unbullet(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let f = t.first, f == "-" || f == "•" || f == "*" else { return t }
        return t.dropFirst().trimmingCharacters(in: .whitespaces)
    }
}

/// The elapsed time in the band's left wing (it takes the wing's colour).
struct SimTimer: View {
    var start: Date

    var body: some View {
        TimelineView(.periodic(from: start, by: 1)) { ctx in
            let s = max(0, Int(ctx.date.timeIntervalSince(start)))
            Text(String(format: "%02d:%02d", s / 60, s % 60))
                .monospacedDigit()
        }
    }
}
