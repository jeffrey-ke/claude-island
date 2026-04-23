//
//  SSHTunnelManager.swift
//  ClaudeIsland
//
//  Manages a reverse SSH tunnel for the remote bridge
//

import Combine
import Foundation
import os.log

private let logger = Logger(subsystem: "com.claudeisland", category: "SSHTunnel")

enum TunnelState: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting
}

@MainActor
class SSHTunnelManager: ObservableObject {
    static let shared = SSHTunnelManager()

    @Published private(set) var state: TunnelState = .disconnected
    @Published private(set) var currentHost: String = ""

    private var sshProcess: Process?
    private var reconnectTask: Task<Void, Never>?
    private var connectCheckTask: Task<Void, Never>?
    private let port: UInt16 = HookSocketServer.tcpPort

    private init() {}

    // MARK: - Public API

    func connect(host: String) {
        guard !host.isEmpty else { return }

        // Disconnect existing tunnel if any
        disconnectInternal()

        currentHost = host
        state = .connecting
        logger.info("\(LogTS.now()) Connecting tunnel to \(host, privacy: .public)")

        // Kill any stale tunnel processes from previous app runs
        killStaleTunnels()

        launchTunnel(host: host)
    }

    func disconnect() {
        disconnectInternal()
        state = .disconnected
        currentHost = ""
        logger.info("\(LogTS.now()) Tunnel disconnected")
    }

    // MARK: - Private

    private func killStaleTunnels() {
        // Kill any ssh -N -R 19876 processes left over from previous app runs
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        process.arguments = ["-f", "ssh -N -R \(port)"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }

    private func disconnectInternal() {
        reconnectTask?.cancel()
        reconnectTask = nil
        connectCheckTask?.cancel()
        connectCheckTask = nil

        if let process = sshProcess, process.isRunning {
            process.terminate()
            sshProcess = nil
        }

        // Best-effort: remove bridge_port file on remote
        if !currentHost.isEmpty {
            let host = currentHost
            Task.detached {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
                process.arguments = [
                    "-o", "ConnectTimeout=3",
                    host,
                    "rm -f ~/.claude/run/bridge_port"
                ]
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                try? process.run()
                // Fire and forget — don't wait
            }
        }
    }

    private func launchTunnel(host: String) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            await Self.killStaleRemoteTunnels(host: host)
            guard self.state == .connecting, self.currentHost == host else { return }
            self.launchTunnelProcess(host: host)
        }
    }

    /// Kill orphaned `sshd: <user>` tunnel-only sessions on the remote.
    /// Our Mac-side `killStaleTunnels()` only reaps the local ssh client; when that
    /// client dies uncleanly (Xcode SIGKILL, laptop sleep, network drop), the remote
    /// sshd can linger and keep the reverse-forwarded port bound, causing
    /// `ExitOnForwardFailure=yes` to fail the next launch with exit 255.
    /// Regex `^sshd: $USER$` targets only tunnel sessions (shells have `@pts/N`,
    /// exec sessions have `@notty`).
    private static func killStaleRemoteTunnels(host: String) async {
        _ = await ProcessExecutor.shared.runWithResult(
            "/usr/bin/ssh",
            arguments: [
                "-o", "ConnectTimeout=5",
                host,
                "pkill -u \"$USER\" -f \"^sshd: $USER\\$\" 2>/dev/null; true"
            ]
        )
    }

    private func launchTunnelProcess(host: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = [
            "-N",                                   // No remote command
            "-R", "\(port):localhost:\(port)",       // Reverse tunnel
            "-o", "ServerAliveInterval=30",          // Keep-alive
            "-o", "ServerAliveCountMax=3",           // 3 missed = disconnect
            "-o", "ExitOnForwardFailure=yes",        // Fail if port taken
            "-o", "ConnectTimeout=10",
            host
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        // Monitor for unexpected termination
        process.terminationHandler = { [weak self] proc in
            Task { @MainActor [weak self] in
                guard let self = self, self.sshProcess === proc else { return }
                self.sshProcess = nil

                if self.state == .connected || self.state == .connecting {
                    logger.warning("\(LogTS.now()) Tunnel to \(host, privacy: .public) exited with code \(proc.terminationStatus)")
                    self.scheduleReconnect(host: host)
                }
            }
        }

        do {
            try process.run()
            sshProcess = process
            logger.info("\(LogTS.now()) SSH process launched (pid \(process.processIdentifier))")

            // Check if tunnel is up after a short delay
            connectCheckTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                guard !Task.isCancelled else { return }
                guard let self = self else { return }

                if let proc = self.sshProcess, proc.isRunning {
                    self.state = .connected
                    logger.info("\(LogTS.now()) Tunnel to \(host, privacy: .public) connected")

                    // Write bridge_port file on remote
                    await self.writeBridgePort(host: host)

                    // Install hook script and settings on remote (idempotent)
                    await RemoteHookInstaller.install(host: host)
                }
            }
        } catch {
            logger.error("\(LogTS.now()) Failed to launch SSH: \(error.localizedDescription, privacy: .public)")
            scheduleReconnect(host: host)
        }
    }

    private func writeBridgePort(host: String) async {
        let result = await ProcessExecutor.shared.runWithResult(
            "/usr/bin/ssh",
            arguments: [
                "-o", "ConnectTimeout=5",
                host,
                "mkdir -p ~/.claude/run && echo \(port) > ~/.claude/run/bridge_port"
            ]
        )
        switch result {
        case .success:
            logger.info("\(LogTS.now()) Wrote bridge_port on \(host, privacy: .public)")
        case .failure(let error):
            logger.error("\(LogTS.now()) Failed to write bridge_port: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func scheduleReconnect(host: String) {
        state = .reconnecting
        reconnectTask?.cancel()

        reconnectTask = Task { [weak self] in
            logger.info("\(LogTS.now()) Reconnecting to \(host, privacy: .public) in 5 seconds...")
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled else { return }
            guard let self = self else { return }

            self.state = .connecting
            self.launchTunnel(host: host)
        }
    }
}
