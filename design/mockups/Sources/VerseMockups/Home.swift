import SwiftUI

enum HomePage: String, CaseIterable {
    case prepare, sessions, practice, scripts, settings

    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .prepare: "checklist"
        case .sessions: "clock.arrow.circlepath"
        case .practice: "person.wave.2"
        case .scripts: "text.alignleft"
        case .settings: "gearshape"
        }
    }
}

enum HomeVariant: CaseIterable {
    case standard, reduceTransparency, increaseContrast
    var suffix: String {
        switch self {
        case .standard: ""
        case .reduceTransparency: "-reduce-transparency"
        case .increaseContrast: "-increase-contrast"
        }
    }
    func applies(to page: HomePage) -> Bool { self == .standard || page == .prepare }
    var a11y: A11y {
        switch self {
        case .standard: A11y()
        case .reduceTransparency: A11y(reduceTransparency: true)
        case .increaseContrast: A11y(increaseContrast: true)
        }
    }
}

// MARK: - Semantic window colours

private struct WindowInk {
    var scheme: ColorScheme
    var a11y: A11y
    var dark: Bool { scheme == .dark }
    var primary: Color { dark ? .white.opacity(0.92) : .black.opacity(0.86) }
    var secondary: Color { a11y.increaseContrast ? primary : (dark ? .white.opacity(0.58) : .black.opacity(0.54)) }
    var tertiary: Color { a11y.increaseContrast ? primary.opacity(0.8) : (dark ? .white.opacity(0.36) : .black.opacity(0.34)) }
    var background: Color { dark ? Color(hex: 0x1D1D20) : Color(hex: 0xF5F5F7) }
    var group: Color {
        if a11y.reduceTransparency || a11y.increaseContrast { return dark ? Color(hex: 0x2A2A2E) : .white }
        return dark ? .white.opacity(0.055) : .white.opacity(0.52)
    }
    var plate: Color {
        if a11y.reduceTransparency || a11y.increaseContrast { return dark ? Color(hex: 0x252528) : .white }
        return dark ? .black.opacity(0.22) : .white.opacity(0.72)
    }
    var fill: Color { dark ? .white.opacity(0.10) : .black.opacity(0.055) }
    var selection: Color { dark ? .white.opacity(0.12) : .black.opacity(0.075) }
    var separator: Color { a11y.increaseContrast ? (dark ? .white.opacity(0.5) : .black.opacity(0.5)) : (dark ? .white.opacity(0.08) : .black.opacity(0.08)) }
    var edge: Color { a11y.increaseContrast ? (dark ? .white.opacity(0.6) : .black.opacity(0.6)) : (dark ? .white.opacity(0.14) : .white.opacity(0.65)) }
    var mintText: Color { dark ? VT.mint : VT.mintDeep }
}

private struct InkKey: EnvironmentKey { static let defaultValue = WindowInk(scheme: .light, a11y: A11y()) }
private extension EnvironmentValues {
    var ink: WindowInk { get { self[InkKey.self] } set { self[InkKey.self] = newValue } }
}

// MARK: - Scene

struct HomeScene: View {
    var page: HomePage
    var wallpaper: Wallpaper
    var variant: HomeVariant
    static let size = CGSize(width: 1280, height: 800)

    var body: some View {
        ZStack {
            WallpaperView(kind: wallpaper)
            HomeWindow(page: page, a11y: variant.a11y)
                .frame(width: 1100, height: 680)
                .shadow(color: .black.opacity(wallpaper == .dark ? 0.45 : 0.18), radius: 30, y: 16)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .environment(\.colorScheme, wallpaper.scheme)
        .environment(\.ink, WindowInk(scheme: wallpaper.scheme, a11y: variant.a11y))
    }
}

struct HomeWindow: View {
    var page: HomePage
    var a11y: A11y
    @Environment(\.ink) private var ink

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: VT.Radius.window, style: .continuous)
        ZStack(alignment: .topLeading) {
            if a11y.reduceTransparency {
                shape.fill(ink.background)
            } else {
                shape.fill(.clear).glassEffect(.regular, in: shape)
                shape.fill(ink.background.opacity(a11y.increaseContrast ? 0.94 : VT.windowVeil))
            }
            HStack(spacing: 0) {
                Sidebar(selected: page).frame(width: 220)
                Rectangle().fill(ink.separator).frame(width: 1).padding(.vertical, 16).opacity(a11y.increaseContrast ? 1 : 0)
                PageView(page: page)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            shape.strokeBorder(ink.edge, lineWidth: 1)
        }
        .clipShape(shape)
    }
}

// MARK: - Sidebar

private struct Sidebar: View {
    var selected: HomePage
    @Environment(\.ink) private var ink

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 8) {
                Circle().fill(Color(hex: 0xFF5F57)); Circle().fill(Color(hex: 0xFEBC2E)); Circle().fill(Color(hex: 0x28C840))
            }
            .frame(width: 52, height: 12)
            .padding(.leading, 20).padding(.top, 20).padding(.bottom, 28)

            ForEach(HomePage.allCases, id: \.self) { p in
                HStack(spacing: 10) {
                    Image(systemName: p.symbol).font(.system(size: 14, weight: .medium)).frame(width: 20)
                        .foregroundStyle(p == selected ? ink.primary : ink.secondary)
                    Text(p.title).font(VT.Font.sidebar).foregroundStyle(ink.primary)
                    Spacer()
                    if p == .sessions { Text("12").font(VT.Font.caption).foregroundStyle(ink.tertiary).monospacedDigit() }
                }
                .padding(.horizontal, 10).frame(height: 32)
                .background(p == selected ? ink.selection : .clear, in: RoundedRectangle(cornerRadius: VT.Radius.row, style: .continuous))
            }
            .padding(.horizontal, 10)

            Text("Recent").font(VT.Font.caption).foregroundStyle(ink.tertiary)
                .padding(.leading, 20).padding(.top, 22).padding(.bottom, 4)
            ForEach(["Mara · Northwind Labs", "Brightwave case review", "Harbor Tech technical"], id: \.self) { s in
                Text(s).font(VT.Font.body).foregroundStyle(ink.secondary).lineLimit(1)
                    .padding(.horizontal, 20).frame(height: 26)
            }

            Spacer()
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Circle().fill(VT.mint).frame(width: 7, height: 7)
                    Text("Ready").font(VT.Font.bodyEmph).foregroundStyle(ink.primary)
                }
                Text("⌥⌘V starts listening").font(VT.Font.caption).foregroundStyle(ink.tertiary)
            }
            .padding(.leading, 20).padding(.bottom, 20)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - Building blocks

private struct PrimaryButton: View {
    var title: String
    var shortcut: String? = nil
    var body: some View {
        HStack(spacing: 6) {
            Text(title)
            if let shortcut { Text(shortcut).opacity(0.55) }
        }
        .font(.system(size: 13, weight: .semibold)).foregroundStyle(VT.onMint)
        .padding(.horizontal, 14).frame(height: 30)
        .background(VT.mint, in: RoundedRectangle(cornerRadius: VT.Radius.control, style: .continuous))
    }
}

private struct SecondaryButton: View {
    var title: String
    var symbol: String? = nil
    @Environment(\.ink) private var ink
    var body: some View {
        HStack(spacing: 6) {
            if let symbol { Image(systemName: symbol) }
            Text(title)
        }
        .font(.system(size: 13, weight: .medium)).foregroundStyle(ink.primary)
        .padding(.horizontal, 12).frame(height: 28)
        .background(ink.fill, in: RoundedRectangle(cornerRadius: VT.Radius.control, style: .continuous))
        .overlay {
            if ink.a11y.increaseContrast {
                RoundedRectangle(cornerRadius: VT.Radius.control, style: .continuous).strokeBorder(ink.separator)
            }
        }
    }
}

private struct InsetGroup<Content: View>: View {
    var plate = false
    @ViewBuilder var content: Content
    @Environment(\.ink) private var ink
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .background(plate ? ink.plate : ink.group, in: RoundedRectangle(cornerRadius: VT.Radius.group, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: VT.Radius.group, style: .continuous)
                    .strokeBorder(ink.a11y.increaseContrast ? ink.separator : (ink.dark ? Color.white.opacity(0.06) : Color.white.opacity(0.7)), lineWidth: 1)
            }
    }
}

private struct RowDivider: View {
    @Environment(\.ink) private var ink
    var inset: CGFloat = 14
    var body: some View { Rectangle().fill(ink.separator).frame(height: 1).padding(.leading, inset) }
}

private struct ValueRow<Trailing: View>: View {
    var label: String
    var value: String? = nil
    @ViewBuilder var trailing: Trailing
    @Environment(\.ink) private var ink
    var body: some View {
        HStack(spacing: 10) {
            Text(label).font(VT.Font.body).foregroundStyle(ink.primary)
            Spacer(minLength: 16)
            if let value { Text(value).font(VT.Font.body).foregroundStyle(ink.secondary).lineLimit(1) }
            trailing
        }
        .padding(.horizontal, 14).frame(minHeight: 40)
    }
}

extension ValueRow where Trailing == EmptyView {
    init(label: String, value: String?) { self.init(label: label, value: value) { EmptyView() } }
}

private struct SectionHeader: View {
    var text: String
    @Environment(\.ink) private var ink
    var body: some View {
        Text(text).font(.system(size: 12, weight: .semibold)).foregroundStyle(ink.secondary)
            .padding(.leading, 4).padding(.top, 20).padding(.bottom, 7)
    }
}

private struct Segmented: View {
    var items: [String]
    var selected: Int
    @Environment(\.ink) private var ink
    var body: some View {
        HStack(spacing: 2) {
            ForEach(items.indices, id: \.self) { i in
                Text(items[i]).font(.system(size: 12, weight: i == selected ? .semibold : .medium))
                    .foregroundStyle(i == selected ? ink.primary : ink.secondary)
                    .padding(.horizontal, 11).frame(height: 24)
                    .background(i == selected ? (ink.dark ? Color.white.opacity(0.18) : Color.white) : .clear,
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            }
        }
        .padding(2)
        .background(ink.fill, in: RoundedRectangle(cornerRadius: VT.Radius.control, style: .continuous))
    }
}

private struct PopupValue: View {
    var text: String
    @Environment(\.ink) private var ink
    var body: some View {
        HStack(spacing: 5) {
            Text(text).font(VT.Font.body).foregroundStyle(ink.primary)
            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(ink.secondary)
        }
    }
}

private struct ToggleMark: View {
    var on: Bool
    @Environment(\.ink) private var ink
    var body: some View {
        ZStack(alignment: on ? .trailing : .leading) {
            Capsule().fill(on ? VT.mint : ink.fill).frame(width: 34, height: 20)
            Circle().fill(Color.white).frame(width: 16, height: 16).padding(2)
                .shadow(color: .black.opacity(0.15), radius: 1, y: 0.5)
        }
    }
}

private struct SliderMark: View {
    var fraction: CGFloat
    var width: CGFloat = 220
    @Environment(\.ink) private var ink
    var body: some View {
        ZStack(alignment: .leading) {
            Capsule().fill(ink.fill).frame(width: width, height: 5)
            Capsule().fill(VT.mint).frame(width: width * fraction, height: 5)
            Capsule().fill(Color.white).frame(width: 22, height: 15)
                .shadow(color: .black.opacity(0.18), radius: 1.5, y: 0.5)
                .offset(x: width * fraction - 11)
        }
        .frame(width: width, height: 16)
    }
}

private struct PageHeader<Actions: View>: View {
    var title: String
    var subtitle: String?
    @ViewBuilder var actions: Actions
    @Environment(\.ink) private var ink
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(VT.Font.largeTitle).tracking(-0.5).foregroundStyle(ink.primary)
                if let subtitle { Text(subtitle).font(VT.Font.body).foregroundStyle(ink.secondary) }
            }
            Spacer()
            HStack(spacing: 8) { actions }
        }
    }
}

// MARK: - Pages

private struct PageView: View {
    var page: HomePage
    var body: some View {
        switch page {
        case .prepare: PreparePage()
        case .sessions: SessionsPage()
        case .practice: PracticePage()
        case .scripts: ScriptsPage()
        case .settings: SettingsPage()
        }
    }
}

private struct PreparePage: View {
    @Environment(\.ink) private var ink
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Prepare", subtitle: "Paste what you have. Verse builds your answers before the call.") { EmptyView() }
            SectionHeader(text: "Up next")
            InsetGroup {
                meeting("Mara · Northwind Labs", "Today 14:30 · Comet · in 4 minutes", ready: true)
                RowDivider(inset: 54)
                meeting("Design review with Ingrid", "Tomorrow 10:00 · Zoom", ready: false)
            }
            SectionHeader(text: "New preparation")
            InsetGroup {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Conversation").font(VT.Font.body).foregroundStyle(ink.primary)
                    Text("Mara Castellan · 14 Oct\nHi Alex, thanks for the call last week. We'd like to go deeper on the internal tools: the shift planner and the reminder agent are the two we'd turn into a SaaS first. Could you walk us through how you'd scope a v1…")
                        .font(VT.Font.body).foregroundStyle(ink.secondary).lineSpacing(3).lineLimit(4)
                    Text("1,842 characters · stays on this Mac").font(VT.Font.caption).foregroundStyle(ink.tertiary)
                }
                .padding(14)
                RowDivider()
                ValueRow(label: "Job posting") {
                    Text("linkedin.com/jobs/view/0000000000").font(VT.Font.body).foregroundStyle(ink.secondary)
                    Image(systemName: "link").font(.system(size: 11)).foregroundStyle(ink.tertiary)
                }
                RowDivider()
                ValueRow(label: "Company website", value: "northwindlabs.com")
                RowDivider()
                ValueRow(label: "Note", value: "Ask who owns pricing and the SaaS roadmap")
            }
            HStack(spacing: 8) {
                Spacer()
                SecondaryButton(title: "Clear")
                PrimaryButton(title: "Prepare", shortcut: "⌘↩")
            }
            .padding(.top, 16)
        }
        .padding(.horizontal, 28).padding(.top, 22).frame(maxWidth: 760, alignment: .leading)
    }

    private func meeting(_ title: String, _ meta: String, ready: Bool) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "calendar").font(.system(size: 14, weight: .medium)).foregroundStyle(ink.secondary)
                .frame(width: 28, height: 28).background(ink.fill, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(VT.Font.bodyEmph).foregroundStyle(ink.primary)
                Text(meta).font(VT.Font.callout).foregroundStyle(ink.secondary)
            }
            Spacer()
            if ready {
                Label("Prepared", systemImage: "checkmark").font(VT.Font.callout).foregroundStyle(ink.secondary)
                SecondaryButton(title: "Open")
            } else {
                Text("Not prepared").font(VT.Font.callout).foregroundStyle(ink.tertiary)
                SecondaryButton(title: "Prepare")
            }
        }
        .padding(.horizontal, 14).frame(height: 56)
    }
}

private struct SessionsPage: View {
    @Environment(\.ink) private var ink
    private let sessions = [("Mara · Northwind Labs", "Today · 42 min"), ("Brightwave case review", "Tue 14 Oct · 35 min"),
                            ("Harbor Tech technical", "Mon 13 Oct · 58 min"), ("Practice · Brightwave", "Mon 13 Oct · 30 min"),
                            ("Harbor Tech first call", "Thu 9 Oct · 31 min"), ("Practice · Harbor Tech", "Wed 8 Oct · 15 min")]

    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Sessions").font(VT.Font.largeTitle).tracking(-0.5).foregroundStyle(ink.primary)
                    .padding(.leading, 10).padding(.bottom, 14)
                ForEach(sessions.indices, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(sessions[i].0).font(VT.Font.bodyEmph).foregroundStyle(ink.primary)
                        Text(sessions[i].1).font(VT.Font.callout).foregroundStyle(ink.secondary)
                    }
                    .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    .background(i == 0 ? ink.selection : .clear, in: RoundedRectangle(cornerRadius: VT.Radius.row, style: .continuous))
                }
            }
            .frame(width: 236).padding(.leading, 18).padding(.top, 22)

            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Mara · Northwind Labs").font(.system(size: 20, weight: .bold)).tracking(-0.3).foregroundStyle(ink.primary)
                        Text("Today 14:30 · 42 minutes · Comet · 11 answers shown").font(VT.Font.callout).foregroundStyle(ink.secondary)
                    }
                    Spacer()
                    SecondaryButton(title: "Transcript")
                    PrimaryButton(title: "Save to vault")
                }
                InsetGroup(plate: true) {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("Summary").font(VT.Font.title).foregroundStyle(ink.primary)
                        Text("Mara wants the shift planner and the reminder agent turned into one SaaS for regional dental clinics. She owns pricing; Jonas owns onboarding. Budget is €4–5k a month for a contractor, starting in November.")
                            .font(VT.Font.body).foregroundStyle(ink.primary).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
                        Text("Follow up").font(VT.Font.title).foregroundStyle(ink.primary).padding(.top, 4)
                        ForEach(["Send a one-page v1 scope by Friday", "Ask Jonas for three clinic logins to test with",
                                 "Price the reminder agent per location, not per seat"], id: \.self) { t in
                            HStack(spacing: 10) {
                                Circle().strokeBorder(ink.tertiary, lineWidth: 1.3).frame(width: 15, height: 15)
                                Text(t).font(VT.Font.body).foregroundStyle(ink.primary)
                            }
                        }
                        Text("Questions you got").font(VT.Font.title).foregroundStyle(ink.primary).padding(.top, 4)
                        ForEach([("How would you scope a v1?", "answered"), ("What breaks first at 500 locations?", "answered"),
                                 ("Would you work our hours?", "missed")], id: \.0) { q in
                            HStack {
                                Text(q.0).font(VT.Font.body).foregroundStyle(ink.primary)
                                Spacer()
                                Text(q.1).font(VT.Font.callout).foregroundStyle(q.1 == "missed" ? ink.primary : ink.secondary)
                            }
                        }
                    }
                    .padding(20)
                }
                .padding(.top, 18)
            }
            .padding(.leading, 20).padding(.trailing, 28).padding(.top, 26)
        }
    }
}

private struct PracticePage: View {
    @Environment(\.ink) private var ink
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Practice", subtitle: "A spoken mock interview, built from the posting.") { EmptyView() }
            SectionHeader(text: "Job posting")
            InsetGroup {
                ValueRow(label: "Link") {
                    Text("brightwave.com/careers/ai-engineer").font(VT.Font.body).foregroundStyle(ink.secondary)
                }
                RowDivider()
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("AI Engineer · Brightwave").font(VT.Font.bodyEmph).foregroundStyle(ink.primary)
                        Spacer()
                        Label("Confirmed", systemImage: "checkmark").font(VT.Font.callout).foregroundStyle(ink.secondary)
                    }
                    Text("Remote, Europe. You'll build the agents that answer e-commerce customers on WhatsApp and email, own evaluation, and ship weekly with a team of six…")
                        .font(VT.Font.body).foregroundStyle(ink.secondary).lineSpacing(3).lineLimit(2)
                }
                .padding(14)
            }
            SectionHeader(text: "Interview")
            InsetGroup {
                ValueRow(label: "Type") { Segmented(items: ["Screening", "Hiring manager", "Technical", "Mixed"], selected: 2) }
                RowDivider()
                ValueRow(label: "Length") { PopupValue(text: "30 min · 8 questions") }
                RowDivider()
                ValueRow(label: "Feedback") { Segmented(items: ["Coach after each answer", "Report at the end"], selected: 0) }
                RowDivider()
                ValueRow(label: "Interviewer voice") { PopupValue(text: "Apple · Zoe (Premium)") }
            }
            HStack(spacing: 8) {
                Text("Answer out loud. Your answer ends after 2 seconds of silence, or ⌥Space.")
                    .font(VT.Font.callout).foregroundStyle(ink.secondary)
                Spacer()
                PrimaryButton(title: "Start practice", shortcut: "⌘↩")
            }
            .padding(.top, 16)
        }
        .padding(.horizontal, 28).padding(.top, 22).frame(maxWidth: 760, alignment: .leading)
    }
}

private struct ScriptsPage: View {
    @Environment(\.ink) private var ink
    var body: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Scripts").font(VT.Font.largeTitle).tracking(-0.5).foregroundStyle(ink.primary)
                    .padding(.leading, 10).padding(.bottom, 14)
                ForEach([("Northwind Labs pitch", "212 words · 1:35"), ("Intro, 60 seconds", "148 words · 1:00"),
                         ("Lantern story", "306 words · 2:20"), ("Why Brightwave", "121 words · 0:55")], id: \.0) { s in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(s.0).font(VT.Font.bodyEmph).foregroundStyle(ink.primary)
                        Text(s.1).font(VT.Font.callout).foregroundStyle(ink.secondary).monospacedDigit()
                    }
                    .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                    .background(s.0 == "Northwind Labs pitch" ? ink.selection : .clear, in: RoundedRectangle(cornerRadius: VT.Radius.row, style: .continuous))
                }
            }
            .frame(width: 236).padding(.leading, 18).padding(.top, 22)

            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Northwind Labs pitch").font(.system(size: 20, weight: .bold)).tracking(-0.3).foregroundStyle(ink.primary)
                    Spacer()
                    SecondaryButton(title: "Write with Verse")
                    PrimaryButton(title: "Present", shortcut: "⌘P")
                }
                InsetGroup(plate: true) {
                    VStack(alignment: .leading, spacing: 12) {
                        para("Northwind Labs keeps clinic calendars full. I build the tools that turn that into a product your team can sell without me in the room.")
                        Text("[pause, look at Mara]").font(.system(size: 15)).foregroundStyle(ink.tertiary)
                        HStack(spacing: 10) {
                            Rectangle().fill(ink.separator).frame(height: 1)
                            Text("Page 2").font(VT.Font.caption).foregroundStyle(ink.tertiary)
                            Rectangle().fill(ink.separator).frame(height: 1)
                        }
                        .padding(.vertical, 4)
                        para("Two of your internal tools are already most of a SaaS: the shift planner and the reminder agent. A v1 is one login, one clinic group, twelve sites, and a weekly report the owner actually reads.")
                        para("I'd ship it in six weeks, behind your brand.")
                    }
                    .padding(22)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                Text("212 words · about 1:35 at your pace · saved").font(VT.Font.callout).foregroundStyle(ink.tertiary)
            }
            .padding(.leading, 20).padding(.trailing, 28).padding(.top, 26)
        }
    }

    private func para(_ s: String) -> some View {
        Text(s).font(.system(size: 15)).foregroundStyle(ink.primary).lineSpacing(5).fixedSize(horizontal: false, vertical: true)
    }
}

private struct SettingsPage: View {
    @Environment(\.ink) private var ink
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PageHeader(title: "Settings", subtitle: nil) { EmptyView() }
            SectionHeader(text: "Appearance")
            InsetGroup {
                ValueRow(label: "Island opacity") {
                    SliderMark(fraction: (0.62 - 0.35) / 0.65)
                    Text("62 %").font(VT.Font.body).foregroundStyle(ink.secondary).monospacedDigit().frame(width: 54, alignment: .trailing)
                }
                RowDivider()
                ValueRow(label: "Window opacity") {
                    SliderMark(fraction: 0.34)
                    Text("34 %").font(VT.Font.body).foregroundStyle(ink.secondary).monospacedDigit().frame(width: 54, alignment: .trailing)
                }
                RowDivider()
                ValueRow(label: "Text size") { Segmented(items: ["S", "M", "L", "XL"], selected: 1) }
                RowDivider()
                ValueRow(label: "Card width") {
                    SliderMark(fraction: 0.5)
                    Text("600 pt").font(VT.Font.body).foregroundStyle(ink.secondary).monospacedDigit().frame(width: 54, alignment: .trailing)
                }
            }
            Text("Reduce Transparency and Increase Contrast (System Settings › Accessibility › Display) override these.")
                .font(VT.Font.callout).foregroundStyle(ink.tertiary).padding(.leading, 4).padding(.top, 7)
            SectionHeader(text: "Meetings")
            InsetGroup {
                ValueRow(label: "Ask to start when a call app turns on the microphone") { ToggleMark(on: true) }
                RowDivider()
                ValueRow(label: "Follow my answer when I change the subject") { ToggleMark(on: true) }
                RowDivider()
                ValueRow(label: "Hide Verse from screen sharing") { ToggleMark(on: true) }
            }
            SectionHeader(text: "Claude")
            InsetGroup {
                ValueRow(label: "Anthropic API key") {
                    Text("Saved in Keychain").font(VT.Font.body).foregroundStyle(ink.secondary)
                    SecondaryButton(title: "Replace…")
                }
            }
        }
        .padding(.horizontal, 28).padding(.top, 22).frame(maxWidth: 760, alignment: .leading)
    }
}
