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
direct clients keep their usual timeouts and retries. A proxy that accepts the connection and then never answers (an upstream
stall) is only caught by the read timeout: 30 s (Haiku) / 60 s (Sonnet) in the live runtime, 120 s in the ask client, 600 s in
prep, and the live runtime's hedge goes to the same stalled proxy. That wait comes back once per cool-off, when the probe tries the
proxy again.

The route state belongs to one client: the live transport's lanes and hedges share one router (one per brain process), while the
ask client and each prep model keep their own cool-off.

## Streams that break half way

- **Before any text reached the consumer** (the usual case: connection refused, an error before the first token): the request is
  restarted on the fallback inside the stream; the consumer sees one clean answer.
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
| `api_route_fallback` | `reason` (`offline`, `timeout`, `auth`, `rate_limited`, `overloaded`, `credit`, `stream_broken`), `status` (HTTP status or absent), `cool_off_s`, `failovers` (switches so far in this process) |
| `api_route_primary` | `fallback_s` (time spent on the fallback), `fallback_calls` (requests the fallback answered so far), `failovers` |

A failed probe after the cool-off is not a change and writes nothing.

## Startup check and status reasons

The meeting runtime's key check is its pre-warm (`runtime/engine.py`). With a base URL it goes to the proxy; a dead or rejecting
proxy fails over to the direct API with your Anthropic key and the call starts normally. The status reasons (`no_connection`,
`invalid_api_key`, `no_credit`) then describe the direct API (the last route tried): `invalid_api_key` means `verse-anthropic`
itself was rejected. `no_api_key` means the `verse-anthropic` item is missing.

## Spend and error text

Usage comes back from whichever route answered and is priced the same way, so `spend.json`, the budget cap and the ask cost lines
keep working on both routes (calls through a proxy are counted at API list prices). Every key read in a process is scrubbed from
printed error text (`prep/keychain.redact`); a rejected request's message (which may come from the proxy) is also cut to 200
characters with anything shaped like an `sk-` key or a bearer token removed. The SDK clients are built with an explicit key, so an
`ANTHROPIC_API_KEY`, `ANTHROPIC_AUTH_TOKEN` or (for the fallback) `ANTHROPIC_BASE_URL` in the brain's environment is not used.

## Not covered

- The live pre-warm sends `max_tokens: 0`; whether a given proxy accepts that is up to the proxy (a 400 from it is not a failover).
- The brief and persona actions keep their whole answer too but use the same stream as the ask panel, so a proxy stream that broke
  after text ends them with an error instead of a restart.
