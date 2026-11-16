import Darwin
import Foundation

/// Cross-UID CPU times.
///
/// `PROC_PIDTASKINFO` and `proc_pid_rusage` return `EPERM` for processes owned by
/// another UID unless the caller is root, so `WindowServer` (UID 88) and the root
/// daemons stay invisible to a menu-bar app. `/bin/ps` ships setuid root on macOS
/// and prints cumulative CPU seconds for every process; differencing those seconds
/// keeps the same machine-wide percentage as `CPUTime.percent()`.
///
/// The panel only runs this while a table is visible. Never call it from the hidden
/// refresh loop: a per-second subprocess is exactly the shape of the 2026-09 fan
/// regression.
nonisolated enum ForeignProcessCPU {
    struct Sample: Equatable, Sendable {
        var uid: uid_t
        var seconds: Double
    }

    static let executablePath = "/bin/ps"

    static func read() async -> [pid_t: Sample]? {
        let text = await Task.detached(priority: .utility) { () -> String? in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executablePath)
            process.arguments = ["-Axo", "pid=,uid=,time="]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                return nil
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                return nil
            }
            return String(decoding: data, as: UTF8.self)
        }.value
        guard let text else {
            return nil
        }
        return parse(text)
    }

    /// One process per line: `pid uid seconds`. `time` prints `mm:ss.ss` or
    /// `hh:mm:ss.ss`, and `pid=` / `uid=` / `time=` headerless columns keep the
    /// output stable across locales.
    static func parse(_ text: String) -> [pid_t: Sample] {
        var samples: [pid_t: Sample] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 3,
                  let pid = pid_t(fields[0]),
                  let uid = uid_t(fields[1]),
                  let seconds = seconds(String(fields[2]))
            else { continue }
            samples[pid] = Sample(uid: uid, seconds: seconds)
        }
        return samples
    }

    /// `0:03.58`, `12:34.50` and `354:53.50` all mean cumulative CPU seconds.
    static func seconds(_ text: String) -> Double? {
        let parts = text.split(separator: ":")
        guard (1...3).contains(parts.count) else { return nil }
        var total = 0.0
        for part in parts {
            guard let value = Double(part), value >= 0 else { return nil }
            total = total * 60 + value
        }
        return total
    }
}
