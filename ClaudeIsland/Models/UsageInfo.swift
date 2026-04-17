//
//  UsageInfo.swift
//  ClaudeIsland
//
//  Subscription rate-limit snapshot surfaced by ccmonitor-statusline.py.
//  Global (account-wide), not per-session.
//

import Foundation

struct UsageInfo: Sendable, Equatable {
    let fiveHourUsedPct: Double
    let fiveHourResetsAt: Date
    let receivedAt: Date
}
