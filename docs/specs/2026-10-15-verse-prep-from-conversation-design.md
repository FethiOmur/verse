# Verse: prep from a conversation

Status: decided 2026-10-15. the owner's rule: after a spec, build. GENERAL AGENT item #16.

## 1. Goal

Turn the manual Mara pipeline into one step. That pipeline (14 Oct) was: LinkedIn thread → company and technical research → prep note → Verse session. It lives in
`~/Workspace/NorthwindLabs_Mara/` (`linkedin_messages_mara.md`, `research_company.md`,
`research_technical.md`, `prep_note.md`), which is the reference output. Alex pastes a conversation (LinkedIn or
email thread) plus, optionally, a posting link and a company URL. Verse builds a ready meeting session whose answers
are in his voice.

## 2. Decisions

| Topic | Decision |
|---|---|
| Inputs | Required: conversation text, pasted. Optional: posting URL (fetched by the app with `VersePosting`, or pasted text), company URL, a free note. |
| Pipeline | 1) **Extract** (Sonnet): the people, company, role, what they want from Alex, the meeting's likely purpose, open questions, and promises made in the thread. 2) **Research** (Sonnet with the Anthropic server-side `web_search` tool, max 8 searches): company facts, product, size, funding, recent news, tech stack, and the people's public roles. Every fact must carry its source URL. 3) **Prep note**: a `prep_note.md` in the format the meeting prep already reads (`--prep-note`), with "unverified" marked wherever a source is weak. 4) **Existing meeting prep** (`--prep-note`, repos, vault, voice profile) builds the session. |
| Where | Brain: `python -m verse_brain.prep conversation --thread FILE [--posting-file F] [--posting-url U] [--company-url U] [--note F] [--fake]`. Stdout is the session folder. The research files are kept in the session folder (`research.md` with sources, `thread.md`). |
| App | Menu "New session from a conversation…" opens a window: paste box, posting link with Fetch (as in the sim setup), company URL, and Prepare. It shows progress and warnings, then selects the new session as the current one. Reuse the sim setup's prep runner pattern; keys never go on argv. |
| Spend | No cap (Alex). Report the cost per run, including the search count. |
| Privacy | Thread text stays local in the session folder. Only the model calls see it. Never commit it to the repo; fixtures are fictional. |
| Fallback | No local Gemma for this command: research needs the web. A failure shows in the window. |

Rejected: our own scraper or search API (the Anthropic tool is one key and one bill), and writing the research into the vault (keep it in the session; the vault write stays opt-in).

## 3. Tests

- Extract on a fictional thread fixture: people, company, role and promises.
- Research with a fake transport: every fact line carries a URL, and a missing URL becomes "unverified".
- The prep note parses with the existing prep note reader.
- End to end with `--fake` produces a session folder.
- App: the window model runs the runner (fake) and selects the session.
- One live run on the Mara thread (`linkedin_messages_mara.md`, local file, never committed), compared with the hand-made `research_company.md` / `prep_note.md`: what it found, what it missed, and cost.

## 4. Done means

From the menu, paste the Mara thread, press Prepare, and a session appears with sourced research and answers in the owner's voice, at a reported cost.
