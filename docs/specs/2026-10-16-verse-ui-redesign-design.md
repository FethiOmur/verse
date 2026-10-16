# Verse: UI redesign (island + home window)

Status: design draft 2026-10-16, **waiting for the owner's visual approval of the mockups**. The look is his call; once he
approves it, his rule "after a spec, build" covers the implementation.

Research: `~/Workspace/Verse_Design_Research/research.md`. Mockup source: `design/mockups/` (this repo).
Renders: `~/Workspace/Verse_Design_Research/mockups-2026-10-16/` (40 PNGs, 2x) and two contact sheets in
`docs/specs/assets/2026-10-16-ui-redesign/`.

## 1. Goal

Two surfaces replace today's scattered UI:

1. **The island.** During a meeting Verse is one object hanging from the notch. It changes shape between states:
   idle → listening → hearing the question → answer card → "following you" card → practice capsule → teleprompter,
   plus the meeting prompt and status. One silhouette at every size, so it reads as one thing that grows, never as
   windows popping up.
2. **One home window** with a sidebar (Prepare, Sessions, Practice, Scripts, Settings) on a full Liquid Glass
   background. It replaces the sim setup, prep-from-conversation, script editor, report and settings windows.

Direction in one line: **a calm, native macOS 26 instrument**: system type, one mint accent, glass only where the
platform puts it, and the line Alex reads is the largest thing on screen.

Left out on purpose: purple/blue "AI" gradient blobs, neon glow, heavy drop shadows, opaque cards, chart-heavy
dashboards, emoji, springy motion on everything, entrance animations on card text, pill-shaped "AI" buttons,
monospace eyebrow labels.

## 2. Tokens

The values live in `design/mockups/Sources/VerseMockups/Tokens.swift`; implementation copies them into
`VerseUI/DesignTokens.swift` (one file, used by both surfaces).

### 2.1 Colour

| Token | Value | Use |
|---|---|---|
| `mint` | `#6BE6B3` | The only accent: live dot, SAY bar, primary action fill, system control "on" (toggles, slider fill). |
| `mintDeep` | `#0D8057` | Mint for text/glyphs on light surfaces (4.6:1 on white). |
| `onMint` | `#052B1C` | Label on a mint fill. |
| `amber` | `#FFB547` | Status only: credit, permission. |
| `coral` | `#FF6B5E` | Status only: errors. |
| Island text | white 100 / 80 / 56 / 36 % | SAY / points / meta / struck or hint. |
| Island fills | white 11 % (chips, secondary), 17 % (secondary button) | |
| Window text | light: black 86 / 54 / 34 %; dark: white 92 / 58 / 36 % | primary / secondary / tertiary. |
| Window background | light `#F5F5F7`, dark `#1D1D20` | The veil colour on the window glass (2.4). |
| Inset group fill | light white 52 %, dark white 5.5 % | Grouped rows on the window glass. Not glass. |
| Reading plate | light white 72 %, dark black 22 % | Long text (report, script editor). Not glass. |
| Selection | light black 7.5 %, dark white 12 % | Sidebar and list selection. Neutral, never mint. |
| Separator | light black 8 %, dark white 8 % | Row dividers. |

### 2.2 Type (SF Pro, system font; sizes at text size M)

| Role | Size / weight | Tracking | Notes |
|---|---|---|---|
| SAY line | 22 semibold | −0.35 | Line spacing +2. Text size S/M/L/XL = 19/22/25/28. |
| Points | 15 regular | 0 | Line spacing +2. Scales with SAY. |
| Chip | 12.5 medium | 0 | Fact text 94 %, source 56 %. |
| Wing (band) | 11.5 medium | 0 | Never inside the camera band. |
| Island meta | 12 medium | 0 | "Following you", "Comet is using the microphone". |
| Prompter current | 30 semibold | −0.4 | Spoken words 100 %, unspoken 55 %. |
| Prompter other | 26 medium | 0 | Previous line 28 %, next line 55 %. |
| Window large title | 26 bold | −0.5 | One per page. |
| Window title | 15 semibold | 0 | Report sections. |
| Window body | 13 regular / medium | 0 | macOS default. |
| Callout / caption | 12 / 11 medium | 0 | |

### 2.3 Spacing and radii

Spacing is a 4-pt grid: 4, 8, 12, 16, 20, 24, 32. Content inset on the island is shoulder (14) + 22 = 36 pt from the
silhouette edge, so the wing dot and the SAY bar share one vertical axis.

Radii are concentric: window 26 → inset group 14 → row / control 9 → chip 7. Island: shoulder 14, bottom corner 26
(the capsule states scale both arcs down to fit 32 pt).

### 2.4 Glass variants

| Variant | Where | Recipe |
|---|---|---|
| **G1 Island** | The island, every state | Pure black through the camera band (notch height + 6 pt), then **Regular** glass under a black veil. The veil falls with a smootherstep to the user's **Island opacity** (default **62 %**, range **35–100 %**) by 34 % of the height; the last 24 pt ease to 75 % of that so the lower rim reads as glass; a 1 pt rim stroke, white 0 → 20 % top to bottom, catches the light on the lower edge. Always dark (`colorScheme = .dark`). |
| **G2 Window** | The home window background, whole window | **Regular** glass behind the window, then the window background colour at the user's **Window opacity** (default **34 %**, range 0–100 %; 100 % = solid). One sheet: no separate sidebar material, no `NSVisualEffectView` inside it (HIG: it blocks the glass). 1 pt edge: light white 65 %, dark white 14 %. |
| **Fills on glass** | Everything on G1/G2 | Inset groups, reading plates, chips, buttons, selection are fills (2.1), never another glass layer. No glass on glass. |
| **Primary action** | One per page or card | Mint fill, `onMint` label, radius 9, 30 pt tall. The only tinted element. Secondary actions are neutral fills. |

Measured contrast of the answer card (worst background pixel next to the text, `design/mockups` renders, white page):

| Island opacity | SAY | Points (80 % white) | Chips |
|---|---|---|---|
| 62 % (default) | 17.3 : 1 | 10.2 : 1 | 12.5 : 1 |
| 35 % (minimum) | 13.8 : 1 | 7.2 : 1 | 9.0 : 1 |

The minimum is set where points still clear 7 : 1 over a white page. Over the dark call frame every value is higher.

## 3. The island

### 3.1 Geometry

One silhouette (`HangingNotchGeometry`, unchanged): concave shoulders into the screen's top edge, straight sides, round
lower corners. The band (notch height, 32 pt on a 14"/16" MacBook Pro) holds the **wings**: short status on the left
and right of the camera, never under it. Text starts 36 pt in from the silhouette edge on cards, 26 pt on capsules.
On Macs without a notch the same shape hangs from the menu bar centre with a 186 × 32 virtual band.

### 3.2 State machine

| # | State | Size (w × h, pt) | Left wing | Right wing | Body |
|---|---|---|---|---|---|
| 0 | Meeting detected | 480 × auto (≈136) | idle ring | – | "Comet is using the microphone", meeting title, "Prepared · 14 questions", **Not now** + **Start ↩** (primary). |
| 1 | Idle (session on, quiet) | 266 × 32 | idle ring | – | – |
| 2 | Listening | 354 × 32 | mint dot + 3 level bars | speaker name | – |
| 3 | Hearing a question for you | 600 × auto (≈96) | dot + bars | "for you" | The heard question, 15 medium, 56 %. Shows the latency honestly: Verse heard it, the answer is coming. |
| 4 | Answer card | 600 × auto (≈225) | dot | "for you" | SAY line with mint bar, 2–3 points, fact chips. Sonnet's deep points append under a hairline in the same card. |
| 5 | Following you | 600 × auto | dot + bars | "your answer" | "↳ Following you", the continuation SAY, points; points he has said are struck through and dimmed. |
| 6 | Practice capsule | 442 × 32 | "Q3 of 8" + timer | "your turn" + dot | – |
| 6b | Practice coach note | 520 × auto | same | same | "Coach", one note in 16 medium, "⌥Space for the next question". |
| 7 | Teleprompter | 640 × auto (≈190) | dot + "voice" | page "2 / 5" | Three lines: previous 28 %, current 30 pt (spoken 100 %, unspoken 55 %), next 55 %. |
| 8 | Status (credit, permission, offline, error) | 480 × auto | amber or coral dot | short label | One sentence, 15 semibold, plus one line of what still works. |

Card width is a setting (420–960, the existing range; default 600). Card height follows the content (bottom padding 20 pt); a card never
grows past 420 pt: older deep points drop first.

Transitions: `1 ↔ 2` on speech, `2 → 3` when a question is addressed to Alex, `3 → 4` on the first streamed token,
`4 → 5` on divergence (follow spec), `4/5 → 2` on the next turn or dismiss, `0 → 2` on Start, `6 ↔ 6b` per answer,
`7` replaces 1–5 while the prompter is open, `8` overlays any state and returns to it.

### 3.3 Motion

- The silhouette morphs size with an ease-out of 140 ms, no spring and no overshoot (unchanged from v1). Text does not
  animate in: the new text is in place when the shape reaches its size; old text is removed at the start.
- Level bars follow the last 300 ms of audio level, no idle loop. The thinking dot breathes at 0.9 s only while a call
  is in flight.
- Struck points: the strike and the dim are instant.
- Reduce Motion: no size morph; a 150 ms cross-fade between the two sizes.

## 4. The home window

### 4.1 Layout

1100 × 680 default, resizable (min 900 × 600). G2 glass, 26 pt corners, hidden title bar with the traffic lights in
the sidebar.

- **Sidebar (220 pt), no own background.** Traffic lights; then Prepare, Sessions (count), Practice, Scripts, Settings
  (SF Symbols `checklist`, `clock.arrow.circlepath`, `person.wave.2`, `text.alignleft`, `gearshape`); 32 pt rows,
  radius 9, neutral selection. "Recent": the last three sessions. Bottom: status ("● Ready", "⌥⌘V starts listening").
- **Content.** 28 pt side padding, 22 pt top. Large title + one-line subtitle. Grouped rows in inset groups
  (System Settings pattern: label left, value right, 40 pt rows). Long text sits on a reading plate. Max content
  width 760 for single-column pages.

### 4.2 Pages and what each replaces

| Page | Replaces | Content |
|---|---|---|
| Prepare | `ConversationSetupView`, meeting session picker | "Up next" (calendar meetings, prepared or not, Open / Prepare), "New preparation" (conversation thread, job posting link, company website, note), **Prepare ⌘↩**. |
| Sessions | `SimReportWindow`, vault summary viewing | List of meetings and practice runs; detail: title, meta, Summary, Follow up (checkable), Questions you got (answered / missed); **Save to vault**. Granola-calm, no charts. |
| Practice | `SimSetupView` | Job posting (link, preview, Confirmed), Interview (type segmented, length, feedback segmented, interviewer voice); **Start practice ⌘↩**. |
| Scripts | `ScriptEditorView` | Script list; editor on a reading plate with page breaks and [notes]; word count and time; **Write with Verse** (secondary), **Present ⌘P**. |
| Settings | `SettingsView` (+ sections) | Appearance (Island opacity, Window opacity, Text size, Card width), Meetings toggles, Claude key, and the existing sections below them. |

The menu-bar item stays; it opens the home window at the right page.

## 5. Accessibility

| Setting | Island | Window |
|---|---|---|
| Reduce Transparency | No glass: solid `#0E0F11` under the black band. The opacity slider is disabled with a note. | Solid window background; groups solid (`#FFFFFF` / `#2A2A2E`). |
| Increase Contrast | Veil floor at least 92 %, 1.5 pt white 60 % border, points and wings to 100 % / 85 % white, chip borders. | Groups solid with 50 % separators, button borders, a separator between sidebar and content, secondary text at primary strength. |
| Reduce Motion | Cross-fade instead of the morph (3.3). | System default. |
| Text size | S/M/L/XL scales SAY, points, chips and prompter. | Follows the system. |
| VoiceOver | The island is one element per state with the SAY line as its label and points as children; struck points read "…, said". | Standard controls and labels. |

The system's own Liquid Glass setting (Clear / Tinted, macOS 26.1) applies on top; Verse's sliders adjust its veil, not
the system glass.

## 6. Decisions

| Topic | Decision |
|---|---|
| Island colour | Always dark, like the Dynamic Island: white text needs a dark base over any page, and the band must be black to hide the camera. |
| Island translucency | Smoked Regular glass with a user floor, not clear glass. Measured legible at the minimum (2.4). |
| Window glass | One Regular glass sheet for the whole window, like ChatGPT's `vibrancy: menu`, but native (`NSGlassEffectView`, behind-window) with a user opacity and a solid fallback. |
| Glass on glass | Never. Everything on glass is a fill. |
| Accent | One: mint. Status colours only for status. Selection is neutral. |
| Buttons | 9 pt continuous rounded rectangles, not pills. One primary per surface. |
| Wings | Content aligned to the SAY bar's axis (36 pt), not hugging the camera. |
| Teleprompter | Three lines, current line split into spoken / unspoken by brightness, no colour highlight. |
| Hearing state | Show the heard question while the answer streams: the research's top complaint is stale or invisible latency. |

Rejected:

- **Clear glass on the island.** Over a white page the text falls under 3 : 1 without a heavy dim, and the HIG keeps
  clear glass for media.
- **A floating glass sidebar over an opaque content pane** (the stock Tahoe layout). It is correct HIG but it is not
  what Alex asked for (the whole window as glass), and the content pane would be the opaque card he dislikes.
- **Light island in light mode.** It loses the hardware-notch illusion and the black camera band.
- **Tinted glass buttons in the window.** That would be glass on glass; the mint fill gives the same emphasis.
- **Accent-coloured sidebar selection.** "When every element is tinted, nothing stands out."
- **Springs on the morph.** The v1 spec's rule (≤ 150 ms, no spring) stays; a bounce on a reading surface distracts.

## 7. Mockups

Regenerate: `cd design/mockups && swift run verse-mockups OUT_DIR [filter]`. Every state and page renders over a light
(day dunes + document page) and a dark (night dunes + video call) wallpaper, plus accessibility variants:
`island-a1` (opacity 35 %), `island-a2` (Reduce Transparency), `island-a3` (Increase Contrast),
`home-prepare-reduce-transparency`, `home-prepare-increase-contrast`.

How the renders differ from the app: the mockups use SwiftUI `glassEffect` inside one offscreen window that also
holds the wallpaper, captured with ScreenCaptureKit. The app's island samples other apps' windows, which SwiftUI
glass can't do, so it keeps the self-owned glass layer (`NotchCustomGlassView`) with the Regular baseline and these
veil values; the implementation must re-measure contrast on its own renders (`--render-screens`).

## 8. Implementation outline (after approval)

1. `DesignTokens.swift` + island surface: replace `NotchGlassScrim` stops with the 2.4 veil; add the rim; read the
   two opacity settings; Reduce Transparency / Increase Contrast branches. Re-run `--render-screens`.
2. Island states 0–8 in `OverlayView` with the 3.2 sizes; new hearing state; wing layout.
3. Home window shell (`HomeWindow`, sidebar, routing from the menu-bar item), G2 glass.
4. Move the five existing views into pages one at a time, keeping their models.
5. Settings: the Appearance section with both sliders.
