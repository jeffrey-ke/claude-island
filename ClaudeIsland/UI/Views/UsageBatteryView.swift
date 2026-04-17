//
//  UsageBatteryView.swift
//  ClaudeIsland
//
//  Renders the Claude subscription 5-hour usage window as a horizontal
//  battery icon. When compact=false, also shows "N% · HhMm" text with a
//  live-updating countdown to reset time.
//

import Combine
import SwiftUI

struct UsageBatteryView: View {
    let usage: UsageInfo
    let compact: Bool

    @State private var now: Date = Date()

    private let timer = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    private var remainingPct: Int {
        max(0, min(100, Int((100 - usage.fiveHourUsedPct).rounded())))
    }

    private var fillColor: Color {
        switch remainingPct {
        case 50...: return TerminalColors.green
        case 20..<50: return .yellow
        default: return .red
        }
    }

    private var countdownText: String {
        let interval = usage.fiveHourResetsAt.timeIntervalSince(now)
        if interval <= 0 { return "reset" }
        let totalMinutes = Int(interval / 60)
        let h = totalMinutes / 60
        let m = totalMinutes % 60
        if h > 0 { return "\(h)h \(m)m" }
        return "\(m)m"
    }

    var body: some View {
        HStack(spacing: 4) {
            batteryIcon
            if !compact {
                Text("\(remainingPct)% · \(countdownText)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .fixedSize()
            }
        }
        .onReceive(timer) { now = $0 }
    }

    @ViewBuilder
    private var batteryIcon: some View {
        let bodyWidth: CGFloat = 14
        let bodyHeight: CGFloat = 7
        let fillRatio = CGFloat(remainingPct) / 100.0
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 1.5)
                    .stroke(Color.white.opacity(0.6), lineWidth: 1)
                    .frame(width: bodyWidth, height: bodyHeight)
                RoundedRectangle(cornerRadius: 0.5)
                    .fill(fillColor)
                    .frame(width: max(1, (bodyWidth - 2) * fillRatio), height: bodyHeight - 2)
                    .padding(.leading, 1)
            }
            Rectangle()
                .fill(Color.white.opacity(0.6))
                .frame(width: 1.5, height: 3)
        }
    }
}
