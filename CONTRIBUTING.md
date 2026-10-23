# Contributing to Verse

Thanks for your interest. Verse is a small project maintained by one person, so small and focused contributions are the easiest to review.

## Dev setup

Requirements are listed in the [README](README.md#requirements). In short:

```sh
cd brain
python3 -m venv .venv
.venv/bin/pip install -e ".[dev]"
cd ../app
swift build
```

To run the bundled app, use `app/scripts/bundle-app.sh`. You need your own Anthropic key in the Keychain (see the README).

## Running targeted tests

Run only the tests for the code you changed.

```sh
# Swift: one test target or one test
cd app
swift test --filter VersePrompterTests
swift test --filter VerseTurnsTests/SomeTestName

# Brain (Python)
cd brain
.venv/bin/python -m pytest tests/test_some_file.py
```

Swift test targets are defined in `app/Package.swift`; brain tests are in `brain/tests`. Please do not make full-suite runs a requirement for small changes.

## Code style

- Code, comments, commit messages and docs are in English.
- Swift targets use Swift 6 language mode.
- UI strings live in the String Catalog `app/Sources/VerseUI/Resources/Localizable.xcstrings` with English, Italian and Turkish. After changing UI strings, run:

  ```sh
  python3 app/scripts/l10n-check.py
  ```

  It fails when a key lacks an `it` or `tr` translation or a placeholder does not match the English string. See also [docs/l10n-glossary.md](docs/l10n-glossary.md).
- Follow the style of the file you are editing. Keep comments that explain why, not what.

## Pull requests

- Keep PRs small and about one thing.
- Add or update tests for the code you changed, and say which tests you ran.
- Never commit API keys, audio, or real meeting transcripts. Fixtures must be fictional.
- If you change UI strings, run the l10n check.
- Fill in the pull request template.

## Issues and triage

Use the issue templates. The maintainer reads new issues and labels them as bug, feature or question. Bugs with clear reproduction steps come first; feature requests are weighed against the [roadmap](README.md#roadmap). Small, well-scoped tasks may be labelled `good first issue`. Response times are best-effort.

## Conduct and security

Be kind: see the [Code of Conduct](CODE_OF_CONDUCT.md). Report vulnerabilities privately as described in [SECURITY.md](SECURITY.md), not in public issues.
