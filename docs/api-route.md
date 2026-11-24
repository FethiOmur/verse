# API route: proxy base URL and direct-API fallback

The brain (`brain/verse_brain`) talks to Claude through the Anthropic SDK. By default every client goes to `api.anthropic.com` with
the key in the Keychain item `verse-anthropic` (the one the app's Settings screen saves). One optional setting changes that: an
**API base URL**, for example a local Anthropic-compatible proxy. With it, every request goes to the proxy first, and when the proxy
fails the same request goes to `api.anthropic.com` with your Anthropic key from `verse-anthropic`. That key is never sent to the
proxy; the proxy gets its own key from the optional item `verse-anthropic-proxy`.

The code is `brain/verse_brain/apiroute.py`; the clients that use it are the live transport (`runtime/transport.py`), the ask/memory/
brief/persona client (`runtime/ask.py`) and the prep models (`prep/model.py` and its subclasses).

## Configuration

### Base URL

Read once when a client is built (each brain process builds its clients at start):

| Source | Rule |
|---|---|
| `VERSE_API_BASE_URL` (environment) | When the variable is set it wins. An empty value means "no base URL", whatever the file says. |
| `~/Library/Application Support/Verse/api.json` | `{"base_url": "http://127.0.0.1:8317"}`. Used when the variable is not set. `VERSE_API_CONFIG_FILE` moves the file (tests use this). |

Unset, empty, unreadable, or not an `http://` / `https://` URL: no base URL, and the behaviour is exactly what it was before (the
direct path is not even wrapped). A URL with a user name, password, query or fragment is ignored too. The value is never logged.
Today nothing in the app writes `api.json` or the proxy item: both are set by hand, and the brain picks a change up at its next
start. The proxy must serve the same model ids (`claude-sonnet-5-5`, `claude-haiku-5-5`, `claude-opus-5-5`); there is no model
mapping.

`http://` sends the proxy's key in clear text. That is fine for a proxy on `127.0.0.1` / `localhost`; for any other host the brain
logs a warning, and you should use `https://`.

### Keys (macOS Keychain, account = your user name)

| Item (service) | Holds | Read when | Sent to |
|---|---|---|---|
| `verse-anthropic` | your **Anthropic** API key (the app's Settings screen saves it here) | always; required | `api.anthropic.com` only: the direct route without a base URL, the fallback with one |
| `verse-anthropic-proxy` | the **proxy's** key (optional) | only when a base URL is set | the base URL only |

If your proxy checks a client key, add it without putting it in your shell history (`-w` with no value prompts for it):

```sh
security add-generic-password -a "$USER" -s verse-anthropic-proxy -w
```

| Setup | Result |
|---|---|
| no base URL | direct API with `verse-anthropic`; the proxy item is ignored (not even read) |
| base URL + proxy item | proxy with the proxy key first, direct API with `verse-anthropic` when the proxy fails |
| base URL, no proxy item | the same, but the proxy gets the placeholder key `verse-proxy-no-key` (a warning is logged). A proxy that ignores the key works; one that checks it answers 401, which counts as a proxy failure, so requests run on the direct API and the proxy is probed once per cool-off |
| no `verse-anthropic` item | `status error` with reason `no_api_key`, as before, with or without a base URL and proxy item |

Upgrading from the first version of this feature: it used `verse-anthropic` as the proxy's key and an item called
`verse-anthropic-fallback` for the Anthropic key. That layout is gone. Put your Anthropic key back in `verse-anthropic` (or save it
in the app's Settings), the proxy's key, if any, in `verse-anthropic-proxy`, and delete `verse-anthropic-fallback`, which is no
longer read.

## What counts as a proxy failure

Fails over to the direct API:

- connection refused or reset, connect or read timeout (`offline`, `timeout`)
- HTTP 401 / 403 (`auth`), 429 (`rate_limited`), 5xx and `overloaded_error` (`overloaded`), 402 / billing errors (`credit`: the
  proxy's account, not your Anthropic key's)
- a stream that breaks before the message is complete: a transport error mid-stream, or a stream that ends without a stop reason
  (`stream_broken`)
- HTTP 404 / 405 (`not_supported`): the proxy lacks that endpoint (for example `count_tokens`). Only that one request goes direct;
  the proxy stays primary and there is no cool-off.

Stays on the proxy and is returned to the caller: other 400-class request errors (400, 413, 422, ...), which the direct API would
reject too.

## Cool-off

After a failover, new requests go straight to the direct API for **60 s** (`COOL_OFF_S`). Then exactly one request probes the
proxy (requests made while it is in flight stay on the direct API): if it fails, the cool-off starts again; if it succeeds, the
proxy is primary again. Only that probe can switch back: a proxy request that started before the failover and succeeds late
changes nothing, so a flapping proxy does not cancel the cool-off. A dead proxy therefore costs one failed attempt per minute, not
one per request.

The proxy clients connect with a **1 s** timeout and with SDK retries off, so a refused or unreachable port fails over at once; the
direct clients keep their usual timeouts and retries. A proxy that accepts the connection and then goes quiet (an upstream stall)
is caught by the stall guards below, not by the read timeout. On the live cards and in the ask panel, a proxy that sends nothing
costs the hedge delay (**1.5 s**, longer only when the proxy itself has recently been that slow, see below) plus the direct API's
own time to first content, about 2 s end to end in a measured run and 2.5-3 s on a fresh connection; so does a proxy that sends its
headers or `message_start` and then nothing. A proxy that has sent content and then stops costs the idle limit (**6 s**) plus the
direct API's first content. The probe after a cool-off is guarded the same way.

## Stalls

A proxy that accepted the request but sends nothing is raced or timed out instead of waited for. The guards live in
`brain/verse_brain/apiroute.py`; each is a constant there with an environment variable that overrides it when a client is built
(each brain process builds its clients at start). `0` turns a guard off; a value that is not a number is ignored with a warning.

| Guard | Default | Variable | Where | What happens |
|---|---|---|---|---|
| Hedged start | 1.5 s (`HEDGE_S`) | `VERSE_API_HEDGE_S` | live cards, ask panel | No first content from the proxy after this (or after the adaptive delay below): the same request starts on the direct API in parallel. Whichever reaches its first content first is used (see "The race's milestone" below); the other is cancelled and its connection closed. |
| Idle limit | 6 s (`IDLE_S`) | `VERSE_API_IDLE_S` | live cards, ask panel | A proxy stream that has started and then sends nothing for this long (outside a thinking block) has stalled: handled like a stream that broke half way (below). |
| Call hedge | 4 s (`CALL_HEDGE_S`) | `VERSE_API_CALL_HEDGE_S` | pre-warm, keep-alive and ping (live), `count_tokens` (ask) | The same race for these small non-streaming calls. |
| First-byte deadline | 15 s (`PREP_FIRST_BYTE_S`) | `VERSE_API_PREP_FIRST_BYTE_S` | prep, sim, conversation research | No response headers (or `count_tokens` answer) from the proxy within this: the request is restarted on the direct API. No race: prep requests are large and not latency-bound. |

- A proxy that loses the race, or hits the idle limit or the deadline, is a failover with reason `stalled`: the cool-off starts and
  the following requests go straight to the direct API, with the usual single probe after it. A proxy that wins the race after
  the direct request started changes no route (it only widens the next delays, below); the direct request is cancelled.
- The race's milestone is the first content, the same for both routes: the first `content_block_start` or `content_block_delta` of
  any kind (a thinking block counts), or the end of the message (`message_stop` / end of stream) for an answer with no content at
  all, such as a `max_tokens: 0` pre-warm or an immediate stop. Response headers and `message_start` do not count: the direct API
  sends `message_start` about 0.4 s after the request, long before any content, while the local proxy buffers and sends its
  `message_start` together with its first content (measured: 0.6-0.9 s for Haiku, 0.8-1.4 s for Sonnet on tiny prompts, more on
  real ones). Judged on the first event, every race whose proxy first token came later than the hedge delay plus about 0.4 s went
  to the direct API as a `stalled` failover, sending everything to the paid key for the cool-off. Each route's stream marks its
  first content with an internal `content` event (`apiroute.CONTENT`, from `transport.StreamTap.saw`); a stream without markers
  reaches the milestone at its first text or stop event.
- An attempt's events before the milestone (its `message_start`, which carries the input usage) are held, not shown. The winner's
  held events are then delivered in order, exactly once, followed by the rest of its stream; the loser's are dropped with its
  closed stream, so the caller never sees events from both routes. While the race runs, a proxy that has sent something and then
  goes quiet for the idle limit also ends its attempt (`stalled`). The race's cleanup (closing the loser) runs to its end even
  when the caller is cancelled meanwhile (a discarded live call, a closed ask panel), and the winner's already opened stream is
  then closed too before the cancel goes on, so no HTTP stream is left generating on either key.
- The race only decides on the first content, so a hedge delay a little too short costs an occasional duplicate request, never a
  wrong or spliced answer. A healthy but slow proxy (first content later than 1.5 s, for example Sonnet with a large uncached
  prompt) will sometimes lose to the direct API; that is a failover too, and the proxy is probed again after the cool-off.
- Adaptive delay, so that a slow but healthy proxy does not start a paid direct duplicate on every request: the router keeps the
  proxy's last `HEDGE_WINDOW` (8) first-content latencies per model, separately for streams and for the non-streaming calls, and a
  race waits at least `HEDGE_WIDEN` (1.25) x the slowest of them, never more than `HEDGE_MAX_FACTOR` (3) x the base delay
  (4.5 s for streams, 12 s for the call hedge). A proxy that wins after the direct request started (`Router.late_wins`) therefore
  widens the next races on that model, and eight faster answers bring the delay back to the base. The cost: right after the proxy
  was slow, a stall on that model is detected that much later (at most the cap). The latencies are kept across a failover, so
  the probe after the cool-off waits the same widened delay (a slow but healthy proxy that lost one race is not judged at the
  base delay again); one outlier keeps the delay widened until eight newer answers have pushed it out. These three are
  constants in `apiroute.py` with no environment variable.
- The idle limit counts everything the server sends: the SDK drops `ping` events before its iterator yields them, so the clients
  tap the SDK stream's raw event iterator to count them (best effort; without it only parsed events count). Inside a thinking
  block silent gaps are normal (the thinking text may be omitted), so there the limit waits and only the read timeout (30 / 60 /
  120 s) applies. Live cards ask for no thinking blocks (Haiku: `disabled`; Sonnet: `between_tools`, and they send no tools), so this
  matters in the ask panel with Sonnet or Opus.
- Without a base URL, or with a base URL but no fallback, nothing is raced or timed: the behaviour is as before.

### The live runtime's lane hedge

The meeting brain has its own hedge (`runtime/engine.py`, `hedged_stream`): a call with no first event after 1.5 s (Haiku) / 2 s
(Sonnet) gets a duplicate on lane 1, its own HTTP/2 connection. With a base URL that duplicate would go to the same stalled
proxy, so the two compose like this: while the transport is racing a request's proxy stream against the direct API and the
proxy attempt is still pending (`AnthropicTransport.route_racing`), the engine does not start its lane-1 duplicate (metric stage
`hedge_route` instead of `hedge`); the race already sends one to a different host over a different connection. The engine
decides this once, at its own hedge time. When the proxy attempt has failed before then (a refused port fails at once), what is
left is a single direct request, often on a fresh connection, and the lane hedge covers it as usual: its lane-1 duplicate goes
direct too, because the router has already failed over. When the proxy attempt fails after that moment (an idle stall, a 5xx at
1.6 s), the remaining direct request gets no lane-1 duplicate (see "Not covered"). When there is no race (no base URL, or during
the cool-off, when requests go straight to the direct API) the lane hedge works exactly as before. With a base URL the
`first_byte` metric also says which route answered (`api_route`: `proxy` or `fallback`) and whether the route race started the
paid direct duplicate (`route_hedged`).

The route state belongs to one client: the live transport's lanes and hedges share one router (one per brain process), while the
ask client and each prep model keep their own cool-off.

## Streams that break half way

- **Before any text reached the consumer** (the usual case: connection refused, an error before the first token, a proxy that
  stops sending for the idle limit): the request is restarted on the fallback inside the stream; the consumer sees one clean
  answer.
- **After text reached the consumer**: the live overlay and the ask panel show text as it arrives and cannot take it back, so the
  stream is *not* spliced with a second answer. It ends with a connection error (`offline` to the caller), the router has already
  switched, and the caller's own retry goes direct: the meeting brain's offline/pending-turn path, or the user asking again. In the
  meeting brain that path shows a short "no connection" status until its next ping (every 5 s while offline) succeeds through the
  fallback, then the turn is retried.
- **Prep** (`prep/model.py`, sim, conversation research) keeps the whole answer before using it, so a broken proxy stream is
  restarted from scratch on the fallback and only the fallback's answer is kept.

## Events

The live meeting runtime writes route changes to the session's `events.jsonl` (`runtime/events.py`); other processes log a warning
to stderr. Numbers and enums only: never a key, never a URL.

| `ev` | Fields |
|---|---|
| `api_route_fallback` | `reason` (`offline`, `timeout`, `auth`, `rate_limited`, `overloaded`, `credit`, `stream_broken`, `stalled`), `status` (HTTP status or absent), `cool_off_s`, `failovers` (switches so far in this process) |
| `api_route_primary` | `fallback_s` (time spent on the fallback), `fallback_calls` (requests the fallback answered so far), `failovers` |

A failed probe after the cool-off is not a change and writes nothing.

## Startup check and status reasons

The meeting runtime's key check is its pre-warm (`runtime/engine.py`). With a base URL it goes to the proxy; a dead or rejecting
proxy fails over to the direct API with your Anthropic key and the call starts normally. The status reasons (`no_connection`,
`invalid_api_key`, `no_credit`) then describe the direct API (the last route tried): `invalid_api_key` means `verse-anthropic`
itself was rejected. `no_api_key` means the `verse-anthropic` item is missing.

## Spend and error text

Usage comes back from whichever route answered and is priced the same way, so `spend.json`, the budget cap and the ask cost lines
keep working on both routes (calls through a proxy are counted at API list prices). When a race starts a second request, only the
winner's events reach the caller, so only the winner is counted. The loser is cancelled before its first content; a
`message_start` it had already sent is held and dropped, so its usage is not counted either. Whatever the API or the proxy bills
for a request cancelled that early is not counted (it can only be an undercount: a direct duplicate that already sent
`message_start` has had its prompt read; how the API bills a stream cancelled before or right after `message_start` is not
confirmed here). The adaptive delay above keeps such duplicates to
the requests that are slower than the proxy's own recent normal. Every key read in a process is scrubbed from
printed error text (`prep/keychain.redact`); a rejected request's message (which may come from the proxy) is also cut to 200
characters with anything shaped like an `sk-` key or a bearer token removed. The SDK clients are built with an explicit key, so an
`ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN` or (for the fallback) `ANTHROPIC_BASE_URL` in the brain's environment is not used.

## Not covered

- A stall inside a thinking block (ask panel with Sonnet or Opus) still costs the read timeout; so does a prep stream that stalls
  after its response headers (prep has a first-byte deadline only).
- The base hedge delay is one value for every model. The first slow requests on a model (Sonnet's healthy first content is close
  to 1.5 s) start a duplicate on the direct API until the adaptive delay has widened; a proxy whose first content is consistently
  above the cap (4.5 s) still duplicates every request, and loses the race whenever the direct API's first content comes first.
- A proxy that sends `message_start` early, does not relay pings and then takes longer than the hedge delay before its first
  content block races the direct API like a silent proxy (it wins only if its content still comes first).
- When the direct request fails first after the hedge while the proxy is still silent, the race keeps waiting for the proxy up to
  its read timeout before it raises the direct error (no worse than without the race).
- The engine's lane hedge stands down for a route race once, at its own hedge time. A proxy attempt that fails after that moment
  (an idle stall, a late 5xx) leaves a single direct request without a lane-1 duplicate; a stall on that direct connection then
  costs the read timeout. Re-checking would need a signal from the transport when the proxy attempt ends: polling `racing`
  would see the proxy's own win a moment before its first event reaches the engine and start a needless duplicate.
- The simulator's own lane hedge (`runtime/sim.py`) does not stand down during a route race; it only costs a duplicate request.

- The live pre-warm sends `max_tokens: 0`; whether a given proxy accepts that is up to the proxy (a 400 from it is not a failover).
- The brief and persona actions keep their whole answer too but use the same stream as the ask panel, so a proxy stream that broke
  after text ends them with an error instead of a restart.
