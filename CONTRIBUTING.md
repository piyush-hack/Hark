# Contributing to Hark

Thanks for helping. Hark's bar is simple: it should feel like Apple built it, and it should never surprise the person using it.

## Setup

```bash
make test    # must pass
make run     # build and launch
```

Requirements: Apple Silicon, macOS 14+, Swift 5.10+, and Claude Code signed in (the brain). FluidAudio is pinned to 0.8.2, the last release that builds with Swift 5.10; bump it once the minimum toolchain moves to Swift 6.

## Ground rules

- **Instant beats smart.** If a command can be parsed with a rule, add it to `CommandParser` with a test instead of relying on the model.
- **Never surprise.** Anything destructive, outgoing (send/post/pay), or irreversible must go through `HarkEngine.confirm`.
- **Stay asleep.** New features must not keep a model, the microphone, or a timer busier than needed. The microphone is only open while a hotkey is held, in hands-free mode, or while Hark waits for a yes/no answer.
- **Private by default.** Speech stays on the Mac. Only requests that need thinking go to Claude, with just the context they need. No telemetry.
- **Match the house style.** SF Symbols, system materials, continuous corner radii, spring animations, sentence-case copy. Run `make snapshots` and attach before/after images to UI pull requests.

## Testing a change

- Parser: add cases to `Tests/HarkCoreTests/CommandParserTests.swift`.
- Speech: `harkctl listen file.wav` streams a recording through VAD, ASR, and the streaming planner.
- Brain: `harkctl agent "…" --dry` runs Claude with simulated tools; `--model=sonnet` to compare; `||` separates requests in one session.
- End to end: `harkctl run "…"` really executes.

## Releasing a new version

1. Write what changed, in plain words, to a file (it becomes the update window's text):

   ```markdown
   ## What's new
   - **Updates install themselves.** Hark offers new versions in a window.
   - Dictation keeps your place after “scratch that”.
   ```

2. With a clean working tree on `main`: `make publish VERSION=0.3.0 NOTES=whats-new.md`.

   This bumps `Resources/Info.plist`, builds and signs `dist/Hark-0.3.0.dmg` and `.zip`, commits “Release v0.3.0”, tags `v0.3.0`, pushes, and creates the GitHub release with both files. It uses the gh account `HARK_GH_USER` (default: the repository owner) without switching your active one.

3. Running copies pick it up at their next launch or within six hours. To try the update window before publishing, run `make release VERSION=…`, write a GitHub-style release JSON pointing at the zip with a `file://` URL, and launch an older build with `open --env HARK_UPDATE_FEED=file:///…/latest.json Hark.app`.

Versions must go up (0.2.0 → 0.2.1 → 0.3.0): installed copies compare numbers and only offer newer ones. Release from the Mac that holds the “Hark Local Signing” identity (or your `HARK_SIGN_IDENTITY`). The updater refuses builds signed by anyone else, and macOS keeps each user's permissions only while the signature stays the same.

## Pull requests

Keep them focused, include tests for parser or engine changes, and describe how you verified the change.
