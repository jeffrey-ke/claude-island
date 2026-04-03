# Claude Island (remote SSH fork)

A macOS notch overlay for monitoring Claude Code sessions — forked from [farouqaldori/claude-island](https://github.com/farouqaldori/claude-island) and being modified to work with remote sessions over SSH.

## What's different from upstream

Upstream claude-island monitors local Claude Code sessions via a Unix domain socket. This fork adds remote session monitoring: it fetches session state from a Linux server over SSH and displays it alongside local sessions in the same notch UI.

The goal is a full remote control for Claude Code — see working/blocked/idle states, approve permissions, and send prompts, all from the Mac notch without switching to a terminal.

## Requirements

- macOS 15.6+
- Xcode with Swift 6
- SSH key auth configured for the remote host (`~/.ssh/config`)
- [ccmonitor](../) running on the remote server

## Build

```bash
xcodebuild -scheme ClaudeIsland -configuration Debug build
```

Or open `ClaudeIsland.xcodeproj` in Xcode and Cmd+R.

## Current status

**Stage 1: SSH Fetch + Parse** — code written, awaiting Mac build + test.

The app fetches `~/.claude/run/status` from the remote server via SSH, parses the fixed-width table into Swift structs, and logs the result. See `stage1-progress.md` for build and test instructions.

## Roadmap

| Stage | What it does | Status |
|---|---|---|
| 1 | SSH fetch + parse status file | Code written |
| 2 | Remote sessions appear in notch UI | Planned |
| 3 | Visual differentiation + settings UI | Planned |
| 4 | Approve/deny remote permissions | Planned |
| 5 | Richer detail via tmux pane captures | Planned |
| 6 | Send prompts to remote sessions | Planned |

See `remote-ssh-stages.md` for details on each stage.

## How it works

### Local sessions (upstream behavior, unchanged)

```
Claude Code → hook fires → Python script → Unix socket → app displays in notch
```

### Remote sessions (new)

```
Remote: hooks → state files → claude_status.py → ~/.claude/run/status
                                                        ↓
Local:  ssh fetch → StatusParser → SessionStore → notch UI
```

The remote path runs parallel to the local path. Both feed into the same `SessionStore`, so local and remote sessions appear side by side.

## Upstream features (preserved)

- Animated notch overlay that expands from the MacBook notch
- Live monitoring of multiple Claude Code sessions
- Approve or deny tool executions from the notch
- Full conversation history with markdown rendering
- Auto-update via Sparkle

## License

Apache 2.0
