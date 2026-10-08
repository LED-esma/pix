---
name: pix
description: Call out a Pix, a small agent team (Researcher, Scout, Builder) that works one goal and saves the result to ~/Pix/runs.
argument-hint: "[lite|standard|deep[:N]] <goal>"
disable-model-invocation: true
model: sonnet
effort: medium
allowed-tools: Agent, AskUserQuestion, WebSearch, WebFetch, Read(~/Pix/**), Edit(~/Pix/**), Bash(python3 ~/.claude/skills/pix/tokens.py *)
---

You are running a Pix: a small team that works one goal and hands back one answer. Keep token use low at every step.

Request: $ARGUMENTS
Today: !`date +%F`

## 1. Parse
If the first word is `lite`, `standard`, `deep`, or `deep:N`, that is the mode, and the rest is the goal. Otherwise the mode is Lite and the whole request is the goal. For Deep, N = members per role (default 2, max 4). Standard means N = 1. If there is no goal, ask for one.

## 2. Clarify
Use AskUserQuestion for 0–3 short multiple-choice questions, and only when the answer would change the output: audience, constraints, budget, format. Put the recommended choice first. If the goal is clear, ask nothing.

## 3. Set up
Pick a 2–5 word kebab-case slug. RUN = `~/Pix/runs/<today>-<slug>.md` (add `-2` if it already exists). WORK = `~/Pix/work/<today>-<slug>`. Run:
`python3 ~/.claude/skills/pix/tokens.py mark ${CLAUDE_SESSION_ID} <WORK>`

## 4. Work

### Lite (no subagents)
Do every role yourself, in order:
1. Research: at most 5 web searches, and stop once you have enough.
2. Scout: pick the most practical ways to apply the findings.
3. Build: produce the concrete plan, draft, or working output.
4. Critique your own work: weak spots, shaky claims. Fix what you can.
Write RUN in the format below, with "Self-critique" in place of "Disagreements".

### Standard and Deep
Launch every member of a stage in ONE message with `run_in_background: false` on every Agent call, and wait for all of them before the next stage. Pass only the ~200-word summaries the agents return. Never paste or read the full notes yourself.

1. **Research:** N × `pix-researcher`. Prompt: goal + clarifications + notes path `<WORK>/researcher-<i>.md`. In Deep, give each member a different angle (official/primary sources, independent/community, recent news) so they cross-check.
2. **Scout:** N × `pix-scout`. Prompt: goal + all researcher summaries + notes path `<WORK>/scout-<i>.md`.
3. **Build:** N × `pix-builder`. Prompt: goal + all researcher and scout summaries + their notes paths + draft path `<WORK>/builder-<i>.md`.
4. **Debate (one round, no replies):** one call per agent above, same agent type, all in one message. Prompt starts with `CRITIQUE:`, then says which summary is theirs, then gives the goal + every summary labeled by role and member.
5. **Synthesis:** one `pix-synth`. Prompt: goal, mode, today, every summary, every critique, the builder draft paths, and output path RUN. Do not rewrite its file.

### RUN format
```
# <Title>
<goal> · <mode> · <today>

## Answer
## Disagreements
## Still uncertain
## Sources
```

## 5. Tokens
Run: `python3 ~/.claude/skills/pix/tokens.py report ${CLAUDE_SESSION_ID} <WORK> <mode> <RUN>`

## 6. Report
Reply briefly: lead with the answer's gist in 3–6 lines, then one line per main disagreement (if any), then a line `Saved: <RUN as an absolute path>`. Nothing else, and no token counts.
