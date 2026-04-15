//
//  RemoteHostPickerRow.swift
//  ClaudeIsland
//
//  SSH host selection picker for remote bridge settings
//

import SwiftUI

/// Parses ~/.ssh/config and returns Host names (excluding wildcards)
private func parseSSHConfigHosts() -> [String] {
    let configPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".ssh/config").path
    guard let content = try? String(contentsOfFile: configPath, encoding: .utf8) else {
        print("[RemoteHost] Failed to read SSH config at \(configPath)")
        return []
    }
    print("[RemoteHost] Parsed SSH config, \(content.components(separatedBy: .newlines).count) lines")
    return content.components(separatedBy: .newlines)
        .compactMap { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("Host ") else { return nil }
            let host = String(trimmed.dropFirst(5)).trimmingCharacters(in: .whitespaces)
            guard !host.contains("*") && !host.contains("?") && !host.isEmpty else { return nil }
            return host
        }
}

struct RemoteHostPickerRow: View {
    @ObservedObject private var tunnel = SSHTunnelManager.shared
    @State private var isHovered = false
    @State private var isExpanded = false
    @State private var selectedHost: String = AppSettings.remoteSSHHost
    @State private var bridgeEnabled: Bool = AppSettings.remoteBridgeEnabled
    @State private var hosts: [String] = parseSSHConfigHosts()

    var body: some View {
        VStack(spacing: 0) {
            // Main row — shows current selection
            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: "network")
                        .font(.system(size: 12))
                        .foregroundColor(textColor)
                        .frame(width: 16)

                    Text("SSH Bridge")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(textColor)

                    Spacer()

                    if selectedHost.isEmpty {
                        Text("None")
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.3))
                    } else {
                        Circle()
                            .fill(tunnelDotColor)
                            .frame(width: 6, height: 6)
                        Text(selectedHost)
                            .font(.system(size: 11))
                            .foregroundColor(.white.opacity(0.4))
                            .lineLimit(1)
                    }

                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(.system(size: 10))
                        .foregroundColor(.white.opacity(0.4))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isHovered ? Color.white.opacity(0.08) : Color.clear)
                )
            }
            .buttonStyle(.plain)
            .onHover { isHovered = $0 }

            // Expanded host list + enable toggle
            if isExpanded {
                VStack(spacing: 4) {
                    // Enable/disable toggle (only if a host is selected)
                    if !selectedHost.isEmpty {
                        BridgeToggleRow(isOn: bridgeEnabled) {
                            bridgeEnabled.toggle()
                            AppSettings.remoteBridgeEnabled = bridgeEnabled
                            if bridgeEnabled {
                                SSHTunnelManager.shared.connect(host: selectedHost)
                            } else {
                                SSHTunnelManager.shared.disconnect()
                            }
                        }
                    }

                    // "None" option
                    HostOptionRow(
                        host: "None",
                        isSelected: selectedHost.isEmpty
                    ) {
                        selectedHost = ""
                        bridgeEnabled = false
                        AppSettings.remoteSSHHost = ""
                        AppSettings.remoteBridgeEnabled = false
                        SSHTunnelManager.shared.disconnect()
                    }

                    // SSH config hosts
                    ForEach(hosts, id: \.self) { host in
                        HostOptionRow(
                            host: host,
                            isSelected: selectedHost == host
                        ) {
                            selectedHost = host
                            bridgeEnabled = true
                            AppSettings.remoteSSHHost = host
                            AppSettings.remoteBridgeEnabled = true
                            SSHTunnelManager.shared.connect(host: host)
                        }
                    }
                }
                .padding(.leading, 28)
                .padding(.top, 4)
            }
        }
        .onAppear {
            selectedHost = AppSettings.remoteSSHHost
            bridgeEnabled = AppSettings.remoteBridgeEnabled
        }
    }

    private var textColor: Color {
        .white.opacity(isHovered ? 1.0 : 0.7)
    }

    private var tunnelDotColor: Color {
        switch tunnel.state {
        case .connected:
            return TerminalColors.green
        case .connecting, .reconnecting:
            return TerminalColors.amber
        case .disconnected:
            return bridgeEnabled ? Color.white.opacity(0.3) : Color.white.opacity(0.3)
        }
    }
}

// MARK: - Host Option Row

private struct HostOptionRow: View {
    let host: String
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isSelected ? TerminalColors.green : Color.white.opacity(0.2))
                    .frame(width: 6, height: 6)

                Text(host)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(isHovered ? 1.0 : 0.7))

                Spacer()

                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(TerminalColors.green)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.white.opacity(0.06) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}

// MARK: - Bridge Toggle Row

private struct BridgeToggleRow: View {
    let isOn: Bool
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Circle()
                    .fill(isOn ? TerminalColors.green : Color.white.opacity(0.3))
                    .frame(width: 6, height: 6)

                Text(isOn ? "Bridge On" : "Bridge Off")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.white.opacity(isHovered ? 1.0 : 0.7))

                Spacer()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(isHovered ? Color.white.opacity(0.06) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .onHover { isHovered = $0 }
    }
}
