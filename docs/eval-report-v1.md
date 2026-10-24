# Verse v1: replay evaluation (P1-6)

Generated 2026-10-14 18:34 from run `live1` (worktree at 55b8cca). English only; Italian and Turkish are listed as not measured.

## Setup

- 12 synthetic dialogues made with macOS `say` (6 with two speakers, 6 with three), 59 questions to the user, 12 questions to the other interviewer, plus statements, fragments and short replies; exact bank questions, blind paraphrases (`bench/embed/blind_set.json`) and off-bank questions. One more dialogue (d13) has six 2-3 word questions, scored apart, to exercise the fresh-Haiku path (speculation cannot fire on fewer than four words). Labels: `eval/dialogues/*.json`. Audio is generated at run time in a temp folder and deleted after each dialogue; each dialogue starts with silence while the English engine loads.
- Remote channel only: `verse-run --file` plays the mix of interviewers; the user's answers are silence. Speech recognition: the app's English engine (Nemotron 0.6B, 560 ms chunks) after a lead-in long enough for it to load.
- Brain: the live runtime (Haiku 5.5 for S/F, Sonnet 5.5 for D) against the P1-1 sample session (`sample-interview`, 22 bank entries).
- All times are measured from the true acoustic end of each question (known exactly from the generated audio). Machine load average at the start of each dialogue: min 4.3, max 122.0 (end of dialogue: max 38.3). The Mac was shared with other sessions, so latencies are pessimistic and noisy.
- Time zero: the generated audio is played at real-time pace, so the wall-clock time of every utterance's acoustic end is known to within about 50 ms (the file starts within tens of milliseconds of the session clock; `session_t0` reports the origin as 0).

## Spec section 9: done means

| # | Criterion | Target | Measured | Status |
|---|---|---|---|---|
| 1 | Section 6 latency targets in replay (en) | all five paths within target | see the latency table: bank hit visible met; fact chip visible met; correct speculation missed; no hit met; sonnet deep points met | missed |
| 1b | ... in one live Meet call per language | all paths | no live call run | not measured |
| 2 | Blind paraphrase bank hit rate, English | wrong-hit rate <= 5 % | hit rate on the right entry 47 % (21/45; exact 21/21, paraphrase 0/24); wrong hit left on screen 1/93 = 1 % (wrong at any moment: 2/93 = 2 %); wrong and confirmed by Haiku 0/93 | met on the wrong-hit rate; paraphrase hit rate 0 % |
| 2b | ... Italian, Turkish (Turkish separately) | wrong-hit rate <= 5 % | English only in this package | not measured |
| 3 | Questions to others get no SAY line (3-speaker replays) | >= 90 % | 12/12 = 100 % (all dialogues: 12/12) | met |
| 4 | Replay through the MacBook speakers produces no false "me" turns | zero | the me channel and the speaker-bleed test need P1-5 (follow-up) | not measured |
| 5 | Question detection, questions to the user | precision and recall >= 80 % | precision 100 % (58/58), recall 98 % (58/59) | met |
| 6 | No suggestion states a number, date or fact absent from the pack | zero | 363 lines shown: 357 passed the string check (6 did not); Haiku read all 363 in 2 passes and flagged 15; Sonnet cleared 8, so 7 unsupported (0 not judged) | missed |
| 7 | No audio file written anywhere | none | filesystem watch (250 ms polls) over the session folder, the app's Verse folder and the brain's output folder during all 13 dialogues: no audio file appeared; temp audio removed after every dialogue | met |
| 8 | API key never in logs or files | none | 54 files scanned (everything under eval/out (every recorded stdout line, stderr log, metadata and score file, the spend ledger) and this report): exact Keychain key and key-shaped strings not found | met |
| 9 | Cost per 30-minute meeting measured | measured | $0.432 per 30 min of replayed dialogue ($0.193 over 13.4 min, pre-warm and summaries included); shown in Settings: needs P1-5 | measured; Settings display not measured |

## What this means

Met today: question detection, addressing of questions to the other interviewer, wrong bank hits, Sonnet deep points, no audio files, no key leaks. Missed: the speculation opener target, and "no unsupported content" in suggestions. The fresh-Haiku path is met on only three samples.

- **Speculation opener is 0.67 s p50 / 1.22 s p90, not 0.3 / 0.5 s.** The speculative reply is held back until the `turn` message, and `turn` itself is sent 0.51 s p50 / 0.72 s p90 after the question's acoustic end (recognizer lag plus the endpoint wait, 300 ms for a finished question). The brain adds about 0.15 s at the median on top. With the endpoint wait as designed, 0.3 s cannot be reached; either the target moves to roughly 0.7 / 1.3 s or the opener is shown before the endpoint.
- **Outliers.** One Sonnet answer started 9.5 s after the question ended (d05, load average 14); the next slowest was 2.9 s. One Haiku opener took 2.6 s (d11, load average 39). The Mac was shared with other sessions (load average 4 to 122 at dialogue starts), so all latencies lean pessimistic.
- **Bank hits: exact questions 21/21, blind paraphrases 0/24.** The 3-5-gram matcher at the product thresholds (0.55 / 0.08) never fires on a paraphrase. This matches `bench/embed` (F3: 0 % for the n-gram matcher at these defaults, about 78 % with the embedding matcher). The wrong-hit rate is low (1 of 93 utterances ended on a wrong hit) largely because the matcher hits so rarely. Haiku's `BANK:` check agreed with 18 of the 21 correct hits.
- **Detection: 58 of 59 questions to the user found, no false questions.** The miss ("How big is the team you currently work in?") ends on "in", which the fragment rule treats as a cut-off clause. In the short-question dialogue d13, three of six 2-word questions ("Describe Lantern.", "Notice period?", "Why Halden?") were classed as fragments (minimum three words) and got no answer.
- **Addressing: 12 of 12 questions to the other interviewer were recognised and got no SAY line.** This relied on the recognizer's spelling being passed as a name: it writes "Tomas" as "Thomas" (listed in `--others`), and "the owner" came back as Fethy, Fifty and other variants. Replies between the interviewers ("Yes, in a moment.", "Sure, sharing it now.") have addressee "unknown" and got a short acknowledgement SAY line in 3 of 7 cases; the overlay would show those to the user.
- **Grounding: no invented number or date, but 7 of 363 shown lines add content that is not in the pack** (Python as his language, a lesson from the courier pilot, what a former manager would say, an extra definition of ETA drift, "notice counted from acceptance"). They are mostly filler answers to off-bank questions. Haiku is not deterministic: two earlier scoring passes of the same run (their output was overwritten) confirmed 8 and 5 lines with different members, including "shadow mode then a small pilot", "slower prompt iteration, but it caught regressions" and "grow into technical leadership". I read all of them: apart from one generic opener that answered a different question, each adds an unsupported claim, so the count over passes is about eleven lines, roughly 3 % of the lines shown.
- **Cost: $0.43 per 30 minutes of replay.** The dialogues are dense (a question about every 15 s) and include a pre-warm and summary per run, so a real meeting should cost less.
- **Speech engine.** All 13 reported dialogues ran on the Nemotron engine after the silent lead-in. The first attempt of d04 to d06 ran on the Apple fallback because Nemotron took longer to load than the run under heavy load; those files are kept as `eval/out/live1/*.try1.*` and are not scored.
- **Judge.** Grounding was judged by Haiku (two passes over every line) with Sonnet as second opinion on flagged lines, plus a string check for numbers, dates and names. Judge cost is included in the spend.
- **Files in `eval/out/live1`.** `*.try1.*` are attempts that were not scored: d04 to d06 on the Apple fallback, and d07, a partial recording of a run I stopped to fix the engine-load retry.

## Section 6 latency, from the acoustic end of the question

| Path | Target p50 / p90 | Measured p50 / p90 | Status |
|---|---|---|---|
| Bank hit visible | 0.3 / 0.4 s | -0.52 / 0.07 s (n=21) | met |
| Fact chip visible | 0.3 / 0.4 s | -0.26 / 0.28 s (n=16) | met |
| Correct speculation, opener visible | 0.3 / 0.5 s | 0.67 / 1.22 s (n=58) | missed |
| No hit, fresh Haiku, first word (d13 only) | 2.0 / 2.8 s | 1.55 / 1.58 s (n=3) | met |
| Sonnet deep points, first words | 2.0 / 3.0 s | 1.98 / 2.38 s (n=42) | met |

Stage by stage (all questions to the user that the system answered):

| Stage | p50 / p90 |
|---|---|
| acoustic end to `turn` sent (recognizer lag + endpoint wait) | 0.51 / 0.72 s (n=59) |
| acoustic end to first visible S/F text | 0.67 / 1.22 s (n=58) |
| S/F text came from a speculative call / from the fresh F call | 58 / 0 questions |
| questions with no S/F text at all | 1 |
| questions with D text | 42 |

Negative numbers mean the item was visible before the question had ended. Fact chips and bank hits are shown while the question is still being spoken, so they are measured against the end of the whole question, as the spec states.

## Question detection and addressing

- Questions to the user missed: 1 of 59.
  - "How big is the team you currently work in?" -> heard "How big is the team you currently work in" kinds ['fragment'] addressee ['me']
- Statements, replies, fragments or other-addressed questions that were sent on as questions for the user: 0.
- Questions to the other interviewer: 12/12 recognised as addressed to someone else; 0 not detected as a turn at all; 0 produced a SAY line.
- Statements: 10 (7 got a short acknowledgement, 0 were called questions). Fragments: 5 (0 produced output).

## Bank matching

- Matcher's last hit is the right entry: 21/45; confirmed by Haiku's `BANK:` check: 18.
- Wrong hits: 1 of 93 spoken utterances ended on a wrong hit (including off-bank questions, statements and questions to the other interviewer); 2 showed a wrong hit at some moment, even if corrected later.
  - (exact) "Can you tell me about yourself and your background?" -> ['b003', 'b001'] (expected b001)
  - (offbank) "How would you measure success for the dispatcher pilot?" -> ['b004'] (expected None)

## Grounding findings

- d02 (offbank): "SAY: Mostly Python for the pipeline and evaluation work, and I'm comfortable reading other languages when needed." (string check: {'names': ['Python']}; judge: Claims Python is used day to day and that other languages are comfortable; the notes never name any programming language.)
- d02 (offbank): "- I use Python for Lantern's extraction pipeline and its evaluation harness." (string check: {'names': ['Python']}; judge: States Lantern uses Python for extraction and its evaluation harness; the notes do not mention Python.)
- d05 (exact): "- It's the metric that tells you whether a routing change actually helps drivers keep their promises." (string check: {}; judge: Claims ETA drift is the metric that tells whether a routing change helps drivers keep promises; the notes only define ETA drift as the gap between promised and actual arrival time.)
- d06 (offbank): "SAY: The pilot taught me how much live conditions can break a plan, so I'd want to see real data first." (string check: {}; judge: The notes say nothing about what the courier pilot taught about live conditions or breaking plans.)
- d06 (offbank): "- I came away convinced that live traffic and driver status must feed re-planning, which matches how Compass works." (string check: {}; judge: The notes do not state any conviction drawn from the courier pilot about live traffic and driver status feeding re-planning.)
- d12 (paraphrase): "- I'd expect them to say I'm quick to ship a first version and then tighten it." (string check: {}; judge: Claims a former manager would say the candidate is quick to ship a first version and then tighten it; the notes contain no manager feedback.)
- d12 (paraphrase): "- If the offer were signed soon, the earliest start would be mid-December 2026, as the notice period is counted from acceptance. (b015)" (string check: {}; judge: The claim that the notice period is counted from acceptance is not stated in the notes.)

## Runs

| Dialogue | Speakers | Audio length (with lead-in) | Lead-in | Speech engine | Exit | Cost | Load avg start / end |
|---|---|---|---|---|---|---|---|
| d01 | 2 | 111 s | 45 s | Nemotron (took over at 12.8 s) | 0 | $0.0164 | 4.34 / 5.22 |
| d02 | 2 | 76 s | 17 s | Nemotron (took over at 0.6 s) | 0 | $0.0131 | 5.37 / 4.1 |
| d03 | 2 | 75 s | 10 s | Nemotron (took over at 0.6 s) | 0 | $0.0202 | 5.86 / 5.93 |
| d04 | 2 | 111 s | 45 s | Nemotron (took over at 20.8 s) | 0 | $0.0223 | 40.62 / 14.15 |
| d05 | 2 | 103 s | 25 s | Nemotron (took over at 1.0 s) | 0 | $0.0178 | 13.73 / 38.28 |
| d06 | 2 | 88 s | 20 s | Nemotron (took over at 0.7 s) | 0 | $0.0133 | 58.76 / 17.55 |
| d07 | 3 | 88 s | 20 s | Nemotron (took over at 0.6 s) | 0 | $0.0092 | 16.54 / 5.88 |
| d08 | 3 | 83 s | 20 s | Nemotron (took over at 0.6 s) | 0 | $0.0211 | 5.57 / 19.19 |
| d09 | 3 | 83 s | 20 s | Nemotron (took over at 3.8 s) | 0 | $0.0165 | 21.5 / 30.42 |
| d10 | 3 | 84 s | 20 s | Nemotron (took over at 8.0 s) | 0 | $0.0137 | 32.55 / 33.17 |
| d11 | 3 | 87 s | 20 s | Nemotron (took over at 1.2 s) | 0 | $0.0123 | 39.13 / 12.75 |
| d12 | 3 | 97 s | 20 s | Nemotron (took over at 0.8 s) | 0 | $0.0169 | 12.13 / 7.06 |
| d13 | 2 | 88 s | 25 s | Nemotron (took over at 1.1 s) | 0 | $0.0109 | 121.98 / 31.21 |

## Not run in this package

- Italian and Turkish dialogues (English first, as decided).
- The me channel and the speaker-bleed test (replay through the speakers into the microphone): needs the P1-5 overlay app merged.
- A live Google Meet call per language.
- Cost shown in Settings (P1-5).
