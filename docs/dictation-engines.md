# Dictation engines

Dictation (Fn + Space or ⌃⌥⌘D) can write its final text with one of two engines. Pick one in
Settings › Dictation › Dictation engine (`DictationSettings.engine`, stored as `dictationEngine`).

| Engine | Live preview in the island | Final text | Audio leaves the Mac |
|---|---|---|---|
| Apple (on device), the default | Apple engine | Apple engine | never |
| Groq Whisper (cloud) | Apple engine | Groq `whisper-large-v3` | only when a dictation stops |

Dictation stays off while Verse listens to a meeting or another run, whichever engine is selected.

## How the Groq engine works

`GroqDictationTranscriber` (app/Sources/VerseUI/DictationGroq.swift) wraps the Apple transcriber:

1. The Apple engine runs exactly as it does with the Apple engine selected: live text, level meter,
   release tail, start and stop cues.
2. The same microphone tee that feeds the level meter (`MeteredCaptureSource`) also feeds a
   `DictationAudioRecorder`. It converts each chunk to 16 kHz mono 16-bit as it arrives and keeps it
   in memory only, never on disk. It stops at 5 minutes (9.6 MB as WAV). Groq's free tier accepts
   25 MB.
3. When the dictation stops, after the release tail, the Apple engine finishes first. Then the audio
   is encoded as WAV and sent to Groq. The island shows "finishing" the whole time.
4. Groq's text then goes through the usual chain, the same as Apple text: corrections, smart
   insertion, paste check, recent dictations.

### Request

```
POST https://api.groq.com/openai/v1/audio/transcriptions
Authorization: Bearer <key>
Content-Type: multipart/form-data; boundary=verse-<uuid>

model=whisper-large-v3          (whisper-large-v3-turbo when GroqWhisper.useTurbo is true)
language=tr | en | it           (the language resolved for this dictation)
prompt=<vocabulary terms>       (omitted when there are none)
temperature=0
response_format=json
file=dictation.wav              (audio/wav, 16 kHz mono 16-bit PCM)
```

The answer is `{"text": "..."}`. The session is ephemeral (no cache, no cookies) and shared by all
dictations.

`GroqWhisper.useTurbo` is a constant in the source, not a setting: switching to the turbo model means
changing it and rebuilding.

`language` is always sent. Without it Whisper guesses the language from the audio, and on a short
dictation it can guess wrong and write the text in another language. With it, Whisper still keeps
English terms inside a Turkish or Italian sentence, which is what "handles mixed languages better" in
Settings compares against: the Apple engine, which is locked to one locale.

The prompt is the Settings vocabulary written as a short list ("Claude Code, Groq, Whisper.").
Whisper reads it as a spelling and context hint. Groq caps the prompt at 224 tokens. Verse has no
Whisper tokenizer, so it estimates one token per two UTF-8 bytes (an over-estimate) and stops adding
terms at an estimated 200. A term is never cut in half.

### Fallback: the dictation is never lost

The Apple engine's text is used instead of Groq's, with a short notice in the island, when:

- there is no key ("No Groq key: used the on-device text");
- the Keychain read has not returned 3 s after the stop, for example while a keychain prompt waits
  ("Groq unavailable: used the on-device text"; logged as `outcome=key_timeout`);
- the recording is longer than 5 minutes, the network fails, Groq answers with an HTTP error or with
  empty text, or no answer arrives in time ("Groq unavailable: used the on-device text"). The time
  limit is 8 s, plus 0.05 s per second of audio, at most 20 s.

Audio shorter than 0.1 s is not sent and gets no notice.

Esc during the upload cancels the request. Nothing is inserted. Esc marks the engine cancelled at
once, so an upload that was about to start does not start.

A notice that follows at once ("heard nothing", or the text went to the clipboard) replaces the
fallback notice; the log still records the fallback.

The log records only the outcome, latencies and sizes, for example
`dictation: groq outcome=http audio_ms=4200 ms=310 status=401`. It never records text or the key.

## The key

The key lives in the login Keychain with service `verse-groq` and account `$USER`. The item is
created through `/usr/bin/security`, the same way as the Anthropic key (`KeychainStore`) and the voice
keys (`VoiceKeys`), so both the app and scripts can read it without a prompt. When the Groq engine is
selected, Settings has Save / Replace / Remove rows for it. To save it from Terminal instead
(`security` asks for the key, so it does not end up in the shell history):

```
security add-generic-password -U -a "$USER" -s verse-groq -l verse-groq -w
```

## Source

Groq speech-to-text documentation, https://console.groq.com/docs/speech-to-text (read 2026-11-25):
the endpoint, the model ids `whisper-large-v3` and `whisper-large-v3-turbo`, the accepted formats
(wav among them), the 25 MB free-tier limit, the 0.01 s minimum, the 224-token prompt limit,
`response_format=json`, and `temperature` (default 0).
