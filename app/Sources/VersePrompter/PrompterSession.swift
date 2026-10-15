import Foundation
import VerseSpeech

public enum PrompterNotice: Sendable, Equatable {
    /// The requested mode needed the mic or the recognizer and it did not start; the prompter runs in classic mode.
    case fellBackToClassic(reason: String)
}

/// What the UI draws. Page-local positions.
public struct PrompterState: Sendable, Equatable {
    public var pageIndex = 0
    public var pageCount = 1
    /// Fractional word index inside the page (`PromptPage.words`).
    public var wordPosition = 0.0
    public var wordCount = 0
    /// Characters of `PromptPage.text` that count as read.
    public var readOffset = 0
    public var isSpeaking = false
    /// Word tracking only: speech without a match for 8 s. The UI shows "lost: click a word".
    public var isLost = false
    public var isPaused = true
    /// The last page is fully read.
    public var isDone = false
    /// The mode in effect (can differ from `requestedMode` after a fallback).
    public var mode = PrompterMode.classic
    public var requestedMode = PrompterMode.classic
    public var wordsPerMinute = 150.0
    public var notice: PrompterNotice?
}

/// Owns the script, the active `ScrollDriver` and the input pumps; publishes `PrompterState` on `states`
/// (newest value wins, one consumer).
public actor PrompterSession {
    public static let speedRange: ClosedRange<Double> = 30...400
    public static let speedStep = 10.0

    public nonisolated let states: AsyncStream<PrompterState>
    private let continuation: AsyncStream<PrompterState>.Continuation

    private var pages: [PromptPage]
    private var pageIndex = 0
    private var driver: any ScrollDriver
    private var requestedMode: PrompterMode
    private var notice: PrompterNotice?
    private var wordsPerMinute: Double
    private var paused = true
    private var started = false
    private var lastPublished: PrompterState?

    private let transcriptSource: (any TranscriptSource)?
    private let levelSource: (any LevelSource)?
    private let clock: any PrompterClock
    private let lostAfter: TimeInterval
    private let tickInterval: TimeInterval
    private let autoTick: Bool
    private var transcriptPump: Task<Void, Never>?
    private var levelPump: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?

    /// `autoTick: false` leaves publishing to explicit `tick()` calls (tests with a manual clock).
    public init(script: PromptScript,
                mode: PrompterMode = .wordTracking,
                wordsPerMinute: Double = 150,
                transcript: (any TranscriptSource)? = nil,
                levels: (any LevelSource)? = nil,
                clock: any PrompterClock = SystemPrompterClock(),
                lostAfter: TimeInterval = 8,
                tickInterval: TimeInterval = 1.0 / 30,
                autoTick: Bool = true) {
        let pages = script.pages.isEmpty ? [PromptPage(text: "")] : script.pages
        self.pages = pages
        requestedMode = mode
        self.wordsPerMinute = Self.clampSpeed(wordsPerMinute)
        transcriptSource = transcript
        levelSource = levels
        self.clock = clock
        self.lostAfter = lostAfter
        self.tickInterval = tickInterval
        self.autoTick = autoTick
        (states, continuation) = AsyncStream.makeStream(of: PrompterState.self, bufferingPolicy: .bufferingNewest(1))
        // Placeholder until `start()` picks the real mode; never read before then.
        driver = ClassicDriver(wordCount: pages[0].wordCount, wordsPerMinute: self.wordsPerMinute, now: clock.now())
    }

    private static func clampSpeed(_ wpm: Double) -> Double { min(max(wpm, speedRange.lowerBound), speedRange.upperBound) }

    // MARK: reading state

    public var script: PromptScript { PromptScript(pages: pages) }
    public var currentPage: PromptPage { pages[pageIndex] }

    public var state: PrompterState { snapshot(at: clock.now()) }

    private func snapshot(at t: TimeInterval) -> PrompterState {
        let page = pages[pageIndex]
        let position = driver.position(at: t)
        let isLast = pageIndex == pages.count - 1
        var s = PrompterState()
        s.pageIndex = pageIndex
        s.pageCount = pages.count
        s.wordPosition = position
        s.wordCount = page.wordCount
        s.readOffset = page.characterOffset(forWordProgress: position)
        s.isSpeaking = driver.isSpeaking(at: t)
        s.isLost = driver.isLost(at: t)
        s.isPaused = paused
        s.isDone = isLast && page.wordCount > 0 && position >= Double(page.wordCount) - 0.001
        s.mode = driver.mode
        s.requestedMode = requestedMode
        s.wordsPerMinute = wordsPerMinute
        s.notice = notice
        return s
    }

    /// Computes the state at the clock's now and publishes it if it changed.
    public func tick() {
        let s = snapshot(at: clock.now())
        guard s != lastPublished else { return }
        lastPublished = s
        continuation.yield(s)
    }

    // MARK: lifecycle

    /// Starts reading: opens the inputs for the mode (falling back to classic if they fail) and begins ticking.
    public func start() async {
        guard !started else { resume(); return }
        started = true
        await activate(mode: requestedMode, startWord: driver.position(at: clock.now()))
        paused = false
        driver.setPaused(false, at: clock.now())
        startTicking()
        tick()
    }

    public func pause() {
        paused = true
        driver.setPaused(true, at: clock.now())
        tick()
    }

    public func resume() {
        guard started else { return }
        paused = false
        driver.setPaused(false, at: clock.now())
        tick()
    }

    public func stop() async {
        tickTask?.cancel()
        transcriptPump?.cancel()
        levelPump?.cancel()
        tickTask = nil; transcriptPump = nil; levelPump = nil
        await transcriptSource?.stop()
        await levelSource?.stop()
        paused = true
        started = false
        tick()
        continuation.finish()
    }

    private func startTicking() {
        guard autoTick, tickTask == nil else { return }
        let clock = self.clock, interval = tickInterval
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.tick()
                do { try await clock.sleep(until: clock.now() + interval) } catch { return }
            }
        }
    }

    // MARK: modes and drivers

    private func makeDriver(_ mode: PrompterMode, startWord: Double, carrying old: (any ScrollDriver)?) -> any ScrollDriver {
        let page = pages[pageIndex]
        let now = clock.now()
        switch mode {
        case .classic:
            return ClassicDriver(wordCount: page.wordCount, startWord: startWord, wordsPerMinute: wordsPerMinute, now: now)
        case .voicePaced:
            return VoicePacedDriver(wordCount: page.wordCount, startWord: startWord, wordsPerMinute: wordsPerMinute, now: now)
        case .wordTracking:
            return WordTrackingDriver(page: page, startWord: startWord, lostAfter: lostAfter, anchor: old?.openTranscript ?? "")
        }
    }

    /// Opens the inputs for `mode` (closing the old pumps) and installs a driver at `startWord`.
    private func activate(mode: PrompterMode, startWord: Double) async {
        transcriptPump?.cancel(); transcriptPump = nil
        levelPump?.cancel(); levelPump = nil
        notice = nil
        var effective = mode
        switch mode {
        case .classic:
            break
        case .voicePaced:
            do {
                guard let levelSource else { throw FallbackReason.noLevelSource }
                let stream = try await levelSource.samples()
                levelPump = Task { [weak self] in
                    for await level in stream { await self?.deliver(level: level) }
                }
            } catch {
                effective = .classic
                notice = .fellBackToClassic(reason: Self.describe(error))
            }
        case .wordTracking:
            do {
                guard let transcriptSource else { throw FallbackReason.noTranscriptSource }
                let stream = try await transcriptSource.events()
                transcriptPump = Task { [weak self] in
                    for await event in stream { await self?.deliver(event) }
                }
            } catch {
                effective = .classic
                notice = .fellBackToClassic(reason: Self.describe(error))
            }
        }
        let old = driver
        driver = makeDriver(effective, startWord: startWord, carrying: old)
        driver.setPaused(paused, at: clock.now())
    }

    private enum FallbackReason: Error, CustomStringConvertible {
        case noTranscriptSource, noLevelSource
        var description: String {
            switch self {
            case .noTranscriptSource: return "No speech source is available."
            case .noLevelSource: return "No microphone level source is available."
            }
        }
    }

    private static func describe(_ error: any Error) -> String {
        (error as? FallbackReason)?.description ?? String(describing: error)
    }

    /// Live mode switch; the reading position carries over.
    public func setMode(_ mode: PrompterMode) async {
        let position = driver.position(at: clock.now())
        requestedMode = mode
        await activate(mode: mode, startWord: position)
        tick()
    }

    private func deliver(_ event: TranscriptEvent) {
        driver.ingest(event, at: clock.now())
    }

    private func deliver(level: Double) {
        driver.ingest(level: level, at: clock.now())
    }

    // MARK: controls

    /// Click on a word: move the read position to the start of word `index` of the current page.
    public func jump(toWord index: Int) {
        let target = Double(max(0, min(index, pages[pageIndex].wordCount)))
        driver.jump(toWord: target, at: clock.now())
        tick()
    }

    public func nextPage() { goToPage(pageIndex + 1) }
    public func previousPage() { goToPage(pageIndex - 1) }

    public func goToPage(_ index: Int) {
        guard index >= 0, index < pages.count, index != pageIndex else { return }
        pageIndex = index
        installDriverKeepingMode(startWord: 0)
        tick()
    }

    private func installDriverKeepingMode(startWord: Double) {
        let old = driver
        driver = makeDriver(old.mode, startWord: startWord, carrying: old)
        driver.setPaused(paused, at: clock.now())
    }

    /// `steps` of 10 words per minute, up or down (speed ±). Applies to classic and voice-paced; word tracking
    /// keeps the value for a later fallback or mode switch.
    public func adjustSpeed(bySteps steps: Int) { setWordsPerMinute(wordsPerMinute + Double(steps) * Self.speedStep) }

    public func setWordsPerMinute(_ wpm: Double) {
        wordsPerMinute = Self.clampSpeed(wpm)
        driver.setWordsPerMinute(wordsPerMinute, at: clock.now())
        tick()
    }

    /// Meeting card: keep what was already read on the current page and replace only the unread tail with
    /// `newText` (Textream `updateText` semantics).
    public func replaceUnread(with newText: String) {
        let now = clock.now()
        let page = pages[pageIndex]
        let offset = page.characterOffset(forWordProgress: driver.position(at: now))
        let replaced = page.replacingUnread(from: offset, with: newText)
        pages[pageIndex] = replaced.page
        installDriverKeepingMode(startWord: replaced.page.wordProgress(forCharacterOffset: replaced.readOffset))
        tick()
    }

    /// Swap the whole script (editor round trip); back to page 0 unless `keepingPage`.
    public func replaceScript(_ script: PromptScript, keepingPage: Bool = false) {
        pages = script.pages.isEmpty ? [PromptPage(text: "")] : script.pages
        pageIndex = keepingPage ? min(pageIndex, pages.count - 1) : 0
        installDriverKeepingMode(startWord: 0)
        tick()
    }
}
