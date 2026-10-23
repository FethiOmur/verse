# Verse

A native macOS meeting and interview assistant that shows answer cards in the notch while you speak.

<!-- screenshots: added with the first release -->

## What Verse does

- **Live notch answer cards.** When the other side asks a question, Verse shows a suggested answer in a teleprompter-style card at the notch, then follows your reading and strikes points as you say them.
- **Prep packs.** Build a pack for a meeting from a note, a repository or a calendar event.
- **A permanent "me" profile.** Facts about you that persist across meetings and feed the prep and the live answers.
- **Practice.** Spoken mock interviews: an interviewer asks, you answer aloud, and a report follows.
- **After the call.** Summary, transcript, and an Ask panel to question the meeting.
- **Session folders** to organise past sessions.
- **Interface languages:** English, Italian and Turkish.

The design documents are in [docs/specs](docs/specs/). Start with the [v1 design](docs/specs/2026-10-14-verse-meeting-assistant-v1-design.md).

## Status

Verse is built by one person for his own meetings and interviews. It is being generalised for other users. Expect rough edges.

## Requirements

- Apple Silicon Mac
- macOS 26.0 or later (`app/Package.swift`)
- Xcode with a Swift 6.2 toolchain or later (`swift-tools-version: 6.2`)
- Python 3.12 or later (`brain/pyproject.toml`)
- An Anthropic API key

## Build from source

```sh
# 1. Brain (Python)
cd brain
python3 -m venv .venv
.venv/bin/pip install -e ".[dev]"
cd ..

# 2. App (Swift)
cd app
swift build

# 3. Bundle the menu-bar app into app/build/Verse.app (ad-hoc signed)
scripts/bundle-app.sh
```

`bundle-app.sh` records the repo's `brain/` folder in the app's Info.plist. Set `VERSE_BRAIN_DIR=/path/to/brain` to use a different folder at run time or at bundle time.

## Your Anthropic API key

Verse's brain runs on Claude and uses your own Anthropic API key. The key is stored in the macOS Keychain under the service `verse-anthropic` and is never written to a file or committed.

Add it in Verse's Settings, or from a terminal:

```sh
security add-generic-password -a "$USER" -s verse-anthropic -w
```

Because `-w` has no value, `security` prompts for the key instead of putting it in your shell history.

### Optional voice keys

The practice interviewer can speak with Apple's voice, or with OpenAI or ElevenLabs text-to-speech. Those keys are optional and live in the Keychain services `verse-openai` and `verse-elevenlabs`, added the same way as above.

## Privacy

What leaves your machine:

- Text sent to Anthropic for the brain: transcript text, your prep and profile, and your questions.
- Optional: the interviewer's spoken lines, as text, sent to OpenAI or ElevenLabs if you pick one of those voices.

What does not:

- No audio is written to disk. Audio stays in memory long enough to be transcribed.
- No telemetry: Verse contains no analytics or tracking code.
- Everything else (sessions, transcripts, profile, models) is stored locally under `~/Library/Application Support/Verse`.

## Known limitations today

- Owner-specific paths and prompts remain in the code and docs; they are being turned into settings.
- The local Nemotron speech model is set up by hand (it is not downloaded by the app).
- Builds are unsigned (ad-hoc signed) until the signed release lands.

## Roadmap

- Stranger-friendly setup and a signed release.
- System audio capture for Zoom, Meet and Teams.
- Cross-meeting memory: Ask across all meetings with citations, pre-meeting briefs, people and company pages (in progress).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) and the [Code of Conduct](CODE_OF_CONDUCT.md). Report security issues as described in [SECURITY.md](SECURITY.md). The previous owner-specific README is kept in [docs/owner-setup.md](docs/owner-setup.md).

## Licence

MIT, see [LICENSE](LICENSE). Third-party components and notices: [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES) and [docs/licences.md](docs/licences.md).
