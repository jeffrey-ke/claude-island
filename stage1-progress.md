# Stage 1: SSH Fetch + Parse — Progress

## Status: Code written, awaiting Mac build + test

## What was implemented

Three changes, all on the Linux server:

1. **`ClaudeIsland/Models/RemoteSessionStatus.swift`** (new)
   - Value type: target, state, name, cwd
   - Equatable, Sendable, Identifiable

2. **`ClaudeIsland/Services/Remote/StatusParser.swift`** (new)
   - Pure function `StatusParser.parse(_ raw: String) -> [RemoteSessionStatus]`
   - Parses the fixed-width table written by `claude_status.py`
   - Column offsets: TARGET 0-11, STATE 13-20, NAME 22-46, CWD 48+
   - Handles header line, empty input, "(no sessions detected)"

3. **`ClaudeIsland/App/AppDelegate.swift`** (modified)
   - Added temporary test call at end of `applicationDidFinishLaunching`
   - Runs `ssh -o ConnectTimeout=5 tesu cat ~/.claude/run/status`
   - Parses result with `StatusParser.parse()`, prints to console
   - Tagged with `[RemoteSSH]` for easy filtering
   - To be removed in Stage 2

## Build directions (on Mac)

```bash
# 1. Pull the changes
cd ~/repo/ccmonitor/claude-island
git pull

# 2. Open in Xcode
open ClaudeIsland.xcodeproj

# 3. Add new files to the project (they won't appear automatically):
#    - Right-click Models group → Add Files → select RemoteSessionStatus.swift
#    - Right-click Services group → New Group "Remote"
#    - Right-click Remote group → Add Files → select StatusParser.swift
#    - Ensure both have the ClaudeIsland target checked

# 4. Build and run
#    Cmd+R in Xcode, or:
xcodebuild -scheme ClaudeIsland -configuration Debug build 2>&1 | tail -5
```

## Test verification

Check Xcode console (or Console.app filtered to "RemoteSSH"):

**Success looks like:**
```
[RemoteSSH] 3 sessions:
  eval:2.0 working my-project ~/repo/project
  ipl:1.0 idle another-session ~/other/dir
  main:0.3 blocked unnamed ~/work
```

**Compare against:**
```bash
ssh tesu cat ~/.claude/run/status
```

**Error case:** Change host to `"nonexistent"` in AppDelegate, rebuild. Expect
`[RemoteSSH] Failed: executionFailed(...)` within ~5 seconds.

**Empty case:** If no sessions running on remote, expect `[RemoteSSH] 0 sessions:`.

## What's next (Stage 2)

- Remove the temporary test call from AppDelegate
- Create `RemoteSessionPoller` actor with 3s polling loop
- Emit synthetic `SessionEvent` values into `SessionStore`
- Remote sessions appear in the notch UI alongside local sessions
