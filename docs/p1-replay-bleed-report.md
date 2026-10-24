# P1: me-channel replay, speaker bleed, final-text embedding pass

Branch `replay-bleed`. Fake brain for every replay (no spend). Synthetic speech only (`say`, voices Kathy for Ingrid and Mara for the user); no audio is stored. One run per table cell: the recognizers and the load on the Mac move single numbers by one or two turns between runs.

## 1. Me-channel replay

`verse-run --file remote.wav --me-file me.wav` plays both tracks side by side at real-time pace from the same start (origins measured equal within 1 ms). `eval/run_twotrack.py` renders `eval/twotrack/t01.json` (13 utterances, 56 s: hand-offs, a 150 ms answer, the owner talking over the end of a question, a follow-up that interrupts his answer, a question he interrupts half way, a backchannel in a statement) and `eval/score_twotrack.py` scores it.

**Finding:** the first replay (clean me track, no bleed) gave 14 me turns for the user's 6 utterances and chopped questions into 2 to 4 pieces. In `TurnEngine` every remote result closed the open me turn and every me result closed the open remote turn, so two people talking at once cut each other up (and the me recognizer's bursts, up to 1.1 s apart, made one utterance look like several).

**Change (`TurnEngine.swift`):** the first result of a me turn closes the open remote turn (the owner starts talking: the question is over, as before); later results of the same utterance do not. A remote result no longer closes a me turn. A me turn ends after `meEndpointMs` (1200 ms) without any me result. A question that starts while the owner is still talking is addressed to him.

| t01, clean me track | before | after |
|---|---|---|
| questions answered once | 4/4 (one of them on the last piece of its question) | 4/4, one remote turn each |
| me turns for 6 utterances | 14 | 6 (all 6 landed) |
| answers attached to a me turn | 0 | 0 |
| statements answered | 0/2 | 0/2 |
| interrupted question (`either`) | 4 pieces | 2 pieces (answered up to the interruption, the rest is a statement) |

Final run, defenses on: `[final_clean] exit 0 ... questions 4/4 answered once (missed 0, double 0); statements wrongly answered 0/2; remote turns 10 (answered 5, spurious 0); me turns 6 (false 0); answers on me turns 0; the owner's utterances landing as me turns 6/6; wrong triggers 0`.

Tests: `TurnOverlapTests` (4; 3 fail on the old engine), `MeChannelTests` (4, real recognizers: the owner lands as a me turn, nothing is ever attached to one, the question is answered once and whole), `eval/tests/test_score_twotrack.py` (9).

## 2. Speaker bleed

Setup: the me track is the remote track attenuated, delayed, plus low-pass room noise. VP cannot be applied in file mode (voice processing lives in `MicSource` on the real input device), and the app runs with it off anyway (`cfg.voiceProcessing = false`: it ducks the meeting by 8 to 30 dB). So the production defenses measured here are the envelope gate (`BleedGate` in `ListenSession`, existing) and the new text guard.

**Text guard (`EchoGuard.swift`, in `TurnEngine`):** a me result with at least 2 words whose words are, in order (LCS, one-letter tolerance on long words), at least 60 % the words the remote channel said within 1.5 s of it is dropped before it can open a me turn or close the remote turn. An open me turn that turns out to be an echo once the remote words arrive is discarded unsent. Each drop is a `echo_guard_dropped` metric; the gate's drops are `echo_gate_dropped`. `verse-run --no-echo-guard` and `--no-bleed-gate` switch them off.

False me turns = me turns while the owner is silent (except the last block, where he talks).

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
| -25 dB, 40 ms + the owner talking | none | 3/4 | 13 | 7 (0) | 55 | 0 / 0 | 1 |
| | gate (today) | 4/4 | 11 | 7 (0) | 41 | 14 / 0 | 0 |
| | gate + guard | 4/4 | 11 | 7 (0) | 41 | 14 / 1 | 0 |

Before the `TurnEngine` fix (first run, -25 dB / 40 ms, no defenses): 1/4 questions answered, 34 remote turns, 37 me turns, one double answer. The same cell after the fix and still without defenses: 4/4, 14 remote turns, 6 me turns. Most of the damage was the turn logic, not the echo.

What the numbers say:
- The gate catches the loud cases completely (-20 and -25 dB: 0 leaks over six runs). At -30 dB it lets garbled fragments through ("ers", "ion", "week", "What", "models", "eighteen", "Thanks,"): the mic recognizer hears the room noise as words, and those words are not the remote's words.
- The text guard alone is as good as the gate at -25 dB (it dropped 49 of 54 results; the other 5 produced no me turn) and is independent of loudness and lag. It cannot catch garbled single words (it ignores results under 2 words: with 1-word results allowed it dropped the owner's real "You" in the clean run), so at -30 dB it adds little: 3 false me turns with the gate, 3 without it.
- No bleed condition changed an answer once the engine fix was in, except the one text-guard-only -30 dB run (3/4, gate off). All remaining false me turns are 1 to 3 garbled words.

Two findings about real speech:
- The envelope gate dropped real speech twice: the owner's interjection "Sorry, one second. Let me share my screen first." (correlation 0.70 in one clean run, 0.602 against the 0.6 threshold in another, while Ingrid was speaking). The text guard did not touch it. Fixed in section 4.
- When the owner and the bleed share the microphone, one recognizer result can mix both ("What do you know about how company you build dispatch software"). The guard dropped one such mixed result; the later results of his utterance still landed, but the me turn text carries the bleed words.

Fails when reverted: `EchoGuardTests` has 4 failures with the guard disabled, and 2 with only the retroactive discard removed (`testEchoThatArrivesBeforeTheRemoteWordsIsDiscardedLater`). `testWithoutTheGuardTheEchoCutsTheQuestionAndInventsAMeTurn` shows the damage with the guard off.

## 3. Final-text embedding pass (brain)

When a remote turn closes with no bank hit (n-gram or embedding) and it is not for someone else, `Brain._embed_final` queues one embedding match on the final text (at least `embed_min_words`, once per turn, `Config.embed_final_pass`). The result goes through `_on_embed_result`; a final job needs one evaluation instead of two consecutive partials. A statement or fragment turn is then answered through `_late_hit` (probe dropped, acknowledgement and escalated probe stand, window and newer-turn rules apply). A question turn only gets the bank hit and the verdict check, no second answer.

`brain/tests/test_runtime_finalembed.py`: 9 tests, among them "a turn whose partials never matched but whose final text does gets answered exactly once" (statement and fragment). With the `_embed_final` call removed, 6 of the 9 fail.

## Not verified

- Real speakers in a real room (reverb, frequency response, a laptop mic's own noise reduction, Bluetooth delay beyond 80 ms), and voice processing on.
- Italian and Turkish; the live brain on these fixtures (all runs used the fake brain; "answered" means the fake brain's canned answer, not a good answer).
- The final-text pass against the real embedding model (fake embedder only).
- the owner's speech and bleed at the same time over more than one run; one run per cell.
- A me result that arrives before the remote words and is a single garbled word still opens a me turn (and closes the remote turn for that moment). Narrowed in section 5.

## 4. Gate fix (branch `echo-gate`)

**Root cause.** `BleedGate` decided on one number, the Pearson correlation of the 10 ms envelopes (threshold 0.6). Two speech envelopes correlate at 0.7 by chance, so a person talking while the remote talks is dropped whenever the syllable rhythms happen to line up. Measured with `verse-run --trace` (every me result now logs `echo_gate_decision`: correlation, lag, mic level over the bins where the remote is active, remote level, ratio in dB, share of mic activity with no remote under it). Data: 26 two-track runs, all t01, synthetic speech.

| events with correlation >= 0.6 | events (one run each; real speech: distinct) | correlation | mic/remote level ratio |
|---|---|---|---|
| the owner's real speech (clean and own-speech runs; about 37 distinct real events in all, the other 35 have corr <= 0.45) | 2 ("Sorry" onset, 160 to 240 ms) | 0.73 | -2.9 and -8.1 dB |
| echo -25 dB, 40 ms (the owner silent) | 55 | 0.97 to 1.00 | -24.9 to -24.5 |
| echo -30 dB, 80 ms | 44 | 0.69 to 0.99 | -27.9 to -26.1 |
| echo -15 dB / -10 dB (new cells) | 53 / 52 | 0.99 or more | -15.0 / -10.0 |

The level ratio separates them by 16 dB (-8.1 versus -24.5). Mic-only share (mic active where the remote is not) did not: 0.25 for the real events, 0.0 to 0.78 for echo, so it is logged but not used.

**Rule (c, level plus text guard).** In `BleedGate.verdict`: correlation < 0.6 keeps; otherwise drop if ratio <= -15 dB, or if correlation >= 0.9 and ratio <= -6 dB (a loud speaker echo; two different voices never got above 0.73); anything else is `defer`: the event passes to `TurnEngine`, where `EchoGuard` decides on words (drop only when the text matches the remote's). -15 dB is 7 dB under the owner's lowest ratio and 9.5 dB over the nearest echo cell of this report. The single-correlation rule is kept as `verse-run --gate-corr-only` (the "before" arm).

**Tests** (`GateDoubleTalkTests` with a scripted recognizer, `BleedGateTests`): a correlated double-talk (0.999, ratio 0 dB) is kept; echo at -25/40, -30/80, -15/40 and -10/40 dB is dropped; the same tests with the rule reverted to correlation alone fail (`the gate dropped the owner's real speech`, `the owner's real double-talk was classed as echo`). `eval/tests/test_score_twotrack.py` has 10 tests (new: `gate_dropped_over_own_speech`, `echo_gate_deferred`).

**Two-track runs, before (correlation only) and after.** One row per run.

| cell | arm | runs | questions once | me turns (false) | the owner landed | gate dropped | gate drops over his speech | deferred | wrong triggers |
|---|---|---|---|---|---|---|---|---|---|
| clean | before | 3 | 4/4 x3 | 5, 6, 6 (0) | 5/6, 6/6, 6/6 | 1, 0, 0 | 1, 0, 0 | - | 0 |
| clean | after | 3 | 4/4 x3 | 6, 6, 6 (0) | 6/6 x3 | 0, 0, 0 | 0, 0, 0 | 0 | 0 |
| -25 dB, 40 ms, the owner talks (`--with-own`) | before | 1 | 4/4 | 7 (0) | 6/6 | 14 | 1 ("Sorry") | - | 0 |
| | after | 2 | 4/4 x2 | 7 (0) x2 | 6/6 x2 | 13, 13 | 0, 0 | 1, 1 ("Sorry") | 0 |
| -25 dB, 40 ms | before | 2 | 4/4 x2 | 2 (2) x2 | - | 55, 55 | - | - | 0 |
| | after | 2 | 4/4 x2 | 2 (2) x2 | - | 55, 55 | - | 0 | 0 |
| -30 dB, 80 ms | before | 2 | 4/4 x2 | 3 (3) x2 | - | 44, 44 | - | - | 0 |
| | after | 2 | 4/4 x2 | 3 (3) x2 | - | 44, 44 | - | 0 | 0 |
| -30 dB, 20 ms | before | 2 | 4/4 x2 | 2 (2) x2 | - | 0, 0 | - | - | 0 |
| | after | 2 | 4/4 x2 | 2 (2) x2 | - | 0, 0 | - | 0 | 0 |
| -15 dB / -10 dB, 40 ms | before / after | 1 / 1 each | 4/4 | 0 (0) | - | 53 / 52, same after | - | 0 | 0 |

The three bleed cells are unchanged by the fix (same counts, same false me turns: "els", "so" / "What", "models", "eighteen" / "Thanks,", "Thanks."). The -25 dB cell shows 2 false me turns in all four runs of this session, before and after, where the table in section 2 has 0 for its single run: the rule did not cause them (the before arm has them too), but I did not find why this session differs. The clean run's drop is intermittent (1 of 3 before runs, depending on how the recognizer cuts the first word), so the clean before/after rows alone do not prove the fix; the own-speech cell, where the same "Sorry" window (correlation 0.734, -2.9 dB) is dropped before and deferred after in every run, and the tests above do.

**Not verified here:** a real room and microphone (the ratio depends on mic gain against the tap level: a very quiet mic would push the owner's ratio down toward the -15 dB line); echo louder than -6 dB with correlation under 0.9; the owner's real speech louder than the remote with a tight correlation; `verse-run` with voice processing on; Italian and Turkish.

## 5. A bleed word that splits a remote question (branch `me-turn-split`)

**Failure.** `MeChannelTests.testBleedIsDroppedByTheTextGuardAlone` (envelope gate off, real recognizers) failed 3 of 3 on main: the question came out as r1 "Can you tell me" and r2 "about yourself and your background?". Traced with a stderr line per engine event (since removed):

- Run A: the remote recognizer's "Can you tell me" is in, then the mic result "Can" (one word). `EchoGuard` ignores results under `echoMinWords` (2), so "Can" opened a me turn and closed r1. The next mic result, "Can you", was dropped as echo and the me turn discarded, but r1 was already closed; the rest of the question became r2.
- Run B (the other failure of the same test, after run A was fixed): no single word. The mic recognizer is a few words ahead of the remote one: "Can you tell me about yourself and" (7 words) arrived 6 ms before the remote's own result for those words. Only 4 of its 7 words were in what the remote had said so far, 0.57, under the 0.6 drop line, so it opened a me turn and closed r1.

Both are one cause: the engine closes the open remote turn on the first me result, before the text guard can tell whether that result is the owner or the remote voice, and a closed turn cannot be reopened (its `turn` event is already out).

**Choice.** (a), hold the close; not (b), re-merge. (b) would have to take back a `turn` event the brain already acted on. Lowering `echoMinWords` to 1 is what section 2 already rejected (it dropped the owner's real "You"). Holding it unconditionally fails `TurnOverlapTests.testInterruptionMidQuestionClosesItAsAFragment` ("Sorry" must close the question in the same call), so the hold is conditional.

**Rule (`TurnEngine.ingestMe`, `EchoGuard.suspicion`).** The first result of a me turn still opens the me turn at once. If the remote turn is open, the close is held when the result's suspicion is at least `echoHoldSimilarity` (0.4): the share of its words found, in order, in what the remote said within 1.5 s, where a word also counts when the remote's volatile word is its first 3+ letters ("sal" for "salary"), with no minimum word count. A result below that closes the remote turn at once, exactly as before. While held:
- the me turn is discarded as echo (a later remote result or the guard): the remote turn was never closed;
- the me turn reaches 2+ words with suspicion under 0.4: the remote turn closes then, at the time of that result;
- `meCloseHoldMs` (1200) passes since the first result and the me turn is still there: the remote turn closes, stamped at the end of the window;
- the me turn ends by its own quiet or the remote turn ends by its own quiet: the hold is dropped.
`--no-echo-guard` also switches the hold off; `verse-run --me-hold-ms N` sets the window (0 = before, the "before" arm below).

**Latency cost.** Zero for a first word the remote did not say nearby ("Sorry", "Between"; pinned by `TurnOverlapTests` and `testWordTheRemoteNeverSaidClosesImmediately`). A real interruption that starts with a word the remote also said (say "and", "you") and whose first recognizer result is that one word: the remote turn closes when the next me result has 2+ words not echo-like, otherwise at most 1200 ms after the first word. That window is the recognizers' burst cadence (volatile results about 1 s apart; section 1), not a guess of mine: 500 and 800 ms were tried and were too short, because the remote words that settle the question arrive with the next burst (text-guard-only, -30 dB/80 ms: 14, 9, 10 remote turns for 500, 800, 1200 ms; 15 with the hold off; one run each). A held remote turn is a fragment or a question the user cut off, so a late close delays nothing the brain would have answered.

**Replays** (`eval/run_twotrack.py`, t01, fake brain, synthetic speech, one run per cell, built from this branch; "hold 0" = `--me-hold-ms 0`, the engine as on main):

| cell | arm | questions once | remote turns | me turns (false) | the owner landed | dropped gate / guard |
|---|---|---|---|---|---|---|
| clean | hold 1200 | 4/4 | 10 | 6 (0) | 6/6 | 0 / 0 |
| -30 dB, 80 ms, noise -50, text guard only | hold 0 | 4/4 | 15 | 3 (3) | - | 0 / 31 |
| | hold 1200, run a | 4/4 | 10 | 3 (3) | - | 0 / 31 |
| | hold 1200, run b | 4/4 | 10 | 3 (3) | - | 0 / 31 |
| -30 dB, 80 ms, noise -50, gate + guard (the app) | hold 1200 | 4/4 | 8 | 3 (3) | - | 44 / 2 |
| -25 dB, 40 ms + the owner talking, gate + guard | hold 0 | 4/4 | 12 | 7 (0) | 6/6 | 13 / 1 |
| | hold 1200 | 4/4 | 11 | 7 (0) | 6/6 | 13 / 1 |

Section 2 gave 12 remote turns for the -30 dB text-guard-only cell (3/4 questions); this session's hold-0 arm gave 15 (4/4), so single numbers move by a few turns between sessions; the paired hold 0 / hold 1200 rows are the comparison. Clean and the the owner-talking cell show no change in what lands (6/6, same me turns), the app configuration is unchanged (8, as in section 2). In the text-guard-only cell all three arms have 3 false me turns (garbled results such as "models"); the hold does not touch them, it only stops the bleed from cutting the question.

**What the hold does not fix.** A me result that is not made of words the remote said so far, because the mic recognizer is ahead and the remote's words are not out yet ("We are" against a remote turn that ends in "us"; "to like ten" against "ship around ten thousand"). Nothing in the text can tell it from the owner starting to talk, so it still closes the remote turn at once; only the hold-0-versus-1200 gap (15 versus 10 in the text-guard-only cell, versus 8 with the gate) remains as split turns there. The envelope gate removes most of them in the app. Closing that rest needs either a hold on every first me result (fails the "Sorry" test and costs every real interruption the window) or taking back an emitted `turn` event.

**Tests.** `MeTurnHoldTests` (6, fake events, no recognizer): a one-word bleed mid-question leaves one remote turn; the mic recognizer ahead (4 of 7 words) leaves one; a bleed word discarded later never closes it; a real interruption with an ambiguous first word closes on the second word at once; a lone ambiguous word closes within 1200 ms (at +1200 exactly, not before); a word the remote never said closes at once. With the hold switched off in the engine, 5 of the 6 fail (the sixth is the immediate-close control). `TurnOverlapTests` and `EchoGuardTests` unchanged and green; `MeChannelTests.testBleedIsDroppedByTheTextGuardAlone` passes (it failed 3 of 3 before).

**Not verified.** Real speakers and a real room; Italian and Turkish (the 3-letter prefix rule and the word lists are English-tested); the live brain; more than one run per replay cell; how often a real interruption starts with a word the remote also said, so the share of interruptions that pay the wait is unmeasured.
