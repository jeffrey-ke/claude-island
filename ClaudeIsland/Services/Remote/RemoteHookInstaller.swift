//
//  RemoteHookInstaller.swift
//  ClaudeIsland
//
//  Idempotent installation of ccbridge-hook.py on a remote machine via SSH
//

import Foundation
import os.log

private let logger = Logger(subsystem: "com.claudeisland", category: "RemoteHookInstaller")

struct RemoteHookInstaller {

    private static let hookFilename = "ccbridge-hook.py"
    private static let hookIdentifier = "ccbridge-hook.py"  // String to match in commands
    private static let statuslineFilename = "ccmonitor-statusline.py"
    private static let bridgeSendFilename = "bridge_send.py"

    /// (bundled resource basename, ext, remote filename, chmod +x)
    private static let bundledScripts: [(resource: String, ext: String, remote: String, executable: Bool)] = [
        ("ccbridge-hook",         "py", "ccbridge-hook.py",         true),
        ("bridge_send",           "py", "bridge_send.py",           false),
        ("ccmonitor-statusline",  "py", "ccmonitor-statusline.py",  true),
    ]

    private static let hookEvents: [(event: String, needsMatcher: Bool, needsTimeout: Bool, preCompact: Bool)] = [
        ("UserPromptSubmit", false, false, false),
        ("PreToolUse",       true,  false, false),
        ("PostToolUse",      true,  false, false),
        ("PermissionRequest", true, true,  false),
        ("Notification",     true,  false, false),
        ("Stop",             false, false, false),
        ("SubagentStop",     false, false, false),
        ("SessionStart",     false, false, false),
        ("SessionEnd",       false, false, false),
        ("PreCompact",       false, false, true),
    ]

    /// Install hook scripts and update settings.json on remote host. Idempotent.
    static func install(host: String) async {
        logger.info("Installing bridge hooks on \(host, privacy: .public)")

        // Step 1: Copy all hook scripts to remote (ccbridge, bridge_send, statusline)
        for script in bundledScripts {
            guard await copyBundledScript(host: host, resource: script.resource, ext: script.ext, remote: script.remote, executable: script.executable) else {
                logger.error("Bailing out: failed to copy \(script.remote, privacy: .public)")
                return
            }
        }

        // Step 2: Read remote settings.json
        guard let settingsJSON = await readRemoteSettings(host: host) else { return }

        // Step 3: Update hooks + statusLine (idempotent)
        var json = settingsJSON
        let hooksChanged = addHooks(to: &json, python: "python3")
        let statuslineChanged = addStatusLine(to: &json, python: "python3")

        // Step 4: Write back if changed
        if hooksChanged || statuslineChanged {
            await writeRemoteSettings(host: host, json: json)
        } else {
            logger.info("Hooks + statusLine already installed on \(host, privacy: .public)")
        }
    }

    // MARK: - Private

    private static func copyBundledScript(host: String, resource: String, ext: String, remote: String, executable: Bool) async -> Bool {
        guard let bundledURL = Bundle.main.url(forResource: resource, withExtension: ext),
              let scriptContent = try? String(contentsOf: bundledURL, encoding: .utf8) else {
            logger.error("Failed to read bundled \(remote, privacy: .public)")
            return false
        }

        let chmodCmd = executable ? " && chmod +x ~/.claude/hooks/\(remote)" : ""

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-o", "ConnectTimeout=5",
            host,
            "mkdir -p ~/.claude/hooks && cat > ~/.claude/hooks/\(remote)\(chmodCmd)"
        ]

        let stdinPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            stdinPipe.fileHandleForWriting.write(scriptContent.data(using: .utf8)!)
            stdinPipe.fileHandleForWriting.closeFile()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                logger.info("Copied \(remote, privacy: .public) to \(host, privacy: .public)")
                return true
            } else {
                logger.error("Failed to copy \(remote, privacy: .public), exit code \(process.terminationStatus)")
                return false
            }
        } catch {
            logger.error("Failed to launch ssh for \(remote, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private static func readRemoteSettings(host: String) async -> [String: Any]? {
        let result = await ProcessExecutor.shared.runWithResult(
            "/usr/bin/ssh",
            arguments: ["-o", "ConnectTimeout=5", host, "cat ~/.claude/settings.json 2>/dev/null || echo '{}'"]
        )

        switch result {
        case .success(let processResult):
            guard let data = processResult.output.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                logger.error("Failed to parse remote settings.json")
                return [:]
            }
            return json
        case .failure(let error):
            logger.error("Failed to read remote settings: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func writeRemoteSettings(host: String, json: [String: Any]) async {
        guard let data = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]),
              let jsonString = String(data: data, encoding: .utf8) else {
            logger.error("Failed to serialize settings JSON")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-o", "ConnectTimeout=5",
            host,
            "cat > ~/.claude/settings.json"
        ]

        let stdinPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            stdinPipe.fileHandleForWriting.write(jsonString.data(using: .utf8)!)
            stdinPipe.fileHandleForWriting.closeFile()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                logger.info("Updated settings.json on \(host, privacy: .public)")
            } else {
                logger.error("Failed to write settings.json, exit code \(process.terminationStatus)")
            }
        } catch {
            logger.error("Failed to write remote settings: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Add ccbridge hooks to settings dict. Returns true if any changes were made.
    private static func addHooks(to json: inout [String: Any], python: String) -> Bool {
        let command = "\(python) ~/.claude/hooks/\(hookFilename)"
        let hookEntry: [String: Any] = ["type": "command", "command": command]
        let hookEntryWithTimeout: [String: Any] = ["type": "command", "command": command, "timeout": 86400]

        var hooks = json["hooks"] as? [String: Any] ?? [:]
        var changed = false

        for config in hookEvents {
            let entries: [[String: Any]]
            if config.preCompact {
                entries = [
                    ["matcher": "auto", "hooks": [hookEntry]],
                    ["matcher": "manual", "hooks": [hookEntry]],
                ]
            } else if config.needsMatcher && config.needsTimeout {
                entries = [["matcher": "*", "hooks": [hookEntryWithTimeout]]]
            } else if config.needsMatcher {
                entries = [["matcher": "*", "hooks": [hookEntry]]]
            } else {
                entries = [["hooks": [hookEntry]]]
            }

            if var existing = hooks[config.event] as? [[String: Any]] {
                let hasOurHook = existing.contains { entry in
                    if let entryHooks = entry["hooks"] as? [[String: Any]] {
                        return entryHooks.contains { h in
                            let cmd = h["command"] as? String ?? ""
                            return cmd.contains(hookIdentifier)
                        }
                    }
                    return false
                }
                if !hasOurHook {
                    existing.append(contentsOf: entries)
                    hooks[config.event] = existing
                    changed = true
                }
            } else {
                hooks[config.event] = entries
                changed = true
            }
        }

        json["hooks"] = hooks
        return changed
    }

    /// Add ccmonitor statusLine, skipping if the user already has a non-ccmonitor statusLine.
    /// Returns true if the settings were modified.
    private static func addStatusLine(to json: inout [String: Any], python: String) -> Bool {
        let command = "\(python) ~/.claude/hooks/\(statuslineFilename)"

        if let existing = json["statusLine"] as? [String: Any],
           let existingCmd = existing["command"] as? String {
            if existingCmd.contains(statuslineFilename) {
                // Already ours — keep or refresh.
                if existingCmd == command { return false }
                json["statusLine"] = ["type": "command", "command": command]
                return true
            } else {
                logger.warning("Existing statusLine on remote is not ccmonitor (\(existingCmd, privacy: .public)); skipping")
                return false
            }
        }

        json["statusLine"] = ["type": "command", "command": command]
        return true
    }
}
