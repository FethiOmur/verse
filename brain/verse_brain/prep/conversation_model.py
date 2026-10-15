"""Model access for "prep from a conversation": the extract call (plain Sonnet) and the research call (Sonnet with the
Anthropic server-side `web_search` tool). Same client setup and key handling as `prep/model.py`; the key lives only in the
SDK client.

`ResearchOutput` carries what the code needs to check the model's claims: the final text, every URL the search tool
really returned (and the URLs the model cited), the queries it ran and the number of searches billed. A fact is
"sourced" only when its URL is in that set (see `conversation.verify_facts`).

Tool type: `web_search_20250305` (basic, direct calls). The newer `web_search_20260209/20260318` run the search inside
code execution (dynamic filtering) and nest the results in code-execution blocks; here every result block sits in the
response itself, which keeps the URL check simple. Override with VERSE_WEB_SEARCH_TOOL to try another version.
Pricing (platform docs, web search tool page): $10 per 1,000 searches plus the normal token cost of the results.
"""

from __future__ import annotations

import os
import re
import sys
from dataclasses import dataclass, field
from typing import Any, Protocol

from .model import PREP_MODEL, AnthropicPrepModel, ModelOutput, PrepError, Usage

SEARCH_USD = 0.01  # $10 per 1,000 searches
DEFAULT_MAX_SEARCHES = 8
MAX_CONTINUATIONS = 4  # pause_turn resumptions per research call
WEB_SEARCH_TOOL = os.environ.get("VERSE_WEB_SEARCH_TOOL") or "web_search_20250305"


@dataclass
class Page:
    url: str
    title: str = ""
    page_age: str = ""
    cited: list[str] = field(default_factory=list)  # cited_text snippets the model's citations pointed at


@dataclass
class ResearchOutput:
    text: str
    pages: dict[str, Page] = field(default_factory=dict)  # url -> page, in retrieval order
    queries: list[str] = field(default_factory=list)
    searches: int = 0
    errors: list[str] = field(default_factory=list)  # web_search_tool_result error codes
    usage: Usage = field(default_factory=Usage)
    stop_reason: str | None = "end_turn"


class ConversationModel(Protocol):
    model: str

    async def extract(self, system: str, user: str, max_tokens: int) -> ModelOutput: ...

    async def research(self, system: str, user: str, max_uses: int, max_tokens: int) -> ResearchOutput: ...


def _as_dict(block: Any) -> dict:
    if isinstance(block, dict):
        return block
    dump = getattr(block, "model_dump", None)
    return dump() if dump is not None else {}


def collect_sources(content: list[Any]) -> tuple[str, dict[str, Page], list[str], list[str]]:
    """(text, pages, queries, error codes) from a response's content blocks (SDK objects or the documented JSON dicts).

    `pages` holds every `web_search_result` url, then any cited url that was not among them (a citation always names a
    result, but the order of blocks is not relied on). Error results (`content` is an object, not a list) are listed in
    the error codes, never indexed."""
    text: list[str] = []
    pages: dict[str, Page] = {}
    queries: list[str] = []
    errors: list[str] = []
    for raw in content:
        b = _as_dict(raw)
        kind = b.get("type")
        if kind == "text":
            text.append(b.get("text") or "")
        elif kind == "server_tool_use" and b.get("name") == "web_search":
            q = (b.get("input") or {}).get("query")
            if q:
                queries.append(str(q))
        elif kind == "web_search_tool_result":
            res = b.get("content")
            if isinstance(res, list):
                for r in res:
                    r = _as_dict(r)
                    url = r.get("url")
                    if url and url not in pages:
                        pages[url] = Page(url, r.get("title") or "", r.get("page_age") or "")
            elif isinstance(res, dict) and res.get("error_code"):
                errors.append(str(res["error_code"]))
    for raw in content:
        b = _as_dict(raw)
        if b.get("type") != "text":
            continue
        for c in b.get("citations") or []:
            c = _as_dict(c)
            url = c.get("url")
            if not url:
                continue
            page = pages.setdefault(url, Page(url, c.get("title") or ""))
            snippet = (c.get("cited_text") or "").strip()
            if snippet and snippet not in page.cited:
                page.cited.append(snippet)
    return "".join(text), pages, queries, errors


class AnthropicConversationModel(AnthropicPrepModel):
    """Sonnet through the prep client. `extract` is the plain prep call; `research` adds the web_search server tool."""

    def __init__(self, api_key: str, model: str = PREP_MODEL, progress: bool = False) -> None:
        super().__init__(api_key, model, progress)

    async def extract(self, system: str, user: str, max_tokens: int) -> ModelOutput:
        return await self.generate(system, user, max_tokens)

    async def research(self, system: str, user: str, max_uses: int, max_tokens: int) -> ResearchOutput:
        messages: list[dict] = [{"role": "user", "content": user}]
        out = ResearchOutput("")
        texts: list[str] = []
        usage = Usage()
        for _ in range(MAX_CONTINUATIONS + 1):
            remaining = max_uses - out.searches
            if remaining <= 0:
                out.errors.append("search budget reached while the turn was still paused")
                break
            tool = {"type": WEB_SEARCH_TOOL, "name": "web_search", "max_uses": remaining}
            async with self._client.messages.stream(
                model=self.model, max_tokens=max_tokens, system=system, messages=messages, tools=[tool],
                thinking={"type": "adaptive"}, output_config={"effort": "high"},
            ) as stream:
                async for ev in stream:
                    if self._progress and getattr(ev, "type", "") == "content_block_stop":
                        b = _as_dict(getattr(ev, "content_block", None))
                        if b.get("type") == "server_tool_use" and (b.get("input") or {}).get("query"):
                            print(f"  search: {b['input']['query']}", file=sys.stderr, flush=True)
                final = await stream.get_final_message()
            u = final.usage
            usage.input += u.input_tokens or 0
            usage.output += u.output_tokens or 0
            usage.cache_read += getattr(u, "cache_read_input_tokens", 0) or 0
            usage.cache_write += getattr(u, "cache_creation_input_tokens", 0) or 0
            if final.stop_reason == "refusal":
                raise PrepError("the model refused the research request (stop_reason=refusal)")
            text, pages, queries, errors = collect_sources(list(final.content))
            texts.append(text)
            for url, p in pages.items():
                out.pages.setdefault(url, p)
            out.queries += queries
            out.errors += errors
            stu = getattr(u, "server_tool_use", None)
            billed = getattr(stu, "web_search_requests", None) if stu is not None else None
            out.searches += billed if isinstance(billed, int) else len(queries)
            out.stop_reason = final.stop_reason
            if final.stop_reason != "pause_turn":
                break
            messages.append({"role": "assistant", "content": list(final.content)})
        out.text = "\n".join(texts)
        out.usage = usage
        return out


# ---------------------------------------------------------------------------------------------- offline model

_NAME = r"[A-Z][\w'.-]+(?: [A-Z][\w'.-]+){0,2}"
# "**Mon 5 Oct 10:02 - Name (role)**" (LinkedIn paste) or "Name: text"
_SPEAKER = re.compile(rf"^\*\*[^*]*? [-–—] ({_NAME})\s*(?:\(.*\))?\*\*|^({_NAME}):")


class FakeConversationModel:
    """Deterministic offline stand-in (`--fake`): no network, no key, no spend. Extraction reads speaker names and one
    verbatim line from the thread; research returns two sourced facts, one fact without a source and one with a URL the
    search never returned, so the unverified path runs end to end."""

    model = PREP_MODEL
    free = True  # the cost report counts no searches

    async def extract(self, system: str, user: str, max_tokens: int) -> ModelOutput:
        import json

        thread = _between(user, "thread")
        owner = (re.search(r"The owner of the thread is ([^.\n]+)\.", user) or [None, ""])[1].strip()
        names: list[str] = []
        for ln in thread.splitlines():
            m = _SPEAKER.match(ln.strip())
            name = (m[1] or m[2]) if m else None
            if name and name not in names and name not in ("Company", owner):
                names.append(name)
        company = next((m[1].strip() for ln in thread.splitlines() if (m := re.match(r"^Company:\s*(.+)$", ln.strip()))),
                       "Example Co")
        quote = next((ln.strip() for ln in thread.splitlines() if 30 <= len(ln.strip()) <= 160), "")
        payload = {
            "title": f"Call with {names[0]}, {company}" if names else f"Call, {company}",
            "company": company, "role": None,
            "people": [{"name": n, "role": None, "company": company, "notes": None} for n in names[:3]],
            "what_they_want": ["To talk through the next step."],
            "meeting": {"purpose": "A first call to go through scope and setup.", "when": None, "format": None},
            "open_questions": ["What should the first month look like?"],
            "promises": [{"who": names[0] if names else "They", "text": "They will send a calendar invite."}],
            "candidate_said": ["Available to start soon."], "terms": [],
            "quotes": [{"who": names[0] if names else "They", "text": quote}] if quote else [],
        }
        return ModelOutput(json.dumps(payload), Usage(), "end_turn")

    async def research(self, system: str, user: str, max_uses: int, max_tokens: int) -> ResearchOutput:
        base = "https://example.com/about"
        text = "\n".join([
            "@FACT", "topic: company", "text: Example Co is a fictional company used for offline runs.", f"url: {base}", "@END",
            "@FACT", "topic: product", "text: Its product is a fictional dashboard for reports.",
            "url: https://example.com/product", "@END",
            "@FACT", "topic: size", "text: It has about forty people.", "url: none", "@END",
            "@FACT", "topic: funding", "text: It raised a fictional seed round.", "url: https://invented.example.net/seed", "@END",
            "@GAP", "text: Recent news was not found.", "@END",
        ])
        pages = {base: Page(base, "About Example Co"), "https://example.com/product": Page("https://example.com/product", "Product")}
        return ResearchOutput(text, pages, ["example co about", "example co product"], 2, [], Usage(), "end_turn")


def _between(text: str, tag: str) -> str:
    m = re.search(rf"<{tag}[^>]*>\n?(.*?)\n?</{tag}>", text, re.S)
    return m[1] if m else ""
