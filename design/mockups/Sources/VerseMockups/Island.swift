import SwiftUI

/// The island's silhouette: concave shoulders into the screen's top edge, straight sides, round lower corners.
/// Same curves at every size, so idle, card and prompter read as one object (the app's HangingNotchGeometry).
struct IslandShape: Shape {
    var shoulder: CGFloat = VT.Radius.islandShoulder
    var bottom: CGFloat = VT.Radius.islandBottom

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let top0 = min(shoulder, rect.width / 2)
        let bottom0 = min(bottom, max(0, (rect.width - 2 * top0) / 2))
        let scale = min(1, rect.height / max(top0 + bottom0, 1))
        let t = top0 * scale, b = bottom0 * scale
        let k: CGFloat = 0.552_284_75
        let lx = rect.minX + t, rx = rect.maxX - t, uy = rect.minY + t, ly = rect.maxY - b
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addCurve(to: CGPoint(x: lx, y: uy), control1: CGPoint(x: rect.minX + t * k, y: rect.minY), control2: CGPoint(x: lx, y: uy - t * k))
        p.addLine(to: CGPoint(x: lx, y: ly))
        p.addCurve(to: CGPoint(x: lx + b, y: rect.maxY), control1: CGPoint(x: lx, y: ly + b * k), control2: CGPoint(x: lx + b - b * k, y: rect.maxY))
        p.addLine(to: CGPoint(x: rx - b, y: rect.maxY))
        p.addCurve(to: CGPoint(x: rx, y: ly), control1: CGPoint(x: rx - b + b * k, y: rect.maxY), control2: CGPoint(x: rx, y: ly + b * k))
        p.addLine(to: CGPoint(x: rx, y: uy))
        p.addCurve(to: CGPoint(x: rect.maxX, y: rect.minY), control1: CGPoint(x: rx, y: uy - t * k), control2: CGPoint(x: rect.maxX - t * k, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

/// The island surface: black through the camera band, then Regular glass under a black veil. The veil's floor is the
/// user's opacity (60-100 %) behind the text; the last 24 pt ease to 75 % of the floor so the lower rim
/// reads as glass, and a hairline rim catches light on the lower edge. Reduce Transparency: solid near-black, no
/// glass. Increase Contrast: floor at least 92 % and a 45 % white border.
struct IslandSurface: View {
    var size: CGSize
    var a11y: A11y

    private var floor: Double {
        if a11y.reduceTransparency { return 1 }
        return a11y.increaseContrast ? max(a11y.islandVeil, 0.92) : a11y.islandVeil
    }

    var body: some View {
        let shape = IslandShape()
        ZStack(alignment: .top) {
            if a11y.reduceTransparency {
                shape.fill(Color(hex: 0x0E0F11))
            } else {
                shape.fill(.clear).glassEffect(.regular, in: shape)
            }
            shape.fill(veil)
            if a11y.increaseContrast {
                shape.stroke(Color.white.opacity(0.6), lineWidth: 1.5)
            } else if !a11y.reduceTransparency && size.height > VT.notchHeight + 8 {
                shape.stroke(LinearGradient(stops: [.init(color: .white.opacity(0), location: 0),
                                                     .init(color: .white.opacity(0), location: min(0.99, (VT.notchHeight + 10) / size.height)),
                                                     .init(color: .white.opacity(0.20), location: 1)],
                                            startPoint: .top, endPoint: .bottom), lineWidth: 1)
            }
        }
        .frame(width: size.width, height: size.height)
        .environment(\.colorScheme, .dark)
    }

    private var veil: LinearGradient {
        let h = max(size.height, 1)
        let band = min((VT.notchHeight + 6) / h, 1)
        guard band < 1 else { return LinearGradient(colors: [.black], startPoint: .top, endPoint: .bottom) }
        func smooth(_ t: Double) -> Double { t * t * t * (t * (t * 6 - 15) + 10) }
        var stops: [Gradient.Stop] = [.init(color: .black, location: 0), .init(color: .black, location: band)]
        let reach = max(band + 0.01, min(0.78, band + 0.34))
        for i in 1...8 {
            let t = Double(i) / 8
            stops.append(.init(color: .black.opacity(1 - (1 - floor) * smooth(t)), location: band + (reach - band) * t))
        }
        let rimStart = max(reach, 1 - 24 / h)
        let rim = a11y.reduceTransparency || a11y.increaseContrast ? floor : floor * 0.75
        for i in 0...6 {
            let t = Double(i) / 6
            stops.append(.init(color: .black.opacity(floor - (floor - rim) * smooth(t)), location: rimStart + (1 - rimStart) * t))
        }
        return LinearGradient(stops: stops, startPoint: .top, endPoint: .bottom)
    }
}

// MARK: - Pieces

private struct IslandContrastKey: EnvironmentKey { static let defaultValue = false }
extension EnvironmentValues {
    /// Increase Contrast: secondary text goes to full white, tertiary to 80 %.
    var islandContrast: Bool { get { self[IslandContrastKey.self] } set { self[IslandContrastKey.self] = newValue } }
}

struct LiveDot: View {
    enum Kind { case live, idle, waiting }
    var kind: Kind = .live
    var body: some View {
        Group {
            switch kind {
            case .live: Circle().fill(VT.mint)
            case .waiting: Circle().fill(VT.mint.opacity(0.45))
            case .idle: Circle().strokeBorder(Color.white.opacity(0.5), lineWidth: 1.3)
            }
        }
        .frame(width: 7, height: 7)
    }
}

/// Who is talking, as three short bars; heights are the last 300 ms of level, not an animation loop.
struct LevelBars: View {
    var levels: [CGFloat] = [0.45, 0.9, 0.6]
    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(levels.indices, id: \.self) { i in
                Capsule().fill(Color.white.opacity(0.72)).frame(width: 2, height: 3 + 9 * levels[i])
            }
        }
        .frame(height: 12)
    }
}

/// The two strips beside the camera. Text never enters the camera band.
struct Wings<L: View, R: View>: View {
    var width: CGFloat
    /// Inset from the straight side: 12 on capsules, 22 on cards (so the dot sits on the SAY bar's axis).
    var inset: CGFloat = 12
    @ViewBuilder var left: L
    @ViewBuilder var right: R
    @Environment(\.islandContrast) private var contrast
    var body: some View {
        let wing = (width - VT.notchWidth) / 2
        HStack(spacing: 0) {
            let pad = VT.Radius.islandShoulder + inset
            HStack(spacing: 7) { left }.frame(width: max(wing - pad, 0), alignment: .leading).padding(.leading, pad)
            Spacer(minLength: VT.notchWidth)
            HStack(spacing: 6) { right }.frame(width: max(wing - pad, 0), alignment: .trailing).padding(.trailing, pad)
        }
        .font(VT.Font.wing)
        .foregroundStyle(contrast ? Color.white.opacity(0.85) : VT.Island.tertiary)
        .frame(width: width, height: VT.notchHeight)
    }
}

struct SayLine: View {
    var text: String
    var scale: CGFloat = 1
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Capsule().fill(VT.mint).frame(width: 3).padding(.vertical, 4)
            Text(text)
                .font(VT.Font.say(scale))
                .tracking(-0.35)
                .lineSpacing(2)
                .foregroundStyle(VT.Island.primary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct Points: View {
    var items: [String]
    var struck: Set<Int> = []
    var scale: CGFloat = 1
    /// Left inset: 15 clears the SAY bar; the prompter-style card has no bar and uses 0.
    var leading: CGFloat = 15
    @Environment(\.islandContrast) private var contrast
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(items.indices, id: \.self) { i in
                let done = struck.contains(i)
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Circle().fill(Color.white.opacity(done ? 0.25 : 0.55)).frame(width: 4.5, height: 4.5)
                        .alignmentGuide(.firstTextBaseline) { d in d[VerticalAlignment.center] + 4.5 }
                    Text(items[i])
                        .font(VT.Font.point(scale))
                        .strikethrough(done, color: .white.opacity(0.55))
                        .foregroundStyle(done ? (contrast ? Color.white.opacity(0.7) : VT.Island.quaternary) : (contrast ? Color.white : VT.Island.secondary))
                        .lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.leading, leading)
    }
}

/// Prompter-style SAY block (cards P1-P3): the teleprompter's "current line" type, wrapped over as many lines as
/// the text needs. Spoken words 100 % white, unspoken 55 %, no colour, no bar.
struct PrompterSay: View {
    var spoken: String
    var rest: String
    var scale: CGFloat = 1
    var body: some View {
        (Text(spoken).foregroundStyle(Color.white) + Text(rest).foregroundStyle(Color.white.opacity(0.55)))
            .font(VT.Font.prompterCurrent(scale))
            .tracking(-0.4)
            .lineSpacing(2)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The line above the prompter-style SAY: the heard question (or the "Following you" mark). One line, tail-truncated.
struct CardLead: View {
    var text: String
    var symbol: String? = nil
    var body: some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol) }
            Text(text).lineLimit(1).truncationMode(.tail)
        }
        .font(VT.Font.cardLead)
        .foregroundStyle(VT.Island.question)
    }
}

struct FactChip: View {
    var text: String
    var source: String
    @Environment(\.islandContrast) private var contrast
    var body: some View {
        HStack(spacing: 6) {
            Text(text).foregroundStyle(VT.Island.primary.opacity(0.94))
            Text(source).foregroundStyle(contrast ? Color.white.opacity(0.8) : VT.Island.tertiary)
        }
        .font(VT.Font.chip())
        .padding(.horizontal, 9).frame(height: 24)
        .background(VT.Island.fill, in: RoundedRectangle(cornerRadius: VT.Radius.chip, style: .continuous))
        .overlay { if contrast { RoundedRectangle(cornerRadius: VT.Radius.chip, style: .continuous).strokeBorder(Color.white.opacity(0.5)) } }
    }
}

struct IslandButton: View {
    var title: String
    var primary = false
    var shortcut: String? = nil
    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            if let shortcut { Text(shortcut).opacity(0.6) }
        }
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(primary ? VT.onMint : VT.Island.primary)
        .padding(.horizontal, 14).frame(height: 30)
        .background(primary ? VT.mint : VT.Island.fillStrong, in: RoundedRectangle(cornerRadius: VT.Radius.control, style: .continuous))
    }
}

// MARK: - States

enum IslandState: String, CaseIterable {
    case meetingDetected = "island-0-meeting-detected"
    case idle = "island-1-idle"
    case listening = "island-2-listening"
    case hearing = "island-3-hearing-question"
    case answer = "island-4-answer-card"
    case following = "island-5-following-you"
    case practice = "island-6-practice-capsule"
    case practiceNote = "island-6b-practice-coach-note"
    case prompter = "island-7-teleprompter"
    case status = "island-8-status-credit"
    // Prompter-style answer card (mockup round 2026-10-16b)
    case promptFresh = "island-P1-answer-prompter-style"
    case promptReading = "island-P2-answer-mid-reading"
    case promptFollowing = "island-P3-following-prompter-style"
    // Accessibility variants of the answer card
    case answerMinVeil = "island-a1-answer-veil-35"
    case answerReduceTransparency = "island-a2-answer-reduce-transparency"
    case answerIncreaseContrast = "island-a3-answer-increase-contrast"

    var a11y: A11y {
        switch self {
        case .answerMinVeil: A11y(islandVeil: 0.35)
        case .answerReduceTransparency: A11y(reduceTransparency: true)
        case .answerIncreaseContrast: A11y(increaseContrast: true)
        default: A11y()
        }
    }

    static let cardWidth: CGFloat = 600
    var isCapsule: Bool { self == .idle || self == .listening || self == .practice }
    var isPrompterCard: Bool { self == .promptFresh || self == .promptReading || self == .promptFollowing }

    var size: CGSize {
        switch self {
        case .idle: CGSize(width: VT.notchWidth + 2 * 40, height: VT.notchHeight)
        case .listening: CGSize(width: VT.notchWidth + 2 * 84, height: VT.notchHeight)
        case .practice: CGSize(width: VT.notchWidth + 2 * 128, height: VT.notchHeight)
        case .meetingDetected: CGSize(width: 480, height: 136)
        case .hearing: CGSize(width: Self.cardWidth, height: 96)
        case .answer, .answerMinVeil, .answerReduceTransparency, .answerIncreaseContrast: CGSize(width: Self.cardWidth, height: 268)
        case .following: CGSize(width: Self.cardWidth, height: 262)
        case .promptFresh, .promptReading, .promptFollowing: CGSize(width: Self.cardWidth, height: 0)   // height follows the content
        case .practiceNote: CGSize(width: 520, height: 150)
        case .prompter: CGSize(width: 640, height: 214)
        case .status: CGSize(width: 480, height: 104)
        }
    }
}

struct IslandView: View {
    var state: IslandState

    var body: some View {
        let w = state.size.width
        VStack(alignment: .leading, spacing: 0) {
            band(width: w)
            bodyContent
        }
        .padding(.bottom, state.isCapsule ? 0 : 20)
        .frame(width: w, alignment: .top)
        .fixedSize(horizontal: false, vertical: true)
        .background(alignment: .top) {
            GeometryReader { g in IslandSurface(size: g.size, a11y: state.a11y) }
        }
        .environment(\.islandContrast, state.a11y.increaseContrast)
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
            if state.isPrompterCard { print("  height \(state.rawValue): \(h) pt") }
        }
    }

    /// The answer card in teleprompter typography. `spokenWords` of the SAY line are already said.
    @ViewBuilder private func promptAnswerBody(spokenWords: Int, struck: Set<Int>) -> some View {
        let say = "In Lantern, bad invoices never blocked the pipeline — they went to a review queue."
        let words = say.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        let spoken = words.prefix(spokenWords).map { $0 + " " }.joined()
        let rest = words.dropFirst(spokenWords).joined(separator: " ")
        VStack(alignment: .leading, spacing: 0) {
            CardLead(text: "“Can you walk me through how Lantern handled bad invoices?”")
            PrompterSay(spoken: spoken, rest: rest).padding(.top, 8)
            Points(items: ["Schema-validated extraction, one retry on a failed field",
                           "Low-confidence fields went to an operator, not the ERP",
                           "Manual entry fell from 11 minutes to 2 per invoice"], struck: struck, leading: 0)
                .padding(.top, 14)
            HStack(spacing: 6) {
                FactChip(text: "38,000 invoices / month", source: "prep note")
                FactChip(text: "Lantern", source: "glossary")
            }
            .padding(.top, 12)
        }
        .padding(.horizontal, VT.Radius.islandShoulder + 22).padding(.top, 12)
    }

    @ViewBuilder private func band(width: CGFloat) -> some View {
        switch state {
        case .idle:
            Wings(width: width, inset: width > 420 ? 22 : 12) { LiveDot(kind: .idle) } right: { EmptyView() }
        case .listening:
            Wings(width: width, inset: width > 420 ? 22 : 12) { LiveDot(); LevelBars() } right: { Text("Ingrid") }
        case .meetingDetected:
            Wings(width: width, inset: width > 420 ? 22 : 12) { LiveDot(kind: .idle) } right: { EmptyView() }
        case .hearing:
            Wings(width: width, inset: width > 420 ? 22 : 12) { LiveDot(); LevelBars(levels: [0.7, 1, 0.5]) } right: { Text("for you").foregroundStyle(VT.Island.secondary) }
        case .answer, .answerMinVeil, .answerReduceTransparency, .answerIncreaseContrast:
            Wings(width: width, inset: width > 420 ? 22 : 12) { LiveDot() } right: { Text("for you").foregroundStyle(VT.Island.secondary) }
        case .following, .promptFollowing:
            Wings(width: width, inset: width > 420 ? 22 : 12) { LiveDot(); LevelBars(levels: [0.3, 0.55, 0.4]) } right: { Text("your answer").foregroundStyle(VT.Island.secondary) }
        case .promptFresh, .promptReading:
            Wings(width: width, inset: width > 420 ? 22 : 12) { LiveDot() } right: { Text("for you").foregroundStyle(VT.Island.secondary) }
        case .practice, .practiceNote:
            Wings(width: width, inset: width > 420 ? 22 : 12) {
                Text("Q3 of 8").foregroundStyle(VT.Island.secondary)
                Text("04:12").monospacedDigit()
            } right: {
                Text("your turn").foregroundStyle(VT.Island.secondary)
                LiveDot()
            }
        case .prompter:
            Wings(width: width, inset: width > 420 ? 22 : 12) { LiveDot(); Text("voice") } right: { Text("2 / 5").monospacedDigit() }
        case .status:
            Wings(width: width, inset: width > 420 ? 22 : 12) { Circle().fill(VT.amber).frame(width: 7, height: 7) } right: { Text("local only") }
        }
    }

    @ViewBuilder private var bodyContent: some View {
        switch state {
        case .idle, .listening, .practice:
            EmptyView()
        case .meetingDetected:
            VStack(alignment: .leading, spacing: 4) {
                Text("Comet is using the microphone").font(VT.Font.meta).foregroundStyle(VT.Island.tertiary)
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Mara · Northwind Labs").font(.system(size: 17, weight: .semibold)).tracking(-0.2).foregroundStyle(VT.Island.primary)
                        Text("Prepared · 14 questions").font(VT.Font.meta).foregroundStyle(VT.Island.tertiary)
                    }
                    Spacer()
                    IslandButton(title: "Not now")
                    IslandButton(title: "Start", primary: true, shortcut: "↩")
                }
            }
            .padding(.horizontal, VT.Radius.islandShoulder + 22).padding(.top, 10)
        case .hearing:
            HStack(spacing: 10) {
                Text("“Can you walk me through how Lantern handled bad invoices?”")
                    .font(.system(size: 15, weight: .medium)).foregroundStyle(VT.Island.tertiary)
                    .lineLimit(2)
            }
            .padding(.horizontal, VT.Radius.islandShoulder + 22).padding(.top, 12)
        case .answer, .answerMinVeil, .answerReduceTransparency, .answerIncreaseContrast:
            VStack(alignment: .leading, spacing: 12) {
                SayLine(text: "In Lantern, bad invoices never blocked the pipeline — they went to a review queue.")
                Points(items: ["Schema-validated extraction, one retry on a failed field",
                               "Low-confidence fields went to an operator, not the ERP",
                               "Manual entry fell from 11 minutes to 2 per invoice"])
                HStack(spacing: 6) {
                    FactChip(text: "38,000 invoices / month", source: "prep note")
                    FactChip(text: "Lantern", source: "glossary")
                }
                .padding(.leading, 15)
            }
            .padding(.horizontal, VT.Radius.islandShoulder + 22).padding(.top, 12)
        case .following:
            VStack(alignment: .leading, spacing: 8) {
                Label("Following you", systemImage: "arrow.turn.down.right")
                    .font(VT.Font.meta).foregroundStyle(VT.Island.tertiary).padding(.leading, 15)
                SayLine(text: "And on the route optimiser I built the first pilot on my own, in six weeks.")
                Points(items: ["12 depots in the pilot, ETA drift down by a third",
                               "I wrote the re-plan loop that runs every 90 seconds",
                               "Dispatchers kept an override on every route"], struck: [0])
                    .padding(.top, 4)
            }
            .padding(.horizontal, VT.Radius.islandShoulder + 22).padding(.top, 10)
        case .promptFresh:
            promptAnswerBody(spokenWords: 0, struck: [])
        case .promptReading:
            promptAnswerBody(spokenWords: 6, struck: [0])
        case .promptFollowing:
            VStack(alignment: .leading, spacing: 0) {
                CardLead(text: "Following you", symbol: "arrow.turn.down.right")
                PrompterSay(spoken: "And on the route optimiser ", rest: "I built the first pilot on my own, in six weeks.")
                    .padding(.top, 8)
                Points(items: ["12 depots in the pilot, ETA drift down by a third",
                               "I wrote the re-plan loop that runs every 90 seconds",
                               "Dispatchers kept an override on every route"], struck: [0], leading: 0)
                    .padding(.top, 14)
            }
            .padding(.horizontal, VT.Radius.islandShoulder + 22).padding(.top, 12)
        case .practiceNote:
            VStack(alignment: .leading, spacing: 8) {
                Text("Coach").font(VT.Font.meta).foregroundStyle(VT.Island.tertiary)
                Text("Good structure. Lead with the result: “manual entry fell from 11 minutes to 2” before the how.")
                    .font(.system(size: 16, weight: .medium)).foregroundStyle(VT.Island.primary).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text("⌥Space for the next question").font(VT.Font.meta).foregroundStyle(VT.Island.quaternary)
            }
            .padding(.horizontal, VT.Radius.islandShoulder + 22).padding(.top, 10)
        case .prompter:
            VStack(alignment: .leading, spacing: 8) {
                Text("Northwind Labs keeps clinic calendars full.")
                    .font(VT.Font.prompterOther).foregroundStyle(Color.white.opacity(0.28)).lineLimit(1)
                (Text("I build the tools that ").foregroundStyle(Color.white)
                 + Text("turn that into a product").foregroundStyle(Color.white.opacity(0.55)))
                    .font(VT.Font.prompterCurrent).tracking(-0.4).lineLimit(1)
                Text("your team can sell without me in the room.")
                    .font(VT.Font.prompterOther).foregroundStyle(Color.white.opacity(0.55)).lineLimit(1)
            }
            .minimumScaleFactor(0.8)
            .padding(.horizontal, VT.Radius.islandShoulder + 26).padding(.top, 14)
        case .status:
            VStack(alignment: .leading, spacing: 4) {
                Text("Max API credit is used up until 1 December.").font(.system(size: 15, weight: .semibold)).foregroundStyle(VT.Island.primary)
                Text("Verse keeps transcribing on this Mac; answers pause.").font(VT.Font.meta).foregroundStyle(VT.Island.tertiary)
            }
            .padding(.horizontal, VT.Radius.islandShoulder + 22).padding(.top, 10)
        }
    }
}

/// One island render: wallpaper, menu bar, the app under the island, the hardware notch, and the island.
struct IslandScene: View {
    var state: IslandState
    var wallpaper: Wallpaper
    static let size = CGSize(width: 1100, height: 440)

    var body: some View {
        ZStack(alignment: .top) {
            WallpaperView(kind: wallpaper)
            VStack(spacing: 0) {
                MenuBarView(kind: wallpaper)
                AppUnderIsland(kind: wallpaper)
                    .padding(.horizontal, 36).padding(.top, 10)
            }
            UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10, style: .continuous)
                .fill(Color.black).frame(width: VT.notchWidth, height: VT.notchHeight)
            IslandView(state: state)
        }
        .frame(width: Self.size.width, height: Self.size.height, alignment: .top)
    }
}
