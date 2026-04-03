# Tmux / System Integration Layer: Mechanisms Reference

This document covers the macOS and Swift library APIs used in the tmux/system integration
layer of Claude Island. For each class and major function, it explains which APIs are used,
why those specific APIs were chosen, and how the function composes them to achieve its effect.

---

## Table of Contents

1. [Foundation.Process — subprocess execution](#1-foundationprocess--subprocess-execution)
2. [ProcessExecutor](#processexecutor)
3. [ProcessTreeBuilder — ps(1) and lsof(1)](#3-processtreebuilder--ps1-and-lsof1)
4. [TmuxPathFinder — FileManager executable discovery](#4-tmuxpathfinder--filemanager-executable-discovery)
5. [TmuxTarget — value type for tmux addressing](#5-tmuxtarget--value-type-for-tmux-addressing)
6. [TmuxTargetFinder — pid-to-pane resolution](#6-tmuxtargetfinder--pid-to-pane-resolution)
7. [TmuxSessionMatcher — pane-content fingerprinting](#7-tmuxsessionmatcher--pane-content-fingerprinting)
8. [ToolApprovalHandler — programmatic key injection](#8-toolapprovalhandler--programmatic-key-injection)
9. [TmuxController — facade over tmux operations](#9-tmuxcontroller--facade-over-tmux-operations)
10. [TerminalAppRegistry — terminal identity table](#10-terminalappregistry--terminal-identity-table)
11. [TerminalVisibilityDetector — CGWindow and NSWorkspace](#11-terminalvisibilitydetector--cgwindow-and-nsworkspace)
12. [WindowFinder and YabaiWindow — yabai JSON window query](#12-windowfinder-and-yabaiwindow--yabai-json-window-query)
13. [WindowFocuser — yabai focus command](#13-windowfocuser--yabai-focus-command)
14. [YabaiController — end-to-end focus orchestration](#14-yabaicontroller--end-to-end-focus-orchestration)
15. [AppDelegate — IOKit, Sparkle, Mixpanel, NSApplication](#15-appdelegate--iokit-sparkle-mixpanel-nsapplication)
16. [Build and release pipeline — xcodebuild, notarytool, Sparkle tooling](#16-build-and-release-pipeline--xcodebuild-notarytool-sparkle-tooling)
17. [Entitlements and sandbox configuration](#17-entitlements-and-sandbox-configuration)
18. [Swift concurrency model used throughout](#18-swift-concurrency-model-used-throughout)

---

## 1. Foundation.Process — subprocess execution

**Framework:** Foundation  
**Type:** `Process` (formerly `NSTask`)

`Process` is the Foundation type that launches a child process, connects its standard
streams to `Pipe` objects, and lets the parent wait for exit. It is the only pure-Swift
way to run an external binary without dropping into POSIX `fork`/`exec` directly.

Key properties used in this codebase:

| Property / Method | Effect |
|---|---|
| `executableURL` | Full path to the binary as a `URL` — avoids shell parsing side-effects |
| `arguments` | Array of `String` arguments passed directly to `execve` — no shell quoting needed |
| `standardOutput = Pipe()` | Captures stdout in memory via a `Pipe`; avoids writing to a temp file |
| `standardError = Pipe()` | Captures stderr separately so it can be included in error messages |
| `process.run()` | Launches the child (throws `NSError` if the binary is missing) |
| `process.waitUntilExit()` | Blocks the calling thread until the child exits |
| `process.terminationStatus` | POSIX exit code; `0` means success |

The sandboxed alternative — `NSAppleScript` or `NSUserUnixTask` — imposes severe
restrictions and cannot invoke arbitrary binaries. `Process` works because the app
disables the macOS App Sandbox (see [section 17](#17-entitlements-and-sandbox-configuration)).

---

## 2. ProcessExecutor

**File:** `ClaudeIsland/Services/Shared/ProcessExecutor.swift`  
**Framework APIs:** `Foundation.Process`, `Foundation.Pipe`, `os.log`, Swift Concurrency  
**Pattern:** `actor` singleton with `withCheckedContinuation`

### Why an actor

Every caller of `ProcessExecutor` is already in an `async` context (Swift actors or
`async` functions). The `actor` keyword serialises internal state and allows callers
to `await` results without a callback.

### `runWithResult(_:arguments:)` — async wrapper around a blocking API

`Process.waitUntilExit()` is a blocking call. Running it on the cooperative thread pool
would starve other async work. The implementation bridges the blocking call into the
async world using `withCheckedContinuation`:

```swift
await withCheckedContinuation { continuation in
    let process = Process()
    // ... setup ...
    try process.run()
    process.waitUntilExit()          // blocks the current thread
    // ...
    continuation.resume(returning: .success(result))
}
```

`withCheckedContinuation` suspends the calling coroutine and hands a `CheckedContinuation`
token to the closure. When the synchronous work completes, `continuation.resume` wakes
the coroutine back up on the cooperative pool. This lets the blocking `waitUntilExit`
occupy a detached thread without holding a Swift concurrency executor thread.

### Error classification

The NSError domain `NSCocoaErrorDomain` with code `NSFileNoSuchFileError` is the signal
that the executable path does not exist. This is caught and mapped to
`.commandNotFound` rather than a generic failure so callers can distinguish "binary
not installed" from "binary ran and returned non-zero".

### `runSync(_:arguments:)` — nonisolated synchronous path

Some callers (`ProcessTreeBuilder`) operate in `nonisolated` or synchronous contexts
where they cannot `await`. `runSync` runs `Process` synchronously on the calling
thread. It is marked `nonisolated` so it can be called without actor isolation.
The `waitUntilExit()` call here is placed *after* reading stdout/stderr to avoid a
deadlock on full pipe buffers in longer-running commands.

### Logging with `os.log`

```swift
nonisolated static let logger = Logger(subsystem: "com.claudeisland", category: "ProcessExecutor")
```

`os.log` (the `Logger` type from the `os` framework) writes to the unified logging
system. The `privacy: .public` annotation on argument interpolations is required
because the default for string interpolation in `os.log` is `.private` (redacted
in crash logs unless the device is in developer mode). Paths and command names are
marked `.public` so they appear in Console.app during debugging.

---

## 3. ProcessTreeBuilder — ps(1) and lsof(1)

**File:** `ClaudeIsland/Services/Shared/ProcessTreeBuilder.swift`  
**Framework APIs:** None (pure `Process` invocations); uses `ProcessExecutor.runSyncOrNil`

### Why ps rather than sysctl or libproc

macOS exposes the process list through three mechanisms:
- **`sysctl` with `CTL_KERN`/`KERN_PROC`** — requires C interop and is not typed
- **`libproc` (`proc_pidinfo`)** — C API, also requires bridging
- **`/bin/ps`** — available on every macOS installation; output is plain text

The codebase favours `ps` because it stays entirely in Swift, requires no C headers,
and produces a stable `pid ppid tty comm` column layout that can be parsed with simple
string splitting.

### `buildTree()` — snapshot of the process forest

```swift
ProcessExecutor.shared.runSyncOrNil("/bin/ps", arguments: ["-eo", "pid,ppid,tty,comm"])
```

The `-e` flag selects every process on the system. `-o pid,ppid,tty,comm` specifies an
exact output format: PID, parent PID, controlling TTY, and the executable name (not the
full command line, which can vary). The result is a `[Int: ProcessInfo]` dictionary
giving O(1) parent lookup for any PID.

### `isDescendant(targetPid:ofAncestor:tree:)` — parent-chain walk

To determine whether a Claude process lives inside a given tmux pane, the code walks
upward through `ppid` links from the Claude PID until it either reaches the pane's
shell PID or exceeds a depth limit of 50 hops. This works because tmux panes are the
direct parents of the shell, which is the ancestor of any process the user starts in
that pane.

### `getWorkingDirectory(forPid:)` — lsof cwd extraction

macOS does not expose the current working directory of another process through a public
file path like Linux's `/proc/<pid>/cwd`. The canonical alternative is `lsof`:

```swift
ProcessExecutor.shared.runSyncOrNil("/usr/sbin/lsof", arguments: ["-p", String(pid), "-Fn"])
```

`-Fn` selects "name" fields only (`-F`) without column headers. The output line `fcwd`
marks a file-descriptor record of type "cwd", and the following line beginning with `n`
contains the path. The parser reads these two consecutive lines to extract the directory.

---

## 4. TmuxPathFinder — FileManager executable discovery

**File:** `ClaudeIsland/Services/Tmux/TmuxPathFinder.swift`  
**Framework APIs:** `Foundation.FileManager`

### Why not `which` or `PATH` lookup

Running `/usr/bin/which tmux` is an extra subprocess for every call. More importantly,
when a macOS app launches at login (as an LSUIElement background agent), its `PATH`
environment may not include Homebrew directories because the shell profile has not been
sourced.

`FileManager.default.isExecutableFile(atPath:)` checks the filesystem directly, with
no PATH resolution. The four candidate paths cover:

| Path | Meaning |
|---|---|
| `/opt/homebrew/bin/tmux` | Homebrew on Apple Silicon |
| `/usr/local/bin/tmux` | Homebrew on Intel |
| `/usr/bin/tmux` | System-provided (rare on macOS) |
| `/bin/tmux` | Fallback |

The result is cached in `private var cachedPath: String?` so the four filesystem
probes happen at most once per app lifetime. Because `TmuxPathFinder` is an `actor`,
concurrent calls safely observe the cached value after the first resolution.

---

## 5. TmuxTarget — value type for tmux addressing

**File:** `ClaudeIsland/Models/TmuxTarget.swift`  
**Framework APIs:** None (pure value type)

tmux addresses a specific pane using the string format `session:window.pane`,
e.g. `main:0.1`. All tmux CLI commands that operate on a pane accept a `-t` argument
in this format.

`TmuxTarget` is a `struct` (value type) that parses and stores the three components:

```swift
struct TmuxTarget: Sendable {
    let session: String
    let window: String
    let pane: String
    var targetString: String { "\(session):\(window).\(pane)" }
}
```

`Sendable` conformance (required because Swift actors pass this type across isolation
boundaries) is possible because all three fields are immutable `String` values.

The failable initializer `init?(from:)` splits on `:` then `.` using
`split(separator:maxSplits:)`. `maxSplits: 1` is important: session names can contain
dots in some configurations, so the split must stop at the first separator.

---

## 6. TmuxTargetFinder — pid-to-pane resolution

**File:** `ClaudeIsland/Services/Tmux/TmuxTargetFinder.swift`  
**Framework APIs:** `ProcessExecutor` (wraps `Foundation.Process`), `ProcessTreeBuilder`

### `findTarget(forClaudePid:)` — process-tree ancestry walk

The challenge: given the PID of a running Claude process, identify which tmux pane it
is running inside.

Step 1 — enumerate all panes with their shell PIDs:

```
tmux list-panes -a -F "#{session_name}:#{window_index}.#{pane_index} #{pane_pid}"
```

`-a` means "all sessions". The `-F` format string uses tmux variables:
`#{pane_pid}` is the PID of the shell process that tmux launched as the pane's
foreground process (typically bash or zsh).

Step 2 — for each pane, check whether the Claude PID is a descendant of the pane's
shell PID using `ProcessTreeBuilder.shared.isDescendant`. Because `buildTree()` reads
the process table once and `isDescendant` walks it in memory, this is fast even with
many panes.

The first pane whose shell PID is an ancestor of the Claude PID is the correct pane.

### `findTarget(forWorkingDirectory:)` — path-based fallback

When no PID is available, the format string changes to `#{pane_current_path}`.
tmux tracks the foreground process's working directory and updates `pane_current_path`
as the user navigates. The code does a direct string equality check against the
requested directory.

### `isSessionPaneActive(claudePid:)` — focus detection for tmux

```
tmux display-message -p "#{session_name}:#{window_index}.#{pane_index}"
```

`display-message -p` prints a format string to stdout rather than to the tmux status
bar. With no `-t` argument, it prints information about the *currently active* pane in
the *currently attached* client. Comparing this string against the target pane's string
determines whether the Claude session's pane is in the foreground.

---

## 7. TmuxSessionMatcher — pane-content fingerprinting

**File:** `ClaudeIsland/Services/Tmux/TmuxSessionMatcher.swift`  
**Framework APIs:** `ProcessExecutor`, `FileManager`, `FileHandle`

This class solves a correlation problem: Claude session state is stored in
`~/.claude/projects/<hash>/<session-id>.jsonl` files, but the filename is a UUID, not a
human-readable label. Given a tmux pane, which session file belongs to it?

### `capturePaneContent(tmuxPath:target:)` — reading terminal history

```
tmux capture-pane -t <target> -p -S -500
```

`capture-pane` copies the visible and scrollback content of a pane into a string.
`-p` prints to stdout. `-S -500` starts capture from 500 lines above the visible top,
providing context from recent conversation turns that should also appear in the
`.jsonl` file.

### `extractSnippets(from:)` — heuristic line filtering

The captured text includes ANSI escape sequences, tmux border characters, and UI
chrome. The filter pipeline:

1. Require line length ≥ 25 characters (short lines are UI chrome or prompts).
2. Skip lines beginning with box-drawing characters (`+-|>⏺─━═[]{}()`), which are
   tmux borders or Claude's spinner frames.
3. Skip comment lines (`//`, `/*`) which are code the user typed, not conversation.
4. Require that more than one third of characters in the line are letters — excludes
   JSON noise, hex dumps, and binary output.
5. Truncate to 80 characters — enough to be distinctive in a substring search.

Up to 5 snippets are returned, sampled evenly across the matching lines.

### `countMatchingSnippets(snippets:inFile:)` — FileHandle tail read

Reading 100 KB from the end of each session file, not the whole file. This uses
`FileHandle`:

```swift
let fileSize = (try? handle.seekToEnd()) ?? 0
let readSize: UInt64 = min(100000, fileSize)
try? handle.seek(toOffset: fileSize - readSize)
let data = try? handle.readToEnd()
```

`FileHandle.seekToEnd()` returns the file size as a side effect (it seeks to the byte
just past the last byte). The tail is read because recent conversation turns are at the
end of the append-only `.jsonl` file. A `String.contains` check for each snippet is
then O(n) in the tail size.

A match requires at least 2 snippets to appear in the same file, guarding against
false positives from common words or short unique tokens appearing in unrelated files.

---

## 8. ToolApprovalHandler — programmatic key injection

**File:** `ClaudeIsland/Services/Tmux/ToolApprovalHandler.swift`  
**Framework APIs:** `ProcessExecutor`, `os.log`, `Task.sleep`

Claude Code's tool-approval prompt is a terminal UI rendered in the tmux pane. The
user must type `1` (approve once), `2` (approve always), or `n` (reject) and press
Return. This handler automates that interaction.

### `sendKeys(to:keys:pressEnter:)` — two-step key injection

```
tmux send-keys -t <target> -l <text>
tmux send-keys -t <target> Enter
```

Two separate invocations are required because the `-l` ("literal") flag must not apply
to the `Enter` key name. Without `-l`, tmux interprets keys like `C-c`, `Enter`, and
`Escape` as key names. With `-l`, it sends every character literally — including the
word "Enter" as plain text. Splitting the two calls ensures the text is sent verbatim
and then a real Return key is injected.

### Rejection with a message — `Task.sleep` between sends

When rejecting with a reason message, there is a 100 ms gap between the `n` + Enter
that dismisses the prompt and the text + Enter that sends the rejection rationale:

```swift
try? await Task.sleep(for: .milliseconds(100))
```

Claude Code must process the `n` keypress and display the "reason" prompt before the
next send-keys lands. Without this gap, the message text arrives while the first prompt
is still active and is interpreted as another answer, not as the rejection reason.

---

## 9. TmuxController — facade over tmux operations

**File:** `ClaudeIsland/Services/Tmux/TmuxController.swift`  
**Framework APIs:** `ProcessExecutor`

`TmuxController` is a thin orchestration layer. It adds no logic of its own — it
delegates everything to the specialised actors below it — but it provides a single
stable call site for UI and coordinator code, decoupling callers from the internal
actor topology.

### `switchToPane(target:)` — two-step pane selection

```
tmux select-window -t <session>:<window>
tmux select-pane -t <session>:<window>.<pane>
```

Two commands are needed because `select-pane` alone fails if the target window is not
already the active window in its session. `select-window` must run first to make the
window current; only then does `select-pane` succeed. The session and window components
of `TmuxTarget` are used for `select-window`, and the full `targetString` is used for
`select-pane`.

---

## 10. TerminalAppRegistry — terminal identity table

**File:** `ClaudeIsland/Services/Shared/TerminalAppRegistry.swift`  
**Framework APIs:** None (pure data)

This is a static lookup table implementing the "fold knowledge into data" principle.
Two sets encode what the codebase knows about terminal applications:

- `appNames: Set<String>` — matched against `ps` command column output (process names)
- `bundleIdentifiers: Set<String>` — matched against `NSRunningApplication.bundleIdentifier`
  values returned by NSWorkspace

The two sets exist because the same app appears differently in different contexts:
`ps -o comm` shows a short process name (e.g. `WezTerm`), while NSWorkspace reports
the bundle ID (e.g. `com.github.wez.wezterm`). Centralising both in one place means
adding support for a new terminal emulator requires editing only this file.

---

## 11. TerminalVisibilityDetector — CGWindow and NSWorkspace

**File:** `ClaudeIsland/Utilities/TerminalVisibilityDetector.swift`  
**Framework APIs:** `CoreGraphics.CGWindowListCopyWindowInfo`, `AppKit.NSWorkspace`

### `isTerminalVisibleOnCurrentSpace()` — CGWindow on-screen enumeration

```swift
let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
CGWindowListCopyWindowInfo(options, kCGNullWindowID)
```

`CGWindowListCopyWindowInfo` is a CoreGraphics function that returns metadata about
all windows currently composited on screen. It does not require Accessibility permission
— it returns publicly-visible information about any window that is on-screen and not
minimised. The `.optionOnScreenOnly` flag excludes minimised and off-space windows,
so the result is scoped to the current Mission Control space.

Each dictionary in the returned array contains:
- `kCGWindowOwnerName` — the application name string
- `kCGWindowLayer` — the window layer; layer 0 is normal application windows

The layer check (`layer == 0`) excludes menu bar extras, overlays, and the desktop.
`TerminalAppRegistry.isTerminal(ownerName)` then determines whether the window belongs
to a known terminal.

This API gives a space-local answer, which is exactly what the notch UI needs: "is
there a terminal visible right now?"

### `isTerminalFrontmost()` — NSWorkspace frontmost app

```swift
NSWorkspace.shared.frontmostApplication
```

`NSWorkspace.shared.frontmostApplication` returns the `NSRunningApplication` that
currently holds keyboard focus. The bundle identifier is checked against
`TerminalAppRegistry.isTerminalBundle`. This is simpler and cheaper than CGWindow
enumeration when only the active app matters.

### `isSessionFocused(sessionPid:)` — combining both detectors

The function first calls `isTerminalFrontmost()` as a fast gate. If no terminal is
frontmost, the session cannot be focused — no further work is done.

If a terminal is frontmost, the code branches:

- **tmux session** — delegates to `TmuxTargetFinder.isSessionPaneActive(claudePid:)`,
  which checks whether the Claude session's pane is the active pane in the attached
  tmux client.
- **non-tmux session** — walks the process tree to find the terminal PID that owns
  the Claude process, then compares it to `frontmostApplication.processIdentifier`.

---

## 12. WindowFinder and YabaiWindow — yabai JSON window query

**File:** `ClaudeIsland/Services/Window/WindowFinder.swift`  
**Framework APIs:** `ProcessExecutor`, `Foundation.JSONSerialization`

[yabai](https://github.com/koekeishiya/yabai) is a third-party tiling window manager
for macOS. When installed, it exposes a `yabai -m query --windows` command that returns
a JSON array describing every window currently managed by the compositor, including
fields not available through public Apple APIs:

- `id` — yabai's internal window identifier, used with `yabai -m window --focus <id>`
- `pid` — the owning process PID
- `title` — the window title string
- `space` — the Mission Control space number
- `is-visible` and `has-focus` — current display state

### Why yabai instead of Accessibility API or CGWindow

`CGWindowListCopyWindowInfo` returns window metadata but cannot programmatically focus
a specific window. Focusing a window through the Accessibility API requires
`AXUIElementPerformAction(window, kAXRaiseAction)`, which in turn requires the user
to grant Accessibility permission to the app in System Settings. yabai — when
installed and configured — can focus windows without those permissions, and its JSON
output provides a richer data model (space number, visibility) than CGWindow.

The trade-off: yabai is an optional dependency. All paths in `WindowFinder` check
`isYabaiAvailable()` first and return empty/false if it is absent. The feature
degrades gracefully.

### Parsing

```swift
let output = try await ProcessExecutor.shared.run(path, arguments: ["-m", "query", "--windows"])
let jsonArray = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
return jsonArray.compactMap { YabaiWindow(from: $0) }
```

`JSONSerialization.jsonObject` converts the JSON bytes into Foundation objects
(`NSArray` of `NSDictionary`). The `YabaiWindow(from:)` failable initializer extracts
the required fields. `compactMap` discards any dict that fails initialisation.

### `nonisolated` filter helpers

Methods like `findTmuxWindow(forTerminalPid:windows:)` do not need actor isolation —
they receive an already-fetched `[YabaiWindow]` array and filter it without any
shared-mutable-state access. They are `nonisolated` so callers can invoke them
synchronously from within `YabaiController` without an extra `await`.

---

## 13. WindowFocuser — yabai focus command

**File:** `ClaudeIsland/Services/Window/WindowFocuser.swift`  
**Framework APIs:** `ProcessExecutor`

```
yabai -m window --focus <id>
```

`yabai -m window --focus <id>` raises and focuses the window identified by yabai's
numeric window ID. This command writes to yabai's Unix domain socket; yabai's server
process then issues the corresponding Quartz compositor calls.

`focusTmuxWindow(terminalPid:windows:)` attempts the best available window within
the terminal app:

1. A window whose title contains "tmux" (the user's tmux session window), found by
   `WindowFinder.findTmuxWindow`.
2. Any window for that terminal PID that does not contain the Claude indicator
   character "✳" in its title, found by `WindowFinder.findNonClaudeWindow`.

The fallback exists because some terminal configurations do not include "tmux" in the
window title.

---

## 14. YabaiController — end-to-end focus orchestration

**File:** `ClaudeIsland/Services/Window/YabaiController.swift`  
**Framework APIs:** `ProcessExecutor` (indirectly), `ProcessTreeBuilder`

`YabaiController` combines process-tree knowledge, tmux pane selection, and yabai
window focus into a single operation: "bring the terminal window running this Claude
session to the front."

### `focusTmuxInstance(claudePid:tree:windows:)` — the full focus path

1. `TmuxController.findTmuxTarget(forClaudePid:)` — resolves the Claude PID to a
   `TmuxTarget` (session:window.pane address).
2. `TmuxController.switchToPane(target:)` — makes the correct pane active within tmux
   using `select-window` + `select-pane`.
3. `findTmuxClientTerminal(forSession:tree:windows:)` — determines which terminal
   application window hosts the tmux client for this session (explained below).
4. `WindowFocuser.focusTmuxWindow(terminalPid:windows:)` — raises that window via yabai.

### `findTmuxClientTerminal(forSession:tree:windows:)` — client-to-terminal mapping

The challenge here is that multiple terminal windows can be attached to the same or
different tmux sessions simultaneously. The mapping from session name to terminal PID
is not exposed by CGWindow or NSWorkspace.

```
tmux list-clients -t <session> -F "#{client_pid}"
```

`list-clients -t <session>` lists only clients attached to the specified session.
`#{client_pid}` is the PID of the `tmux attach` process (or the tmux server process
that launched the client). For each client PID, the code walks up the process tree
looking for a process whose command name matches `TerminalAppRegistry.isTerminal` and
whose PID also appears in the set of yabai-known window PIDs. That PID is the terminal
application hosting this tmux session.

The intersection of "has a yabai window" and "is an ancestor of the tmux client" is
the correct terminal to bring into focus.

---

## 15. AppDelegate — IOKit, Sparkle, Mixpanel, NSApplication

**File:** `ClaudeIsland/App/AppDelegate.swift`  
**Framework APIs:** `IOKit`, `Sparkle`, `Mixpanel`, `AppKit.NSApplication`, `AppKit.NSWorkspace`

### IOKit — hardware UUID for analytics identity

```swift
import IOKit

let platformExpert = IOServiceGetMatchingService(
    kIOMainPortDefault,
    IOServiceMatching("IOPlatformExpertDevice")
)
defer { IOObjectRelease(platformExpert) }

let uuid = IORegistryEntryCreateCFProperty(
    platformExpert,
    kIOPlatformUUIDKey as CFString,
    kCFAllocatorDefault,
    0
)?.takeRetainedValue() as? String
```

`IOKit` is Apple's kernel-level I/O registry. `IOPlatformExpertDevice` is the root
node of the hardware device tree; `kIOPlatformUUIDKey` reads the machine's hardware
UUID, a stable 36-character string that identifies the physical Mac. This is used as
the Mixpanel `distinct_id` so analytics events from the same machine are correlated
across app reinstalls, without requiring a user account.

`IOObjectRelease` is called via `defer` to release the retained IOKit service reference
— IOKit uses reference counting outside of Swift's ARC system, so this manual release
is required.

If `IOKit` returns nil (possible in unusual VM configurations), the code falls back to
generating a random `UUID().uuidString` stored in `UserDefaults`.

### Sparkle — automatic updates

```swift
import Sparkle

let updater = SPUUpdater(
    hostBundle: Bundle.main,
    applicationBundle: Bundle.main,
    userDriver: userDriver,
    delegate: nil
)
try updater.start()
```

`SPUUpdater` is the main Sparkle entry point. It polls the `SUFeedURL` from `Info.plist`
(`https://claudeisland.com/appcast.xml`) and compares the `<enclosure sparkle:edSignature>`
in the appcast against the app's embedded `SUPublicEDKey` (an Ed25519 public key).
If the signature is valid and the version is newer, Sparkle downloads, verifies, and
installs the update.

The custom `NotchUserDriver` (conforming to `SPUUserDriver`) presents update prompts
inside the notch UI rather than in a standard window.

Updates are checked once at launch and then every 3600 seconds via a `Timer`:

```swift
Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
    guard let updater = self?.updater, updater.canCheckForUpdates else { return }
    updater.checkForUpdates()
}
```

`canCheckForUpdates` is Sparkle's gate that prevents overlapping checks.

### NSApplication activation policy

```swift
NSApplication.shared.setActivationPolicy(.accessory)
```

`.accessory` means the app has no Dock icon and does not appear in the Cmd+Tab
switcher. The notch window is the only UI surface. This policy is set after
`applicationDidFinishLaunching` has been called — setting it too early causes
the window to appear behind other windows on first launch.

### `ensureSingleInstance()` — NSWorkspace running application enumeration

```swift
NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == bundleID }
```

`NSWorkspace.shared.runningApplications` returns an array of `NSRunningApplication`
objects for all currently-running user-space processes. Filtering by `bundleIdentifier`
finds other instances of the same app. If more than one is found, the existing instance
is activated with `existingApp.activate()` and the new launch exits.

### Claude version detection via FileManager and FileHandle

The app reads `~/.claude/projects/**/*.jsonl` files to extract a `version` field.
`FileManager.contentsOfDirectory(at:includingPropertiesForKeys:)` fetches directory
listings with `contentModificationDateKey` so the most-recently-modified session file
can be identified without reading all files. `FileHandle(forReadingAtPath:)` reads only
the first 8192 bytes of that file to find the version field in early log entries.

---

## 16. Build and release pipeline — xcodebuild, notarytool, Sparkle tooling

**Files:** `scripts/build.sh`, `scripts/create-release.sh`, `scripts/generate-keys.sh`

### `xcodebuild archive` with Hardened Runtime

```bash
xcodebuild archive \
    -scheme ClaudeIsland \
    -configuration Release \
    -archivePath "$ARCHIVE_PATH" \
    -destination "generic/platform=macOS" \
    ENABLE_HARDENED_RUNTIME=YES \
    CODE_SIGN_STYLE=Automatic
```

`ENABLE_HARDENED_RUNTIME=YES` is required for Apple notarization. The Hardened Runtime
restricts a number of dangerous capabilities (code injection, dyld environment
variable injection, unsigned executable memory). The entitlements file (section 17)
grants the specific exceptions the app needs.

`CODE_SIGN_STYLE=Automatic` lets Xcode choose the signing identity from the developer's
Keychain, avoiding hard-coded team IDs in the script.

### Notarization — xcrun notarytool

```bash
xcrun notarytool submit "$ZIP_PATH" --keychain-profile "$KEYCHAIN_PROFILE" --wait
xcrun stapler staple "$APP_PATH"
```

Apple notarization is a server-side scan that checks the binary for known malware and
verifies the code signature. `notarytool submit --wait` blocks until Apple's servers
respond. `stapler staple` embeds the notarization ticket into the app bundle so Gatekeeper
can verify it offline (without a network call).

Both the `.app` and the final `.dmg` are notarized separately, because Gatekeeper
checks the outermost container (the DMG) at download time.

### Sparkle EdDSA signing — sign_update and generate_appcast

```bash
SIGNATURE=$("$SPARKLE_SIGN" --ed-key-file "$KEYS_DIR/eddsa_private_key" "$DMG_PATH")
"$GENERATE_APPCAST" --ed-key-file "$KEYS_DIR/eddsa_private_key" "$APPCAST_DIR"
```

Sparkle uses Ed25519 (EdDSA) for update signatures. `sign_update` produces a
base64-encoded signature for the DMG. `generate_appcast` produces the `appcast.xml`
file containing the version metadata and the `<enclosure sparkle:edSignature="..."/>`
attribute that Sparkle clients verify against `SUPublicEDKey` in `Info.plist`.

### Key generation — generate_keys

`scripts/generate-keys.sh` invokes Sparkle's `generate_keys` tool (bundled with
the Sparkle package and downloaded by SPM into Xcode's DerivedData):

```bash
"$GENERATE_KEYS" -x "$KEYS_DIR/eddsa_private_key"
```

`-x` exports the private key to a file. The corresponding public key is printed to
stdout and must be placed in `Info.plist` as `SUPublicEDKey`. The private key must
never be committed — the script appends `.sparkle-keys/` to `.gitignore` automatically.

---

## 17. Entitlements and sandbox configuration

**File:** `ClaudeIsland/Resources/ClaudeIsland.entitlements`

```xml
<key>com.apple.security.app-sandbox</key>
<false/>
<key>com.apple.security.files.user-selected.read-only</key>
<true/>
```

The App Sandbox (`com.apple.security.app-sandbox = false`) is disabled. This is the
critical permission that makes the entire integration layer possible:

- `Foundation.Process` can launch arbitrary binaries (`tmux`, `yabai`, `ps`, `lsof`)
- `FileHandle` can read files anywhere in the filesystem (`~/.claude/`)
- IOKit calls can query the hardware device tree

Sandboxed apps may not launch arbitrary subprocesses or access paths outside their
container without user file-picker approval.

The trade-off: disabling the sandbox means the app cannot be distributed through the
Mac App Store. It must be distributed as a notarized developer-id-signed app, which
is what the release pipeline produces.

`com.apple.security.files.user-selected.read-only = true` is a vestigial entitlement —
when sandbox is off, file access is governed by POSIX permissions alone. It has no
effect but signals intent.

### LSUIElement in Info.plist

```xml
<key>LSUIElement</key>
<true/>
```

`LSUIElement = true` marks the app as an "agent" (background app with no Dock icon
and no main menu). This is distinct from `setActivationPolicy(.accessory)` set at
runtime — `LSUIElement` prevents the default activation policy from flashing a Dock
icon during startup before the code runs.

---

## 18. Swift concurrency model used throughout

All service types in this layer follow the same pattern:

```swift
actor TmuxPathFinder {
    static let shared = TmuxPathFinder()
    private var cachedPath: String?
    ...
}
```

### Why `actor` over `class` with a lock

Swift actors enforce serial access to their stored properties at the language level.
All methods are implicitly async at actor isolation boundaries. This eliminates the
race conditions that arise from shared mutable state without requiring explicit
`DispatchQueue` or `NSLock` usage.

### `nonisolated` for pure functions

Functions that only read from their parameters (no actor state) are marked
`nonisolated`. This allows synchronous callers (e.g. `ProcessTreeBuilder` from a
synchronous context) to invoke them without an `await`.

### `Sendable` on value types

`TmuxTarget`, `YabaiWindow`, `ProcessInfo`, and `ProcessResult` all conform to
`Sendable` because they are immutable structs with `String` and `Int` fields.
`Sendable` conformance is required to pass these values across actor isolation
boundaries. Without it, the Swift compiler would flag the cross-actor transfers as
data-race hazards.

### `withCheckedContinuation` for blocking APIs

`Process.waitUntilExit()` is blocking. Rather than spawning a dedicated thread,
`ProcessExecutor.runWithResult` uses `withCheckedContinuation` to bridge the blocking
call into the async system — the continuation is resumed after the process exits,
returning control to the Swift concurrency scheduler.

---

*Document covers source as of the 1.2 release (commit 0c92dfc, 2026-04-02).*
