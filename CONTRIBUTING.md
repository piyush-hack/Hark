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

## Pull requests

Keep them focused, include tests for parser or engine changes, and describe how you verified the change.
