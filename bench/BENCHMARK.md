# Pix token benchmark — 2026-10-02

Rerun with `python3 bench/bench.py baselines | lite 2 | team`, then `python3 bench/bench.py report`.
It uses the exact command lines Pix runs (`Pix --print-args`) and reads every API call from the transcripts.

## Totals

| Run | Tokens | Calls | Billed |
|---|---:|---:|---:|
| Lite · math (typed) | 5.6k | 1 | $0.01 |
| Lite · screen walkthrough | 7.8k | 1 | $0.02 |
| Lite · research (web) | 14.5k | 2 | $0.08 |
| Standard | 996k | 31 | (only part billed before the background bug) |
| Deep, 2 per role | 1,454k | 51 | (same) |

## Where it goes

**Team modes:** the orchestrator is a full Claude Code session. Its setup is ~50k tokens and it re-reads that on every one of its 15–25 calls.

| | Orchestrator | Agents doing the work |
|---|---:|---:|
| Standard | 886k (89%) | 110k |
| Deep | 1,188k (82%) | 266k |

**Lite:** a single lean call. Setup is 71–93% of each run, but setup is only ~5.2k tokens.

| Setup piece (per call) | Tokens |
|---|---:|
| Claude Code minimal scaffolding + answer format | ~2,400 |
| WebSearch tool (+ tool-use scaffolding) | ~1,400 |
| WebFetch tool | ~730 |
| AskUserQuestion tool | ~650 |
| CLAUDE.md + memory index | ~660 |
| Pix system prompt | ~450 |
| Board + "why" format (added after this run) | +~750 |
| Screenshot (1512×982) | +~1,960 |

- Research runs: web results are ~16% of tokens, but the per-search fees are most of the $0.08.
- Cache: the Lite setup is mostly cache reads across runs (cheap).
- Subagents start at ~3.7k each (no CLAUDE.md, few tools), so they're cheap.

## Biggest wins

1. Let the app coordinate Standard/Deep (no orchestrator model): ~−85% (Standard ≈ 110k, Deep ≈ 270k).
2. Lite research: cap web searches at 3 (fees dominate cost).
3. Small: drop CLAUDE.md for Lite (−660/call), drop WebFetch (−730/call). Each about −10%; both lose a little quality.

## After: app-coordinated teams (same research goal)

`Pix --ask "<goal>" out.json 1` runs Standard headless, using the same code the app runs.

| Run | Tokens | Billed | Time |
|---|---:|---:|---:|
| Standard, old (Claude Code orchestrator) | 996k | — | 238 s |
| **Standard, app-coordinated** | **143k (−86%)** | $0.50 | 189 s |

By model: Haiku researchers/scouts 123k (mostly web results; per-search fees are much of the $0.26),
Opus synthesis 13k ($0.20), Sonnet builder 8k.

Lite with the board + plugin cheat sheet: ~6–8k setup per call; a math explanation with a canvas ran 9.4k tokens (~2¢).

## Full suite — speed and bottlenecks (bench/suite.py)

Per-call timing now recorded: Claude Code startup, first reply, model time, turns, searches.

| Run | Tokens | Cost | Time |
|---|---:|---:|---:|
| Lite · typed math | 8.4k (17.9k when it takes an extra turn, ~1 in 3) | $0.01–0.03 | 10–19 s |
| Lite · concept with canvas | 9–19k | $0.03 | 19–31 s |
| Lite · research (3 searches) | 66–68k | $0.12 | 30–44 s |
| Lite · screen walkthrough | 22k | $0.02 | 19 s |
| Lite · "what's due" (Semester) | 50–80k | $0.05–0.07 | 14–20 s |
| Standard | 135k | $0.49 | 193 s |
| Deep, 2 per role | 327k | $1.02 | 328 s |

Canvas: every plugin ready in < 0.2 s, except Python at 0.93 s (runtime boot). Claude Code startup: 0.6 s per call. Toolbox discovery: ~2 s, once per day.

### Bottlenecks found
1. **Opus synthesis**: 43% of Standard's time (124 s, 10.8k output tokens). Still the biggest single wait (~70 s).
2. **Haiku overthinking**: critiques asked for < 120 words wrote up to 7,100 tokens and took up to 67 s. → Critiques moved to Sonnet at low effort: 4–6 s each. Debate round went from 28 s to 6 s.
3. **Web search runs through Haiku**: ~7.7k Haiku tokens per search, plus the search fee. Turning off page reads (WebFetch) didn't help: same cost, slower, and a worse answer. Kept.
4. **Lite extra turn**: when the model writes a "Stage:" line as its own message, Claude Code needs one more full turn (~+9k tokens, +8 s). A prompt fix cut this to about 1 in 3 runs.
5. **Toolbox chatter**: Semester questions take 6–7 tool turns at ~10k context each.
6. **Reliability**: 1 of 2 screen runs returned an empty result. The app retries once automatically.

After the fixes, Standard went from 288 s / 179k / $0.75 to **193 s / 135k / $0.49**.

### Bugs the benchmark caught (fixed)
- The empty-answer guard rejected team members' answers, which broke Standard/Deep (now self-checked).
- Apps opened from the Dock get a bare environment, so Python MCP servers (Semester) failed to start. Pix now uses your shell's environment.

### Sonnet writes Standard's final answer (2026-10-02)
Standard: **153 s / 129k tokens / $0.35** (was 193 s / 135k / $0.49). Final-answer step 36 s (Opus was ~70 s). Same answer shape: recommendation, 3 resolved disagreements, table + checklist. Deep keeps Opus.
