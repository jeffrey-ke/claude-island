# Remote SSH Session Monitoring — Implementation Stages

## Overview

Make Claude Island display remote Claude Code sessions (fetched over SSH from ccmonitor's
status file) in its notch UI alongside local sessions, then progressively add
interactivity.

Everything downstream of `SessionStore.process(_ event: SessionEvent)` is already
transport-agnostic. A new `RemoteSessionPoller` sits parallel to `HookSocketServer`,
producing `SessionEvent` values from SSH-fetched status data.

```
Remote server: hooks → state files → claude_status.py → ~/.claude/run/status
                                                              ↓
Local Mac:     ssh fetch → parse → SessionEvent → SessionStore → existing UI
```

---

## Stage 1: SSH Fetch + Parse (no UI changes)

Prove that `ssh host cat ~/.claude/run/status` works from a macOS GUI app and the
fixed-width table parses into Swift structs.

- `SSHFetcher` actor — wraps ProcessExecutor, runs `/usr/bin/ssh` with 5s timeout
- `StatusParser` — pure function, parses fixed-width columns into `[RemoteSessionStatus]`
- `RemoteSessionStatus` — struct: target, state, name, cwd
- No existing files modified — self-contained
- **Verify:** temporary print/log, compare against `ssh tesu cat ~/.claude/run/status`

---

## Stage 2: Polling Loop + Sessions in UI

Remote sessions appear in the notch alongside local sessions.

- `RemoteSessionPoller` actor — 3s polling loop, diffs against previous state, emits
  synthetic `SessionEvent` values into `SessionStore`
- Add `isRemote`, `remoteHost`, `remoteTarget` to `SessionState`
- `SessionStore` skips local-only ops (file sync, process tree) for remote sessions
- `ClaudeSessionMonitor` starts/stops poller alongside HookSocketServer
- `Settings` gets `remoteSSHHost` and `remoteMonitoringEnabled`
- **Verify:** remote sessions appear with correct state colors, appear/disappear within ~3s

---

## Stage 3: UI Differentiation + Settings

Remote sessions look visually distinct. Connection status visible. SSH host configurable.

- `RemoteIndicator` component — SSH badge + tmux target on instance rows
- Instance rows disable "focus" and "chat" for remote sessions
- Settings menu gets Remote section: toggle, host field, connection status
- **Verify:** distinct visual treatment, settings work, error shown for bad host

---

## Stage 4: Remote Permission Approval

Approve/deny remote blocked sessions via SSH + tmux send-keys.

- `RemoteTmuxController` actor — `ssh host tmux send-keys -t target -l "1" ; ssh host tmux send-keys -t target Enter`
- `ClaudeSessionMonitor` routes approve/deny through RemoteTmuxController when
  `session.isRemote`, existing HookSocketServer path for local
- Optimistic UI transition after approval (don't wait for next poll)
- **Verify:** trigger permission on remote, approve from Mac notch, Claude proceeds

---

## Stage 5: Richer Remote Detail

Fetch tmux pane captures for blocked sessions to show context.

- `RemoteDetailFetcher` — `ssh host tmux capture-pane -p -t target` for blocked sessions
- Populates `conversationInfo.lastMessage` from pane capture
- Rate-limited to avoid SSH connection storms
- **Verify:** blocked remote sessions show what tool is requesting permission

---

## Stage 6: Send Prompts to Remote Sessions

Full interactivity — type in the notch, send to remote Claude Code.

- `RemoteTmuxController.sendPrompt()` — send-keys or load-buffer/paste-buffer for
  multi-line
- ChatView shows text input for remote sessions
- **Verify:** type prompt in notch, appears in remote tmux pane, Claude starts working

---

## Key Design Decisions

- **Parallel, not replacing**: RemoteSessionPoller runs alongside HookSocketServer
- **Session ID namespacing**: remote sessions use `"remote-{target}"` to avoid collisions
- **Synthetic HookEvents**: reuse existing processHookEvent() path
- **SSH via Foundation.Process**: each poll spawns `/usr/bin/ssh`; ControlMaster handles
  connection reuse
- **Optimistic transitions**: after sending approval, immediately update UI
