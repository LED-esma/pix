# Privacy

Pix runs on your Mac. There is no Pix server, no account, and no analytics. This page says exactly what stays on your Mac and what goes where.

## What stays on your Mac

- **Your questions and answers, when you use the built-in AI or a free AI on your Mac** (Ollama, LM Studio, llama.cpp). Nothing leaves your computer.
- **Answers** are saved as Markdown files in `~/Pix/runs`, so you can find them later. Delete them anytime.
- **Memory**: short facts you mention ("I'm taking Calc 3") are kept in `~/Pix/memory.json`. Settings → General shows how many and forgets them (with Undo).
- **Changes Pix makes** (for Undo) are logged in `~/Pix/actions.jsonl`.
- **Keys** for AI services are kept in your Mac's Keychain.
- **"Hey Pix"** (off unless you turn it on) is recognized on your Mac; audio is never sent anywhere.

## What goes to the AI you choose

When you use an AI service (Claude, Gemini, OpenAI, OpenRouter, and others), your question goes to that service so it can answer, along with what the question needs:

- what you typed or said;
- facts from Memory that help;
- results of tools Pix ran for that question (your calendar for "what's due", a page's text, a folder's file names);
- a screenshot or the text of the app in front, only when you ask about your screen or ask Pix to use an app;
- your project's folder name, git state and files Pix reads, only when you call Pix from a terminal or code editor.

That service's own privacy policy then applies. Pix sends nothing to anyone else.

## What Pix can see

Pix uses macOS permissions, each asked for the first time it's needed and listed in Settings → Permissions:

| Permission | What Pix does with it |
|---|---|
| Reminders, Calendar | Reads and adds items when you ask |
| Accessibility | Reads the buttons of the app in front and clicks or types when you ask |
| Screen Recording | Takes a picture of the screen when you ask about it, or (on Claude) to use visual apps |
| Microphone, Speech Recognition | Hears you while you hold the shortcut, click the mic, or after "Hey Pix" if turned on |
| Automation | Runs AppleScript you approved, and controls apps like Notes and Music |

## Updates and feedback

- Once a day Pix asks GitHub whether a newer release exists (a plain request to the GitHub API; nothing about you is sent).
- **Send Feedback** opens a GitHub issue in your browser with Pix's version, your macOS version and which AI you use. You see it before you post it.

## Questions

Open an issue: <https://github.com/LED-esma/pix/issues>.
