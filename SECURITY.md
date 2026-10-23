# Security policy

## Reporting a vulnerability

Please report vulnerabilities privately with GitHub private vulnerability reporting: open the repository's **Security** tab, then **Report a vulnerability**. Do not open a public issue for a security problem.

Include what you found, the steps to reproduce it, and the impact you expect.

## Scope

In scope:

- Handling of API keys: Verse stores the Anthropic, OpenAI and ElevenLabs keys in the macOS Keychain. Anything that leaks, logs or writes a key elsewhere is a vulnerability.
- Local data under `~/Library/Application Support/Verse` (sessions, transcripts, profile) and anything that exposes it unintentionally.
- Unintended network traffic, or audio written to disk.

Out of scope: issues in Anthropic, OpenAI or ElevenLabs services, and in third-party dependencies (report those upstream).

## Supported versions

Only the latest `main` is supported.
