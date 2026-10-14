"""Client-side token buckets per model, sized at a fraction (80 %) of the org limits read from the
`anthropic-ratelimit-*` response headers (spec 5.8, B11). Phase 0 measured 1,000 RPM / 2 M ITPM / 400 K OTPM.
"""

from __future__ import annotations

import time

DEFAULT_LIMITS = {"requests": 1000, "input-tokens": 2_000_000, "output-tokens": 400_000}


class Bucket:
    def __init__(self, per_minute: float, now: float | None = None) -> None:
        self.capacity = per_minute
        self.level = per_minute
        self.t = time.monotonic() if now is None else now

    def _refill(self, now: float) -> None:
        self.level = min(self.capacity, self.level + (now - self.t) * self.capacity / 60.0)
        self.t = now

    def try_take(self, n: float, now: float) -> bool:
        self._refill(now)
        if self.level >= n:
            self.level -= n
            return True
        return False

    def set_capacity(self, per_minute: float, now: float) -> None:
        self._refill(now)
        self.level = min(self.level, per_minute) if per_minute < self.capacity else self.level
        self.capacity = per_minute


class ModelLimiter:
    def __init__(self, fraction: float = 0.8) -> None:
        self.fraction = fraction
        now = time.monotonic()
        self.limits = dict(DEFAULT_LIMITS)
        self.buckets = {k: Bucket(v * fraction, now) for k, v in self.limits.items()}

    def update_from_headers(self, headers: dict) -> None:
        now = time.monotonic()
        for k in self.limits:
            v = headers.get(f"anthropic-ratelimit-{k}-limit")
            try:
                lim = int(v) if v is not None else None
            except ValueError:
                lim = None
            if lim and lim != self.limits[k]:
                self.limits[k] = lim
                self.buckets[k].set_capacity(lim * self.fraction, now)

    def fraction_left(self) -> float:
        """The emptiest bucket as a fraction of its capacity (1.0 = full). Used to keep low-priority calls out."""
        now = time.monotonic()
        for b in self.buckets.values():
            b._refill(now)
        return min(b.level / b.capacity for b in self.buckets.values() if b.capacity > 0)

    def try_acquire(self, input_tokens: int, output_tokens: int) -> bool:
        """All-or-nothing: one request plus the estimated uncached input and the output cap."""
        now = time.monotonic()
        want = {"requests": 1, "input-tokens": input_tokens, "output-tokens": output_tokens}
        for b in self.buckets.values():
            b._refill(now)
        if all(self.buckets[k].level >= n for k, n in want.items()):
            for k, n in want.items():
                self.buckets[k].level -= n
            return True
        return False
