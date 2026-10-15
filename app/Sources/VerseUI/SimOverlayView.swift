import SwiftUI

/// The practice-interview panel under the capsule (S4): what the interviewer said (always in text mode, as a caption
/// when the toggle is on), what Verse hears, the coach note, the AI-voice note, and the controls. Same glass, type and
/// single accent as the meeting card; text is never animated.
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
        VStack(alignment: .leading, spacing: size(10)) {
            HStack(spacing: size(8)) {
                Text(stateLine)
                    .font(.system(size: size(12), weight: .medium))
                    .foregroundStyle(.white.opacity(0.62))
                Spacer(minLength: 0)
                if sim.showsAIDisclosure {
                    Label("AI-generated voice", systemImage: "waveform")
                        .font(.system(size: size(11), weight: .medium))
                        .foregroundStyle(.white.opacity(0.72))
                        .padding(.horizontal, size(7))
                        .padding(.vertical, size(2))
                        .background(Capsule().fill(.white.opacity(0.11)))
                        .accessibilityIdentifier("verse.sim.aiVoice")
                }
                if sim.voiceFellBack {
                    Text("Apple voice used")
                        .font(.system(size: size(11), weight: .medium))
                        .foregroundStyle(.white.opacity(0.62))
                }
            }

            if sim.showsLine {
                HStack(alignment: .top, spacing: size(11)) {
                    Capsule().fill(OverlayStyle.accent).frame(width: 3).padding(.vertical, size(3))
                    Text(sim.line)
                        .font(.system(size: size(sim.textMode ? 19 : 15), weight: sim.textMode ? .semibold : .medium))
                        .foregroundStyle(.white)
                        .lineLimit(sim.textMode ? nil : 2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .fixedSize(horizontal: false, vertical: true)
            }

            if sim.listening, !sim.answer.isEmpty {
                Text(sim.answer)
                    .font(.system(size: size(13)))
                    .foregroundStyle(.white.opacity(0.6))
                    .lineLimit(2)
                    .truncationMode(.head)
                    .padding(.leading, size(14))
            }

            if !sim.coach.isEmpty {
                VStack(alignment: .leading, spacing: size(6)) {
                    HStack(spacing: size(8)) {
                        Rectangle().fill(.white.opacity(0.16)).frame(width: size(14), height: 0.5)
                        Text("Coach").font(.system(size: size(11), weight: .medium)).foregroundStyle(.white.opacity(0.5))
                        Rectangle().fill(.white.opacity(0.16)).frame(height: 0.5)
                    }
                    .padding(.leading, size(14))
                    PointList(points: sim.coach.map(Self.unbullet), scale: scale, opacity: 0.86)
                }
            }

            HStack(spacing: size(6)) {
                Button("Done  ⌥Space") { onAction(.doneAnswering) }
                    .buttonStyle(OverlayButtonStyle(prominent: sim.listening, scale: scale))
                    .disabled(!sim.listening)
                    .opacity(sim.listening ? 1 : 0.45)
                Button("Repeat") { onAction(.repeat) }
                    .buttonStyle(OverlayButtonStyle(prominent: false, scale: scale))
                Button("Skip") { onAction(.skip) }
                    .buttonStyle(OverlayButtonStyle(prominent: false, scale: scale))
                Spacer(minLength: 0)
                if !sim.textMode {
                    Button(action: { onAction(.toggleCaption) }) {
                        Image(systemName: sim.showCaption ? "captions.bubble.fill" : "captions.bubble")
                    }
                    .buttonStyle(OverlayButtonStyle(prominent: false, scale: scale))
                    .help(sim.showCaption ? "Hide the caption" : "Show the interviewer's line")
                    .accessibilityLabel("Caption")
                }
                Button("End") { onAction(.end) }
                    .buttonStyle(OverlayButtonStyle(prominent: false, scale: scale))
            }
            .disabled(sim.closing)
        }
        .padding(.horizontal, size(18))
        .padding(.top, size(12))
        .padding(.bottom, size(14))
        .frame(maxWidth: .infinity, alignment: .leading)
        .transaction { $0.animation = nil }
        .accessibilityIdentifier("verse.sim")
    }

    /// Coach lines come as "- text"; the list draws its own dots.
    static func unbullet(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard let f = t.first, f == "-" || f == "•" || f == "*" else { return t }
        return t.dropFirst().trimmingCharacters(in: .whitespaces)
    }
}

/// The elapsed time in the capsule's left wing.
struct SimTimer: View {
    var start: Date

    var body: some View {
        TimelineView(.periodic(from: start, by: 1)) { ctx in
            Text(SimOverlay.elapsed(from: start, now: ctx.date))
                .monospacedDigit()
        }
        .font(.system(size: 11.5, weight: .medium))
        .foregroundStyle(.white.opacity(0.82))
    }
}
