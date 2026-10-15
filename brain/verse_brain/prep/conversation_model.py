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

Web fetch: `web_fetch_20250910` (basic, direct), no extra charge beyond tokens; capped by `max_uses` (fetches) and
`max_content_tokens` per page. It can only fetch URLs that already appeared in the conversation: the company URL in the
user message, URLs from search results and links on pages it fetched. The fetched page text comes back in the response, so
the code can check a fact's evidence quote against it. It does not run JavaScript: a chat widget or script tag is not
visible in the text.
"""

from __future__ import annotations

import asyncio
import os
import re
import sys
from dataclasses import dataclass, field
from typing import Any, Awaitable, Callable, Protocol, TypeVar

from .model import PREP_MODEL, AnthropicPrepModel, ModelOutput, PrepError, Usage

SEARCH_USD = 0.01  # $10 per 1,000 searches
DEFAULT_MAX_SEARCHES = 8
DEFAULT_MAX_FETCHES = 5
FETCH_CONTENT_TOKENS = 15_000
MAX_PAGE_TEXT_CHARS = 120_000
MAX_CONTINUATIONS = 4  # pause_turn resumptions per research call
WEB_SEARCH_TOOL = os.environ.get("VERSE_WEB_SEARCH_TOOL") or "web_search_20250305"
WEB_FETCH_TOOL = os.environ.get("VERSE_WEB_FETCH_TOOL") or "web_fetch_20250910"


@dataclass
class Page:
    url: str
    title: str = ""
    page_age: str = ""
    cited: list[str] = field(default_factory=list)  # cited_text snippets the model's citations pointed at
    text: str = ""  # the page text, only for pages the fetch tool returned (lets the code check evidence quotes)
    fetched: bool = False


@dataclass
class ResearchOutput:
    text: str
    pages: dict[str, Page] = field(default_factory=dict)  # url -> page, in retrieval order
    queries: list[str] = field(default_factory=list)
    searches: int = 0
    errors: list[str] = field(default_factory=list)  # web_search / web_fetch error codes
    fetches: list[str] = field(default_factory=list)  # URLs the model asked the fetch tool for
    fetch_count: int = 0
    usage: Usage = field(default_factory=Usage)
    stop_reason: str | None = "end_turn"


T = TypeVar("T")
RETRY_ATTEMPTS = 3  # tries per streaming call (the first plus two more)
RETRY_DELAY_S = 5.0


def _transient_types() -> tuple[type[BaseException], ...]:
    """Errors a streaming call can die with after it started: the SDK's connection, timeout and 5xx errors, and the raw
    transport errors of the HTTP client (a dropped or stalled stream raises those unwrapped, often with an empty message).
    The SDK's own retries cover only the request that opens the stream."""
    import anthropic
    import httpx2

    return (anthropic.APIConnectionError, anthropic.APITimeoutError, anthropic.InternalServerError,
            getattr(httpx2, "TransportError", httpx2.HTTPError), ConnectionError, TimeoutError)


def describe_error(e: BaseException) -> str:
    """`ReadTimeout: ...` even when the exception text is empty."""
    return f"{type(e).__name__}: {str(e) or repr(e)}"


async def retry_transient(call: Callable[[], Awaitable[T]], *, attempts: int = RETRY_ATTEMPTS, delay: float = RETRY_DELAY_S,
                          log: Callable[[str], None] | None = None) -> T:
    """Runs `call`, trying again (after `delay` seconds, doubling) when it dies with a transient transport error. Any other
    error, and the last transient one, propagate."""
    transient = _transient_types()
    for i in range(attempts):
        try:
            return await call()
        except transient as e:
            if i == attempts - 1:
                raise
            (log or (lambda m: print(m, file=sys.stderr, flush=True)))(
                f"warning: {describe_error(e)}; trying again ({i + 2}/{attempts})")
            await asyncio.sleep(delay * 2**i)
    raise AssertionError("unreachable")


class ConversationModel(Protocol):
    model: str

    async def extract(self, system: str, user: str, max_tokens: int) -> ModelOutput: ...

    async def research(self, system: str, user: str, max_uses: int, max_fetches: int, max_tokens: int) -> ResearchOutput: ...


def _as_dict(block: Any) -> dict:
    if isinstance(block, dict):
        return block
    dump = getattr(block, "model_dump", None)
    return dump() if dump is not None else {}


@dataclass
class Collected:
    text: str = ""
    pages: dict[str, Page] = field(default_factory=dict)
    queries: list[str] = field(default_factory=list)
    fetches: list[str] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)


def collect_sources(content: list[Any]) -> Collected:
    """Text, pages, queries, fetched URLs and error codes from a response's content blocks (SDK objects or the documented
    JSON dicts).

    `pages` holds every `web_search_result` url and every `web_fetch_result` url (with its page text), then any cited url
    that was not among them (a citation always names a result, but the order of blocks is not relied on). Error results
    (`content` is an object, not a list, or a `*_error` object) are listed in `errors`, never indexed."""
    out = Collected()
    text: list[str] = []
    for raw in content:
        b = _as_dict(raw)
        kind = b.get("type")
        if kind == "text":
            text.append(b.get("text") or "")
        elif kind == "server_tool_use" and b.get("name") == "web_search":
            q = (b.get("input") or {}).get("query")
            if q:
                out.queries.append(str(q))
        elif kind == "server_tool_use" and b.get("name") == "web_fetch":
            u = (b.get("input") or {}).get("url")
            if u:
                out.fetches.append(str(u))
        elif kind == "web_search_tool_result":
            res = b.get("content")
            if isinstance(res, list):
                for r in res:
                    r = _as_dict(r)
                    url = r.get("url")
                    if url and url not in out.pages:
                        out.pages[url] = Page(url, r.get("title") or "", r.get("page_age") or "")
            elif isinstance(res, dict) and res.get("error_code"):
                out.errors.append(f"web_search: {res['error_code']}")
        elif kind == "web_fetch_tool_result":
            res = _as_dict(b.get("content"))
            if res.get("error_code"):
                out.errors.append(f"web_fetch: {res['error_code']}")
            elif res.get("url"):
                doc = _as_dict(res.get("content"))
                src = _as_dict(doc.get("source"))
                body = src.get("data") if src.get("type") == "text" and isinstance(src.get("data"), str) else ""
                page = out.pages.setdefault(res["url"], Page(res["url"]))
                page.title = page.title or doc.get("title") or ""
                page.text, page.fetched = body[:MAX_PAGE_TEXT_CHARS], True
    for raw in content:
        b = _as_dict(raw)
        if b.get("type") != "text":
            continue
        for c in b.get("citations") or []:
            c = _as_dict(c)
            url = c.get("url")
            if not url:
                continue
            page = out.pages.setdefault(url, Page(url, c.get("title") or ""))
            snippet = (c.get("cited_text") or "").strip()
            if snippet and snippet not in page.cited:
                page.cited.append(snippet)
    out.text = "".join(text)
    return out


class AnthropicConversationModel(AnthropicPrepModel):
    """Sonnet through the prep client. `extract` is the plain prep call; `research` adds the web_search server tool."""

    def __init__(self, api_key: str, model: str = PREP_MODEL, progress: bool = False) -> None:
        super().__init__(api_key, model, progress)

    async def generate(self, system: str, user: str, max_tokens: int) -> ModelOutput:
        return await retry_transient(lambda: super(AnthropicConversationModel, self).generate(system, user, max_tokens))

    async def extract(self, system: str, user: str, max_tokens: int) -> ModelOutput:
        return await self.generate(system, user, max_tokens)

    async def _stream_turn(self, system: str, messages: list[dict], tools: list[dict], max_tokens: int):
        """One streaming request with the research tools; returns the final message."""
        async with self._client.messages.stream(
            model=self.model, max_tokens=max_tokens, system=system, messages=messages, tools=tools,
            thinking={"type": "adaptive"}, output_config={"effort": "high"},
        ) as stream:
            async for ev in stream:
                if self._progress and getattr(ev, "type", "") == "content_block_stop":
                    b = _as_dict(getattr(ev, "content_block", None))
                    inp = b.get("input") or {}
                    if b.get("type") == "server_tool_use" and inp.get("query"):
                        print(f"  search: {inp['query']}", file=sys.stderr, flush=True)
                    elif b.get("type") == "server_tool_use" and inp.get("url"):
                        print(f"  fetch: {inp['url']}", file=sys.stderr, flush=True)
            return await stream.get_final_message()

    async def research(self, system: str, user: str, max_uses: int, max_fetches: int, max_tokens: int) -> ResearchOutput:
        messages: list[dict] = [{"role": "user", "content": user}]
        out = ResearchOutput("")
        texts: list[str] = []
        usage = Usage()
        for _ in range(MAX_CONTINUATIONS + 1):
            searches_left, fetches_left = max_uses - out.searches, max_fetches - out.fetch_count
            if searches_left <= 0 and fetches_left <= 0:
                out.errors.append("tool budget reached while the turn was still paused")
                break
            tools: list[dict] = []
            if searches_left > 0:
                tools.append({"type": WEB_SEARCH_TOOL, "name": "web_search", "max_uses": searches_left})
            if fetches_left > 0:
                tools.append({"type": WEB_FETCH_TOOL, "name": "web_fetch", "max_uses": fetches_left,
                              "max_content_tokens": FETCH_CONTENT_TOKENS})
            final = await retry_transient(lambda: self._stream_turn(system, messages, tools, max_tokens))
            u = final.usage
            usage.input += u.input_tokens or 0
            usage.output += u.output_tokens or 0
            usage.cache_read += getattr(u, "cache_read_input_tokens", 0) or 0
            usage.cache_write += getattr(u, "cache_creation_input_tokens", 0) or 0
            if final.stop_reason == "refusal":
                raise PrepError("the model refused the research request (stop_reason=refusal)")
            got = collect_sources(list(final.content))
            texts.append(got.text)
            for url, p in got.pages.items():
                if url in out.pages:
                    old = out.pages[url]
                    old.text, old.fetched = old.text or p.text, old.fetched or p.fetched
                    old.cited += [c for c in p.cited if c not in old.cited]
                else:
                    out.pages[url] = p
            out.queries += got.queries
            out.fetches += got.fetches
            out.errors += got.errors
            stu = getattr(u, "server_tool_use", None)
            billed = getattr(stu, "web_search_requests", None) if stu is not None else None
            fetched = getattr(stu, "web_fetch_requests", None) if stu is not None else None
            out.searches += billed if isinstance(billed, int) else len(got.queries)
            out.fetch_count += fetched if isinstance(fetched, int) else len(got.fetches)
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

    async def research(self, system: str, user: str, max_uses: int, max_fetches: int, max_tokens: int) -> ResearchOutput:
        base = "https://example.com/about"
        about_text = "Example Co is a fictional company used for offline runs. Example Co Ltd, registered in Delaware."
        text = "\n".join([
            "@FACT", "topic: company", "text: Example Co is a fictional company used for offline runs.", f"url: {base}",
            "evidence: Example Co is a fictional company used for offline runs.", "@END",
            "@FACT", "topic: entity", "text: The legal entity is Example Co Ltd, registered in Delaware.", f"url: {base}",
            "evidence: Example Co Ltd, registered in Delaware.", "@END",
            "@FACT", "topic: entity", "text: Its head office is in Atlantis.", "url: https://www.facebook.com/exampleco",
            "evidence: Atlantis", "@END",
            "@FACT", "topic: product", "text: Its product is a fictional dashboard for reports.",
            "url: https://example.com/product", "@END",
            "@FACT", "topic: funding", "text: It raised a fictional seed round.", "url: https://invented.example.net/seed", "@END",
            "@INFER", "text: It is probably a small founder-led team.", "basis: no public team page", "@END",
            "@GAP", "text: Recent news was not found.", "@END",
        ])
        pages = {base: Page(base, "About Example Co", text=about_text, fetched=True),
                 "https://example.com/product": Page("https://example.com/product", "Product"),
                 "https://www.facebook.com/exampleco": Page("https://www.facebook.com/exampleco", "Example Co")}
        return ResearchOutput(text, pages, ["example co product"], 1, [], [base], 1, Usage(), "end_turn")


def _between(text: str, tag: str) -> str:
    m = re.search(rf"<{tag}[^>]*>\n?(.*?)\n?</{tag}>", text, re.S)
    return m[1] if m else ""
