# Verse: interview simulation mode (design)

Status: draft for the user's review, 2026-10-14. Implementation starts after approval.
Builds on: `2026-10-14-verse-meeting-assistant-v1-design.md` (prep stage, brain sidecar, audio, overlay).

## 1. Goal and audience

A practice mode inside Verse: a mock interviewer asks questions built from **the user's own experience** and
**a specific job posting**, listens to the spoken answers, asks follow-ups like a real interviewer, and gives
feedback, either after each answer or as a scored report at the end.

First user: the owner, preparing for real interviews (Brightwave case study, Harbor Tech technical round). Later: every
Verse user, so nothing in the design may depend on the owner's vault being present.

## 2. What the owner decided (2026-10-14)

| Topic | Decision |
|---|---|
| Interviewer voice | User's choice: **Apple voice** (local, free), **cloud voice** (ElevenLabs or OpenAI, user's own key), or **written questions** in the overlay. The user always answers by voice |
| Cloud keys | The user enters an ElevenLabs key and/or an OpenAI key (one OpenAI key covers TTS, and STT later) |
| Feedback | Both, selectable: **Coach** (short note after each answer) and **Realistic** (silent, scored report at the end) |
| Job posting input | Paste a **link** or paste the **text** |
| Hints during practice | The normal Verse card can be toggled on and off; **off by default** |

## 3. Constraints

- **Brain on the Anthropic API credit.** Interviewer questions, follow-ups, scoring and the report use Claude through the
  same Individual Org key as the meeting assistant. ElevenLabs and OpenAI are used only for voice, and only when the
  user chose them and entered a key.
- **Keys in the Keychain**: `verse-elevenlabs` and `verse-openai` (same account rule as `verse-anthropic`). They are
  never logged, printed, written to files or passed on a command line.
- **No audio is stored.** The user's answers are transcribed and kept as text only, like meetings. Synthesized
  interviewer audio is played from memory and discarded.
- **English first.** Italian and Turkish are follow-ups; the design keeps language as a parameter.
- **No vault required.** The experience source is a CV (PDF or text) and/or a short "about me" note; the vault
  and repos are optional extra sources when present.

## 4. Approaches considered

| Option | Verdict | Reason |
|---|---|---|
| **Reuse prep + a new `sim` runtime in the brain + a sim view in the app** | **Chosen** | Prep already turns notes, vault and commits into a grounded pack; the brain already streams Claude with caching; STT, bleed gate and the overlay exist |
| Separate practice app | Rejected | Duplicates audio, STT, Keychain and settings |
| Realtime voice model (gpt-live / Gemini Live) as the interviewer | Rejected for v1 | Bills outside the Anthropic API credit, and the owner measured gpt-live as laggy (2026-10-14). Revisit as an option later |
| Text chat only | Rejected | Speaking the answer is the point of practice |

## 5. Design

### 5.1 Sim prep (Python, `verse_brain.prep` extended)

Input: the job posting (URL or text), the experience sources (CV file, about-me note, optional vault and repos),
interview type, difficulty, length and language.

- **Posting fetch** (Swift side, so the brain needs no network beyond the API): known ATS endpoints first
  (LinkedIn guest job API, Ashby, Greenhouse, Lever JSON), else the page's readable text. On failure: "paste the
  text instead". The fetched text is shown to the user before prep runs.
- **Sonnet builds the sim pack** (`sim.json` + `sim_pack.md` in a new session folder `sessions/sim-<date>-<company>/`):
  - role summary: company, role, the 5–8 competencies the posting asks for, with the posting sentence each comes from;
  - the user's evidence: projects, numbers and stories from the sources, each with its source (same grounding
    rules as the meeting bank: no number without a source);
  - a question plan of N questions (default 8 for 30 min) mixing behavioural, role/technical and motivation
    questions, each tagged with the competency it probes, the evidence a strong answer would use, and 1–2
    follow-up hooks ("ask for the metric", "ask what they would do differently");
  - a rubric per competency (what 1, 3 and 5 look like).
- **Interview types:** screening (HR), hiring manager, technical, and mixed. **Difficulty:** friendly, standard, tough
  (tough interrupts vague answers and pushes on numbers).

### 5.2 Sim runtime (brain, new mode `sim`)

A half-duplex turn loop:

1. `ask`: the interviewer line for the next planned question (Haiku rewrites the planned question into natural
   speech in the interviewer's persona, streaming; the first sentence is sent to TTS as soon as it is complete).
2. `listen`: the app plays the line, then listens on the **mic channel only**. The answer ends after
   `answer_silence_s` of silence (default 2.0 s; people pause to think) or when the user presses "done".
   The mic is ignored while the interviewer speaks (no self-transcription of TTS through the speakers).
3. `judge` (Haiku, cached prefix): was the answer complete enough? Pick one: a follow-up from the hooks, a
   clarifying push ("Can you put a number on that?"), or move on. At most 2 follow-ups per question.
4. In **Coach** mode, after the last follow-up of a question: a 2–3 line note (what worked, what was missing, one
   better sentence built from the user's own evidence). In **Realistic** mode nothing is shown.
5. After the last question: "Do you have any questions for us?" and a short answer to one user question
   (Sonnet, from the posting only), then the close.

New protocol messages (JSON lines, additive to the meeting protocol):
- Swift → brain: `{"type":"sim_start","session_dir","mode":"coach|realistic","voice":"apple|elevenlabs|openai|text"}`,
  `{"type":"answer","q_id","text","t_start","t_end","words","fillers"}`, `{"type":"control","action":"skip|repeat|end"}`.
- Brain → Swift: `{"type":"say","id","text","final":bool}` (interviewer speech, streamed by sentence),
  `{"type":"listen","q_id"}`, `{"type":"coach","q_id","lines":[...]}`, `{"type":"sim_report","path"}`, `status` as today.

### 5.3 Voices (Swift, `VerseVoice` new module)

One protocol, three engines, chosen in Settings and per simulation:
- `AppleVoice`: `AVSpeechSynthesizer` with the best installed English voice (Premium/Enhanced when present; the
  Settings screen links to System Settings to download one).
- `ElevenLabsVoice`: streaming TTS over HTTPS with the user's key; voice picked from the user's ElevenLabs voices.
- `OpenAIVoice`: OpenAI's current TTS model over HTTPS with the user's key (model id confirmed at implementation
  time from OpenAI's docs, not from memory).
- `TextOnly`: no audio; the line appears in the overlay card.
- Sentence-level streaming: the first sentence starts playing while the rest is generated. If a cloud call fails,
  fall back to Apple voice for that line and show a small chip.

### 5.4 App (Swift)

- **Menu:** "Practice interview…" opens a sim setup window: posting (link field + paste area + preview), experience
  (CV file picker, about-me note, "use my vault" toggle, repos), type, difficulty, length, mode (Coach/Realistic),
  voice, hints toggle. "Build interview" runs sim prep (progress shown); "Start" begins.
- **During the sim:** the notch capsule shows `practice · Q3/8` and the timer. The interviewer's line appears in
  the card in text mode, and as a one-line caption in voice modes (toggle). A "done answering" key (⌥Space) ends
  an answer early. When hints are on, the normal Verse card runs on the interviewer's lines (the interviewer
  becomes the "remote" speaker).
- **Report window** at the end, also saved as `report.html` in the session folder:
  - overall and per-competency scores (1–5) with the rubric line that justified each;
  - per question: the question, the user's answer (transcript), what was strong, what was missing, a better
    answer built only from the user's own evidence (with sources), and delivery numbers;
  - delivery: speaking pace (words per minute), filler words ("um", "like", "you know"), answer length vs. a
    target of 60–120 s for behavioural answers, longest pause;
  - the 3 things to practise next.

### 5.5 Costs

Measured in the spike and shown in Settings like meetings (no cap; the owner, 2026-10-14). Estimate to verify: one
30-minute sim ≈ prep (Sonnet, once) + ~8 questions × (Haiku ask + judge) + report (Sonnet) ≈ well under $1.
Cloud voice costs are billed by ElevenLabs/OpenAI to the user's own key and are not counted against the Anthropic API credit.

## 6. Error handling

- Posting link unreadable → ask for pasted text; never invent the posting.
- No experience source → the sim still runs on the posting alone, and the report says answers could not be checked
  against the user's background.
- Cloud TTS error or missing key → Apple voice for that line plus a chip; the sim never stops for a voice error.
- Mic permission denied → the same guided message as meetings.
- The user is silent for 20 s after a question → the interviewer offers to repeat or skip.
- Brain crash → the meeting supervisor's restart-once rule; the transcript so far is kept and a partial report is
  written.

## 7. Test cases

- Sim prep: a fixture posting + fixture CV → a deterministic `sim.json` with competencies that each cite a posting
  sentence, questions tagged with competencies, and evidence items that each cite a source; a posting with no
  matching evidence → questions still planned, evidence empty, flagged.
- Posting fetch: recorded LinkedIn guest, Ashby, Greenhouse and Lever responses → clean text; an unknown page →
  readable text; a failure → the paste prompt.
- Runtime (fake model): a scripted answer timeline → `say`/`listen` ordering, at most 2 follow-ups, Coach notes
  only in Coach mode, report written at the end.
- Turn-taking: TTS playback with the mic open → no answer text from the TTS audio (bleed), silence of 2.0 s ends
  the answer, ⌥Space ends it at once.
- Voices: each engine behind the protocol with a fake transport; ElevenLabs/OpenAI failure → Apple fallback;
  keys are read from the Keychain and never appear in logs (grep check).
- Report: delivery numbers from a fixture transcript (WPM, filler count, pause) match hand-computed values; every
  "better answer" sentence with a number cites a source.
- Live: one 10-minute English sim per voice mode on this Mac.

## 8. Done means

the user pastes the Brightwave posting link, picks his CV, chooses Coach + Apple voice, and does a 10-minute practice
interview end to end: spoken questions, his spoken answers, sensible follow-ups, Coach notes, and a report that
cites his real projects and contains no invented numbers. The same run works with ElevenLabs and OpenAI voices
when their keys are set, and in text mode with no voice key at all.

## 9. Out of scope (later)

Italian and Turkish sims; video (camera, eye contact, posture); panel interviews with several AI interviewers;
coding-round simulation with a shared editor; sharing reports; realtime voice models as interviewers.
