import SwiftUI

/// The prompt under the notch: a title, one or two lines of detail and the buttons. Same footing as the start-up
/// panel (it replaces it before a session and after one); nothing here animates.
struct MeetingPromptView: View {
    var prompt: MeetingPrompt
    var scale: CGFloat
    var onAction: (PromptAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10 * scale) {
            HStack(alignment: .top, spacing: 12 * scale) {
                Group {
                    if prompt.busy {
                        ProgressView().controlSize(.small).tint(.white)
                    } else {
                        Circle().fill(OverlayStyle.accent).frame(width: 10 * scale, height: 10 * scale)
                    }
                }
                .frame(width: 18 * scale, height: 18 * scale)
                VStack(alignment: .leading, spacing: 3 * scale) {
                    Text(prompt.title)
                        .font(.system(size: (16 * scale).rounded(), weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text(prompt.subtitle)
                        .font(.system(size: (13 * scale).rounded()))
                        .foregroundStyle(.white.opacity(0.72))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Button(prompt.acceptLabel) { onAction(.accept) }
                    .buttonStyle(OverlayButtonStyle(prominent: true, scale: scale))
                    .disabled(prompt.busy)
                    .accessibilityIdentifier("verse.prompt.accept")
                if let d = prompt.dismissLabel {
                    Button(d) { onAction(.dismiss) }
                        .buttonStyle(OverlayButtonStyle(prominent: false, scale: scale))
                        .accessibilityIdentifier("verse.prompt.dismiss")
                }
            }
            .padding(.leading, 30 * scale)
        }
        .padding(.horizontal, 18 * scale)
        .padding(.top, 12 * scale)
        .padding(.bottom, 16 * scale)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("verse.prompt")
    }
}
