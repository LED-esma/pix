# Where Pix's tokens go, and how it stays cheap (2026-10-04)

Measured with `bench/pix_tests.py` on Claude (Sonnet). Prices are API-equivalent; on a Claude plan they come out of the usage limit instead.

## The map

| What | Size | When it's paid |
|---|---|---|
| Pix's setup: instructions (~3.3k tokens) + 41 tool descriptions (~3.3k) + Claude Code's own | ~7–10k per turn | every turn; at 10% price when cached, full price on a cold start |
| Cold start (cache expired after 5 min, or the setup changed) | ~15k at full price | the first run after a pause, ~$0.05 |
| Your question + memory + answer | ~1–2k | every run |
| Web pages (WebSearch, WebFetch, Pix's browser looks, web_read) | 2–15k each | re-read on every later turn of the same run |
| Connected apps' replies (Canvas: ~20k) | whatever the app returns | re-read on every later turn |
| Turns | 2–3 for a quick answer, 6–15 for digging | each one re-reads everything above |

A quick question costs about $0.015 warm, about $0.05 cold. This Mac (qwen3) costs nothing.

## What changed

| Fix | Before | After |
|---|---|---|
| Saved tools no longer change the cached setup (one fixed `use_tool`; names travel with the question) | running a saved tool right after saving: $0.070 | $0.015 |
| Page reads capped at 12k characters, `look_for` returns only matching lines, `from` reads further | up to 60k characters per page | 12k, or a few hundred with look_for |
| Leaner browser looks (60 things, 2,500 characters of text) | Home Depot drill bits: 15 turns, $0.178 | 6 turns, $0.098 |
| Home Depot vs Lowe's | 14 turns, $0.276 | 6 turns, $0.114 |
| App work: press several buttons in one step, short replies | Calculator: 204k tokens | 78k |
| Auto: quick questions stay on This Mac, only doing goes to Claude | | free for anything that doesn't need doing |

## Still on the table (cheapest first)

1. ~~Quick Claude answers on Haiku~~: tried, and it costs more. Haiku wrote ~4x the output (4,249 vs 1,044 tokens on the incline problem): 2.5¢ vs 1.9¢ warm, and twice as slow. Left as a Settings switch, off.
2. Shorter instructions and tool descriptions: ~20% off every turn.
3. Ask connected apps for less (e.g. "due in the next 7 days" instead of everything).
4. Questions asked within 5 minutes of each other stay warm; a cold start is the most common extra cost.
