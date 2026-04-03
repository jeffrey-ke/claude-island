# Mechanism Reference Documentation

These documents catalog every macOS and Swift framework API used in Claude Island,
explaining **why** each API was chosen and **how** calls compose into higher-level
functions. They are intended as development reference for software agents working
on this codebase.

## Documents

| Document | Scope |
|---|---|
| [mechanisms-ui-window.md](mechanisms-ui-window.md) | NSPanel/NSWindow construction, SwiftUI hosting, hit-testing, click-through, notch shape geometry, screen detection, global event monitoring, animations, inverted-scroll chat, markdown rendering, CGEvent re-posting, ServiceManagement login items, accessibility checks |
| [mechanisms-services-ipc.md](mechanisms-services-ipc.md) | Unix domain sockets (Darwin), DispatchSource file watching, Swift actors for state management, Combine publishers, Foundation.Process subprocess execution, JSONL incremental parsing, Sparkle SPUUserDriver bridge, tool-use-id correlation |
| [mechanisms-tmux-system.md](mechanisms-tmux-system.md) | Tmux CLI integration (list-panes, capture-pane, send-keys, select-window), process tree building via ps/lsof, yabai window queries and focus, CGWindowListCopyWindowInfo, IOKit hardware UUID, Sparkle update pipeline, build/notarization/signing toolchain |

## Key Framework Dependencies

| Framework | Used For |
|---|---|
| **AppKit** (NSPanel, NSWindow, NSScreen, NSEvent, NSWorkspace) | Window management, screen detection, event monitoring, app enumeration |
| **SwiftUI** | All view content, animations, state binding via @Published |
| **CoreGraphics** (CGWindowList, CGEvent, CGDisplay) | Window enumeration, synthetic event injection, display identification |
| **Foundation** (Process, FileManager, FileHandle, JSONSerialization) | Subprocess execution, file I/O, JSON parsing |
| **Dispatch** (DispatchSource) | kqueue-based file watching, socket accept-loop |
| **Darwin** (socket, bind, listen, accept, poll, fcntl) | Unix domain socket IPC with hook scripts |
| **IOKit** (IOServiceGetMatchingService, IORegistryEntry) | Hardware UUID for analytics identity |
| **ServiceManagement** (SMAppService) | Launch-at-login registration |
| **os** (Logger) | Unified logging with privacy annotations |
| **Sparkle** (SPUUpdater, SPUUserDriver) | Auto-update with EdDSA signature verification |
| **Mixpanel** | Anonymous usage analytics |
| **swift-markdown** | Markdown AST parsing for inline styled text |

## Why the Sandbox is Disabled

The app sets `com.apple.security.app-sandbox = false` because its core functionality
requires capabilities that the sandbox blocks:

- `Foundation.Process` launching arbitrary binaries (tmux, yabai, ps, lsof)
- `FileHandle` reading files anywhere in `~/.claude/`
- IOKit queries to the hardware device tree
- Unix domain socket creation in `/tmp/`

This means the app cannot be distributed via the Mac App Store — it ships as a
notarized Developer ID-signed app instead.
