import Foundation

struct StatusParser {

    static func parse(_ raw: String) -> [RemoteSessionStatus] {
        let lines = raw.components(separatedBy: .newlines)
        var results: [RemoteSessionStatus] = []

        for line in lines {
            if line.isEmpty || line.hasPrefix("TARGET") || line.contains("(no sessions detected)") {
                continue
            }
            guard let session = parseLine(line) else { continue }
            results.append(session)
        }

        return results
    }

    private static func parseLine(_ line: String) -> RemoteSessionStatus? {
        // Format from claude_status.py write_status():
        //   f"{target:<14} {s['state']:<8} {name:<25} {cwd}"
        // Offsets: TARGET 0-13, STATE 15-22, NAME 24-48, CWD 50+

        guard line.count >= 24 else { return nil }

        let target = sliceField(line, start: 0, end: 14)
        let state = sliceField(line, start: 15, end: 23)

        guard !target.isEmpty, !state.isEmpty else { return nil }

        let name = line.count >= 49 ? sliceField(line, start: 24, end: 49) : ""
        let cwd = line.count >= 50 ? sliceField(line, start: 50, end: line.count) : ""

        return RemoteSessionStatus(target: target, state: state, name: name, cwd: cwd)
    }

    private static func sliceField(_ line: String, start: Int, end: Int) -> String {
        let clampedEnd = min(end, line.count)
        guard start < clampedEnd else { return "" }

        let startIndex = line.index(line.startIndex, offsetBy: start)
        let endIndex = line.index(line.startIndex, offsetBy: clampedEnd)

        return String(line[startIndex..<endIndex]).trimmingCharacters(in: .whitespaces)
    }
}
