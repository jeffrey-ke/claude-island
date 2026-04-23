//
//  LogTimestamp.swift
//  ClaudeIsland
//
//  Produces a human-readable timestamp prefix for log messages so copy-pasted
//  log excerpts carry their own wall-clock time without needing Console.app's
//  column. Eastern time, 12-hour, millisecond precision.
//
//  NOTE: after pulling on the Mac, add this file to the Xcode project
//  (right-click Utilities group → Add Files to "ClaudeIsland", check target).
//

import Foundation

enum LogTS {
    nonisolated(unsafe) private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd h:mm:ss.SSS a"
        f.timeZone = TimeZone(identifier: "America/New_York")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    /// Current wall-clock time formatted for log prefixes. Safe to call from any thread.
    static func now() -> String {
        formatter.string(from: Date())
    }
}
