import AppKit
import ScreenCaptureKit
import SwiftUI

/// Renders the overlay states to PNG for review (`Verse --render-screens DIR`).
///
/// Liquid Glass is drawn by the window server, so `ImageRenderer` can't show it. Each shot is a borderless window placed
/// almost entirely below the bottom edge of the screen and behind other windows (desktop level), holding a background (a white page or a busy dark video
/// frame), a black stand-in for the notch and the real `OverlayView`. ScreenCaptureKit captures only that window
/// (`SCShareableContent.currentProcess`: this process's own windows, no Screen Recording permission), then the window
/// is closed at once. Nothing stays on screen.
@MainActor
public enum ScreenRenderer {
    public enum Backdrop: String, CaseIterable { case white, dark }

    public struct Shot {
        public var name: String
        public var state: OverlayState
        public var width: Double = 560
        /// T-UI: a teleprompter shown in the panel (see `PrompterModel.presentForPreview`).
        public var prompter: PrompterModel?
        public init(name: String, state: OverlayState, width: Double = 560, prompter: PrompterModel? = nil) {
            self.name = name
            self.state = state
            self.width = width
            self.prompter = prompter
        }
    }

    static let canvas = CGSize(width: 1180, height: 600)

    public static func sampleShots() -> [Shot] {
        var idle = OverlayState()
        idle.running = true
        idle.activity = .listening

        var marco = idle
        marco.addresseeTag = "for Marco"
        marco.tagDimmed = true

        var q = idle
        q.addresseeTag = "for you"
        var card = OverlayCard(turnID: "r3", question: "Can you walk me through how Lantern handled bad invoices?")
        card.say = "In Lantern, bad invoices never blocked the pipeline — they went to a review queue."
        card.sayTier = "S"
        card.bullets = ["Schema-validated extraction with one retry on a failed field",
                        "Low-confidence fields went to an operator, not straight to the ERP",
                        "Manual entry fell from 11 minutes to 2 per invoice"]
        card.chips = [OverlayChip(text: "38,000 invoices a month", source: "prep note", kind: "number"),
                      OverlayChip(text: "Lantern", source: "glossary", kind: "term")]
        q.card = card

        var d = q
        d.card?.deepPoints = ["For credit data the decision stays in code; the model only extracts (prep)",
                              "Every retry is logged with the field and the reason, so the queue can be audited (f004)"]

        var corrected = q
        corrected.card?.say = "Lantern didn't reject invoices; it flagged them and kept the rest of the batch moving."
        corrected.card?.sayTier = "D"
        corrected.card?.sayCorrected = true
        corrected.card?.deepPoints = ["Flagged fields carried the extractor's confidence score into the review UI (prep:L14)"]

        // Follow my answer: the original card, the follow card with its mark, and the follow card with one point said.
        var followOriginal = idle
        followOriginal.addresseeTag = "for you"
        var fCard = OverlayCard(turnID: "r5", question: "What was the hardest project you worked on?")
        fCard.say = "The hardest was Lantern: bad invoices had to be flagged without blocking the batch."
        fCard.sayTier = "F"
        fCard.bullets = ["Schema-validated extraction with one retry on a failed field",
                         "Low-confidence fields went to an operator, not straight to the ERP",
                         "Manual entry fell from 11 minutes to 2 per invoice"]
        fCard.chips = [OverlayChip(text: "38,000 invoices a month", source: "prep note", kind: "number")]
        followOriginal.card = fCard
        var followCard = followOriginal
        followCard.card?.say = "And on the route optimiser I built the first pilot on my own, in six weeks."
        followCard.card?.sayTier = "C"
        followCard.card?.bullets = ["12 depots in the pilot, ETA drift down by a third",
                                    "I wrote the re-plan loop that runs every 90 seconds",
                                    "Dispatchers kept an override on every route"]
        followCard.card?.following = true
        var followCovered = followCard
        followCovered.card?.struck = [0]

        var credit = idle
        credit.status = .creditExhausted("Max API credit used up until 1 December. Verse keeps transcribing locally.")

        var topics = idle
        topics.topics = [OverlayChip(text: "ETA drift", source: "glossary", kind: "topic"),
                         OverlayChip(text: "Compass re-plans every 90 s", source: "prep note", kind: "topic")]

        var perm = idle
        perm.activity = .offline
        perm.status = .permission("audioCapture")

        var offline = q
        offline.status = .offline
        offline.activity = .offline
        offline.card = nil

        var starting = OverlayState()
        starting.running = true
        starting.activity = .warming
        starting.startup = StartupPanel(phase: .starting(step: "Starting the brain and loading models"), session: "mara-northwindlabs", app: "Comet")
        var ready = idle
        ready.startup = StartupPanel(phase: .ready, session: "mara-northwindlabs", app: "Comet")
        var listening = idle
        listening.startup = StartupPanel(phase: .listening, session: "mara-northwindlabs", app: "Comet")
        var failed = OverlayState()
        failed.status = .error("The session ended: brain did not become ready (timeout); stopping")

        let reading = Self.prompterSample(idle)

        // W2: the notch questions before and after a meeting (nothing is running).
        var detected = OverlayState()
        detected.meetingPrompt = .detected(appName: "Comet", eventTitle: "Mara · Northwind Labs", plan: .prepared("mara-northwindlabs"))
        var detectedNoEvent = OverlayState()
        detectedNoEvent.meetingPrompt = .detected(appName: "Comet", eventTitle: nil, plan: .selected("mara-northwindlabs"))
        var detectedInvite = OverlayState()
        detectedInvite.meetingPrompt = .detected(appName: "Zoom", eventTitle: "Design review with Ingrid", plan: .fromInvite)
        var upcoming = OverlayState()
        upcoming.meetingPrompt = .upcoming(eventTitle: "Mara · Northwind Labs", minutes: 4, plan: .prepared("mara-northwindlabs"))
        var saveSummary = OverlayState()
        saveSummary.meetingPrompt = .saveSummary(session: "mara-northwindlabs", folder: "📥 000-Inbox/Verse")
        var listeningHeard = idle
        listeningHeard.startup = StartupPanel(phase: .listening, session: "mara-northwindlabs", app: "Comet", transcribing: true)

        return [
            Shot(name: "prompter-reading", state: idle, prompter: reading.reading),
            Shot(name: "prompter-lost", state: idle, prompter: reading.lost),
            Shot(name: "prompter-fallback", state: idle, prompter: reading.fallback),
            Shot(name: "starting", state: starting),
            Shot(name: "ready", state: ready),
            Shot(name: "listening", state: listening),
            Shot(name: "error", state: failed),
            Shot(name: "meeting-detected", state: detected),
            Shot(name: "meeting-detected-no-event", state: detectedNoEvent),
            Shot(name: "meeting-detected-invite", state: detectedInvite),
            Shot(name: "meeting-upcoming", state: upcoming),
            Shot(name: "summary-save", state: saveSummary),
            Shot(name: "listening-transcribing", state: listeningHeard),
            Shot(name: "card-persistent", state: q),
            Shot(name: "capsule-idle", state: idle),
            Shot(name: "capsule-for-marco", state: marco),
            Shot(name: "card-question", state: q),
            Shot(name: "card-follow-original", state: followOriginal),
            Shot(name: "card-follow", state: followCard),
            Shot(name: "card-follow-covered", state: followCovered),
            Shot(name: "card-sonnet-points", state: d),
            Shot(name: "card-opener-corrected", state: corrected),
            Shot(name: "credit-exhausted", state: credit),
            Shot(name: "topic-chips", state: topics),
            Shot(name: "permission-needed", state: perm),
            Shot(name: "capsule-offline", state: offline),
            Shot(name: "card-min-width", state: d, width: AppSettings.cardWidthRange.lowerBound),
            Shot(name: "card-max-width", state: d, width: AppSettings.cardWidthRange.upperBound),
        ]
    }

    /// Shows the named sample states one after the other in the real notch panel (`--preview-overlay`), then closes
    /// it. The panel is the same one a session uses, so this checks the real placement against the notch.
    public static func preview(names: [String], seconds: Double, settings: AppSettings) async {
        let shots = sampleShots()
        let model = OverlayModel()
        // A state before the panel exists: the panel hides itself on an idle state, and its subscription delivers
        // the first value a run-loop turn later, so an empty start would hide the first preview right after show().
        if let first = shots.first(where: { names.contains($0.name) }) { model.show(first.state) }
        let panel = NotchPanelController(model: model, settings: settings, onOpenSettings: { _ in })
        defer { panel.close() }
        for name in names {
            guard let shot = shots.first(where: { $0.name == name }) else {
                FileHandle.standardError.write(Data("preview: no sample state \(name)\n".utf8))
                continue
            }
            model.show(shot.state)
            panel.show()
            print("preview: \(name) window \(panel.windowNumber)")
            try? await Task.sleep(for: .seconds(seconds))
        }
    }

    /// Renders every shot over both backdrops into `dir`. Returns the written paths.
    public static func renderAll(to dir: URL, shots: [Shot] = sampleShots(), scales: [TextScale] = [.medium]) async throws -> [URL] {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var out: [URL] = []
        let suite = "dev.fethiverse.verse.render"
        defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
        for shot in shots {
            for b in Backdrop.allCases {
                for sc in scales {
                    let d = UserDefaults(suiteName: suite)!
                    d.removePersistentDomain(forName: suite)
                    let settings = AppSettings(defaults: d)
                    settings.cardWidth = shot.width
                    settings.textScale = sc
                    let suffix = scales.count > 1 ? "-\(sc.rawValue)" : ""
                    let url = dir.appendingPathComponent("\(shot.name)-\(b.rawValue)\(suffix).png")
                    try await render(shot.state, settings: settings, backdrop: b, prompter: shot.prompter, to: url)
                    out.append(url)
                }
            }
        }
        return out
    }

    public static func render(_ state: OverlayState, settings: AppSettings, backdrop: Backdrop, prompter: PrompterModel? = nil,
                              to url: URL) async throws {
        let model = OverlayModel()
        model.show(state)
        let metrics = NotchMetrics.macBookPro
        let scene = ZStack(alignment: .top) {
            BackdropView(kind: backdrop)
            // The hardware notch stand-in.
            UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10, style: .continuous).fill(Color.black)
                .frame(width: metrics.notchWidth, height: metrics.notchHeight)
            OverlayView(model: model, settings: settings, prompter: prompter ?? PrompterModel(), metrics: metrics)
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .top)
        .clipped()

        let window = NSWindow(contentRect: NSRect(origin: .zero, size: canvas), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)   // behind every app window
        window.collectionBehavior = [.ignoresCycle, .transient]
        window.hasShadow = false
        window.contentView = NSHostingView(rootView: scene)
        // All but a 2-point strip below the bottom edge of the main screen: the window stays capturable (a window fully
        // off screen is not) but practically nothing of it shows on the display, and only for half a second.
        if let s = NSScreen.main { window.setFrameOrigin(NSPoint(x: s.frame.midX - canvas.width / 2, y: s.frame.minY - canvas.height + 2)) }
        window.orderBack(nil)
        defer { window.orderOut(nil); window.close() }
        try await Task.sleep(for: .milliseconds(450))   // let the glass settle

        let content = try await SCShareableContent.currentProcess
        guard let w = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else {
            throw NSError(domain: "ScreenRenderer", code: 1, userInfo: [NSLocalizedDescriptionKey: "window not capturable"])
        }
        let filter = SCContentFilter(desktopIndependentWindow: w)
        let cfg = SCStreamConfiguration()
        let px = filter.pointPixelScale
        cfg.width = Int(canvas.width * CGFloat(px))
        cfg.height = Int(canvas.height * CGFloat(px))
        cfg.showsCursor = false
        cfg.ignoreShadowsSingleWindow = true
        // The capture service fails now and then on a loaded machine (SCStreamError -3811); a retry succeeds.
        var image: CGImage?
        var lastError: Error?
        for attempt in 0..<5 where image == nil {
            do { image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg) } catch {
                lastError = error
                try await Task.sleep(for: .milliseconds(250 * (attempt + 1)))
            }
        }
        guard let image else { throw lastError ?? NSError(domain: "ScreenRenderer", code: 3) }
        let rep = NSBitmapImageRep(cgImage: image)
        guard let png = rep.representation(using: .png, properties: [:]) else { throw NSError(domain: "ScreenRenderer", code: 2) }
        try png.write(to: url)
    }
}

/// Test backgrounds: a bright document page and a busy, dark video-call frame (drawn, no external images).
struct BackdropView: View {
    var kind: ScreenRenderer.Backdrop

    var body: some View {
        switch kind {
        case .white: WhitePage()
        case .dark: DarkCallFrame()
        }
    }
}

private struct WhitePage: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white
            VStack(alignment: .leading, spacing: 9) {
                Spacer().frame(height: 46)
                Text("Q3 delivery review").font(.system(size: 30, weight: .bold)).foregroundStyle(.black)
                Text("Halden Logistics · Platform team").font(.system(size: 14)).foregroundStyle(.gray)
                ForEach(0..<16, id: \.self) { i in
                    Text(String(repeating: "Route planning latency and ETA drift across the Milan depots. ", count: 3))
                        .font(.system(size: 15)).foregroundStyle(.black.opacity(i % 5 == 0 ? 0.95 : 0.8))
                        .lineLimit(1)
                }
            }
            .padding(.horizontal, 60)
        }
    }
}

private struct DarkCallFrame: View {
    var body: some View {
        ZStack {
            Color(red: 0.07, green: 0.08, blue: 0.10)
            HStack(spacing: 8) {
                tile(bg: [Color(red: 0.55, green: 0.42, blue: 0.30), Color(red: 0.18, green: 0.14, blue: 0.12)], shirt: Color(red: 0.12, green: 0.30, blue: 0.62), skin: Color(red: 0.86, green: 0.67, blue: 0.53), name: "Ingrid Solberg")
                tile(bg: [Color(red: 0.95, green: 0.93, blue: 0.88), Color(red: 0.32, green: 0.35, blue: 0.40)], shirt: Color(red: 0.75, green: 0.22, blue: 0.18), skin: Color(red: 0.62, green: 0.44, blue: 0.32), name: "Tomas Weir")
            }
            .padding(8)
        }
    }

    private func tile(bg: [Color], shirt: Color, skin: Color, name: String) -> some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: bg, startPoint: .topLeading, endPoint: .bottomTrailing)
            // a bright window and shelves behind the person
            Rectangle().fill(Color.white.opacity(0.85)).frame(width: 150, height: 210).offset(x: 330, y: -250).blur(radius: 6)
            ForEach(0..<5, id: \.self) { i in
                Rectangle().fill([Color.orange, .yellow, .green, .pink, .cyan][i].opacity(0.75))
                    .frame(width: 22, height: 70 + CGFloat(i * 9)).offset(x: 40 + CGFloat(i) * 26, y: -330 + CGFloat(i * 4))
            }
            VStack(spacing: -14) {
                Circle().fill(skin).frame(width: 150, height: 170)
                RoundedRectangle(cornerRadius: 90).fill(shirt).frame(width: 330, height: 230)
            }
            .offset(x: 120, y: 60)
            Text(name).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
                .padding(12)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
