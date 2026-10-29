# Verse: follow my answer

Status: decided 2026-10-16 (the owner). His rule applies: after a spec, build.

## 1. Goal

Verse keeps working exactly as today: a question arrives and the card shows a suggested answer (SAY plus points). the owner
doesn't always read the card. Something else may come to mind, and he may start talking about it. That will usually
still be on the question. When that happens, Verse notices at once, understands what he is talking about (from his
words and the question), and updates the card in his direction:

- **next sentence**: one sentence that continues *his* line, in his voice (STYLE GUIDE from the pack);
- **points still to make**: 2–3 short points on his topic that he hasn't said yet (numbers, projects, posting
  competencies from the pack). Each one is struck through as he says it.

If he reads the card, nothing changes. the owner: "Sapmayı fark etmeyi düzgün oturttuğumuzda harika bir program olmuş olacak."
Divergence detection is the core of this spec.

## 2. Decisions

| Topic | Decision |
|---|---|
| Default | Unchanged. The card stays as long as the owner's words follow it, including paraphrases. |
| Divergence | Measured continuously on his own (`me`) speech while a card is open for the latest remote question. **Diverged** when ≥ 5 content words *or* ≥ 1.2 s of his speech since he started do not match the card. A match is either (a) lexical, with stemmed content-word overlap against the card's SAY and points, or (b) semantic: the EmbeddingGemma similarity of his last ~12 words to the best card line is ≥ the threshold. The threshold is tuned on fixtures; start at the bank matcher's calibrated value. Fillers and backchannels ("so", "yeah", "um") are ignored. |
| Where | **In the brain.** It owns the card text, the pack and the embedder (`runtime/embed.py`). Swift only has to deliver his `me` partials, which it does today. If it doesn't, F2 adds that. |
| Follow call | New tier **C** (continue), Haiku, low effort, streamed like F. Input: the cached pack prefix (same cache as F), the question turn, the owner's words so far, and the original card. Output, in the same line format as F: `SAY:` one next sentence that continues his line, then 2–3 `- ` points. Hard rules: never contradict what he said, stay on his topic, ground every point in the pack (bank, facts, evidence) or leave it out, and add no meta comments. Amended 2026-10-29: the call also gets every earlier follow card and may answer `NONE`; the brain drops lines that repeat what is shown or what he said (spec 2026-10-29). |
| Latency | Target is the first C sentence on screen ≤ 1.5 s after divergence is detected (detection itself ≈ 1–1.5 s after his first off-card words). Pre-warm C with F. |
| Refresh | After a follow card, refresh at his sentence ends only (final result or ≥ 700 ms pause), at most once every 4 s, and only when he has said ≥ 4 new content words since the last C (distinct stems he has not said earlier in the turn and that are on no card line of the turn; amended 2026-10-29, see docs/specs/2026-10-29-verse-card-size-and-repeats.md). The card never changes mid-sentence. |
| Coverage | Every point on the current card (original or follow) is checked against his speech with the same match rule. Covered points are sent as `covered` and struck through. When all points are covered and he has stopped for ≥ 1.5 s, the card shows nothing new; Verse doesn't push him to keep talking. |
| Back on card | If after a follow card his words match the *original* card again, mark those points covered and don't switch back. Avoid flicker. |
| End | A new remote question, or the owner silent for ≥ 4 s after the remote speaks again, ends follow mode for that turn. |
| Toggle | Settings → Meetings: "Follow my answer" (default **on**). The brain gets it in `start`. |
| Teleprompter | When the meeting-card prompter is on, a follow card calls `replaceUnread(with:)` with the new SAY, so the read prefix stays. |
| Cost | One Haiku call per divergence plus refreshes. No cap (the owner). Report the count per meeting in `summary.md` metrics. |
| Fallback | When degraded (G1 local Gemma), C runs on Gemma the same way as F does. If Gemma can't, no follow card and the original stays. |

Rejected:
- **Detection in Swift.** Swift has no semantic matcher and no card meaning, and duplicating the embedder would cost RAM.
- **Updating continuously per word.** It distracts and costs more; the owner asked for an immediate switch, not churn.
- **Asking the owner to tap.** It must be hands-free.

## 3. Protocol (additive; meeting messages unchanged)

- Brain → Swift:
  - `{"type":"follow","turn_id":str,"reason":"diverged|refresh","card_id":str}`. A new card version for that turn
    follows as `delta`s with `tier:"C"` and that `card_id`. Swift replaces the visible card's text with it and shows a
    small "following you" mark.
  - `{"type":"covered","turn_id":str,"card_id":str,"point":int}` (0-based point index on that card).
  - `metric` stages: `follow_diverged` (with lexical score, embed score, words, ms since his start), `follow_card`
    (first-sentence latency), `follow_refresh`, `follow_covered`.
- Swift → brain: `start` gains `"follow": bool`. the owner's `me` partials and finals are the existing transcript messages.

## 4. Units

- **F1, brain:**
  - `runtime/follow.py`: divergence detector, coverage checker and refresh scheduler, as a pure state machine fed by
    me/remote events and the card text, unit-testable with fakes.
  - Tier C in `settings.py` / prompt.
  - Wiring in `engine.py`.
  - Protocol additions.
  - Metrics.
  - Two-track eval cases (below).
- **F2, Swift:**
  - Overlay reducer and view: follow cards, the C tier, the "following you" mark, struck-through covered points.
  - Settings toggle and the `start` flag.
  - Teleprompter `replaceUnread` on follow.
  - Me partials to the brain, if they aren't sent yet.
  - Offscreen renders of the three states.

## 5. Tests

- Detector (pure, deterministic):
  - Reading the card verbatim → no divergence.
  - Paraphrasing it ("I built most of it on my own" vs "I built it mostly solo") → no divergence (embed path).
  - Starting another project → divergence within 5 content words.
  - "so, um, yeah" → nothing.
  - Diverging, then returning to the card → no flicker.
- Coverage: a point said in other words gets struck; an unrelated sentence doesn't.
- Refresh: never mid-sentence, at most once every 4 s, needs ≥ 4 new content words.
- Engine with a fake transport: divergence → one C call → `follow` + C deltas; a new remote question ends follow mode.
- Two-track replay (`eval/twotrack`, fake brain plus fake embedder, then one live run):
  - t02, the owner reads the card → 0 follow calls.
  - t03, the owner goes off-card on a pack topic → follow card; record the detection ms and the first-sentence ms.
  - t04, off-card on a non-pack topic → follow card with ≤ 1 point, no invented facts.
- Swift: reducer states and settings persistence, plus one offscreen render per state, looked at.

## 6. Done means

In a replay, the owner's off-card answer gets a follow card with the first sentence within ~3 s of his first off-card
words, reading the card verbatim triggers nothing, covered points strike through, and the live run's C text is
grounded in the pack and sounds like the STYLE GUIDE.

## 7. Later (not this spec)

Calendar and Notes support (the owner, 2026-10-16: "ileride takvim ve notes desteği"). F5 calendar prep exists already;
Notes would be a prep source.
