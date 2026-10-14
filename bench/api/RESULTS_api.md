# P0-A results: API latency and rate limits

Run: 2026-10-14 (about 02:59 local), Mac on macOS 26.6.2 / arm64, Python 3.14.7, `anthropic` 1.13.0, `httpx2` 2.13.1.
Official run: `results/api-20261014-025859.json` (`bench_api.py --all`). Extras: `results/api-20261014-030645.json`
(`--cases ab_salt4`) and `results/api-20261014-030835.json` (`--long-idle`). Earlier iterations of the same script are kept in
`results/_run1`, `_run2`, `_stub`.

Organization billed: `00000000-0000-0000-0000-000000000000` (response header `anthropic-organization-id`,
workspace `wrkspc_000000000000000000000000`). Whether this is "Personal API Org" must be checked in the Console.

## Headline numbers (ms from request start, warm HTTP/2 connection, cache hit)

| case | n ok/req | cache read>0 | TTFT p50 | TTFT p90 | TTFT max | first SAY line p50 | p90 | first "- " point p50 | p90 |
|---|---|---|---|---|---|---|---|---|---|
| **warm_haiku** (Haiku 5.5, effort low, thinking disabled) | 30/30 | 30 | 933 | 1,042 | 10,768 | 1,119 | 1,415 | 1,399 | 1,610 |
| **cold_haiku** (new client + connection per call, cache warm) | 9/10 | 9 | 973 | 1,045 | 1,045 | 1,110 | 1,424 | 1,386 | 1,818 |
| idle10_haiku (10 s idle before each call, same connection) | 6/6 | 6 | 957 | 1,200 | 1,200 | 1,212 | 1,370 | 1,442 | 1,638 |
| burst3_haiku (3 concurrent calls, S <= 3 in flight) | 15/15 | 15 | 1,022 | 1,230 | 1,253 | 1,192 | 1,384 | 1,524 | 1,979 |
| prewarm: real calls after the `max_tokens: 0` call | 3/3 | 3 | 902 | 938 | 938 | 1,009 | 1,111 | 1,336 | 1,456 |
| **sonnet_between_tools** (Sonnet 5.5, medium) | 15/15 | 15 | 916 | 1,047 | 1,049 | 1,230 | 1,380 | 1,615 | 2,054 |
| **sonnet_adaptive** (Sonnet 5.5, medium) | 15/15 | 15 | 802 | 2,429 | 6,365 | 1,154 | 2,642 | 1,604 | 2,929 |

Reading the table:
- TTFT = first `text_delta`. "First SAY line" = the first complete `SAY:` line (its newline has arrived). "Point" =
  first complete `- ` line. Response headers arrive at the same moment as the first token (headers p50 = TTFT p50),
  so TTFT is first byte.
- p50 is the median (linear interpolation). p90 is the nearest-rank value (the 27th of 30, 14th of 15, 9th of 10, 6th of 6).
  With n = 3..15 the p90 is basically "second-worst call"; treat it as indicative. Max is shown because single stalls matter here.
- `cold_haiku` removes the cache-warm confound: the 5-minute cache stays warm, only the TCP+TLS+HTTP/2 setup is new.
  It was not a real >6 min idle (that is the separate idle ladder below). One of its 10 calls failed to connect (see "Fresh connections").
- All 100+ calls negotiated HTTP/2. Edge colo in `cf-ray` is `FRA`.
- Output speed (median, tokens/s after first token): Haiku ~246, Sonnet ~125.
- Pack: one user message, blocks = meeting pack (breakpoint 1) + 6 finalized turns (breakpoint 2 on the newest) + the
  question after the last breakpoint; frozen system before them. 6,204 tokens total with `count_tokens` (identical on
  both models); 6,190-6,266 cached per call.

### What the numbers say for the spec (my reading; the verdict is the gate's)
- The API part alone is ~0.9 s p50 / ~1.0 s p90 for Haiku (warm, cached). Spec section 6 asks "no hit, fresh Haiku -> first word"
  p50 <= 1.1 s from the acoustic end; endpoint (~0.3 s) plus ASR lag come on top, so this path lands near 1.2-1.4 s p50: **needs change or
  out of reach** unless speculation (S) starts before the end. A no-inference round trip on the same connection costs 244 ms p50
  (count_tokens, n=20, min 223, p90 254, max 378), so ~0.65 s is server time, not network.
- Sonnet D (`between_tools`): TTFT p50 0.92 s / p90 1.05 s, so "first words" p50 <= 2.0 s, p90 <= 3.0 s is met with room
  (SAY line p50 1.23 s, p90 1.38 s; the target counts from t=0, so add the ~0.3-0.6 s of endpoint/ASR).
- **Haiku has no TTFT advantage over Sonnet `between_tools` here.** Interleaved extra (below): Haiku 759 vs Sonnet 704 ms p50.
  Haiku only wins on output speed. Pack-to-pack variance (730-1,025 ms) is larger than the model gap.
- Thinking must be switched off explicitly on Haiku: the `haiku_ad` / `haiku_default` extras think on 10/10 calls and reach TTFT p50 2.0-2.3 s.
- Sonnet `adaptive` at medium thought on 3/15 calls (TTFT 1.75-2.43 s) plus one 6.4 s stall without thinking; `between_tools` never
  emitted a thinking block (0/15) and had max TTFT 1.05 s. Choose `between_tools` for D, as the spec leans.

## Cache proof

| check | result |
|---|---|
| warm_haiku warm-up call | `cache_creation_input_tokens` 6,190, `cache_read` 0 |
| warm_haiku calls 1-30 | `cache_read_input_tokens` = 6,190 on **30/30**, `cache_creation` = 0 on 30/30, uncached `input_tokens` 30-45 (question + last turn) |
| prewarm: `max_tokens: 0`, non-streaming, thinking disabled, effort low | **accepted** (HTTP 200): `content: []`, `stop_reason: "max_tokens"`, `cache_creation` 6,203, `output_tokens` 0, 964 ms |
| first real (streamed) call after the pre-warm | `cache_read` 6,203 on 3/3 real calls. The pre-warm entry is the one the streamed calls read |
| mismatch control: pre-warm with effort `medium`, real call with effort `low` (Haiku, thinking disabled both) | real call still read the pre-warmed entry (6,192 tokens). One sample on a thinking-disabled route; the guide warns a mismatch can miss, so keep the tuple byte-identical anyway |
| Sonnet `between_tools` and `adaptive` | both 15/15 calls read the cache (6,266 and 6,226 tokens) after their own warm-up write |

Minimum-prefix and TTL: no `ttl` was set (5 minutes default). Whether the entry survives a real gap longer than 5 minutes is in
the idle ladder below.

## Rate-limit headers (`anthropic-ratelimit-*`, identical on Haiku and Sonnet responses)

| header | value |
|---|---|
| requests-limit | 1,000 per minute |
| input-tokens-limit | 2,000,000 per minute |
| output-tokens-limit | 400,000 per minute |
| tokens-limit (combined) | 2,400,000 per minute |
| `*-reset` | rolling, within ~1 minute of the request time |

- Observed `remaining` barely moved: 999 requests, input 1,997,000 of 2,000,000 after a ~6.2k-token call, output 400,000. No 429 in
  any call of any run, including the 3-concurrent bursts (about 200 priced calls overall).
- The org is **not** on a low tier: peak Verse load (3 S calls/s plus F, D, keep-alive) is about 5 requests/s against 16.7 requests/s,
  and ~20k input tokens/s against 33k/s. B11 (429 at t=0) is not a risk at these limits. Whether the Haiku and Sonnet limits are separate
  pools or one shared pool is not shown by the headers (same numbers on both). A 30-minute replay at peak density was not run.

## Fresh connections: a real problem on this network (not in the plan)

- Handshake cost (curl, 15 runs): DNS 2 ms, TCP connect ~35 ms, TLS done ~95 ms. SDK cold-vs-warm delta: +40 ms (this run) to +130 ms
  (earlier runs), consistent with the critique's +60-160 ms.
- **But new connections sometimes hang.** `curl` to `api.anthropic.com`: 2 of 30 TCP connects never completed in 8 s (1 of 15 on IPv4, 1 of 15 on
  IPv6), so it is not the SDK or IPv6. SDK with fresh clients: official run `cold_haiku` 1/10 `ConnectTimeout` at my 10 s cap; earlier
  iterations 2/10 `APIConnectionError` and one call that took 9.97 s; a 25-connection probe had one success after 22.9 s and one
  `ConnectError: All connection attempts failed` after 52 s. Roughly 5-8 % of new connections stall for 10-50 s.
- One stall also hit a **warm** connection: `warm_haiku` call 7 took 10.8 s to first byte (the other 29: max 1.07 s). In earlier iterations the warm
  max was 2.0-2.1 s. Cause unknown (the connection was reused; no reconnect is visible).
- Consequence for Phase 1 (design input, not in scope here): keep a warm connection open (HTTP/2, `keepalive_expiry` 300 s worked for the
  10 s case), never open the first connection at t=0, and consider a hedged second request for S/F after ~1.5 s. See the idle ladder for how long an
  idle connection survives.

## Idle ladder (optional real idle; `--long-idle`, one call per gap, n = 1 so only indicative)

One client, one kept-alive connection (`keepalive_expiry` 300 s), Haiku route, cache written before the first gap.

| idle before the call | TTFT ms | SAY line ms | cache | note |
|---|---|---|---|---|
| (reference: back-to-back, warm_haiku) | 933 p50 | 1,119 | read | |
| 30 s | 1,158 | 1,596 | read 6,245 | +225 ms vs reference |
| 60 s | 1,170 | 1,184 | read 6,245 | +240 ms |
| 120 s | 1,350 | 1,359 | read 6,245 | +420 ms |
| 240 s | 923 | 1,119 | read 6,245 | back to reference |
| 390 s (cache TTL and client keepalive both expired) | 1,692 | 1,791 | **miss: `cache_creation` 6,245, `cache_read` 0** | slow = new connection + cache write |
| next call after that | 873 | 1,388 | read 6,245 | recovered at once |

- A real >5 min gap loses the 5-minute cache entry: the first call afterwards is a write (1.7 s TTFT here, includes a new connection since my
  client drops idle connections after 300 s). A keep-alive (`max_tokens: 0` re-warm) must land before 5 minutes.
- Gaps of 30-120 s cost an extra ~0.2-0.4 s in single samples while the 10 s gaps (n = 6) cost only ~+25 ms; the effect (connection idle path,
  cache entry going cold, or noise) is **unconfirmed**. If it is real, a keep-alive every ~20-30 s would remove it. Needs n >= 10 per gap to settle.
- The HTTP/2 connection did survive 240 s idle on the client side (no reconnect penalty visible). Server-side idle close was not observed below 300 s.


## Cancel billing

- Test: Sonnet 5.5 (`between_tools`, medium, cache warm), prompt that asks for ~40 facts (long output), `max_tokens` 1,500. The stream was closed
  0.1 ms after the first text delta (`await stream.close()`; client side this ends the HTTP/2 stream). Control: the same prompt, not cancelled
  (output 171 tokens for that run; the model is concise, so it did not run to the cap).
- What the API shows for the cancelled call: only the `message_start` usage (`input_tokens` 63, `cache_read_input_tokens` 6,266,
  `output_tokens` 7). No `message_delta`/final usage arrives after a close, and the rate-limit output counters stayed at 400,000 before and after,
  so there is no evidence either way from headers.
- **Finding: UNCONFIRMED whether output billing stops at the close.** The full input (prefill) is certainly billed as cache read + input, because
  the server had accepted the request and shows it in `message_start`. To settle output billing, compare the cancelled request id
  `req_000000000000000000000000` with the control `req_000000000000000000000000` in the Console request log (output tokens recorded for the
  cancelled one vs the ~7 seen at start), or run a Console usage diff around a batch of 50 cancelled long-output calls. This key has no
  admin/usage-API access, and I did not try to use it for that.
- Budget accounting: the cancelled call is charged to the spend total pessimistically (full 1,500 output tokens, $0.015).

## Extras (not in the plan; cheap, added because they change the design)

| case | n | cache>0 | TTFT p50 | p90 | max | SAY p50 | p90 | point p50 | p90 | thinking blocks |
|---|---|---|---|---|---|---|---|---|---|---|
| cmp: Haiku, thinking disabled, low | 10 | 10 | 759 | 790 | 832 | 1,008 | 1,219 | 1,182 | 1,421 | 0/10 |
| cmp: Haiku, adaptive, low | 10 | 10 | 2,019 | 2,737 | 2,839 | 2,140 | 2,816 | 2,351 | 3,078 | 10/10 |
| cmp: Haiku, no thinking/effort params | 10 | 10 | 2,276 | 3,369 | 3,383 | 2,447 | 3,507 | 2,601 | 3,672 | 10/10 |
| cmp: Sonnet, between_tools, medium | 10 | 10 | 704 | 2,519 | 2,826 | 1,226 | 2,858 | 1,772 | 3,201 | 0/10 |
| ab: pack salt A / H1 (same route, interleaved) | 12 / 12 | all | 908 / 732 | 965 / 820 | 986 / 879 | 999 / 924 | | 1,273 / 1,144 | | |
| ab4: salts A / H1 / B2 / C3 (rotating order) | 12 each | all | 984 / 766 / 799 / 1,025 | 1,117 / 925 / 867 / 1,150 | 3,843 / 1,547 / 1,115 / 1,292 | | | | | |

- The `cmp:` rows are four routes called round-robin, each with its own pack and warm-up, so drift hits all of them equally.
- **TTFT depends on the pack (cache entry), not only on the route:** the same Haiku route on four different 6.2k-token packs gave p50 766-1,025 ms.
  Unexplained. My guess (unconfirmed) is that a cache entry pins requests to a particular server. Consequence: measure the real session's
  entry, and do not expect a single fixed number.
- Several `cmp:sonnet_between_tools` p90 values come from a single 2.5-2.8 s call; the median is the stable number.

## Spend (computed from `usage` x list prices)

| run | spend |
|---|---|
| official `--all` run (`results/api-20261014-025859.json`) | $0.2270 (Haiku $0.0254, Sonnet $0.2016) |
| extra `ab_salt4` | $0.0089 |
| extra idle ladder | $0.0024 |
| earlier iterations of the same script (`_run1`, `_run2`, prewarm smoke test) | $0.3645 |
| `count_tokens` calls and connection probes | free |
| **total, everything run for this package** | **about $0.60** (limit: target < $1, hard stop $2; one `--all` costs about $0.23) |

Almost all of the cost is Sonnet cache writes (each pack write = 6.2k tokens x $2.50/MTok = $0.0155) and the long-output cancel test. Prices used:
Haiku $0.10 / $0.50 per MTok, Sonnet $2 / $10, cache write (5 min) 1.25x, cache read 0.1x (matches the skill's stated Sonnet 5.5 read price of $0.20/MTok).
The cancelled call is counted at the full 1,500 output tokens. The 5-minute-TTL multiplier is assumed from the request (`usage.cache_creation` TTL split was not recorded).

## Method notes

- Client: `AsyncAnthropic(api_key=..., http_client=DefaultAsyncHttpxClient(http2=True, limits=Limits(keepalive_expiry=300)), max_retries=0, timeout=60 s / connect 10 s)`.
  Plan deviation: the plan says `httpx.AsyncClient`; `anthropic` 1.x runs on **httpx2** and rejects a plain `httpx` client, so the bench uses the SDK's
  `DefaultAsyncHttpxClient` (httpx2 underneath) with `http2=True`. Phase 1 must do the same (declare `httpx2[http2]`).
- Raw streaming: `client.messages.with_raw_response.create(stream=True)` then iterate events; `t0` is just before the call; every stage time is
  `perf_counter` at event arrival. Headers come from the raw response. Usage = `message_start` + `message_delta`.
- Models/settings (one tuple per route, used identically by pre-warm and real calls): Haiku `claude-haiku-5-5`, `thinking: {"type":"disabled"}`,
  `output_config.effort = "low"`, `max_tokens` 300. Sonnet `claude-sonnet-5-5`, `thinking: {"type":"between_tools"}` or `{"type":"adaptive"}`,
  effort `medium`, `max_tokens` 800 / 3000. Explicit `cache_control` on two blocks only; no top-level caching. Output is plain-text lines
  (`SAY:` then three `- ` points), no structured output.
- The pack is synthetic (fictional company Larkspur Logistics: fact sheet, glossary, answer bank, snippets) and each case uses its own pack
  salt so cases cannot read each other's cache. Questions are generated from facts that exist in the pack, in English, Italian and Turkish rotation.
  An earlier iteration used questions the pack could not answer; the model then answered "let me check" in a fixed sentence, which made SAY too fast, so it was replaced.
- Order inside `--all`: floor, prewarm, warm_haiku, cold_haiku, idle10_haiku, burst3_haiku, sonnet (bt/adaptive interleaved), model_compare, ab_salt, cancel. Each case
  with a cache has an uncounted warm-up call that writes the entry; counted calls are n as stated.
- No audio. Result files contain timings, header values, usage and the first 220 characters of synthetic output. The script reads the key from the Keychain
  and, before leaving the results file on disk, scans it for the key (none found).
- The local check of the key class: it starts with `sk-ant-` but is not an `sk-ant-api`, `sk-ant-oat` or `sk-ant-admin` key; the API accepted it as `x-api-key` on every call.
