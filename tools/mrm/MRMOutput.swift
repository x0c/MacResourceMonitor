import Darwin
import Foundation

// MARK: - Language

/// User-visible CLI copy follows the app contract: English + Simplified Chinese,
///
/// driven by the system preferred language. Stable enums / codes stay English.
enum MRMLang {
    static var isChinese: Bool {
        Locale.preferredLanguages.first?.hasPrefix("zh") == true
    }

    static func pick(_ en: String, _ zh: String) -> String {
        isChinese ? zh : en
    }
}

// MARK: - TTY / color

enum MRMTTY {
    static var stdinIsTTY: Bool { isatty(STDIN_FILENO) != 0 }
    static var stdoutIsTTY: Bool { isatty(STDOUT_FILENO) != 0 }
    static var interactive: Bool { stdinIsTTY && stdoutIsTTY }

    static var colorEnabled: Bool {
        guard stdoutIsTTY else { return false }
        if ProcessInfo.processInfo.environment["NO_COLOR"] != nil { return false }
        if ProcessInfo.processInfo.environment["TERM"] == "dumb" { return false }
        return true
    }
}

func logStderr(_ message: String) {
    FileHandle.standardError.write((message + "\n").data(using: .utf8) ?? Data())
}

// MARK: - Binary identity

/// Absolute path of this binary, used in hints / next_commands so agents
/// never fall back to a stale copy on PATH.
func mrmAbsolutePath() -> String {
    let argv0 = CommandLine.arguments.first ?? "mrm"
    if argv0.hasPrefix("/") { return argv0 }
    let cwd = FileManager.default.currentDirectoryPath
    let candidate = (cwd as NSString).appendingPathComponent(argv0)
    if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    if let exec = Bundle.main.executablePath { return exec }
    return argv0
}

// MARK: - JSON envelope

/// Agent-first envelope: {ok, data, error, meta}. Failures still print a valid
/// envelope to stdout + non-zero exit. doom always carries data (per-target
/// results) even when ok=false, so partial kills stay auditable.
struct MRMEnvelope<T: Encodable>: Encodable {
    var ok: Bool
    var data: T?
    var error: MRMError?
    var meta: MRMMeta
}

struct MRMError: Encodable {
    var code: String
    var message: String
    var hint: String?
    var next_commands: [String]?
    var retryable: Bool?
}

struct MRMMeta: Encodable {
    var version: String
    var build: Int
    var command: String
    var dry_run: Bool?
    var duration_ms: Int?
}

func printEnvelope<T: Encodable>(ok: Bool, data: T?, error: MRMError?, command: String, dryRun: Bool? = nil, startedAt: Date) {
    let duration = Int(Date().timeIntervalSince(startedAt) * 1000)
    let meta = MRMMeta(
        version: MRMVersion.marketing,
        build: MRMVersion.build,
        command: command,
        dry_run: dryRun,
        duration_ms: duration
    )
    let envelope = MRMEnvelope(ok: ok, data: data, error: error, meta: meta)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let bytes = try? encoder.encode(envelope) {
        FileHandle.standardOutput.write(bytes)
        FileHandle.standardOutput.write("\n".data(using: .utf8) ?? Data())
    }
}

// MARK: - Exit codes

/// 0 success / 1 generic or partial failure / 2 usage / 3 not found / 4 permission.
enum MRMExit: Int32 {
    case success = 0
    case failure = 1
    case usage = 2
    case notFound = 3
    case permission = 4
}
