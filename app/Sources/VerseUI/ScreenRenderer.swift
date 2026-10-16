import AppKit
import ScreenCaptureKit
import SwiftUI
import VersePrompter

/// Renders the overlay states to PNG for review (`Verse --render-screens DIR`).
///
/// Liquid Glass is drawn by the window server, so `ImageRenderer` can't show it. Each shot is a borderless window placed
/// almost entirely below the bottom edge of the screen and behind other windows (desktop level), holding the same scene
/// the approved mockups use (wallpaper, menu bar, a document page or a video call, 1100 x 440 pt), a black stand-in for
/// the notch and the real `OverlayView`. ScreenCaptureKit captures only that window
/// (`SCShareableContent.currentProcess`: this process's own windows, no Screen Recording permission), then the window
/// is closed at once. Nothing stays on screen.
@MainActor
public enum ScreenRenderer {
    public enum Backdrop: String, CaseIterable { case white, dark }

    public struct Shot {
        public var name: String
        public var state: OverlayState
        public var width: Double = 600
        /// T-UI: a teleprompter shown in the panel (see `PrompterModel.presentForPreview`).
        public var prompter: PrompterModel?
        /// Island opacity (spec 2.4); nil: the default.
        var islandOpacity: Double?
        /// Reduce Transparency / Increase Contrast / Reduce Motion, forced (the renderer cannot flip the system's).
        var a11y: IslandA11y?
        /// The practice states as the bare capsule (spec 3.2, state 6).
        var practiceCapsule = false
        /// The pointer is over the island (the control rows show). Renders show the at-rest state; the hover ones are named `-hover`.
        var hover = false
        /// Whole words of the card's SAY line already said (the prompter-style card, mid-reading).
        var spokenWords = 0
        public init(name: String, state: OverlayState, width: Double = 600, prompter: PrompterModel? = nil) {
            self.name = name
            self.state = state
            self.width = width
            self.prompter = prompter
        }
    }

    /// The mockup scene's size (spec 7): wallpaper, menu bar, the app under the island and the notch.
    static let canvas = CGSize(width: 1100, height: 440)

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

        // More deep points than the card has room for: the oldest drop until it fits under 420 pt.
        var overflow = q
        overflow.card?.deepPoints = ["For credit data the decision stays in code; the model only extracts (prep)",
                                     "Every retry is logged with the field and the reason, so the queue can be audited (f004)",
                                     "Operators saw the extractor's confidence next to each flagged field (prep:L14)",
                                     "The review queue was cleared twice a day by one person, 40 invoices at a time (vault)"]

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

        // The spec 3.2 states, with the content of the approved mockups (design/mockups Island.swift) so each render can
        // be compared with `island-*` there.
        let question = "Can you walk me through how Lantern handled bad invoices?"
        var i0 = OverlayState()
        i0.meetingPrompt = .detected(appName: "Comet", eventTitle: "Mara · Northwind Labs", plan: .prepared("mara-northwindlabs"), questionCount: 14)
        let i1 = idle
        var i2 = idle
        i2.remoteSpeaking = true
        i2.remoteBars = [0.45, 0.9, 0.6]
        i2.addresseeTag = "Ingrid"
        i2.tagDimmed = true
        var i3 = idle
        i3.addresseeTag = "for you"
        i3.remoteSpeaking = true
        i3.remoteBars = [0.7, 1, 0.5]
        i3.card = OverlayCard(turnID: "r3", question: question)
        var i4 = q
        i4.card?.chips = [OverlayChip(text: "38,000 invoices / month", source: "prep note", kind: "number"),
                          OverlayChip(text: "Lantern", source: "glossary", kind: "term")]
        i4.card?.bullets = ["Schema-validated extraction, one retry on a failed field",
                            "Low-confidence fields went to an operator, not the ERP",
                            "Manual entry fell from 11 minutes to 2 per invoice"]
        var i4m = i4
        i4m.card?.struck = [0]
        var i5 = followCovered
        i5.meBars = [0.3, 0.55, 0.4]
        i5.card?.chips = []
        i5.card?.bullets = ["12 depots in the pilot, ETA drift down by a third",
                            "I wrote the re-plan loop that runs every 90 seconds",
                            "Dispatchers kept an override on every route"]
        var sim6 = SimOverlay(startedAt: Date().addingTimeInterval(-252), voice: "text", showCaption: false)
        sim6.qIndex = 3
        sim6.qTotal = 8
        sim6.listening = true
        var i6 = idle
        i6.sim = sim6
        var sim6b = sim6
        sim6b.listening = false
        sim6b.coach = ["- Good structure. Lead with the result: “manual entry fell from 11 minutes to 2” before the how."]
        var i6b = idle
        i6b.sim = sim6b
        var i8 = idle
        i8.status = .creditExhausted("Max API credit is used up until 1 December. Verse keeps transcribing on this Mac; answers pause.")
        let page7 = PrompterModel(settings: PrompterSettings(defaults: .init(suiteName: "dev.fethiverse.verse.render")!))
        page7.presentForPreview(page: PromptPage(text: "Northwind Labs keeps shops on the first screen. I build the tools that turn that into a product your team can sell without me in the room."),
                                state: { var st = PrompterState(); st.pageCount = 5; st.pageIndex = 1; st.wordCount = 28; st.wordPosition = 14.2
                                    st.isPaused = false; st.isSpeaking = true; st.mode = .voicePaced; st.requestedMode = .voicePaced; return st }())
        func shot(_ name: String, _ st: OverlayState, prompter: PrompterModel? = nil, _ tweak: (inout Shot) -> Void = { _ in }) -> Shot {
            var sh = Shot(name: name, state: st, prompter: prompter)
            tweak(&sh)
            return sh
        }
        let islandShots: [Shot] = [
            shot("island-0-meeting-detected", i0),
            shot("island-1-idle", i1),
            shot("island-2-listening", i2),
            shot("island-3-hearing-question", i3),
            shot("island-4-answer-card", i4),
            shot("island-4-answer-card-mid-reading", i4m) { $0.spokenWords = 6 },
            shot("island-5-following-you", i5) { $0.spokenWords = 5 },
            shot("island-6-practice-capsule", i6) { $0.practiceCapsule = true },
            shot("island-6b-practice-coach-note", i6b),
            shot("island-7-teleprompter", idle, prompter: page7),
            shot("island-8-status-credit", i8),
            shot("island-6b-practice-coach-note-hover", i6b) { $0.hover = true },
            shot("island-7-teleprompter-hover", idle, prompter: page7) { $0.hover = true },
            shot("island-a1-answer-veil-35", i4) { $0.islandOpacity = 0.35 },
            shot("island-a2-answer-reduce-transparency", i4) { $0.a11y = IslandA11y(reduceTransparency: true) },
            shot("island-a3-answer-increase-contrast", i4) { $0.a11y = IslandA11y(increaseContrast: true) },
            shot("island-a4-answer-reduce-motion", i4) { $0.a11y = IslandA11y(reduceMotion: true) },
        ]

        return islandShots + [
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
            Shot(name: "card-deep-overflow", state: overflow, width: AppSettings.cardWidthRange.lowerBound),
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
        // VERSE_RENDER_FILTER=island-4,island-7 keeps only shots whose name starts with one of those.
        let only = (ProcessInfo.processInfo.environment["VERSE_RENDER_FILTER"] ?? "").split(separator: ",").map(String.init)
        for shot in shots where only.isEmpty || only.contains(where: { shot.name.hasPrefix($0) }) {
            for b in Backdrop.allCases {
                for sc in scales {
                    let d = UserDefaults(suiteName: suite)!
                    d.removePersistentDomain(forName: suite)
                    let settings = AppSettings(defaults: d)
                    settings.cardWidth = shot.width
                    settings.textScale = sc
                    if let o = shot.islandOpacity { settings.islandOpacity = o }
                    let suffix = scales.count > 1 ? "-\(sc.rawValue)" : ""
                    let url = dir.appendingPathComponent("\(shot.name)-\(b.rawValue)\(suffix).png")
                    try await render(shot.state, settings: settings, backdrop: b, prompter: shot.prompter, a11y: shot.a11y,
                                     practiceCapsule: shot.practiceCapsule, hover: shot.hover, spokenWords: shot.spokenWords, to: url)
                    out.append(url)
                }
            }
        }
        return out
    }

    static func render(_ state: OverlayState, settings: AppSettings, backdrop: Backdrop, prompter: PrompterModel? = nil,
                              a11y: IslandA11y? = nil, practiceCapsule: Bool = false, hover: Bool = false, spokenWords: Int = 0,
                              to url: URL) async throws {
        let model = OverlayModel()
        model.show(state)
        let prompter = prompter ?? PrompterModel()
        if spokenWords > 0, let say = state.card?.say { prompter.cardReading.presentForPreview(say: say, spokenWords: spokenWords) }
        let metrics = NotchMetrics.macBookPro
        let wallpaper: MockWallpaper = backdrop == .white ? .light : .dark
        let scene = ZStack(alignment: .top) {
            MockWallpaperView(kind: wallpaper)
            VStack(spacing: 0) {
                MockMenuBar(kind: wallpaper)
                MockAppUnderIsland(kind: wallpaper).padding(.horizontal, 36).padding(.top, 10)
            }
            // The hardware notch stand-in.
            UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10, style: .continuous).fill(Color.black)
                .frame(width: metrics.notchWidth, height: metrics.notchHeight)
            OverlayView(model: model, settings: settings, prompter: prompter, metrics: metrics,
                        forcePracticeCapsule: practiceCapsule)
                .environment(\.islandA11yOverride, a11y ?? IslandA11y())
                .environment(\.islandHoverOverride, hover)
        }
        .frame(width: canvas.width, height: canvas.height, alignment: .top)
        .clipped()

        let window = NSWindow(contentRect: NSRect(origin: .zero, size: canvas), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)) + 1)   // behind every app window
        window.collectionBehavior = [.ignoresCycle, .transient]
        window.hasShadow = false
        window.appearance = NSAppearance(named: backdrop == .white ? .aqua : .darkAqua)
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
