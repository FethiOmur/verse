# Verse as an open-source project: spec and plan

Date: 2026-10-23. Source brief: `~/Workspace/Verse_OSS/BRIEF_2026-10-23.md` (general session).
Goal: make Verse a real open-source project that can later apply to Anthropic's Claude for Open Source and
OpenAI's Codex for Open Source on honest evidence (users, external contributors, open maintenance).

## Decisions (Alex, 2026-10-23)

| Topic | Decision |
|---|---|
| Licence | MIT |
| Repo | Keep `FethiOmur/verse`, publish the full history as is (197 commits) |
| Privacy | No scrub of personal paths, names or docs before going public; generalise gradually |
| Brain | Stays Claude-first; no OpenAI brain for the applications |
| Signing | Developer ID: Alex has or will get one; releases are signed and notarised |
| Timing | Flip public when Phase A is done; apply after Phase C has real numbers |

Standing constraint: after every phase the owner's own setup works exactly as today (vault, Individual Org key in Keychain
item `verse-anthropic`, his prompts and profile). Never put invented usage numbers in the README or the applications.

## Pre-flight check done (2026-10-23)

- `gitleaks git` over the whole history: no leaks. A manual grep for Anthropic/OpenAI/ElevenLabs/AWS key shapes found
  one hit, the sentinel `sk-ant-api03-SENT…-KEY` inside a test (`test_no_secrets`), not a real key.
- Known and accepted by Alex: owner paths (`/Users/user`), his name in prompts and UI copy, an OpenAI org ID in
  bench/spec files, job-target names in docs, and history that once held fragments later replaced with fiction.

## Phase A: legally open source (now)

1. `LICENSE` (MIT, copyright Alex Rivera). Check `docs/licences.md` and `THIRD_PARTY_NOTICES` stay compatible
   (Textream MIT, Moonglade notice) and link them from the README.
2. Public `README.md`: what Verse is (live notch answer cards that follow your reading, prep packs, mock interviews,
   meeting memory), screenshots from the fictional renders, requirements (Apple Silicon, macOS version from
   `Package.swift`), build-from-source steps, bring-your-own Anthropic key, what leaves the machine (Anthropic for the
   brain; optional OpenAI/ElevenLabs TTS; no audio stored; no telemetry), honest status ("built for one person, being
   generalised"), roadmap, contributing. The owner-specific README moves to `docs/owner-setup.md`.
3. `CONTRIBUTING.md`, `CODE_OF_CONDUCT.md` (Contributor Covenant 2.1), `SECURITY.md` (private report via GitHub
   security advisories), `.github/ISSUE_TEMPLATE/{bug,feature}.yml`, `.github/pull_request_template.md`.
4. Alex flips the repo to public in GitHub settings (his action), then turns on private vulnerability reporting.

Acceptance: files present, README renders on GitHub, links resolve, `swift build` and the brain tests untouched.

## Phase B: a stranger can install and run it

1. Owner values become settings that default to the owner's current values: vault path (optional), user display name
   (replaces the hard-coded name in brain prompts and UI copy), model choices.
2. First-run onboarding: paste an Anthropic key (stored in Keychain), optional OpenAI/ElevenLabs key; friendly errors
   for a missing or rejected key (the raw 401 seen on 21 Oct becomes "Your Anthropic key was rejected").
3. `scripts/setup.sh`: creates the brain `.venv` and installs dependencies; downloads the Nemotron model or falls back
   to Apple speech with a note.
4. Signed and notarised `.app` (Developer ID) zipped and attached to a GitHub Release by a release script.
5. Acceptance: a clean macOS user account (no vault, no owner paths) installs the release, adds a key, prepares a
   meeting from a note and runs a practice interview. the owner's account still works unchanged.

## Phase C: visible open maintenance (4–8 weeks)

1. Tagged releases with changelogs; a short demo video in the README.
2. `good first issue` labels on real small tasks (e.g. strings, docs, small UI polish).
3. Codex wired into maintenance (PR review and issue triage on this repo), so the Codex application describes a
   workflow that already runs.
4. Track real numbers monthly: stars, clones, release downloads, external PRs merged, issues closed.

## Phase D: applications

- Codex for OSS: public profile and repo, OpenAI Organization ID, two ≤ 500-character answers from real numbers.
- Claude for OSS: the "apply anyway" door with the maintenance and contributor evidence.
- Alex decides when; drafts are written from the Phase C numbers only.

## Execution

- Phase A is docs only: LICENSE by the main session; README and community files by one executor (Antigravity pool,
  Sonnet) with this spec as its contract; the main session reviews and commits.
- Phase B is planned as packages after Phase A lands (it touches Swift, the brain prompts and release tooling).
