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
        //   f"{target:<12} {s['state']:<8} {name:<25} {cwd}"
        // Offsets: TARGET 0-11, STATE 13-20, NAME 22-46, CWD 48+

        guard line.count >= 22 else { return nil }

        let target = sliceField(line, start: 0, end: 12)
        let state = sliceField(line, start: 13, end: 21)

        guard !target.isEmpty, !state.isEmpty else { return nil }

        let name = line.count >= 47 ? sliceField(line, start: 22, end: 47) : ""
        let cwd = line.count >= 48 ? sliceField(line, start: 48, end: line.count) : ""

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
