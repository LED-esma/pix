# Architecture

Pix is one macOS app (Swift, AppKit + SwiftUI, built with xcodegen) that is also its own tool server (`Pix --mcp`) and its own command-line tool (`Pix --ask`, `--selfcheck`, `--doctor`).

## The shape of a question

1. **You ask** in the card (`BubbleView.swift`), by voice (`Voice.swift`, `WakeWord.swift`) or from a schedule (`Scheduler.swift`).
2. **The controller** (`PixController+Runs.swift`) picks the AI (your choice, the failover order in `Provider.swift`, and hand-offs such as math leaving the built-in AI), adds context (memory, the project you called from, your screen when asked), and builds the run's arguments (`Solo.swift`).
3. **A runner** answers it. Both offer the same interface (`AgentRun` in `Engine.swift`) and send the same events:
   - **`Engine`**: Pix's own agent loop for every AI except Claude. It speaks Claude's Messages format to the AI's address (Ollama natively; OpenAI-style services through `Translator.swift`), starts Pix's tool server and your MCP apps (`MCPClient`), and handles project files itself (`ProjectFiles`). The built-in AI runs inside it through Apple's FoundationModels (`AppleModel.swift`).
   - **`ClaudeRunner`**: Claude Code headless (`claude -p`, stream-json), for Claude plans and teams (`Crew.swift`).
4. **Every tool call** comes back to the controller as a permission event and goes through Pix's rules (`permission(from:)`: read-only tools, Undo-able tools, risky clicks, Auto Mode's script guard, project edits). See [SAFETY.md](SAFETY.md).
5. **Tools run** in Pix's tool server (`BuiltIn.swift`); the ones that need the app (its browser window, your screen) reach it through a token-guarded HTTP bridge on 127.0.0.1 (`Bridge.swift`). Changes are logged with Undo (`Actions` in `BuiltIn.swift`).
6. **Free models are checked** (`Judge.swift`): if one skipped a tool it needed (claimed an action, answered live facts from memory), it gets one nudge, then the next AI takes over.
7. **The answer** shows on the card, with a walkthrough (`Screen.Step`) and a board of visuals when it has them (`BoardView.swift`, `Visuals.swift`, `Plugins/`).

## Where to look

| Area | Files |
|---|---|
| Runs: setup, launch, events, permissions, finish, hand-off, failover | `PixController+Runs.swift` |
| Pix's own engine, MCP client, project files | `Engine.swift` |
| The built-in AI (Apple Intelligence) | `AppleModel.swift` |
| One-click free AI: OpenRouter sign-in, local model download | `FreeAI.swift` |
| Claude Code (stream-json, events, install and sign-in) | `ClaudeRunner.swift` |
| Prompts, run arguments, card text | `Solo.swift`, `Schema.swift` |
| Teams (Ask the Team) | `Crew.swift` |
| AIs, failover order, services, translator | `Provider.swift`, `Services.swift`, `Translator.swift` |
| Built-in tools (MCP server), Undo log | `BuiltIn.swift` |
| Files, organizing; Mac settings and windows | `FileTools.swift`, `MacControl.swift` |
| Using your apps (Show Me / Do It), pointer | `ScreenControl.swift`, `Windows.swift` (`HighlightOverlay`) |
| Pix's browser window | `Browser.swift`, `Plugins/core/browser.js` |
| Bridge from tools to the app | `Bridge.swift` |
| Free-model checks | `Judge.swift` |
| Tools Pix makes, script approvals | `Routines.swift` |
| Timers and scheduled questions | `Scheduler.swift`, `PixController+Schedule.swift` |
| Project awareness (terminal or editor → folder, git) | `Project.swift` |
| Memory | `Memory.swift` |
| Voice, Auto Mode, "Hey Pix" | `Voice.swift`, `WakeWord.swift` |
| Card, board, blob | `BubbleView.swift`, `BoardView.swift`, `BlobView.swift`, `Blob.swift`; motion in `PixController+Card.swift`, `+Motion.swift`, `+Tour.swift` |
| Math and Markdown rendering (offline) | `MathText.swift`, `Plugins/core/markdown.js` |
| Welcome card, permissions | `Permissions.swift` |
| Hiding styles | `Hiding.swift` |
| Settings window, shortcut | `Settings.swift`, `HotKey.swift` |
| Updates and feedback | `Updater.swift` |
| Errors in plain words, run log, doctor | `RunLog.swift` |
| Self-checks (one for every behavior) | `SelfCheck.swift` |
| Command line (`--ask`, `--mcp`, `--selfcheck`, `--doctor`, test helpers) | `App.swift`, `Headless.swift` |

## Command line

```bash
Pix --ask "question" out.json [--on apple|local|cloud|claude|<service id>] [--project <dir>] [--auto]
Pix --selfcheck            # every behavior check (runs in build.sh)
Pix --doctor               # health
Pix --mcp                  # Pix's tool server (what each run starts)
Pix --screen-text <app>    # what Pix reads in an app
Pix --render-setup out.png # draw the setup card
```

Debugging: `PIX_ENGINE_LOG=<file>` logs the engine's requests; `PIX_RAW=<file>` logs Claude Code's stream; `PIX_AXDEBUG=1` dumps an app's accessibility tree.

## Tests

- `./build.sh` runs `Pix --selfcheck` (175 checks) and refuses to finish if any fails or the app isn't universal.
- `bench/daily_audit.py`: 18 everyday tasks end to end in a throwaway `~/PixAudit` (math, explaining, websites, folders, safety, developer help).
- `bench/pix_tests.py`, `bench/stress.py`: broader suites comparing AIs.
