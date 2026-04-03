# Stage 1: SSH Fetch + Parse — Progress

## Status: Complete and verified (2026-04-03)

## What was implemented

Three changes to claude-island:

1. **`ClaudeIsland/Models/RemoteSessionStatus.swift`** (new)
   - Value type: target, state, name, cwd
   - Equatable, Sendable, Identifiable

2. **`ClaudeIsland/Services/Remote/StatusParser.swift`** (new)
   - Pure function `StatusParser.parse(_ raw: String) -> [RemoteSessionStatus]`
   - Parses the fixed-width table written by `claude_status.py`
   - Column offsets: TARGET 0-13 (14 wide), STATE 15-22, NAME 24-48, CWD 50+
   - Handles header line, empty input, "(no sessions detected)"

3. **`ClaudeIsland/App/AppDelegate.swift`** (modified)
   - Added temporary test call at end of `applicationDidFinishLaunching`
   - Runs `ssh -o ConnectTimeout=5 tesu cat ~/.claude/run/status`
   - Parses result with `StatusParser.parse()`, prints to console
   - Tagged with `[RemoteSSH]` for easy filtering
   - To be removed in Stage 2

## Column width fix (2026-04-03)

Initial implementation used `{target:<12}` in `claude_status.py`, which truncated targets
longer than 12 chars (e.g. `ccmonitor:1.0` = 13 chars). Fixed by widening to `{target:<14}`
in both `claude_status.py` (remote server) and the parser offsets in `StatusParser.swift`.

## Verified output (2026-04-03)

```
[RemoteSSH] 2 sessions:
  eval:0.1 blocked omnigraph explainer po/visual_servoing/datagen2_isaacsim
  ccmonitor:1.0 idle cks-documentation-archit ~/repo/ccmonitor/claude-island
```

Matches `ssh tesu cat ~/.claude/run/status` ground truth.

## What's next (Stage 2)

- Remove the temporary test call from AppDelegate
- Create `RemoteSessionPoller` actor with 3s polling loop
- Emit synthetic `SessionEvent` values into `SessionStore`
- Remote sessions appear in the notch UI alongside local sessions
