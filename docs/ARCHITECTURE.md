# Architecture

Hark is two Swift targets over one library:

- **HarkCore** — all behavior. No SwiftUI. Testable from `harkctl` and XCTest.
- **Hark** — a menu-bar app (AppKit lifecycle + SwiftUI views) that only observes `HarkEngine` and forwards hotkey events.
- **harkctl** — a CLI over the same library for testing each layer in isolation.

## The life of a request

1. `HotkeyMonitor` sees ⌥⌘ go down (global `NSEvent` monitor; needs Accessibility) and calls `HarkEngine.beginListening(.command)`. Any other key while held cancels: it was a shortcut like ⌥⌘I. Taps under 0.3 s are ignored.
2. `AudioCapture` starts `AVAudioEngine` with voice processing on (Apple's echo cancellation and noise suppression), converting to 16 kHz mono. Samples stream through an `AsyncStream` to a single consumer task, so ordering is guaranteed.
3. `Segmenter` cuts phrases on energy against an adaptive noise floor; about a third of a second of quiet closes one. `Transcriber` (Parakeet TDT 0.6B v2 via FluidAudio, on the Neural Engine) turns it into text, with 0.45 s of silence appended so the last word isn't clipped.
4. If a text field has focus, `SpeechIntent.classify` decides what the phrase is for **before anything is typed** (next section). Otherwise `HarkEngine.ingest` appends the text to the pending utterance and asks `CommandParser.streamingPlan` what can run now. Closed commands run immediately; the open-ended tail is held for the next segment. If the tail looks like something only the agent can handle, the engine starts warming the model right away.
5. When ⌥⌘ is released, the rest of the audio is flushed and `CommandParser.plan` produces the final list: leading instant commands, then one `.agent(text)` for everything from the first unparseable clause on.
6. Commands run serially in `drain()`. Steps stream to the floating island. Commands that synthesize keystrokes wait for `waitForKeysReleased()`.
7. `.agent` runs `ClaudeBrain.run`: one long-lived Claude Code session (`claude -p --input-format stream-json`, the user's sign-in) gets the request, context, and a screenshot with the area under the pointer boxed in red plus a close-up (its text and any selection go in a `[Pointing]` block). Hark's actions are an MCP server (`Agent/MCPServer.swift`, streamable HTTP on 127.0.0.1 with a per-launch bearer token) next to the user's own MCP servers; Claude calls them in its own loop (`screenshot` to look again, `remember_how` / `forget_how` for learned how-tos) and its final message is shown on the island. Each tool call runs on the same executor as instant commands and is logged.

## Speech in a text field

Typing a command into a document is the worst thing Hark can do, so every phrase heard while a text field has focus is sorted locally first (`Brain/SpeechIntent.swift`, about 1 ms, no model):

- **stop** in any wording ("stop typing", "don't type", "bas", "that's enough") stops at once; plain words then aren't typed for a minute unless you say "type …" or "start typing".
- **keys** ("command z, command z", "undo", "next cell", "press enter") are pressed, the right number of times.
- **punctuation** said on its own ("new line", "comma", "full stop") is inserted.
- **words** are typed instantly, rendered by `Brain/Dictation.swift`: spoken punctuation and breaks, "all caps", "capital p", spelled-out letters ("H A R K" → Hark; a word said then spelled is written once), fillers dropped. In web editors they go in as key events, with line breaks as ⇧↩ so a chat doesn't send.
- **edits** ("scratch that", "put that in brackets", "make it bold", "delete the last line") are carried out: "scratch that" removes exactly the last words Hark typed; corrections of what was just dictated go to the writing pass; formatting, selection and cursor moves go to the writing model as exact edit steps.
- **requests** ("send it", "look at this screen", "open Chrome", "fill in a hundred rows") go to Hark's commands or Claude — never typed. "send it" in a chat or mail app presses its send key directly.
- **ask first**: when the words alone can't tell — an order about the text or the app while you're dictating ("add eggs to the list"), a sentence in a spreadsheet cell — the writing model decides (≈2 s) before anything is typed.
- **hold**: a sentence cut off by a pause ("Even though I") waits up to 2 s for the rest, then is taken as it is.

While you dictate (Hark typed into this field in the last two minutes, or you said "start typing"), sentences are text even when they're orders to the message's reader ("Please recharge using the wallet immediately"). A background **writing pass** (`EditorBrain`, Haiku) then fixes what speech recognition got wrong in the newest words and carries out corrections; it never removes a phrase or rewrites text you've already seen unless you asked.

The rules are checked against labeled phrase sets in `Tests/HarkCoreTests/Fixtures/` (`speech-corpus.json` and two unseen sets); `SpeechIntentCorpusTests` prints where each lands.

## Modules

| Module | Responsibility | Key types |
|---|---|---|
| `Speech/` | Mic, VAD, ASR | `AudioCapture`, `Segmenter`, `Transcriber`, `AppleTranscriber`, `SpokenText` |
| `Brain/` | Understanding | `Command`, `CommandParser`, `SpeechIntent`, `Dictation`, `EditorBrain`, `Tools`, `ClaudeBrain` |
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
`ClaudeBrain` needs an agent runtime that can call MCP tools. Claude Code is it today; anything that speaks MCP can drive `MCPServer` the same way (`harkctl agent` runs it against simulated tools).

**Swap the ears**
`Transcriber` is a small actor around FluidAudio's `AsrManager`. Replace it with anything that maps `[Float]` (16 kHz mono) to `String`.

## Files on disk

`~/Library/Application Support/Hark/`
- `settings.json` — all preferences
- `automations.json` — scheduled tasks and watchers
- `activity.json` — recent history (clearable)
- `hark.log` — plain-text log for bug reports (rotated at 2 MB)
- `claude-brain/` — working folder for Hark's Claude sessions (kept apart from your projects)

