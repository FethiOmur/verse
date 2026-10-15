# Verse teleprompter mode: design

Status: draft for the owner's review (2026-10-15). Follows §10 of `2026-10-14-verse-meeting-assistant-v1-design.md`.
Background: `~/Workspace/Textream_Analiz/textream_architecture_and_rebuild.md` (Textream read 2026-10-14).

## 1. Goal and audience

Alex reads text in front of the camera and in meetings while keeping his eyes near the lens. Three uses, all
in scope (Alex, 2026-10-15):

1. **Camera recording** (Shorts/YouTube): read a prepared script.
2. **Meeting:** read Verse's suggested answer card; the card scrolls and marks what he has already said.
3. **Presentation / talk:** a long text split into pages (interview opener, demo talk).

English first; `lang` stays a parameter.

## 2. Decisions

| Topic | Decision | Source |
|---|---|---|
| Scroll | Three modes, picked in Settings: **word tracking** (default), **voice-paced** (moves at a set speed while he speaks, stops when he stops), **classic** (timer). | Alex |
| Surface | The existing hanging notch glass panel (`NotchPanelController`, Moonglade style) grows into the prompter. No floating window in this spec. | Alex |
| Script sources | **Verse writes it** (topic + target length, in his voice), **from a file** (.md, .txt, PowerPoint speaker notes), **the live meeting card**. | Alex |
| Editing | A small editor to correct a Verse-written or imported script before reading. Paste works there, but there is no separate "paste" source. | Assumed, Alex approved the summary |
| Screen share | The prompter panel is hidden from screen share by default (`sharingType = .none`), with a Settings toggle. It must be tested on-device against Meet in Comet, Zoom and Teams, because public reports say ScreenCaptureKit capture can ignore the flag on macOS 15+. | Assumed, approved |
| Recording | Verse does not record the camera. Alex records with his own tool. | Assumed, approved |
| Build | New module inside Verse, reusing Verse's mic capture and STT; port Textream's MIT matcher with its notice. | Approach A, approved |

### Rejected
- **Textream through its Director API:** it needs a LAN-exposed port, forces word tracking, and gives no control
  over design.
- **Forking Textream:** the files we would change (overlay, settings) are its largest and most churned. Plus the
  name and trademark.
- **A separate floating window:** not asked for now. The panel API should not rule it out later.

## 3. Units and interfaces

New Swift module `VersePrompter` (library target). It depends on `VerseSpeech` and `VerseAudio` only, and the UI lives in `VerseUI`.

- **`PromptScript`** (value type): `pages: [PromptPage]`, each with `words: [PromptWord]` (text, char range,
  `isCue` for `[bracketed]` notes that are shown in the cue colour and skipped by the matcher). Built by
  `ScriptParser.parse(_ text: String) -> PromptScript` (page break: a blank line followed by `---`, or a slide boundary from PPTX notes).
- **`PromptMatcher`** (port of Textream `SpeechTextAlignment` + `PromptMatcher`, MIT, notice in file headers and
  `THIRD_PARTY_NOTICES`): `mutating func advance(spoken: String) -> Int?` returns the new read offset (in chars)
  or nil. Two strategies: char-level and word-level. Fuzzy word equality. Forward-only skips of up to 5 words. A commit gate. Its
  iOS test suite is ported with it.
- **`ScrollDriver`** protocol: `func position(at t: TimeInterval) -> Double` (words read, fractional). There are three
  implementations:
  - `WordTrackingDriver` feeds volatile partials from the mic channel of a `ListenSession` into `PromptMatcher`.
  - `VoicePacedDriver` uses the RMS level from `ListenSession.levels` with Textream's VAD numbers (activation 0.012,
    immediate 0.04, 2 frames, 0.75 s hangover) and advances at `wordsPerMinute` while speaking.
  - `ClassicDriver` uses a timer at `wordsPerMinute`.
- **`PrompterSession`** (actor): owns script + driver + listen session; publishes `PrompterState` (page, read
  offset, isSpeaking, mode, done) for the UI. Controls: start, pause, jump to word (click), next/previous
  page, speed ±, switch mode live.
- **UI (`VerseUI/Prompter*.swift`)**: the prompter view inside the notch panel. Read text is dimmed, the current line is held at a fixed
  eye line just under the camera, and upcoming lines are in full colour. There are no entrance animations (the same rule as the cards). Settings
  section: mode, speed, font size, mirror, hide from share.
- **Sources**
  - *File:* `.md` and `.txt` are read directly. `.pptx` speaker notes are read through a port of Textream's
    `PresentationNotesExtractor` (MIT). Keynote is out of scope.
  - *Verse writes:* a new brain command `script` (JSON line: topic, target seconds, use: recording|talk).
    It runs on Sonnet over the existing transport, in the owner's voice from the V1 profile
    (`~/Library/Application Support/Verse/profile/voice.md`). It returns the text; the app opens it in the editor.
  - *Meeting card:* when the teleprompter is on during a meeting, the SAY text of the current card becomes the
    script. A new card replaces the unread tail and keeps the read prefix, as Textream's `updateText` does.
- **Storage:** scripts are saved as `.md` in `~/Library/Application Support/Verse/scripts/`. Nothing is written to
  the repo.

## 4. Error handling

- No mic permission, or STT failing to start: fall back to classic mode and show it on the panel.
- Matcher lost (no commit for 8 s while speaking): keep the position, show a small "lost: click a word" hint.
  Voice-paced mode keeps working.
- In a meeting, the prompter listens only to the mic channel. Remote audio never moves the script.
- Brain `script` failure: show the error in the editor. The local Gemma fallback (G1) applies the same way as for answers.

## 5. Phases (each one is its own work package)

1. **T1 surface:** `VersePrompter` skeleton, `ScriptParser`, panel view, classic + voice-paced drivers, file import
   (.md/.txt), editor, Settings, hide-from-share flag.
2. **T2 word tracking:** matcher port + tests, `WordTrackingDriver` on the mic channel, click-to-jump, lost hint.
3. **T3 Verse writes:** brain `script` command with the voice profile, editor round-trip, `.pptx` notes import.
4. **T4 meeting card:** live card → script with read-prefix preservation. Hide-from-share on-device test in Comet
   Meet, Zoom and Teams; record the result in `docs/`.

T1 can start once S4 is merged (it shares the notch panel and Settings). T3 needs V1 merged.

## 6. Tests

- Parser: page breaks, cues, empty lines, a CJK-free English fixture.
- Matcher: the ported Textream suite, plus Verse cases: a skipped word, a re-read word, filler words ("um") between
  script words, a number read as words ("42" vs "forty-two").
- Drivers: voice-paced stops within the 0.75 s hangover after silence; classic advances at the set speed; word
  tracking advances only on mic events (remote events ignored).
- Meeting card: a new card keeps the read prefix and replaces only the unread tail.
- Manual, once per phase: read a 60-second script aloud and report how often it lost the place.

## 7. Done means

All four phases merged. Alex can (a) have Verse write a 60-second script and read it with word tracking, (b) read
a .pptx's notes page by page, and (c) in a test meeting read a card that tracks his voice, with the panel invisible
in the shared screen (or a written note of which apps still capture it).

## 8. Out of scope

A floating window, Keynote import, a remote director or phone companion, recording video, Italian/Turkish tuning,
and iOS.
