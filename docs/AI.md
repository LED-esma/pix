# The AIs Pix runs on

## The order

Unless you rearrange them in **Settings → AI**, Pix uses: Claude (if you're signed in), the AI built into macOS, Gemini, OpenRouter, other services, a free AI on your Mac, then Ollama Cloud. The card's menu picks one for now; when it errors, hits a limit, or hands a question back, the next one answers and the card says who.

## The built-in AI (Apple Intelligence)

- Needs an Apple silicon Mac on macOS 26 or later with Apple Intelligence turned on. Free, private, on-device.
- Small (an 8,192-token window), so Pix gives it a short prompt and only the few tools a question needs.
- Math with numbers: it writes the steps as formulas and Pix computes each number exactly; if another AI is available, that one takes the math instead.
- Too much for it (live facts it can't look up, long jobs): it hands the question to the next AI.

## A free AI on your Mac

**Get Free AI** installs [Ollama](https://ollama.com) if needed and downloads a model that fits your Mac (qwen3:8b with 16 GB of memory or more on Apple silicon; qwen3:4b otherwise), with progress. Pix also finds models already in Ollama, LM Studio or a llama.cpp server.

## Claude

Your Claude Pro or Max plan, through [Claude Code](https://code.claude.com) (Pix installs it, no admin password, and opens the sign-in). Claude is the best at doing things in your apps and on the web, sees pictures for visual apps, and powers the research teams (**Ask the Team**).

## Any AI service

Settings → AI → **Add an AI**: OpenAI, Google Gemini, xAI, Mistral, Groq, Cerebras, DeepSeek, OpenRouter, or **Other…** for any address that speaks OpenAI's or Claude's format. Paste a key (Pix checks it and keeps it in your Keychain) and pick a model. **Sign In with OpenRouter** gets a key without copying one. You can also add a line to `~/Pix/services.json`:

```json
[{"id": "mine", "name": "My AI", "url": "https://example.com/v1", "model": "model-name", "api": "openai"}]
```

## How it works

- **Pix's own engine** (`Sources/Pix/Engine.swift`) runs every AI except Claude: it sends the question in Claude's Messages format, runs the tools the AI asks for (Pix's tool server and your MCP apps), and repeats until there's an answer. Ollama speaks that format natively; for OpenAI-style services, a small translator inside Pix (`Translator.swift`) converts it. The built-in AI runs through Apple's FoundationModels framework inside the same engine.
- **Claude** runs through Claude Code headless (`claude -p`, stream-json); Pix forces its permission mode to "ask Pix" so Pix's rules decide.
- Both send the same events (status, questions, permissions, results), so the card, Undo and safety rules don't care which AI answered.
