# Architecture

Hark is two Swift targets over one library:

- **HarkCore** — all behavior. No SwiftUI. Testable from `harkctl` and XCTest.
- **Hark** — a menu-bar app (AppKit lifecycle + SwiftUI views) that only observes `HarkEngine` and forwards hotkey events.
- **harkctl** — a CLI over the same library for testing each layer in isolation.

## The life of a request

1. `HotkeyMonitor` sees ⌥⌘ go down (global `NSEvent` monitor; needs Accessibility) and calls `HarkEngine.beginListening(.command)`. Any other key while held cancels: it was a shortcut like ⌥⌘I. Taps under 0.3 s are ignored.
2. `AudioCapture` starts `AVAudioEngine` with voice processing on (Apple's echo cancellation and noise suppression), converting to 16 kHz mono. Samples stream through an `AsyncStream` to a single consumer task, so ordering is guaranteed.
3. `Segmenter` runs Silero VAD on 256 ms chunks. A pause of about half a second closes a segment, which `Transcriber` (Parakeet TDT v3 via FluidAudio, on the Neural Engine) turns into text.
4. `HarkEngine.ingest` appends the text to the pending utterance and asks `CommandParser.streamingPlan` what can run now. Closed commands run immediately; the open-ended tail is held for the next segment. If the tail looks like something only the agent can handle, the engine starts warming the model right away.
5. When ⌥⌘ is released, the rest of the audio is flushed and `CommandParser.plan` produces the final list: leading instant commands, then one `.agent(text)` for everything from the first unparseable clause on.
6. Commands run serially in `drain()`. Steps stream to the floating island. Commands that synthesize keystrokes wait for `waitForKeysReleased()`.
7. `.agent` runs `ClaudeBrain.run`: `claude -p` (the user's Claude Code sign-in) gets the request, context, and tool catalog, plus a screenshot with the area under the pointer boxed in red and a close-up of that area (its text and any selection go in a `[Pointing]` block), and replies with a JSON plan. Each step maps back onto the same executor and is logged; `"continue": true` sends results back for another round. The final answer is shown on the island as text.

## Modules

| Module | Responsibility | Key types |
|---|---|---|
| `Speech/` | Mic, VAD, ASR | `AudioCapture`, `Segmenter`, `Transcriber`, `AppleTranscriber`, `SpokenText` |
| `Brain/` | Understanding | `Command`, `CommandParser`, `Tools`, `ClaudeBrain` |
| `Actions/` | Doing | `AppCatalog`, `Browser`, `Keyboard`, `AX`, `ScreenText`, `SystemControl`, `Shell`, `Downloader` |
| `Automation/` | Event triggers, screen watchers | `Scheduler`, `Automation`, `ScreenWatch`, `RegionPicker`, `RegionFingerprint` |
| `ClaudeCode/` | Claude Code integration | `ClaudeBridge` |
| `Engine/` | Orchestration and UI state | `HarkEngine`, `Step`, `ActivityEntry` |

## Screen watchers

`“If this changes, click Yes”` parses to `.watch(WatchSpec)`. “Here/this” means the UI container under the pointer when you release the keys: `RegionPicker` asks Accessibility for the element at that point and climbs to a panel-sized ancestor, recording the owning app. While you're still talking, the app outlines that region live (`HighlightController`).

`Scheduler` checks each `ScreenWatch` about once a second, with no model involved:
- **Text watchers** read the region's (or app's) Accessibility text and fire when the match count goes up, so a new “hello” fires even when an old one is on screen. In “anywhere” mode the count is kept per app.
- **Change watchers** compare a 32×32 grayscale thumbnail of the region (needs Screen Recording) and fire when more than ~2% of it moves. Without Screen Recording they fall back to a hash of the region's Accessibility text.
- A 3-second cooldown stops feedback loops. When a watcher fires, a `click X` action presses `X` only inside that app and region, and stays silent if it isn't there. `alert/notify/tell me` shows a message on the island until it is closed, at most once per 15 s. Anything else runs like a normal voice command.

## Memory discipline

| Component | Resident when awake | When it sleeps |
|---|---|---|
| Hark at rest | ~300 MB, ~0% CPU | — (animations pause when idle; no background polling except watchers) |
| Parakeet + VAD | ~0.9 GB (Neural Engine) | After `speechIdleUnload` seconds (default 3 min); loads on ⌥⌘ press in ≈1 s |
| Brain | 0 MB | Runs in Claude; a `claude` process lives only for the ~3 s of each request |

Claude sessions resume (`--resume`) for ten minutes, so follow-ups keep context; instant commands are noted into the next request so “open its docs” makes sense.

## Extending

**Add an instant command**
1. Add a case to `Command` (with `title`, `spoken`, and `needsKeyboard` / `isOpenEnded` as appropriate).
2. Add a pattern in `CommandParser.parseClause` (or one of its `parse*` helpers) and a test in `Tests/HarkCoreTests`.
3. Handle it in `HarkEngine.execute`.

**Add an agent tool**
1. Declare it in `Tools.all` (keep the description short — it is part of every request's system prompt).
2. Handle it in `HarkEngine.runTool` and give it a label in `toolLabel`.

**Swap the brain**
`ClaudeBrain` only needs a CLI that takes a system prompt and a message and returns text. Any model that can follow the JSON plan format works; swap `ClaudeBrain.execute`/`ask` for another backend.

**Swap the ears**
`Transcriber` is a small actor around FluidAudio's `AsrManager`. Replace it with anything that maps `[Float]` (16 kHz mono) to `String`.

## Files on disk

`~/Library/Application Support/Hark/`
- `settings.json` — all preferences
- `automations.json` — scheduled tasks and watchers
- `activity.json` — recent history (clearable)
- `hark.log` — plain-text log for bug reports (rotated at 2 MB)
- `claude-brain/` — working folder for Hark's Claude sessions (kept apart from your projects)

