import SwiftUI

/// The prompt under the notch (spec 3.2, state 0): a small meta line, the meeting title, one line of what Start will
/// use, and the two buttons: neutral "Not now" and the mint primary. Nothing here animates.
struct MeetingPromptView: View {
    var prompt: MeetingPrompt
    var onAction: (PromptAction) -> Void

    private var eyebrow: String? { prompt.eyebrow }
    private var headline: String { prompt.headline ?? prompt.title }
    private var detail: String? { prompt.detailLine ?? (prompt.subtitle.isEmpty ? nil : prompt.subtitle) }

    /// The quiet button of a start prompt reads "Not now" (the model keeps "Dismiss" for its own callers).
    private var dismissText: String? { prompt.dismissLabel.map { $0 == "Dismiss" ? "Not now" : $0 } }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let eyebrow {
                Text(eyebrow).font(VT.Font.meta).foregroundStyle(VT.Island.tertiary).lineLimit(1)
            }
            HStack(alignment: .center, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(headline)
                        .font(.system(size: 17, weight: .semibold))
                        .tracking(-0.2)
                        .foregroundStyle(VT.Island.primary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let detail {
                        HStack(spacing: 6) {
                            if prompt.busy { ProgressView().controlSize(.small).tint(.white).scaleEffect(0.7).frame(width: 12, height: 12) }
                            Text(detail)
                                .font(VT.Font.meta)
                                .foregroundStyle(VT.Island.tertiary)
                                .lineLimit(3)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                Spacer(minLength: 8)
                if let d = dismissText {
                    Button(d) { onAction(.dismiss) }
                        .buttonStyle(OverlayButtonStyle(prominent: false))
                        .disabled(prompt.busy)
                        .accessibilityIdentifier("verse.prompt.dismiss")
                }
                Button(prompt.acceptLabel) { onAction(.accept) }
                    .buttonStyle(OverlayButtonStyle(prominent: true))
                    .disabled(prompt.busy)
                    .accessibilityIdentifier("verse.prompt.accept")
            }
        }
        .padding(.horizontal, VT.islandCardInset)
        .padding(.top, 10)
        .padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("verse.prompt")
    }
}
