//
//  RemoteTmuxController.swift
//  ClaudeIsland
//
//  Sends tmux commands to remote sessions over SSH
//

import Foundation
import os.log

private let logger = Logger(subsystem: "com.claudeisland", category: "RemoteTmux")

actor RemoteTmuxController {
    static let shared = RemoteTmuxController()

    private init() {}

    /// Send a message (text + Enter) to a remote tmux pane
    func sendMessage(_ message: String, host: String, target: TmuxTarget) async -> Bool {
        guard await sendKeys(host: host, target: target, keys: message, pressEnter: true) else {
            return false
        }
        return true
    }

    /// Send Escape key to a remote tmux pane
    func sendEscape(host: String, target: TmuxTarget) async -> Bool {
        await sendKeys(host: host, target: target, keys: "", pressEnter: false, rawKey: "Escape")
    }

    // MARK: - Private

    private func sendKeys(host: String, target: TmuxTarget, keys: String, pressEnter: Bool, rawKey: String? = nil) async -> Bool {
        let targetStr = target.targetString

        do {
            if let rawKey = rawKey {
                // Send a raw key name (e.g. Escape)
                logger.debug("Sending \(rawKey) to \(host, privacy: .public) \(targetStr, privacy: .public)")
                _ = try await ProcessExecutor.shared.run(
                    "/usr/bin/ssh",
                    arguments: [host, "tmux", "send-keys", "-t", targetStr, rawKey]
                )
            } else if !keys.isEmpty {
                // Send literal text
                logger.debug("Sending text to \(host, privacy: .public) \(targetStr, privacy: .public)")
                _ = try await ProcessExecutor.shared.run(
                    "/usr/bin/ssh",
                    arguments: [host, "tmux", "send-keys", "-t", targetStr, "-l", keys]
                )
            }

            if pressEnter {
                _ = try await ProcessExecutor.shared.run(
                    "/usr/bin/ssh",
                    arguments: [host, "tmux", "send-keys", "-t", targetStr, "Enter"]
                )
            }

            return true
        } catch {
            logger.error("Failed to send keys to \(host, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
