# Services and IPC Layer: macOS/Swift Mechanisms

This document describes each major class and function in the Services/IPC layer,
with focus on which macOS and Swift framework APIs are used, why those APIs were
chosen, and how the pieces compose.

---

## Table of Contents

1. [Hook IPC: Unix Domain Sockets](#1-hook-ipc-unix-domain-sockets)
   - [HookSocketServer](#hookSocketServer)
   - [claude-island-state.py (the hook script)](#claude-island-statepy)
   - [HookInstaller](#hookinstaller)
2. [File Observation: DispatchSource](#2-file-observation-dispatchsource)
   - [JSONLInterruptWatcher](#jsonlinterruptwatcher)
   - [AgentFileWatcher / AgentFileWatcherManager](#agentfilewatcher--agentfilewatchermanager)
3. [Conversation Parsing](#3-conversation-parsing)
   - [ConversationParser](#conversationparser)
4. [State Management: Swift Actors and Combine](#4-state-management-swift-actors-and-combine)
   - [SessionStore (actor)](#sessionstore-actor)
   - [FileSyncScheduler (actor)](#filesynscheduler-actor)
   - [ToolEventProcessor](#tooleventprocessor)
   - [SessionEvent enum](#sessionevent-enum)
5. [Process Inspection](#5-process-inspection)
   - [ProcessExecutor (actor)](#processexecutor-actor)
   - [ProcessTreeBuilder](#processtreebuilder)
   - [TerminalAppRegistry](#terminalappregistry)
6. [UI Binding Layer](#6-ui-binding-layer)
   - [ClaudeSessionMonitor](#claudesessionmonitor)
   - [ChatHistoryManager](#chathistorymanager)
7. [Auto-Update: Sparkle Bridge](#7-auto-update-sparkle-bridge)
   - [NotchUserDriver / UpdateManager](#notchuserdriver--updatemanager)
8. [Models and Utilities](#8-models-and-utilities)
   - [SessionEvent, FileUpdatePayload, ToolCompletionResult](#sessionevent-fileupdatepayload-toolcompletionresult)
   - [ChatMessage, MessageBlock, ToolUseBlock](#chatmessage-messageblock-toolUseblock)
   - [ToolResultData and subtypes](#toolresultdata-and-subtypes)
   - [AnyCodable](#anycodable)
   - [MCPToolFormatter](#mcptoolformatter)
   - [SessionPhaseHelpers](#sessionphasehelpers)

---

## 1. Hook IPC: Unix Domain Sockets

### HookSocketServer

**File:** `ClaudeIsland/Services/Hooks/HookSocketServer.swift`

**Purpose:** Receives lifecycle events from every active Claude Code session in
real time. For permission requests, it holds the connection open and waits for a
user decision before writing a response.

#### Darwin socket APIs

```swift
serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
bind(serverSocket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
listen(serverSocket, 10)
accept(serverSocket, nil, nil)
```

`AF_UNIX` / `SOCK_STREAM` creates a local, stream-oriented socket. This is the
right choice here for three reasons:

- The hook script runs on the same machine (no network needed).
- `SOCK_STREAM` gives ordered, reliable, in-order delivery — important because
  the hook for `PermissionRequest` must block until a response arrives.
- A Unix socket is just a filesystem path (`/tmp/claude-island.sock`), so the
  hook script connects with a single `socket.connect(SOCKET_PATH)` call in
  Python.

`unlink(socketPath)` before `bind` removes any stale socket file from a
previous run, preventing `EADDRINUSE`.

`chmod(Self.socketPath, 0o777)` makes the socket accessible to Claude Code's
child processes regardless of which user or sandbox context they run under.

#### Non-blocking I/O and poll

```swift
let flags = fcntl(serverSocket, F_GETFL)
_ = fcntl(serverSocket, F_SETFL, flags | O_NONBLOCK)

var pollFd = pollfd(fd: clientSocket, events: Int16(POLLIN), revents: 0)
let pollResult = poll(&pollFd, 1, 50)   // 50 ms timeout
```

`fcntl(F_SETFL, O_NONBLOCK)` sets the socket to non-blocking mode so that
`read()` returns immediately with `EAGAIN` instead of blocking when no data is
ready. `poll()` then waits up to 50 ms per iteration, which drives a tight
read loop bounded by a 500 ms wall-clock deadline. This pattern lets the server
drain a complete JSON payload that may arrive in multiple TCP segments without
blocking the dispatch queue thread indefinitely.

`SO_NOSIGPIPE` suppresses `SIGPIPE` on the client socket so that writing a
response to a dead connection returns `EPIPE` as an error code rather than
terminating the process.

#### GCD DispatchSource for accept-loop

```swift
acceptSource = DispatchSource.makeReadSource(fileDescriptor: serverSocket, queue: queue)
acceptSource?.setEventHandler { [weak self] in
    self?.acceptConnection()
}
acceptSource?.resume()
```

`DispatchSource.makeReadSource` asks the kernel (via kqueue internally) to
notify the app when the server socket has a pending connection. This is
level-triggered: the handler fires for every available connection, not just the
first. Compared to a polling loop or a blocking `accept()` thread, this uses
near-zero CPU when idle and integrates cleanly with Swift concurrency via the
serial `DispatchQueue`.

The cancel handler closes the file descriptor to avoid leaks:

```swift
acceptSource?.setCancelHandler { [weak self] in
    if let fd = self?.serverSocket, fd >= 0 {
        close(fd)
        self?.serverSocket = -1
    }
}
```

#### Pending permission map and NSLock

```swift
private var pendingPermissions: [String: PendingPermission] = [:]
private let permissionsLock = NSLock()
```

Permission requests keep the client socket open and store it in
`pendingPermissions` keyed by `toolUseId`. When the user approves or denies,
`sendPermissionResponse` writes a JSON `HookResponse` to the stored file
descriptor and closes it. The Python hook script is blocking on `sock.recv()`,
so it receives the response and outputs the appropriate JSON to stdout for
Claude Code to act on.

`NSLock` is used rather than an actor boundary because the permission map is
accessed from multiple GCD queues (the socket queue for reads, the main actor
for user actions routed through `queue.async`). A mutex is the minimal
serialization needed.

#### tool_use_id correlation cache

```swift
private var toolUseIdCache: [String: [String]] = [:]
private let cacheLock = NSLock()
```

`PermissionRequest` events from Claude Code do not carry a `tool_use_id` in
their hook payload, but `PreToolUse` events for the same tool do. The server
caches the `tool_use_id` from `PreToolUse` keyed by
`"sessionId:toolName:serializedInput"` (using `JSONEncoder` with `.sortedKeys`
for deterministic key generation). When a `PermissionRequest` arrives for the
same tool/input combination it pops the cached ID. The queue is FIFO to handle
concurrent tools with identical arguments.

---

### claude-island-state.py

**File:** `ClaudeIsland/Resources/claude-island-state.py`

**Purpose:** The bridge between Claude Code's hook system and the macOS app.
Claude Code invokes this script as a subprocess for every hook event.

#### Python socket IPC

```python
sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
sock.settimeout(TIMEOUT_SECONDS)
sock.connect(SOCKET_PATH)
sock.sendall(json.dumps(state).encode())
```

The script is a fire-and-forget client for most events: it connects, sends
JSON, and exits. For `PermissionRequest` it blocks on `sock.recv(4096)`,
waiting up to 300 seconds for a `HookResponse` from the app. When it receives
`decision: "allow"` it prints the structured JSON that Claude Code expects on
stdout and exits 0. For `decision: "deny"` it prints the denial JSON. For no
response it exits 0, which causes Claude Code to fall back to its built-in
permission UI.

#### TTY resolution

```python
ppid = os.getppid()
result = subprocess.run(["ps", "-p", str(ppid), "-o", "tty="], ...)
```

`os.getppid()` returns the PID of the Claude Code process that invoked the hook
script. `ps -o tty=` retrieves that process's controlling terminal so the app
can correlate sessions with terminal windows. The fallback uses
`os.ttyname(sys.stdin.fileno())`.

---

### HookInstaller

**File:** `ClaudeIsland/Services/Hooks/HookInstaller.swift`

**Purpose:** Ensures the hook script is installed into `~/.claude/hooks/` and
registered in `~/.claude/settings.json` every time the app launches.

#### FileManager for file deployment

```swift
let claudeDir = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".claude")

try? FileManager.default.createDirectory(at: hooksDir, withIntermediateDirectories: true)

if let bundled = Bundle.main.url(forResource: "claude-island-state", withExtension: "py") {
    try? FileManager.default.removeItem(at: pythonScript)
    try? FileManager.default.copyItem(at: bundled, to: pythonScript)
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pythonScript.path)
}
```

`Bundle.main.url(forResource:withExtension:)` locates the Python script bundled
inside the `.app` package. `FileManager.copyItem` deploys it to the user's home
directory. `setAttributes([.posixPermissions: 0o755])` makes it executable so
Claude Code can invoke it directly via `python3 ~/.claude/hooks/claude-island-state.py`.

#### JSONSerialization for settings patching

```swift
if let data = try? Data(contentsOf: settingsURL),
   let existing = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
    json = existing
}
// ... mutate json["hooks"] ...
if let data = try? JSONSerialization.data(withJSONObject: json,
                                          options: [.prettyPrinted, .sortedKeys]) {
    try? data.write(to: settingsURL)
}
```

`JSONSerialization` is used instead of `Codable` because `settings.json` has
an open-ended structure that should be preserved verbatim — only the hook
entries are added or removed. The installer checks for the presence of
`claude-island-state.py` in each hook entry before adding, making the operation
idempotent. `.sortedKeys` produces deterministic output so diffs against the
file remain readable.

#### Python detection via Foundation.Process

```swift
process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
process.arguments = ["python3"]
process.standardOutput = FileHandle.nullDevice
try process.run()
process.waitUntilExit()
```

`Foundation.Process` launches `/usr/bin/which python3` synchronously to decide
whether to write `python3` or `python` into the hook command string. This is
a one-time probe at install time, not in the hot path.

---

## 2. File Observation: DispatchSource

### JSONLInterruptWatcher

**File:** `ClaudeIsland/Services/Session/JSONLInterruptWatcher.swift`

**Purpose:** Detects when the user interrupts Claude mid-run by watching the
session's `.jsonl` file for interrupt-pattern lines. Fires faster than waiting
for the next hook event.

#### FileHandle + DispatchSource.makeFileSystemObjectSource

```swift
let handle = FileHandle(forReadingAtPath: filePath)
lastOffset = try handle.seekToEnd()

let newSource = DispatchSource.makeFileSystemObjectSource(
    fileDescriptor: fd,
    eventMask: [.write, .extend],
    queue: queue
)
newSource.setEventHandler { [weak self] in
    self?.checkForInterrupt()
}
newSource.resume()
```

`DispatchSource.makeFileSystemObjectSource` wraps a kqueue `EVFILT_VNODE` event.
The kernel delivers `.write` and `.extend` events when the file's content
changes — effectively a push notification, eliminating polling. This gives
sub-millisecond detection latency when Claude writes an interrupt record.

`seekToEnd()` is called before attaching the source so that the initial
position is at end-of-file. Subsequent `checkForInterrupt` calls read only the
bytes appended since the last call:

```swift
let currentSize = try handle.seekToEnd()
guard currentSize > lastOffset else { return }
try handle.seek(toOffset: lastOffset)
let newData = try handle.readToEnd()
lastOffset = currentSize
```

`FileHandle.readToEnd()` reads from `lastOffset` to the current end in a single
call, avoiding partial-line issues because Claude Code writes complete JSON
lines atomically.

The cancel handler closes the file handle:

```swift
newSource.setCancelHandler { [weak self] in
    try? self?.fileHandle?.close()
    self?.fileHandle = nil
}
```

This ensures the file descriptor is released when the watcher stops, regardless
of whether `stop()` or `deinit` triggers the cancellation.

#### Pattern matching without JSON parsing

```swift
private static let interruptContentPatterns = [
    "Interrupted by user",
    "interrupted by user",
    "user doesn't want to proceed",
    "[Request interrupted by user"
]

private func isInterruptLine(_ line: String) -> Bool {
    if line.contains("\"type\":\"user\"") { ... }
    if line.contains("\"tool_result\"") && line.contains("\"is_error\":true") { ... }
    if line.contains("\"interrupted\":true") { return true }
}
```

`String.contains` is used instead of full JSON parsing for two reasons: speed
(interrupt detection is on the hot path during active tool execution) and
robustness (a partial line write won't crash a string scan, but would fail
`JSONSerialization`).

---

### AgentFileWatcher / AgentFileWatcherManager

**File:** `ClaudeIsland/Services/Session/AgentFileWatcher.swift`

**Purpose:** Watches the JSONL file for a running subagent (Task tool) so the
UI can show subagent tool calls in real time while the parent session is still
active.

The mechanism is identical to `JSONLInterruptWatcher`:
`DispatchSource.makeFileSystemObjectSource` with `.write, .extend` events,
`FileHandle.seekToEnd()` for the initial position, and byte-range reads from
`lastOffset` on each event.

On each file event, `parseTools()` delegates to `ConversationParser.parseSubagentToolsSync`,
then diffs against a `seenToolIds` set to avoid emitting the same tool entry
twice. Results are dispatched to the main queue via `DispatchQueue.main.async`
before calling the delegate so UI updates always happen on `@MainActor`.

`AgentFileWatcherManager` is `@MainActor` and owns the watcher dictionary
keyed by `"sessionId-taskToolId"`. The bridge class `AgentFileWatcherBridge`
converts delegate callbacks into `SessionEvent.agentFileUpdated` and sends
them through `SessionStore.process()`.

---

## 3. Conversation Parsing

### ConversationParser

**File:** `ClaudeIsland/Services/Session/ConversationParser.swift`

**Purpose:** Parses the per-session `.jsonl` files that Claude Code writes,
extracting conversation summaries, full message histories, tool use/result
pairs, and incremental updates.

#### Swift actor for shared mutable cache

```swift
actor ConversationParser {
    static let shared = ConversationParser()
    private var cache: [String: CachedInfo] = [:]
    private var incrementalState: [String: IncrementalParseState] = [:]
}
```

`actor` provides mutual exclusion without explicit locks: all access to
`cache` and `incrementalState` is serialized by the actor's executor. Any
`await ConversationParser.shared.parse(...)` call suspends at the actor
boundary, queues, and resumes when the actor is free.

#### Modification-date caching

```swift
let attrs = try? fileManager.attributesOfItem(atPath: sessionFile)
let modDate = attrs[.modificationDate] as? Date

if let cached = cache[sessionFile], cached.modificationDate == modDate {
    return cached.info
}
```

`FileManager.attributesOfItem` retrieves file metadata (`NSFileModificationDate`)
without reading file content. Comparing the cached date against the current
modification date avoids re-parsing unchanged files — important because
`parse(sessionId:cwd:)` is called from multiple sites on every hook event.

#### Incremental byte-range reads with FileHandle

```swift
private func parseNewLines(filePath: String, state: inout IncrementalParseState) -> [ChatMessage] {
    let fileHandle = FileHandle(forReadingAtPath: filePath)
    let fileSize = try fileHandle.seekToEnd()

    if fileSize < state.lastFileOffset {
        state = IncrementalParseState()   // file was truncated (e.g. /clear)
    }

    try fileHandle.seek(toOffset: state.lastFileOffset)
    let newData = try fileHandle.readToEnd()
    state.lastFileOffset = fileSize
    ...
}
```

`FileHandle.seek(toOffset:)` positions the read cursor at the byte offset
saved from the previous call. `readToEnd()` then reads only the new bytes,
returning a `Data` value that is decoded as UTF-8 and split into lines. This
makes incremental parsing O(new bytes) rather than O(file size).

If `fileSize < lastFileOffset` the file was truncated (the user issued `/clear`
or the session was reset), so the incremental state is discarded and a full
re-parse begins.

#### ISO8601DateFormatter for timestamps

```swift
let formatter = ISO8601DateFormatter()
formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
```

Claude's JSONL timestamps use RFC-3339 format with fractional seconds. The
`ISO8601DateFormatter` with `.withFractionalSeconds` is the only Foundation
formatter that handles this without a custom `DateFormatter` pattern string.

#### JSONSerialization for line parsing

Individual JSONL lines are parsed with `JSONSerialization.jsonObject(with:)`.
This is preferred over `Codable` for the same reason as in `HookInstaller`:
Claude's JSONL schema is open-ended and version-dependent. Using a dictionary
representation allows extracting known keys while ignoring unknown ones without
schema brittleness.

---

## 4. State Management: Swift Actors and Combine

### SessionStore (actor)

**File:** `ClaudeIsland/Services/State/SessionStore.swift`

**Purpose:** Single source of truth for all session state. All mutations flow
through a single `process(_ event: SessionEvent)` entry point.

#### Swift actor for thread-safe state mutations

```swift
actor SessionStore {
    static let shared = SessionStore()
    private var sessions: [String: SessionState] = [:]
    private var pendingSyncs: [String: Task<Void, Never>] = [:]
}
```

`actor` provides data-race safety without manual locking. The compiler enforces
that `sessions` can only be read or written from within the actor's isolation
context. Callers from `@MainActor` or other actors must `await` to enter.

#### CurrentValueSubject for Combine publishing

```swift
private nonisolated(unsafe) let sessionsSubject = CurrentValueSubject<[SessionState], Never>([])

nonisolated var sessionsPublisher: AnyPublisher<[SessionState], Never> {
    sessionsSubject.eraseToAnyPublisher()
}
```

`CurrentValueSubject` holds the most recent session array and replays it to
any new subscriber — useful because the UI may subscribe after the first events
have already fired. `nonisolated(unsafe)` is required because `CurrentValueSubject`
is not itself an actor, but its `send()` method is called only inside the actor
(where access is already serialized). `eraseToAnyPublisher()` hides the concrete
subject type from callers.

After every event is processed, `publishState()` sends the updated sorted array:

```swift
private func publishState() {
    let sortedSessions = Array(sessions.values).sorted { $0.projectName < $1.projectName }
    sessionsSubject.send(sortedSessions)
}
```

#### Swift structured concurrency for debounced file sync

```swift
pendingSyncs[sessionId] = Task { [weak self, syncDebounceNs] in
    try? await Task.sleep(nanoseconds: syncDebounceNs)
    guard !Task.isCancelled else { return }
    let result = await ConversationParser.shared.parseIncremental(...)
    ...
    await self?.process(.fileUpdated(payload))
}
```

Each hook event that touches a file (`PreToolUse`, `PostToolUse`, `Stop`,
`UserPromptSubmit`) schedules a debounced sync. The existing `Task` for that
session is cancelled and replaced:

```swift
private func cancelPendingSync(sessionId: String) {
    pendingSyncs[sessionId]?.cancel()
    pendingSyncs.removeValue(forKey: sessionId)
}
```

`Task.cancel()` cooperatively cancels the sleeping task via `Task.isCancelled`
and the `CancellationError` thrown by `Task.sleep`. This avoids redundant JSONL
reads when multiple hook events arrive in rapid succession (e.g., a tool use
followed immediately by post-use).

---

### FileSyncScheduler (actor)

**File:** `ClaudeIsland/Services/State/FileSyncScheduler.swift`

A extracted version of the debounce logic above, encapsulated as its own actor
with a configurable `SyncHandler` callback. Uses the same `Task { try? await
Task.sleep(...) }` / `task.cancel()` pattern. The 100 ms debounce interval
(`100_000_000` nanoseconds) prevents chattering when tool use events arrive
closely together.

---

### ToolEventProcessor

**File:** `ClaudeIsland/Services/State/ToolEventProcessor.swift`

A stateless enum namespace containing pure functions that operate on
`inout SessionState`. These functions are called from `SessionStore` and do
not require actor isolation because they take state by `inout` reference
rather than capturing shared mutable state.

Key operations:

- `processPreToolUse` appends a placeholder `ChatHistoryItem` with `status: .running`
  immediately when the hook fires, so the UI shows the tool before the JSONL
  file is written.
- `processPostToolUse` marks the tool `.success` in the chat item array.
- `markRunningToolsInterrupted` sweeps `chatItems` and sets `.interrupted` on
  any still-running tools when a Stop or interrupt event arrives.

---

### SessionEvent enum

**File:** `ClaudeIsland/Models/SessionEvent.swift`

A `Sendable` enum that is the only legal channel for state mutations in
`SessionStore`. Each case carries exactly the data needed for that transition.
The `Sendable` conformance is required by Swift concurrency to safely send
values across actor boundaries.

`HookEvent` extensions (`determinePhase()`, `shouldSyncFile`, `isToolEvent`)
compute derived properties nonisolated so they can be called from any context
without an actor hop.

---

## 5. Process Inspection

### ProcessExecutor (actor)

**File:** `ClaudeIsland/Services/Shared/ProcessExecutor.swift`

**Purpose:** Wraps `Foundation.Process` in an async/sync API with structured
error types.

#### Foundation.Process with Pipe

```swift
let process = Process()
let stdoutPipe = Pipe()
let stderrPipe = Pipe()

process.executableURL = URL(fileURLWithPath: executable)
process.arguments = arguments
process.standardOutput = stdoutPipe
process.standardError = stderrPipe

try process.run()
process.waitUntilExit()

let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
```

`Foundation.Process` is the standard macOS API for spawning child processes.
`Pipe` creates a pair of connected file descriptors: the child writes to the
write end, the parent reads from `fileHandleForReading`. `readDataToEndOfFile()`
blocks until the child closes its write end (i.e., exits), delivering all
output in a single `Data` value.

#### withCheckedContinuation bridge to async/await

```swift
func runWithResult(_ executable: String, arguments: [String]) async -> Result<ProcessResult, ProcessExecutorError> {
    await withCheckedContinuation { continuation in
        let process = Process()
        ...
        try process.run()
        process.waitUntilExit()
        continuation.resume(returning: ...)
    }
}
```

`withCheckedContinuation` bridges the synchronous `process.waitUntilExit()` to
the async/await world. The continuation suspends the calling task, allowing
the Swift concurrency runtime to run other work while the subprocess executes.
`withCheckedContinuation` adds a debug assertion that `resume` is called exactly
once, catching misuse during development.

The actor isolation is intentional: concurrent calls to `runWithResult` are
serialized through the actor, preventing excessive subprocess spawning.

#### nonisolated runSync for non-async contexts

```swift
nonisolated func runSync(_ executable: String, arguments: [String]) -> Result<String, ProcessExecutorError> {
    let process = Process()
    ...
    try process.run()
    let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    ...
}
```

`nonisolated` lets `runSync` be called from non-actor contexts like
`ProcessTreeBuilder` which must operate synchronously during hook event
processing. The tradeoff (blocking the calling thread) is acceptable because
`ps` and `lsof` complete in well under a millisecond on local data.

---

### ProcessTreeBuilder

**File:** `ClaudeIsland/Services/Shared/ProcessTreeBuilder.swift`

**Purpose:** Builds a snapshot of the running process tree to determine whether
a Claude session is running inside tmux and to find the owning terminal app.

#### ps for process snapshot

```swift
ProcessExecutor.shared.runSyncOrNil("/bin/ps", arguments: ["-eo", "pid,ppid,tty,comm"])
```

`ps -eo pid,ppid,tty,comm` outputs a flat table of every running process with
its PID, parent PID, controlling TTY, and command name. This is parsed into a
`[Int: ProcessInfo]` dictionary. The format `comm` (not `command`) gives the
base executable name without arguments, keeping the output compact.

#### Ancestor walk for tmux and terminal detection

```swift
func isInTmux(pid: Int, tree: [Int: ProcessInfo]) -> Bool {
    var current = pid
    var depth = 0
    while current > 1 && depth < 20 {
        guard let info = tree[current] else { break }
        if info.command.lowercased().contains("tmux") { return true }
        current = info.ppid
        depth += 1
    }
    return false
}
```

Walking the `ppid` chain from the Claude process up toward PID 1 finds
`tmux: server` or `tmux: client` in the ancestry within a bounded number of
steps. The depth limit of 20 prevents infinite loops on corrupted or unusual
process trees.

#### lsof for working directory

```swift
ProcessExecutor.shared.runSyncOrNil("/usr/sbin/lsof", arguments: ["-p", String(pid), "-Fn"])
```

`lsof -Fn` outputs file descriptors in "field" format. The `cwd` entry appears
as a pair of lines: `fcwd` (type marker) followed by `n/actual/path` (name).
This is more reliable than reading `/proc` (which does not exist on macOS) and
more focused than parsing full `lsof` output.

---

### TerminalAppRegistry

**File:** `ClaudeIsland/Services/Shared/TerminalAppRegistry.swift`

A value-type registry of known terminal application names and bundle
identifiers. Both `appNames` and `bundleIdentifiers` are `Set<String>` for O(1)
lookup. The `isTerminal(_:)` function does a case-insensitive substring scan
rather than exact matching because the `comm` field from `ps` may be truncated
or include path components.

Bundle identifiers are used when matching against `NSRunningApplication` or
`CGWindowListCopy` results where the full bundle ID is available.

---

## 6. UI Binding Layer

### ClaudeSessionMonitor

**File:** `ClaudeIsland/Services/Session/ClaudeSessionMonitor.swift`

**Purpose:** `@MainActor` `ObservableObject` that bridges `SessionStore`'s
Combine publisher to SwiftUI `@Published` properties.

#### Combine receive(on:) for main-thread delivery

```swift
SessionStore.shared.sessionsPublisher
    .receive(on: DispatchQueue.main)
    .sink { [weak self] sessions in
        self?.updateFromSessions(sessions)
    }
    .store(in: &cancellables)
```

`receive(on: DispatchQueue.main)` routes all published values through the main
queue before the sink closure runs. This is necessary because `SessionStore` is
an actor with its own executor — its `publishState()` call sends values on the
actor's queue, not the main queue. The `@MainActor` class constraint on
`ClaudeSessionMonitor` does not automatically marshal Combine values; `receive(on:)`
does that explicitly.

`store(in: &cancellables)` ties the subscription lifetime to the monitor
object. When the monitor is deallocated, `cancellables` is deallocated, which
cancels all subscriptions.

#### Task bridging from closure callbacks to async

```swift
HookSocketServer.shared.start(
    onEvent: { event in
        Task {
            await SessionStore.shared.process(.hookReceived(event))
        }
        ...
    }
)
```

The `onEvent` closure runs on `HookSocketServer`'s private serial queue, which
is not an actor context. `Task { await ... }` schedules work on the Swift
concurrency cooperative thread pool, crosses into `SessionStore`'s actor context,
and returns without blocking the socket queue.

---

### ChatHistoryManager

**File:** `ClaudeIsland/Services/Chat/ChatHistoryManager.swift`

**Purpose:** `@MainActor` `ObservableObject` that maintains the per-session
chat history arrays for SwiftUI views.

Subscribes to `SessionStore.shared.sessionsPublisher` via the same
`receive(on: DispatchQueue.main).sink` pattern as `ClaudeSessionMonitor`,
rebuilding `histories` and `agentDescriptions` dictionaries whenever sessions
change.

`loadFromFile` and `syncFromFile` are `async` functions that call
`ConversationParser.shared` (an actor), then route results through
`SessionStore.shared.process(.fileUpdated(...))` — keeping the parsing work off
the main thread while still delivering results through the single state
mutation channel.

---

## 7. Auto-Update: Sparkle Bridge

### NotchUserDriver / UpdateManager

**File:** `ClaudeIsland/Services/Update/NotchUserDriver.swift`

**Purpose:** Integrates Sparkle's auto-update framework with the notch UI
without presenting any standard Sparkle windows.

#### SPUUserDriver protocol implementation

`NotchUserDriver` implements `SPUUserDriver`, which is Sparkle's protocol for
delegating all UI decisions to the host application. Every method
(`showUpdateFound`, `showDownloadDidReceiveData`, `showReady(toInstallAndRelaunch:)`,
etc.) receives a Sparkle callback and forwards it to `UpdateManager.shared` on
`@MainActor` via `Task { @MainActor in ... }`.

The reply closures (`(SPUUserUpdateChoice) -> Void` for install/skip/dismiss)
are stored as `installHandler` on `UpdateManager` and called from the UI when
the user makes a choice, completing the Sparkle state machine.

#### Combine @Published for SwiftUI binding

```swift
@MainActor
class UpdateManager: NSObject, ObservableObject {
    @Published var state: UpdateState = .idle
    @Published var hasUnseenUpdate: Bool = false
}
```

`@Published` wraps `state` in a `PassthroughSubject` that fires `objectWillChange`
before each mutation, triggering SwiftUI view redraws. `UpdateState` is a value
enum, so `Equatable` conformance allows SwiftUI to skip redraws when the value
has not changed.

`Task.sleep(for: .seconds(5))` in `noUpdateFound()` is the Swift 5.7+
`Duration`-based API, which integrates with the structured concurrency clock and
is cancellable via task cancellation.

---

## 8. Models and Utilities

### SessionEvent, FileUpdatePayload, ToolCompletionResult

Defined in `ClaudeIsland/Models/SessionEvent.swift`.

All three types conform to `Sendable`, which is required for them to be passed
as associated values through actor boundaries or in `Task` closures. This is a
Swift concurrency correctness requirement: the compiler rejects `Task { await
actor.process(event) }` if `event` is not `Sendable`.

`ToolCompletionResult.from(parserResult:structuredResult:)` is `nonisolated`
so it can be called from any concurrency context without an actor hop.

---

### ChatMessage, MessageBlock, ToolUseBlock

Defined in `ClaudeIsland/Models/ChatMessage.swift`.

`MessageBlock` is an enum with associated values rather than a class hierarchy.
This enables exhaustive `switch` at call sites without `is` casting, and
`Equatable` synthesis is automatic since all associated values are themselves
`Equatable`. `Identifiable` conformance on `MessageBlock` derives stable IDs
from type prefix and content hash, required for SwiftUI `ForEach` diffing.

---

### ToolResultData and subtypes

Defined in `ClaudeIsland/Models/ToolResultData.swift`.

`ToolResultData` is an enum with one case per tool type, each carrying a
typed struct (`BashResult`, `ReadResult`, `EditResult`, etc.). This represents
the "fold knowledge into data" principle: the selection of which struct to
use and what fields to expose is determined at parse time and folded into the
type, so display logic (`ToolStatusDisplay.completed`) switches on the enum
case and extracts only the fields it needs without conditional casting.

`MCPResult` and `GenericResult` use `@unchecked Sendable` because they contain
`[String: Any]` dictionaries — heterogeneous containers that Swift cannot prove
are Sendable. The custom `==` implementations for these types use
`NSDictionary(dictionary:).isEqual(to:)` which performs deep equality on
Foundation-compatible types.

---

### AnyCodable

Defined in `HookSocketServer.swift`.

`AnyCodable` is a type-erasing `Codable` wrapper for the `tool_input` field,
which can contain any JSON value type (string, int, bool, array, dict, null).
Swift's `Codable` requires statically-known types, so a custom
`init(from decoder:)` tries each concrete type in a priority order (null →
Bool → Int → Double → String → Array → Dictionary). Encoding reverses this by
switching on the underlying `Any` value.

`nonisolated(unsafe) let value: Any` is necessary because `Any` does not
conform to `Sendable`. The `unsafe` annotation is safe here because `AnyCodable`
is effectively immutable after initialization — its value is never mutated.

---

### MCPToolFormatter

Defined in `ClaudeIsland/Utilities/MCPToolFormatter.swift`.

A pure stateless struct. The `toolAliases` dictionary folds the mapping from
tool identifier to display name into data so that `formatToolName` does not
require branching for every known alias. MCP tool names follow the
`mcp__serverName__tool_name` convention; `split(separator:maxSplits:)` with
`maxSplits: 1` handles tool names that themselves contain underscores.

`toTitleCase` composes `split`, `map`, and `joined` — standard functional
transformations on `String.SubSequence` slices, avoiding intermediate array
allocation per character.

---

### SessionPhaseHelpers

Defined in `ClaudeIsland/Utilities/SessionPhaseHelpers.swift`.

A pure stateless struct of display helpers. `phaseColor(for:)` and
`phaseDescription(for:)` centralize the presentation mapping between
`SessionPhase` (a domain type) and SwiftUI `Color` / `String` (UI types),
keeping that coupling out of both the state model and the views themselves.

`timeAgo(_:now:)` uses `Date.timeIntervalSince` (a Foundation method returning
`TimeInterval` = `Double`) and integer arithmetic to produce short elapsed-time
strings. The `now:` parameter makes the function testable by injecting a fixed
reference time.
