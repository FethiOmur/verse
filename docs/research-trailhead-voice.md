# TrailHead voice-API findings for Verse (from the TrailHead session, 2026-10-14)

These are voice-to-voice measurements (VoxNote), not STT last-word lag. Small n, taken on the owner's phone.

- **Default provider:** OpenAI `gpt-live-1` over WebRTC (`edge/functions/voice-live-session`).
- **Second provider:** Gemini `gemini-3.1-flash-live-preview` with `inputAudioTranscription` on. Its
  transcription quality and latency were never measured.
- **Cold start dominates:**
  - request → session open p50 4.1 s (2.7–6.8 s);
  - one instrumented run, speech onset → first audio, 6.85 s;
  - ~730 ms of that was a cross-region edge→DB hop.
- **Once a session is open,** end of user speech → first model audio is **~0.14 s** (24 Sep).
- **Pitfalls:**
  - Ephemeral keys expire ~60 s after mint.
  - Pin the server function to the DB region.
  - GPT-Live bills idle/mute time (~$0.05/min) and a 15 s minimum per session.
  - Watchdog ~6 s for silent connect failures.
  - Bind each session id to one purpose.

**Implication for Verse:** a cloud live API is only viable if one connection is opened before the meeting and kept
warm. Turn latency then looks small, but idle time is billed. On-device Apple STT stays primary (see
`research-cloud-stt.md`).
