"""F6 prompt material: the S/F route prompt of the brain (read-only import of brain/verse_brain/runtime/prompt.py),
the sample session's pack.md, 6 finalized turns, 10 questions. Flattened to one system + one user text for Gemma."""
from __future__ import annotations
import importlib.util, os

SESSION = os.path.expanduser("~/Library/Application Support/Verse/sessions/sample-interview")
BRAIN = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", "brain", "verse_brain", "runtime", "prompt.py"))

_spec = importlib.util.spec_from_file_location("verse_prompt_ro", BRAIN)
import sys
P = importlib.util.module_from_spec(_spec); sys.modules["verse_prompt_ro"] = P; _spec.loader.exec_module(P)
Turn = P.Turn

PACK = open(os.path.join(SESSION, "pack.md"), encoding="utf-8").read()

TURNS = [
    Turn("r1", "remote", "Thanks for joining, Alex. I'm Ingrid, I lead engineering here, and Tomas from the platform team is with me today."),
    Turn("m1", "me", "Thanks for having me, I'm happy to be here."),
    Turn("r2", "remote", "We have about forty minutes. First, can you give us a quick overview of what you have been working on recently?"),
    Turn("m2", "me", "Sure. The main thing was Lantern, an LLM pipeline for supplier invoices, and a small route optimiser for a courier pilot."),
    Turn("r3", "remote", "Interesting. We have been moving our dispatch from rules to something LLM assisted, so that is relevant for us."),
    Turn("m3", "me", "That is exactly what drew me to Halden."),
]

# earlier meeting history, used only to reach the longer prompt lengths
EXTRA_TURNS = [
    Turn("r0a", "remote", "Before we start, a quick note on how we run these sessions. We keep it conversational, and Tomas will ask the technical questions."),
    Turn("m0a", "me", "That sounds good to me."),
    Turn("r0b", "remote", "Great. Halden has about a hundred and forty people, and the AI team is small and sits close to the product."),
    Turn("m0b", "me", "I read about the team on your site, it looks like a focused group."),
    Turn("r0c", "remote", "It is. We ship every two weeks and we try to keep the process light, with one design review per feature."),
    Turn("m0c", "me", "I like that. Short cycles suit the way I work."),
    Turn("r0d", "remote", "Tomas, do you want to say a word about the platform before we get into questions?"),
    Turn("r0e", "remote", "Sure. The platform team owns the routing engine and the data pipeline, and we are the main consumers of whatever the AI team builds."),
    Turn("m0e", "me", "Understood. I would be curious how the two teams hand work over."),
    Turn("r0f", "remote", "Mostly through a shared backlog and a weekly sync, nothing fancy. We can talk about that at the end."),
    Turn("m0f", "me", "Perfect, I have a few questions on that too."),
    Turn("r0g", "remote", "Good. Then let us make a start with some background questions."),
    Turn("m0g", "me", "Ready when you are."),
    Turn("r0h", "remote", "One more housekeeping item: this call is not recorded, but I will take notes for the hiring committee."),
]

QUESTIONS = [
    ("q01", "Could you describe Lantern for us?", "grounded"),
    ("q02", "Did Lantern actually move the needle? Show us figures.", "grounded"),
    ("q03", "What do you do when the model gives a bad or uncertain answer?", "grounded"),
    ("q04", "How expensive was the inference compared with the labour it replaced?", "grounded"),
    ("q05", "Assuming an offer, what is the soonest you could be on board?", "grounded"),
    ("q06", "What kind of package would you want?", "grounded"),
    ("q07", "Where does your past work overlap with routing and logistics?", "grounded"),
    ("q08", "Name an area where you are not as strong as you would like to be.", "grounded"),
    ("q09", "Do you have experience with Kubernetes and container orchestration?", "trap_not_in_pack"),
    ("q10", "How many people were on the Lantern team, and what did you personally build?", "trap_not_in_pack"),
]


def trimmed_pack(max_chars: int) -> str:
    """The pack cut at an entry boundary: facts + glossary kept whole, the answer bank cut to fit."""
    head, bank = PACK.split("## ANSWER BANK", 1)
    out = head + "## ANSWER BANK"
    for part in bank.split("\n[b"):
        piece = part if part.startswith("\n") else "\n[b" + part
        if len(out) + len(piece) > max_chars:
            break
        out += piece
    return out


def render(system: str, pack: str, turns, question: str):
    """-> (system_text, user_text). Same content as the Anthropic request of the brain, blocks joined by newlines."""
    parts = [P.PACK_HEADER + pack + P.TRANSCRIPT_HEADER]
    parts += [P.turn_block_text(t) for t in turns]
    parts.append(P.fast_tail(question, "en", True))
    return system, "\n".join(parts)


def prefix_and_tail(system: str, pack: str, turns, question: str):
    """The cacheable prefix (pack + transcript) and the per-question tail, for the warm-KV measurement."""
    prefix = P.PACK_HEADER + pack + P.TRANSCRIPT_HEADER + "\n".join(P.turn_block_text(t) for t in turns) + "\n"
    return system, prefix, P.fast_tail(question, "en", True)
