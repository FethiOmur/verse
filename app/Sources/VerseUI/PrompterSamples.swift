import VerseAudio
import VersePrompter

extension ScreenRenderer {
    /// Sample prompter states for the screenshot renderer: reading, lost, and fallen back to classic.
    @MainActor
    static func prompterSample(_ idle: OverlayState) -> (reading: PrompterModel, lost: PrompterModel, fallback: PrompterModel) {
        let page = PromptPage(text: "Interviews in a second language are hard. Not because I don't know my work, but because my mind goes blank at the wrong moment. [pause] I got tired of that, so I built Verse. It is a Mac app that listens to my call and shows me the next sentence, right under the camera.")
        func model(_ configure: (inout PrompterState) -> Void) -> PrompterModel {
            let m = PrompterModel(settings: PrompterSettings(defaults: .init(suiteName: "\(AppIdentity.bundleID).render")!))
            var s = PrompterState()
            s.pageCount = 3
            s.wordCount = page.wordCount
            s.wordPosition = 17.3
            s.isPaused = false
            s.isSpeaking = true
            s.mode = .wordTracking
            s.requestedMode = .wordTracking
            configure(&s)
            m.presentForPreview(page: page, state: s)
            return m
        }
        return (model { _ in },
                model { $0.isLost = true; $0.isSpeaking = false },
                model { $0.mode = .classic; $0.notice = .fellBackToClassic(reason: "Microphone access is needed for word tracking."); $0.isSpeaking = false })
    }
}
