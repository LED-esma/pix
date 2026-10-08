# Pix principles

Adapted from [claw-code](https://github.com/ultraworkers/claw-code)'s PHILOSOPHY, ROADMAP and concept docs (read 2026-10-04). Claw-code is about running fleets of coding agents from Discord; these are the ideas that carry over to a personal helper, and where they live in Pix.

| Principle (claw-code) | What it means for Pix | Where |
|---|---|---|
| **Humans set direction; agents do the labor** | You type one sentence. Pix plans, uses tools, checks its work and comes back with the result, a change list with Undo, or one question. No babysitting. | `Solo.swift`, `Crew.swift`, `BuiltIn.swift` |
| **Keep monitoring out of the agent's context** | The app, not the model, tracks status, timers, schedules, history, what actually ran, and teams. The model only does the thinking. | `PixController+Schedule.swift`, `Crew.swift`, `Provider.answeredBy` |
| **State machine first** | Every run has explicit stages (started → ready → finished, or failed / recovered / handed off), logged as typed events. | `RunLog.swift` → `~/Pix/runs/events.jsonl` |
| **Events over scraped prose** | Failures are a type (`Trouble`), app startup comes from Claude Code's start event, tool use from real tool calls (never text that looks like a call). | `Trouble.classify`, `ClaudeRunner.Event.ready`, `Result.toolsCalled` |
| **Recovery before escalation** | Busy, rate-limited or briefly offline gets one quiet retry before you see anything. Free models hand off to Claude. Teams retry a member once and carry on. | `recoverOnce`, `fallBack`, `Crew.attempt` |
| **Partial success is first-class** | An app that failed to start, or a team member who didn't finish, is named on the card instead of silently missing. | `finish` (degraded note), `Crew.shortfall` |
| **Branch freshness before blame** | In project mode Pix says when the branch is behind its upstream, before calling something a new bug. | `Project.behind` |
| **Policy is executable** | Permission rules are code, not prompts: reading never asks; Pix's own changes carry Undo; Shortcuts ask; project reads are limited to that folder. | `Toolbox.isReadOnly`, `BuiltIn.allowedWithoutAsking`, `Read(//root/**)` |
| **Safe by default, explicit limits** | Step limits (16 Lite, 8 local), time limits per call, file reads capped and kept to the home folder, schedules bounded (timers ≤ 24 h, missed runs ≤ 12 h). Failures are predictable, never a loop. | `--max-turns`, `BuiltIn.fileRead`, `Schedules` |
| **Observable** | `Pix --doctor` reports health and recent troubles; headless `--ask` writes structured JSON; the self-check covers every behavior. | `Doctor`, `Headless`, `SelfCheck` |
| **Docs next to the code** | `CLAUDE.md` maps the code for any AI working on Pix; `AUDIT.md` records every decision. | `CLAUDE.md`, `AUDIT.md` |
| **Separate personality, memory and policy** (personal-assistant roadmap) | Memory is facts you can see and forget; policy is code; style lives in the prompts. | `Memory.swift`, permission rules, `Solo.systemPrompt` |

**Not adopted, on purpose**
- *Chat-app front end (Discord/Telegram):* Pix's interface is the blob on your screen. A phone bridge is a possible later addition, not the core.
- *Autonomous push/merge loops:* Pix never commits or publishes on its own. Changes stay on your Mac and can be undone.
- *Typed status tool instead of "Stage:" lines:* a tool call per stage costs a model turn each. Stage lines are free, and the stage is display-only, so text is fine there.
