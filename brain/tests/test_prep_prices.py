"""Prices (docs/specs/2026-10-20-verse-five-features-design.md 3.4): the 3-tuple table, Opus 5.5, the Haiku long-prompt tier, and
the numbers of the callers that existed before (Sonnet and Haiku) unchanged."""

from __future__ import annotations

import pytest

from verse_brain.prep.model import HAIKU, OPUS, PREP_MODEL, PRICES, Usage, spend_usd


def old_spend(model: str, u: Usage) -> float:
    """The formula before F2a (2-tuple prices, cache read = 0.1 x input)."""
    pin, pout = {PREP_MODEL: (2.00, 10.00), HAIKU: (0.10, 0.50)}[model]
    return (u.input * pin + u.cache_write * pin * 1.25 + u.cache_read * pin * 0.10 + u.output * pout) / 1e6


def test_table():
    assert OPUS == "claude-opus-5-5"
    assert PRICES[OPUS] == (4.00, 20.00, 0.20)
    assert PRICES[PREP_MODEL] == (2.00, 10.00, 0.20)
    assert PRICES[HAIKU] == (0.10, 0.50, 0.01)


def test_opus_cache_read_is_020_per_mtok():
    assert spend_usd(OPUS, Usage(cache_read=1_000_000)) == pytest.approx(0.20)
    assert spend_usd(OPUS, Usage(input=1_000_000)) == pytest.approx(4.00)
    assert spend_usd(OPUS, Usage(output=1_000_000)) == pytest.approx(20.00)
    assert spend_usd(OPUS, Usage(cache_write=1_000_000)) == pytest.approx(5.00)       # 1.25 x input


@pytest.mark.parametrize("model", [PREP_MODEL, HAIKU])
@pytest.mark.parametrize("u", [Usage(1200, 340, 0, 0), Usage(50, 30, 4000, 0), Usage(10, 120, 0, 62_000), Usage(0, 0, 99_000, 0),
                               Usage(5, 700, 30_000, 20_000)])
def test_sonnet_and_haiku_numbers_unchanged(model, u):
    assert spend_usd(model, u) == pytest.approx(old_spend(model, u), rel=1e-12, abs=1e-15)


def test_haiku_over_100k_uses_the_long_tier():
    short = Usage(input=0, output=1_000_000, cache_read=100_000)
    assert spend_usd(HAIKU, short) == pytest.approx(0.50 + 100_000 * 0.01 / 1e6)                   # exactly 100k: short tier
    long_ = Usage(input=1_000_000, output=1_000_000, cache_read=100_001, cache_write=0)
    assert spend_usd(HAIKU, long_) == pytest.approx(0.50 * 1 + 2.50 + 100_001 * 0.05 / 1e6)
    # the prompt size counts input + cache read + cache write
    assert spend_usd(HAIKU, Usage(input=10, cache_read=60_000, cache_write=40_001)) == pytest.approx(
        (10 * 0.50 + 40_001 * 0.50 * 1.25 + 60_000 * 0.05) / 1e6)
    # Sonnet and Opus have no long tier
    assert spend_usd(PREP_MODEL, Usage(input=500_000)) == pytest.approx(1.0)
    assert spend_usd(OPUS, Usage(input=500_000)) == pytest.approx(2.0)
