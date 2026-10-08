# Pix

Floating macOS helper (Swift, AppKit + SwiftUI). Free AIs (this Mac, free keys, services, Ollama Cloud) run on Pix's own engine (`Engine.swift`); Claude runs on Claude Code headless (`claude -p`, stream-json), which subscriptions require. If a local HANDOFF.md exists (maintainer notes, not in git), read it first. README.md says what Pix does, docs/ARCHITECTURE.md maps the code, PRINCIPLES.md gives the rules behind every choice, docs/SAFETY.md the safety rules.

## Commands
- `./build.sh`: xcodegen + build + `--selfcheck` (must pass). `./build.sh --install` puts it in /Applications and relaunches.
- `dist/Pix.app/Contents/MacOS/Pix --ask "<q>" out.json [members] [--on local|cloud|<service>] [--project <dir>] [--use semester]`: headless run with structured JSON.
- `--doctor` health · `--render-math "<md>" out.png` renders card text · `--detect-project <bundle id>` · `--check-service <id> <key>` · `--mcp` is Pix's own tool server.
- `python3 bench/stress.py --on local|claude [--only a,b]`: end-to-end suite (~26 cases); a case passes only if the right tool really ran.

## Where to look
| Area | File |
|---|---|
| Runs: setup, launch, events, finish, hand-off, retry | `PixController+Runs.swift` |
| Talking to Claude Code (stream-json, events, setup) | `ClaudeRunner.swift` |
| Pix's own engine for every other AI: same arguments and events as a Claude Code run, Messages API to the AI's address, MCP client for Pix's tools and your apps, project Read/Glob/Grep/Edit/Write | `Engine.swift` (`AgentRun` is what both runners offer; `PIX_ENGINE_LOG=<file>` logs requests) |
| Lite prompts and args; card text | `Solo.swift` |
| Teams (Standard/Deep) | `Crew.swift` |
| What Pix runs on (Claude, Ollama, Ollama Cloud, services, gateway); verification | `Provider.swift`, `Services.swift` |
| Built-in tools (MCP server), Undo log, access | `BuiltIn.swift` |
| Pix's browser window; how tools reach the app (127.0.0.1 + token) | `Browser.swift`, `Plugins/core/browser.js`, `Bridge.swift` |
| Timers and scheduled runs | `Scheduler.swift`, `PixController+Schedule.swift` |
| Project awareness (terminal/editor/Claude app → folder, git, chip) | `Project.swift` |
| Free models: nudge once, then hand off to Claude | `Judge.swift` |
| Routines (named recipes) | `Routines.swift` |
| Memory | `Memory.swift` |
| Typed failures, run event log, doctor | `RunLog.swift` |
| Card UI / board / blob | `BubbleView.swift`, `BoardView.swift`, `BlobView.swift`; motion in `PixController+Card.swift`, `+Motion.swift` |
| Markdown + math rendering (JS, offline) | `Plugins/core/markdown.js`, `MathText.swift` |
| Welcome card, permissions list, tries | `Permissions.swift` (views in `BubbleView.swift`) |
| Hiding styles and behaviors (pill, eyes, sliver, corner, menu bar, notch; sleep, vanish, peek) | `Hiding.swift`, shapes in `BlobView.swift` |
| Settings window, shortcut recorder, main menu | `Settings.swift`, `HotKey.swift` |
| Using the user's apps (Show Me / Do It via Accessibility; screen_see + clicks by position on Claude; web pages in Chromium) | `ScreenControl.swift` (tools in `BuiltIn.swift`, reached through `Bridge.swift`; pointer hand and label in `Windows.swift` HighlightOverlay). Test with `Pix --screen-text <app or pid:N>` and `--screen-click <app> <n>`; `PIX_AXDEBUG=1` dumps the tree |
| Tools Pix makes (recipes, AppleScript, shell; approvals) | `Routines.swift` (`Scripts`), `BuiltIn.swift` |
| Any AI: catalog, OpenAI-style translator, failover order | `Services.swift`, `Translator.swift`, `Provider.swift` (`AIOrder`) |
| Voice (talk, spoken answers, voice choice), Auto mode | `Voice.swift`; "Hey Pix" in `WakeWord.swift` |
| Updates (GitHub Releases; off until `PixUpdateRepo` is set) | `Updater.swift` |
| Self-checks (add one for every behavior) | `SelfCheck.swift` |

## Conventions
- UI copy: no directions or tips anywhere; controls say what they do ("Project: pix", "Ask the Team"); empty fields say what Pix is for in one informative line, like Claude ("Ask anything or tell Pix what to do"), not a sample question; permission rows say what Pix does with it plus a "Try:" example; plain words, no emoji (answers too). Error text states what happened; the button is the action. Fewer options beats more: the card has one menu, and no folder chip, follow-up chip or suggestion buttons (they tested as unfriendly); project and follow-up context are handled quietly.
- Act, don't ask: reversible changes happen at once and appear on the card with Undo. Only irreversible actions ask: running a Shortcut, and browser clicks that submit, buy, send, sign in or delete (`PixBrowser.risk`). Pix never types passwords or payment details.
- Keep JavaScript in files under `Plugins/`, never inside Swift strings (escapes broke rendering twice).
- Free and other models: never show an answer that claims an action no tool performed; verify what ran from `modelUsage`.
- Logging via `Log.*` (os.Logger, subsystem com.ramonledesma.pix); goals are private.

## Don't
- Don't push, release, notarize or install unless the user asks. Build and self-check, then report.
- Don't download models or enter keys or passwords; the user does that in Pix's UI.
- Don't add confirmation dialogs; add Undo.
