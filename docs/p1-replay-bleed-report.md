# P1: me-channel replay, speaker bleed, final-text embedding pass

Branch `replay-bleed`. Fake brain for every replay (no spend). Synthetic speech only (`say`, voices Kathy for Ingrid and Mara for Alex); no audio is stored. One run per table cell: the recognizers and the load on the Mac move single numbers by one or two turns between runs.

## 1. Me-channel replay

`verse-run --file remote.wav --me-file me.wav` plays both tracks side by side at real-time pace from the same start (origins measured equal within 1 ms). `eval/run_twotrack.py` renders `eval/twotrack/t01.json` (13 utterances, 56 s: hand-offs, a 150 ms answer, Alex talking over the end of a question, a follow-up that interrupts his answer, a question he interrupts half way, a backchannel in a statement) and `eval/score_twotrack.py` scores it.

**Finding:** the first replay (clean me track, no bleed) gave 14 me turns for the owner's 6 utterances and chopped questions into 2 to 4 pieces. In `TurnEngine` every remote result closed the open me turn and every me result closed the open remote turn, so two people talking at once cut each other up (and the me recognizer's bursts, up to 1.1 s apart, made one utterance look like several).

**Change (`TurnEngine.swift`):** the first result of a me turn closes the open remote turn (Alex starts talking: the question is over, as before); later results of the same utterance do not. A remote result no longer closes a me turn. A me turn ends after `meEndpointMs` (1200 ms) without any me result. A question that starts while Alex is still talking is addressed to him.

| t01, clean me track | before | after |
|---|---|---|
| questions answered once | 4/4 (one of them on the last piece of its question) | 4/4, one remote turn each |
| me turns for 6 utterances | 14 | 6 (all 6 landed) |
| answers attached to a me turn | 0 | 0 |
| statements answered | 0/2 | 0/2 |
| interrupted question (`either`) | 4 pieces | 2 pieces (answered up to the interruption, the rest is a statement) |

Final run, defenses on: `[final_clean] exit 0 ... questions 4/4 answered once (missed 0, double 0); statements wrongly answered 0/2; remote turns 10 (answered 5, spurious 0); me turns 6 (false 0); answers on me turns 0; the owner's utterances landing as me turns 6/6; wrong triggers 0`.

Tests: `TurnOverlapTests` (4; 3 fail on the old engine), `MeChannelTests` (4, real recognizers: Alex lands as a me turn, nothing is ever attached to one, the question is answered once and whole), `eval/tests/test_score_twotrack.py` (9).

## 2. Speaker bleed

Setup: the me track is the remote track attenuated, delayed, plus low-pass room noise. VP cannot be applied in file mode (voice processing lives in `MicSource` on the real input device), and the app runs with it off anyway (`cfg.voiceProcessing = false`: it ducks the meeting by 8 to 30 dB). So the production defenses measured here are the envelope gate (`BleedGate` in `ListenSession`, existing) and the new text guard.

**Text guard (`EchoGuard.swift`, in `TurnEngine`):** a me result with at least 2 words whose words are, in order (LCS, one-letter tolerance on long words), at least 60 % the words the remote channel said within 1.5 s of it is dropped before it can open a me turn or close the remote turn. An open me turn that turns out to be an echo once the remote words arrive is discarded unsent. Each drop is a `echo_guard_dropped` metric; the gate's drops are `echo_gate_dropped`. `verse-run --no-echo-guard` and `--no-bleed-gate` switch them off.

False me turns = me turns while Alex is silent (except the last block, where he talks).

| bleed | defenses | questions answered once | remote turns | me turns (false) | me results at the engine | dropped gate / guard | wrong triggers |
|---|---|---|---|---|---|---|---|
| -25 dB, 40 ms, noise -55 dBFS | none | 4/4 | 14 | 6 (6) | 52 | 0 / 0 | 0 |
| | gate (today) | 4/4 | 8 | 0 | 0 | 52 / 0 | 0 |
| | text guard only | 4/4 | 9 | 0 | 54 | 0 / 49 | 0 |
| | gate + guard | 4/4 | 8 | 0 | 0 | 62 / 0 | 0 |
| -30 dB, 80 ms, noise -50 | none | 4/4 | 11 | 5 (5) | 52 | 0 / 0 | 0 |
| | gate (today) | 4/4 | 8 | 3 (3) | 6 | 50 / 0 | 0 |
| | text guard only | 3/4 | 12 | 3 (3) | 58 | 0 / 25 | 1 |
| | gate + guard | 4/4 | 8 | 3 (3) | 7 | 44 / 2 | 0 |
| -30 dB, 20 ms, noise -45 | none | 4/4 | 9 | 2 (2) | 4 | 0 / 0 | 0 |
| | gate (today) | 4/4 | 9 | 2 (2) | 4 | 0 / 0 | 0 |
| | gate + guard | 4/4 | 9 | 2 (2) | 4 | 0 / 0 | 0 |
| -25 dB, 40 ms + Alex talking | none | 3/4 | 13 | 7 (0) | 55 | 0 / 0 | 1 |
| | gate (today) | 4/4 | 11 | 7 (0) | 41 | 14 / 0 | 0 |
| | gate + guard | 4/4 | 11 | 7 (0) | 41 | 14 / 1 | 0 |

Before the `TurnEngine` fix (first run, -25 dB / 40 ms, no defenses): 1/4 questions answered, 34 remote turns, 37 me turns, one double answer. The same cell after the fix and still without defenses: 4/4, 14 remote turns, 6 me turns. Most of the damage was the turn logic, not the echo.

What the numbers say:
- The gate catches the loud cases completely (-20 and -25 dB: 0 leaks over six runs). At -30 dB it lets garbled fragments through ("ers", "ion", "week", "What", "models", "eighteen", "Thanks,"): the mic recognizer hears the room noise as words, and those words are not the remote's words.
- The text guard alone is as good as the gate at -25 dB (it dropped 49 of 54 results; the other 5 produced no me turn) and is independent of loudness and lag. It cannot catch garbled single words (it ignores results under 2 words: with 1-word results allowed it dropped the owner's real "You" in the clean run), so at -30 dB it adds little: 3 false me turns with the gate, 3 without it.
- No bleed condition changed an answer once the engine fix was in, except the one text-guard-only -30 dB run (3/4, gate off). All remaining false me turns are 1 to 3 garbled words.

Two findings about real speech:
- The envelope gate dropped real speech twice: the owner's interjection "Sorry, one second. Let me share my screen first." (correlation 0.70 in one clean run, 0.602 against the 0.6 threshold in another, while Ingrid was speaking). The text guard did not touch it. Not changed here.
- When Alex and the bleed share the microphone, one recognizer result can mix both ("What do you know about how company you build dispatch software"). The guard dropped one such mixed result; the later results of his utterance still landed, but the me turn text carries the bleed words.

Fails when reverted: `EchoGuardTests` has 4 failures with the guard disabled, and 2 with only the retroactive discard removed (`testEchoThatArrivesBeforeTheRemoteWordsIsDiscardedLater`). `testWithoutTheGuardTheEchoCutsTheQuestionAndInventsAMeTurn` shows the damage with the guard off.

## 3. Final-text embedding pass (brain)

When a remote turn closes with no bank hit (n-gram or embedding) and it is not for someone else, `Brain._embed_final` queues one embedding match on the final text (at least `embed_min_words`, once per turn, `Config.embed_final_pass`). The result goes through `_on_embed_result`; a final job needs one evaluation instead of two consecutive partials. A statement or fragment turn is then answered through `_late_hit` (probe dropped, acknowledgement and escalated probe stand, window and newer-turn rules apply). A question turn only gets the bank hit and the verdict check, no second answer.

`brain/tests/test_runtime_finalembed.py`: 9 tests, among them "a turn whose partials never matched but whose final text does gets answered exactly once" (statement and fragment). With the `_embed_final` call removed, 6 of the 9 fail.

## Not verified

- Real speakers in a real room (reverb, frequency response, a laptop mic's own noise reduction, Bluetooth delay beyond 80 ms), and voice processing on.
- Italian and Turkish; the live brain on these fixtures (all runs used the fake brain; "answered" means the fake brain's canned answer, not a good answer).
- The final-text pass against the real embedding model (fake embedder only).
- the owner's speech and bleed at the same time over more than one run; one run per cell.
- A me result that arrives before the remote words and is a single garbled word still opens a me turn (and closes the remote turn for that moment).
