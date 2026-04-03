# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

Claude Island is a macOS menu bar app that renders a Dynamic Island-style overlay in the
MacBook notch area. It monitors Claude Code CLI sessions in real time, showing session
state (working/blocked/idle), tool approvals, and chat history. It communicates with
Claude Code via a Python hook script over a Unix domain socket.

Upstream repo: `farouqaldori/claude-island`. This clone lives inside the `ccmonitor`
project and is being modified for remote SSH session monitoring (see parent `../CLAUDE.md`
for the Stage 1/Stage 2 plan).

## Build Commands

```bash
# Debug build (Xcode)
xcodebuild -scheme ClaudeIsland -configuration Debug build

# Release build (archive + export)
./scripts/build.sh

# Full release (notarize + DMG + Sparkle sign + GitHub release + website deploy)
./scripts/create-release.sh

# Generate Sparkle EdDSA keys (first time only)
./scripts/generate-keys.sh
```

Requires macOS 15.6+, Xcode with Swift 6, and the Sparkle SPM dependency.

## Architecture

### Event Flow

```
Claude Code session
  → hook fires (PreToolUse/PostToolUse/Stop/Notification/SessionStart/PermissionRequest)
  → Python script (claude-island-state.py) connects to Unix domain socket
  → HookSocketServer receives JSON, emits SessionEvent
  → SessionStore.process(_:) updates state (actor-isolated)
  → Combine publisher → ClaudeSessionMonitor (@MainActor ObservableObject)
  → SwiftUI views redraw
```

For `PermissionRequest` events, the socket connection stays open. The app renders
approve/deny buttons in the notch; the response is written back on the same socket fd.
The Python script blocks on `sock.recv()` until the user acts or 300s timeout.

### Window System

The notch overlay is an `NSPanel` (not `NSWindow`) with `.nonactivatingPanel` so it
never steals focus. Key properties: `level = .mainMenu + 3` (above menu bar),
`.canJoinAllSpaces`, `ignoresMouseEvents` toggled by panel open/close state,
`PassThroughHostingView.hitTest` returns nil outside the visible region.

### State Management

`SessionStore` (Swift actor) is the single source of truth. All mutations flow through
`process(_ event: SessionEvent)`. State is published via `CurrentValueSubject` with
`nonisolated(unsafe)`, bridged to `@MainActor` via `receive(on: DispatchQueue.main)`.
Debounced file syncs use `Task.sleep` + `Task.isCancelled` for cooperative cancellation.

### IPC: Unix Domain Socket

`HookSocketServer` uses raw Darwin `socket/bind/listen/accept` with `AF_UNIX/SOCK_STREAM`.
Accept loop is driven by `DispatchSource.makeReadSource` (kqueue-backed, zero CPU when idle).
Client reads use `O_NONBLOCK` + `poll()` with 50ms timeout in a bounded loop.

### File Watching

`JSONLInterruptWatcher` and `AgentFileWatcher` use
`DispatchSource.makeFileSystemObjectSource` (kqueue `EVFILT_VNODE`) with `.write/.extend`
events for sub-millisecond file-change detection. Incremental reads via
`FileHandle.seek(toOffset:)` + `readToEnd()`.

### Tmux Integration

PID-to-pane resolution: `tmux list-panes -a -F "#{pane_pid}"` + process-tree ancestry walk.
Tool approval automation: `tmux send-keys -l <text>` (literal flag) then separate
`send-keys Enter`. `TmuxPathFinder` probes 4 Homebrew/system paths with
`FileManager.isExecutableFile` (not PATH lookup, because GUI apps lack Homebrew in PATH).

### Window Focus (optional yabai dependency)

Uses `yabai -m query --windows` for window discovery and `yabai -m window --focus <id>`
to raise terminal windows — avoids requiring Accessibility permission. Degrades gracefully
when yabai is absent. `CGWindowListCopyWindowInfo` (no permission needed) detects terminal
visibility on the current Space.

## Key Design Decisions

- **Sandbox disabled** (`com.apple.security.app-sandbox = false`) — required for
  `Process` launching arbitrary binaries, `FileHandle` reading `~/.claude/`, IOKit
  queries, and Unix socket creation. Consequence: Developer ID distribution only, no
  Mac App Store.
- **LSUIElement + .accessory activation policy** — no Dock icon, no Cmd-Tab entry.
  `LSUIElement` in Info.plist prevents startup flash; `setActivationPolicy(.accessory)`
  set in `applicationDidFinishLaunching`.
- **Actor isolation everywhere** — `SessionStore`, `ProcessExecutor`, `TmuxPathFinder`,
  `ConversationParser` are all actors. `nonisolated` used only for pure functions and
  the synchronous `runSync` path.
- **JSONSerialization over Codable** — Claude's JSONL schema is open-ended and
  version-dependent. Dictionary-based parsing preserves unknown keys and avoids schema
  brittleness.
- **String.contains over JSON parsing for interrupt detection** — speed on hot path +
  robustness against partial line writes.

## Mechanism Reference

Detailed documentation of every macOS/Swift framework API used in this codebase is in
`docs/`:

- `docs/mechanisms-ui-window.md` — NSPanel, SwiftUI hosting, hit-testing, animations,
  screen detection, CGEvent re-posting
- `docs/mechanisms-services-ipc.md` — Unix sockets, DispatchSource, actors, Combine,
  Process, JSONL parsing
- `docs/mechanisms-tmux-system.md` — tmux CLI, process trees, yabai, CGWindow,
  IOKit, Sparkle, build pipeline

See `docs/README.md` for an index with framework dependency table.

## Development Workflow

Code is written on the Linux server and pushed. Build and test happen on the Mac after
pulling. New `.swift` files created on Linux won't appear in the Xcode project until
added manually.

### Adding new Swift files to the project (on Mac after pulling)

1. `git pull`
2. Open `ClaudeIsland.xcodeproj` in Xcode
3. Right-click the appropriate group → **Add Files to "ClaudeIsland"**
4. Select the new `.swift` file(s)
5. Ensure the **ClaudeIsland target** is checked in the file inspector
6. Cmd+R to build and run

### Testing Stage 1: SSH Fetch + Parse

Stage 1 adds `Models/RemoteSessionStatus.swift`, `Services/Remote/StatusParser.swift`,
and a temporary test call in `AppDelegate.swift`.

**After pulling, add the new files to Xcode (see above), then:**

```bash
# Build
xcodebuild -scheme ClaudeIsland -configuration Debug build 2>&1 | tail -5

# Or just Cmd+R in Xcode
```

**Verify:** Check Xcode console (or Console.app, filter "RemoteSSH") for:
```
[RemoteSSH] 3 sessions:
  eval:2.0 working my-project ~/repo/project
  ipl:1.0 idle another-session ~/other/dir
```

**Compare against ground truth:**
```bash
ssh tesu cat ~/.claude/run/status
```

**Error case:** Change the host in the test call to `"nonexistent"`, rebuild. Expect
`Failed: executionFailed(...)` within ~5 seconds.

## Remote SSH Integration

Implementation stages are in `remote-ssh-stages.md`. Current progress: `stage1-progress.md`.

## Third-Party Dependencies (SPM)

- **Sparkle** — auto-update framework (EdDSA-signed appcast at claudeisland.com)
- **Mixpanel** — anonymous usage analytics (app launch, session start events only)
- **swift-markdown** — Markdown AST parsing for chat message rendering
