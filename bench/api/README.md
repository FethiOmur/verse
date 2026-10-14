# bench/api (P0-A): API latency and rate limits

Throwaway CLI. Results and analysis: `RESULTS_api.md`.

```
cd bench/api
python3 -m venv .venv && .venv/bin/pip install -r requirements.txt
.venv/bin/python -u bench_api.py --all                 # ~8 min, ~$0.25
.venv/bin/python -u bench_api.py --cases ab_salt4      # extra: 4 packs, same route
.venv/bin/python -u bench_api.py --long-idle           # extra: idle ladder 30/60/120/240/390 s (~14 min)
```

- Key: macOS Keychain item service `verse-anthropic`, account `$USER`. Read at runtime via `security`; never
  printed, logged or written (the script also scans its own results file for the key before leaving it on disk).
- Stops (exit 2) on 401/403, missing Keychain item, a `refusal` stop_reason, or spend above $1.50.
- Output: `results/api-<timestamp>.json` (per-call timings in ms from request start, server `usage`, response
  headers without auth headers, short synthetic text) and a p50/p90 table on stdout.
- No audio, no GUI. `results/_run1`, `_run2`, `_stub` hold earlier iterations of the same script (kept, not deleted).
