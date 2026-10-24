# Ask panel: look and motion (ask-ui, 20 Oct 2026)

Status: implemented on branch `ask-ui`, waiting for the user's approval of the look. Supersedes the "Panel layout" and "Streaming" rows of
`2026-10-20-verse-five-features-design.md` 2.2 where they differ (listed in section 4). Tokens, glass rules and the leave-out list are
the redesign's (`2026-10-16-verse-ui-redesign-design.md`).

Renders: `~/Workspace/Verse_Design_Research/ask-ui-v2-2026-10-20/` (`panel/` the panel alone, `in-situ/` inside the window,
`motion-frames/` the live stream, `before-after-*.png`). Regenerate: `VERSE_RENDER_ASK_ONLY=1 Verse --render-home DIR sessions` and
`VERSE_RENDER_ASK_DIR=DIR swift test --filter AskPanelRenderTests`.

## 1. Rules the motion follows

1. Motion explains where something came from or what changed. Nothing animates for decoration.
2. Springs for things that move (response in seconds, damping ratio), always damping 1.0: no overshoot anywhere. A bounce on a
   reading surface distracts, and nothing here is thrown by a gesture. Ease-out curves for fades and rises.
3. Everything is interruptible. SwiftUI springs retarget from the current value and velocity; no animation locks input.
4. Budgets (Emil / Apple): presses 100 ms; hover and colour 150 ms; small entrances 260 ms; springs settle in about 0.35 s;
   nothing a person waits for is longer. The only long motion is the thinking breath (1.1 s per half cycle), which is a loop, not a wait.
5. Reduce Motion means crossfades only: no slide, scale, offset, stagger, breathing or scroll animation. Opacity and colour changes stay,
   because they carry meaning.
6. Frequency decides. Things seen tens of times a day (a new message, streamed text) are short and quiet; the panel opening is the largest
   motion and happens occasionally.

## 2. Every animation

Constants live in `AskMotion` (`AskPanel.swift`). `settle` = spring response 0.34 s, damping 1.0. `quick` = spring response 0.26 s,
damping 1.0. `enter` = cubic-bezier(0.23, 1, 0.32, 1), 260 ms. `tint` = ease-out 150 ms. `crossfade` = ease-out 150 ms.

| # | What | Trigger | Curve and parameters | Reduce Motion |
|---|---|---|---|---|
| 1 | Panel slides in | Ask button, ⌘⇧A | `settle` (0.34 / 1.0). The panel moves from the trailing edge (`move(edge: .trailing)`) and fades; the list column's width goes to 0 and its opacity to 0 on the same spring; the detail column takes the width. One transaction, so one spring drives all three. | Panel crossfades in 150 ms; the columns change at once. |
| 2 | Panel slides out | ✕, ⌘⇧A, another session | Same path back (spatial consistency), `spring(0.26 / 1.0)`: the system answers faster than it asks. A second press mid-flight turns it round from where it is. | Crossfade out 150 ms. |
| 3 | Empty state rises | Panel opens, Clear chat | The line and each row: opacity 0 to 1 and 6 pt up, `enter`, 100 ms delay plus 40 ms per item (6 items, last starts at 300 ms). | Opacity only, 150 ms, no stagger. |
| 4 | Suggestions leave | First question sent, Clear chat | Opacity to 0, `tint` (150 ms), driven by the turn list. | Same. |
| 5 | Starter row | Pointer over, press | Fill in 150 ms (`tint`); press scales to 0.985 in 100 ms ease-out; separators hide under the filled row. | Fill only. |
| 6 | His question enters | Send | Scale 0.97 to 1 from the bottom-trailing corner, 8 pt up, opacity 0 to 1, `settle`. It starts from the composer's side and corner. | Opacity only, 150 ms. |
| 7 | Scroll to the new turn | Send | `scrollTo(bottom)` inside `settle`. | Instant. |
| 8 | Thinking | Until the first token | One line, "Thinking…", opacity 1 to 0.45 and back, ease-in-out 1.1 s per half cycle, repeating. After 5 s it adds " · 8 s", counting up (tabular). | No breathing; the line is static (the counter stays). |
| 9 | Thinking leaves | First token | Opacity to 0 in 80 ms ease-out, so the line and the first words never overlap for long (found in `motion-frames/`: at 150 ms they did). | Same. |
| 10 | Streamed text | Each `ask_delta` | Each chunk fades in on its own clock: colour alpha 0 to 1 over 280 ms, ease-out cubic `1 - (1 - t)^3`, from the moment it arrives. Rendered by a `TimelineView` at up to 60 fps that runs only while a chunk is fading (plus 60 ms) and then stops. No typewriter, no per-character cadence: the text arrives in the sizes the model sends it. A `[` that has not closed yet is held back, so a half stamp never flashes. | Kept: it is an opacity change. |
| 11 | Following the text | Each delta | `scrollTo(bottom)` without animation (text grows line by line). Stops when the reader grabs the scroll view (`onScrollPhaseChange`: interacting lets go); a scroll that comes to rest within 40 pt of the bottom picks it up again. The content growing never changes it. | Same. |
| 12 | "Latest" control | Not following, more than 90 pt from the bottom | Opacity and 6 pt rise, `quick`. A click: `pinned = true` and `scrollTo(bottom)` inside `settle`. Solid fill, 9 pt radius, 28 pt tall (a floating control over a glass window must not be glass). | Crossfade; the scroll is instant. |
| 13 | Citation tap | Mark in the text, token in Sources | Hands the stamp to `TranscriptJump`: the detail switches to Transcript, scrolls the row to the centre, and `TranscriptView` flashes it with the selection fill: on at once (a response, not an animation), held 1.5 s, off in 300 ms ease-out. That flash is `TranscriptView`'s own (unchanged). | Held 1.5 s, then off without the fade. |
| 14 | Citation card | Pointer rests on a Sources token | Shows after 250 ms (hover intent); when another card is already open the next one shows at once. Opacity and scale 0.97 from the edge nearest the token, `quick`. Moving between tokens moves the card on `quick` instead of re-appearing. Leaves 90 ms after the pointer does, and when scrolling starts. The token stays lit while its card is up. | Opacity, 150 ms. |
| 15 | Token press | Press | Scale 0.95, 100 ms ease-out. | Kept (it is feedback). |
| 16 | Send button | The draft has text or not | Fill and glyph colour in 150 ms; arrow to stop square is an SF Symbol replace (`contentTransition(.symbolEffect(.replace))`); press 0.96. The accent is on this button only. | Opacity content transition. |
| 17 | Focus ring | Composer focus | 1.5 pt accent ring fades in and out, 150 ms. | Same. |
| 18 | Copy confirms | Copy | Glyph becomes a checkmark for 1.4 s (symbol replace, 150 ms colour), VoiceOver announces "Copied". | Opacity content transition. |
| 19 | Error appears | `ask_error`, `a_error` | The thinking line is replaced: opacity and 6 pt rise, `enter` (260 ms). Retry appears with it. | Opacity, 150 ms. |
| 20 | Answer ready | Last token | No visual motion. VoiceOver announces "Answer ready". | Same. |
| 21 | Edges | Always | Text leaves the plate through a 14 pt (top) and 20 pt (bottom) opacity mask, static. | Same. |

## 3. What does not animate, and why

- Typing, ⏎ to send, ⇧⏎ for a new line, focus moving to the field: instant (keyboard actions).
- The model change in the header menu, the cost in the menu: instant.
- Markers inside the text (superscript timestamps): they are text, they fade with their chunk and nothing else.
- Panel width, the 340 pt column: fixed; only its position animates.
- ⌘⇧A is keyboard-initiated, which usually argues for no animation. It stays animated because the panel changes the layout of the
  window (a column collapses), and an instant layout jump loses the reader. It is the one place the rule is bent; the spring settles
  inside 0.35 s. If the owner finds it slow, `AskMotion.settle` is the one value to shorten.

## 4. Differences from the 2.2 spec text

- Header: title, one ⋯ menu (Model, This chat cost, Clear chat) and ✕. The model segmented control and the cost line left the header.
- Cost: per answer ("Sonnet · 2.4 s · $0.012") and the chat total in the ⋯ menu.
- The conversation plate no longer holds a nested card for the composer: one field with the send control inside it, radius 14, send
  button 9 inside a 5 pt inset (concentric). "Ask" is an arrow, "Stop" a square.
- Citations: superscript timestamps inside the text plus a "Sources" row under each answer; the inline chip is gone.
- Thinking is neutral (no accent dot). Accent: the send button and the focus ring, nothing else.
- Starters: one line, four rows (a fourth, "What is still open?"), the privacy line moved into the empty state.
- The panel enters from the trailing edge on a spring; the 140 ms list morph is replaced.

## 5. Type and measure

Answers 14 pt regular, line spacing 4.5 (about 21 pt, 1.5), paragraphs 12 pt apart, bullets 6 pt apart with a 16 pt hanging indent.
Citations 10 pt semibold tabular, raised 4.5 pt, joined to their word by a narrow no-break space (a mark never starts a line). Question
13.5 pt medium in a neutral fill block, trailing, at most 87 % of the width. The measure is about 41 characters because the panel is
340 pt (spec; the window minimum is 900 = 220 + 340 + 340); it is the one thing a wider panel would improve.

## 6. Accessibility

- VoiceOver reads an answer as one element: every mark becomes "(at 1 minute, 20 seconds)"; each cited time is also a custom action
  ("Show the transcript at 1 minute, 20 seconds"), and each Sources token is a button with that label.
- The question is read as "Your question: …". Send/Stop, Close, Latest, Copy have labels; "Answer ready" and "Copied" are announced.
- Increase Contrast: hairline borders on controls and the card; secondary text at primary strength (token set). Reduce Transparency:
  the plate and window are solid (token set); the card and Latest control are always solid.
- Reduce Motion: section 2, last column.

## 7. Verified and not

Verified by rendering: every static state (empty, thinking, partial answer, failed, three turns, hovered citation) in light and dark,
in the window and alone; the stream fade with the panel running live (a thinking frame, a chunk at +50, +140 and +400 ms, a second chunk
mid-fade, settled; `motion-frames-strip.png`); the logic of following, the composer caret edit, citation parsing, the spoken form and the
fade curve by unit tests (`AskPanelTests`).

Not verified as live motion (rendered or reasoned from code only): the panel spring and the list collapse, the question entrance, the
empty-state stagger, the Latest control, the card moving between tokens, the symbol replaces, the copy confirmation, the error rise,
scroll-phase following with a real trackpad, ⇧⏎ at a mid-text caret in the real field, every Reduce Motion path, and VoiceOver.
