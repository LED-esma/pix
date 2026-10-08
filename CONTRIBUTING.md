# Contributing to Pix

Thanks for helping. Pix is for people who've never set up an AI tool, so every change is judged by one question: does it make Pix simpler and more dependable for them?

## Build and run

```bash
brew install xcodegen
tools/fetch-plugins.sh     # the board's libraries (pinned)
./build.sh                 # universal build into dist/, then the self-check (must pass)
./build.sh --install       # same, then installs to /Applications and relaunches
```

Without a Developer ID certificate, the build is signed ad hoc and works the same; macOS just asks for Screen Recording and Accessibility again after each rebuild.

Handy commands:

```bash
dist/Pix.app/Contents/MacOS/Pix --selfcheck                       # every behavior check
dist/Pix.app/Contents/MacOS/Pix --ask "question" out.json --on apple   # one headless question (apple, local, claude, or a service id)
dist/Pix.app/Contents/MacOS/Pix --doctor                           # health
dist/Pix.app/Contents/MacOS/Pix --screen-text Safari               # what Pix reads in an app
python3 bench/daily_audit.py --on local                            # 18 everyday tasks end to end
```

## Before you send a pull request

1. **Add a self-check** in `Sources/Pix/SelfCheck.swift` for the behavior you added or fixed, and make sure `./build.sh` passes.
2. **Keep the principles** in [PRINCIPLES.md](PRINCIPLES.md). In short:
   - the result first, in plain words, no emoji;
   - no directions or tips in the UI; buttons say what they do;
   - Undo instead of "are you sure?"; only irreversible actions ask;
   - zero setup: detect, don't ask.
3. **Safety first**: anything that can't be undone must go through Pix's rules (see [docs/SAFETY.md](docs/SAFETY.md)). Never add a path that types passwords or payment details.
4. **JavaScript lives in `Plugins/`** files, never inside Swift strings.
5. Describe what changed and how you tested it, with a screenshot for anything visible.

## Where things are

[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) maps every part of the app to its file.

## Reporting bugs

Right-click the blob → **Send Feedback**, or [open an issue](https://github.com/LED-esma/pix/issues/new/choose). Security problems go through [SECURITY.md](SECURITY.md) instead.

By contributing, you agree your contribution is under the [MIT License](LICENSE) and you follow the [Code of Conduct](CODE_OF_CONDUCT.md).
