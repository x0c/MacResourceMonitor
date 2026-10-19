import Darwin
import Foundation

struct MRMMain {
    static func main() async {
        let startedAt = Date()
        let rawArgs = Array(CommandLine.arguments.dropFirst())
        let (command, rest) = splitCommand(rawArgs)
        let jsonMode = rest.contains("--json")
        switch command {
        case "ps", "list":
            runPs(args: rest, startedAt: startedAt, jsonMode: jsonMode)
        case "doom":
            runDoom(args: rest, startedAt: startedAt, jsonMode: jsonMode)
        case "status":
            runStatus(args: rest, startedAt: startedAt, jsonMode: jsonMode)
        case "version":
            runVersion(args: rest, startedAt: startedAt, jsonMode: jsonMode)
        case "doctor":
            runDoctor(args: rest, startedAt: startedAt, jsonMode: jsonMode)
        case "describe":
            runDescribe(args: rest, startedAt: startedAt, jsonMode: jsonMode)
        case "help", "--help", "-h", "":
            printHelp(jsonMode: jsonMode)
            exit(MRMExit.success.rawValue)
        default:
            let msg = MRMLang.pick(
                "Unknown command '\(command)'. See 'mrm help'.",
                "未知命令 '\(command)'，看 'mrm help'。"
            )
            if jsonMode {
                printEnvelope(
                    ok: false, data: Optional<String>.none as String?,
                    error: MRMError(
                        code: "usage_error", message: msg,
                        hint: MRMLang.pick("Run 'mrm help' or 'mrm describe'.", "跑 'mrm help' 或 'mrm describe' 看用法。"),
                        next_commands: ["\(mrmAbsolutePath()) help"],
                        retryable: false
                    ),
                    command: command, startedAt: startedAt
                )
            } else {
                logStderr("mrm: \(msg)")
            }
            exit(MRMExit.usage.rawValue)
        }
    }
}

// MARK: - Arg plumbing

func splitCommand(_ args: [String]) -> (String, [String]) {
    guard let first = args.first, !first.hasPrefix("-") else {
        // No command: `mrm --json` etc. Treat as help request.
        return (args.first ?? "", args)
    }
    return (first, Array(args.dropFirst()))
}

func hasFlag(_ args: [String], _ names: String...) -> Bool {
    for arg in args {
        for name in names where arg == name { return true }
    }
    return false
}

func flagValue(_ args: [String], _ names: String...) -> String? {
    var i = 0
    while i < args.count {
        let arg = args[i]
        for name in names {
            if arg == name, i + 1 < args.count { return args[i + 1] }
            if arg.hasPrefix(name + "=") { return String(arg.dropFirst(name.count + 1)) }
        }
        i += 1
    }
    return nil
}

/// Collect repeatable --exclude values (supports --exclude a --exclude=b,c).
func excludeValues(_ args: [String]) -> [String] {
    var out: [String] = []
    var i = 0
    while i < args.count {
        let arg = args[i]
        if arg == "--exclude", i + 1 < args.count {
            out.append(contentsOf: args[i + 1].split(separator: ",").map(String.init))
            i += 2
        } else if arg.hasPrefix("--exclude=") {
            let v = String(arg.dropFirst("--exclude=".count))
            out.append(contentsOf: v.split(separator: ",").map(String.init))
            i += 1
        } else {
            i += 1
        }
    }
    return out.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// Reject flags this subcommand never reads (accept-then-ignore is worse than loud error).
func rejectUnknownFlags(args: [String], known: Set<String>, command: String, startedAt: Date, jsonMode: Bool) -> Bool {
    for arg in args where arg.hasPrefix("-") {
        let bare = arg.contains("=") ? String(arg.prefix(upTo: arg.firstIndex(of: "=")!)) : arg
        if known.contains(bare) { continue }
        // Allow global -h/--help/--json everywhere.
        if ["-h", "--help", "--json"].contains(bare) { continue }
        let msg = MRMLang.pick(
            "Unknown flag '\(arg)' for 'mrm \(command)'.",
            "'mrm \(command)' 不认识参数 '\(arg)'。"
        )
        if jsonMode {
            printEnvelope(
                ok: false, data: Optional<String>.none as String?,
                error: MRMError(
                    code: "usage_error", message: msg,
                    hint: MRMLang.pick("See 'mrm \(command) --help'.", "看 'mrm \(command) --help'。"),
                    next_commands: ["\(mrmAbsolutePath()) \(command) --help"],
                    retryable: false
                ),
                command: command, startedAt: startedAt
            )
        } else {
            logStderr("mrm: \(msg)")
        }
        exit(MRMExit.usage.rawValue)
    }
    return true
}

// MARK: - help / version / describe

func printHelp(jsonMode: Bool) {
    if jsonMode {
        struct HelpData: Encodable { var commands: [String]; var usage: String }
        printEnvelope(
            ok: true,
            data: HelpData(
                commands: ["ps", "doom", "status", "version", "doctor", "describe"],
                usage: "mrm <ps|doom|status|version|doctor|describe> [--json] [--help]"
            ),
            error: nil, command: "help", startedAt: Date()
        )
        return
    }
    print("""
    mrm — Mac Resource Monitor command line
    mrm — Mac Resource Monitor 命令行

      mrm ps [--limit N] [--json]              List user closable rows / 列出可结束的行
      mrm doom [--dry-run] [--yes] [--json]    End everything closable, keep it quiet
                                              一键结束能关的，留出最清静的环境
        --exclude NAME   keep matching rows (repeatable) / 保留匹配的行，可重复
        --include-caller also end your terminal chain (dangerous) / 连当前终端一起结束（危险）
        --include-monitor also end the menu-bar monitor / 连菜单栏监控一起结束
      mrm status [--json]                     Verify after doom / 结束后复核
      mrm version [--json]                    Print version / 看版本
      mrm doctor [--json]                     Check sampling works / 自检采样
      mrm describe [command] [--json]         Machine-readable command docs / 命令自描述

    Safety 安全:
      doom never touches system rows, other users, itself, your terminal chain,
      or the menu-bar monitor unless you opt in. TTY asks once; non-TTY needs --yes.
      doom 默认不动系统进程、别人进程、自身、当前终端链和菜单栏监控。
      终端里会确认一次；非交互必须加 --yes。
      Capture with redirect (> file), never pipes: piped helpers are closable too.
      输出用重定向 (> file) 接，不要用管道：管道里的 helper 也会被结束。
    """)
}

func runVersion(args: [String], startedAt: Date, jsonMode: Bool) {
    _ = rejectUnknownFlags(args: args, known: [], command: "version", startedAt: startedAt, jsonMode: jsonMode)
    if hasFlag(args, "-h", "--help") { printHelp(jsonMode: jsonMode); exit(MRMExit.success.rawValue) }
    if jsonMode {
        struct V: Encodable { var version: String; var build: Int; var binary: String }
        printEnvelope(
            ok: true,
            data: V(version: MRMVersion.marketing, build: MRMVersion.build, binary: mrmAbsolutePath()),
            error: nil, command: "version", startedAt: startedAt
        )
    } else {
        print("mrm \(MRMVersion.string)")
    }
    exit(MRMExit.success.rawValue)
}

func runDescribe(args: [String], startedAt: Date, jsonMode: Bool) {
    struct FlagDoc: Encodable { var name: String; var takes_value: Bool; var desc: String }
    struct CommandDoc: Encodable {
        var name: String; var risk: String; var desc: String; var flags: [FlagDoc]
    }
    struct DescribeData: Encodable { var commands: [CommandDoc] }
    let docs = [
        CommandDoc(
            name: "ps", risk: "read",
            desc: "List closable rows (no side effects).",
            flags: [
                FlagDoc(name: "--limit", takes_value: true, desc: "Max rows returned."),
                FlagDoc(name: "--json", takes_value: false, desc: "Machine envelope."),
            ]
        ),
        CommandDoc(
            name: "doom", risk: "write_local",
            desc: "SIGKILL every closable row except protections/caller/monitor unless opted in. Capture with redirect (> file), never pipes.",
            flags: [
                FlagDoc(name: "--dry-run", takes_value: false, desc: "Plan only, truly read-only."),
                FlagDoc(name: "--yes", takes_value: false, desc: "Skip confirmation (required non-TTY). Aliases: -y, --force."),
                FlagDoc(name: "--exclude", takes_value: true, desc: "Keep rows matching name/bundle/path (repeatable)."),
                FlagDoc(name: "--include-caller", takes_value: false, desc: "Also end your terminal chain. Dangerous."),
                FlagDoc(name: "--include-monitor", takes_value: false, desc: "Also end the menu-bar monitor."),
                FlagDoc(name: "--json", takes_value: false, desc: "Machine envelope."),
            ]
        ),
        CommandDoc(name: "status", risk: "read", desc: "Verify quiet state after doom.", flags: [
            FlagDoc(name: "--json", takes_value: false, desc: "Machine envelope."),
        ]),
        CommandDoc(name: "version", risk: "read", desc: "Print version offline.", flags: []),
        CommandDoc(name: "doctor", risk: "read", desc: "Check process sampling works.", flags: [
            FlagDoc(name: "--json", takes_value: false, desc: "Machine envelope."),
        ]),
    ]
    let target = args.first(where: { !$0.hasPrefix("-") })
    if let target, !["doom", "ps", "status", "version", "doctor"].contains(target) {
        let msg = MRMLang.pick("Unknown command '\(target)'.", "未知命令 '\(target)'。")
        if jsonMode {
            printEnvelope(
                ok: false, data: Optional<String>.none as String?,
                error: MRMError(code: "not_found", message: msg, hint: nil, next_commands: ["\(mrmAbsolutePath()) describe"], retryable: false),
                command: "describe", startedAt: startedAt
            )
        } else { logStderr("mrm: \(msg)") }
        exit(MRMExit.notFound.rawValue)
    }
    let filtered = target.map { t in docs.filter { $0.name == t } } ?? docs
    if jsonMode {
        printEnvelope(ok: true, data: DescribeData(commands: filtered), error: nil, command: "describe", startedAt: startedAt)
    } else {
        for doc in filtered {
            print("\(doc.name) [\(doc.risk)] — \(doc.desc)")
            for flag in doc.flags { print("  \(flag.name)\(flag.takes_value ? " <value>" : "")  \(flag.desc)") }
        }
    }
    exit(MRMExit.success.rawValue)
}

// MARK: - ps

func runPs(args: [String], startedAt: Date, jsonMode: Bool) {
    _ = rejectUnknownFlags(args: args, known: ["--limit"], command: "ps", startedAt: startedAt, jsonMode: jsonMode)
    if hasFlag(args, "-h", "--help") {
        if jsonMode {
            runDescribe(args: ["ps"], startedAt: startedAt, jsonMode: true)
        } else {
            print(MRMLang.pick(
                "Usage: mrm ps [--limit N] [--json]",
                "用法：mrm ps [--limit N] [--json]"
            ))
        }
        exit(MRMExit.success.rawValue)
    }
    var limit = 30
    if let raw = flagValue(args, "--limit") {
        guard let n = Int(raw), n > 0, n <= 200 else {
            let msg = MRMLang.pick("Bad --limit '\(raw)': 1..200.", "--limit '\(raw)' 非法：填 1..200。")
            if jsonMode {
                printEnvelope(ok: false, data: Optional<String>.none as String?, error: MRMError(code: "usage_error", message: msg, hint: nil, next_commands: nil, retryable: false), command: "ps", startedAt: startedAt)
            } else { logStderr("mrm: \(msg)") }
            exit(MRMExit.usage.rawValue)
        }
        limit = n
    }
    Task {
        let snap = await collectSnapshot()
        struct PsRow: Encodable {
            var display_name: String; var kind: String; var pids: [Int32]
            var cpu_percent: Double; var memory_percent: Double; var can_end: Bool
        }
        struct PsData: Encodable {
            var rows: [PsRow]; var scanned: Int; var matched: Int; var returned: Int
            var truncated: Bool; var note: String?
        }
        let sorted = snap.rows.sorted {
            if $0.cpuPercent != $1.cpuPercent { return $0.cpuPercent > $1.cpuPercent }
            return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        let closable = sorted.filter(\.canEnd)
        let shown = Array(sorted.prefix(limit))
        if jsonMode {
            printEnvelope(
                ok: true,
                data: PsData(
                    rows: shown.map {
                        PsRow(display_name: $0.displayName, kind: $0.kind.rawValue,
                              pids: $0.memberPIDs.map { Int32($0) },
                              cpu_percent: ($0.cpuPercent * 10).rounded() / 10,
                              memory_percent: ($0.memoryPercent * 10).rounded() / 10,
                              can_end: $0.canEnd)
                    },
                    scanned: snap.rawCount, matched: closable.count, returned: shown.count,
                    truncated: sorted.count > shown.count,
                    note: MRMLang.pick("scanned=\(snap.rawCount) raw processes, matched=\(closable.count) closable.", "掃描 \(snap.rawCount) 个原始进程，其中 \(closable.count) 个可结束。")
                ),
                error: nil, command: "ps", startedAt: startedAt
            )
        } else {
            print(MRMLang.pick("Closable: \(closable.count) of \(snap.rows.count) rows (raw \(snap.rawCount) procs)", "可结束：\(snap.rows.count) 行里 \(closable.count) 个（原始进程 \(snap.rawCount) 个）"))
            for row in shown.prefix(20) {
                let mark = row.canEnd ? " " : "🔒"
                let cpu = String(format: "%.1f%%", row.cpuPercent)
                let mem = String(format: "%.1f%%", row.memoryPercent)
                print("\(mark) \(row.displayName)  CPU \(cpu)  Mem \(mem)  [\(row.memberPIDs.count) proc]")
            }
            if sorted.count > shown.count {
                print(MRMLang.pick("… \(sorted.count - shown.count) more (use --limit).", "… 还有 \(sorted.count - shown.count) 个（加 --limit 看）。"))
            }
        }
        exit(MRMExit.success.rawValue)
    }
    RunLoop.main.run()
}

// MARK: - status (verification)

func runStatus(args: [String], startedAt: Date, jsonMode: Bool) {
    _ = rejectUnknownFlags(args: args, known: [], command: "status", startedAt: startedAt, jsonMode: jsonMode)
    if hasFlag(args, "-h", "--help") {
        print(MRMLang.pick("Usage: mrm status [--json]", "用法：mrm status [--json]"))
        exit(MRMExit.success.rawValue)
    }
    Task {
        let snap = await collectSnapshot()
        let ancestors = ancestorPIDs()
        let selfPID = getpid()
        let plan = planDoom(rows: snap.rows, ancestors: ancestors, selfPID: selfPID, excludes: [], includeCaller: false, includeMonitor: false)
        let quiet = plan.candidates.isEmpty
        struct StatusData: Encodable {
            var quiet: Bool; var closable: Int; var total_rows: Int; var scanned: Int
            var top: [DoomRowDTO]; var time: String; var mtime: Int
            var note: String?
        }
        let top = plan.candidates.prefix(5).map(dto)
        if jsonMode {
            printEnvelope(
                ok: true,
                data: StatusData(
                    quiet: quiet, closable: plan.candidates.count,
                    total_rows: snap.rows.count, scanned: snap.rawCount,
                    top: Array(top),
                    time: ISO8601DateFormatter().string(from: Date()),
                    mtime: Int(Date().timeIntervalSince1970),
                    note: quiet
                        ? MRMLang.pick("Quiet: nothing closable left.", "已清静：没有可结束的行了。")
                        : MRMLang.pick("\(plan.candidates.count) closable rows remain; run 'mrm doom --dry-run' to preview.", "还剩 \(plan.candidates.count) 个可结束的行；先跑 'mrm doom --dry-run' 预览。")
                ),
                error: nil, command: "status", startedAt: startedAt
            )
        } else {
            if quiet {
                print(MRMLang.pick("Quiet — nothing closable left.", "已清静——没有可结束的行了。"))
            } else {
                print(MRMLang.pick(
                    "\(plan.candidates.count) closable rows remain:",
                    "还剩 \(plan.candidates.count) 个可结束的行："
                ))
                for row in plan.candidates.prefix(10) {
                    print("  \(row.displayName)  (\(row.memberPIDs.count) proc)")
                }
                print(MRMLang.pick("Run 'mrm doom --dry-run' to preview.", "先跑 'mrm doom --dry-run' 预览。"))
            }
        }
        exit(MRMExit.success.rawValue)
    }
    RunLoop.main.run()
}

// MARK: - doctor

func runDoctor(args: [String], startedAt: Date, jsonMode: Bool) {
    _ = rejectUnknownFlags(args: args, known: [], command: "doctor", startedAt: startedAt, jsonMode: jsonMode)
    Task {
        let sampler = ProcessSampler(reapOrphans: false)
        let snap = await sampler.snapshot()
        let memory = await sampler.memoryBytes
        let memPct = await sampler.memoryUsagePercent
        let responsibilityOK = Responsibility.pidResponsible(for: getpid()) > 0
        struct DoctorData: Encodable {
            var sampling_ok: Bool; var pid_count: Int; var memory_ok: Bool
            var responsibility_ok: Bool; var binary: String
        }
        let ok = !snap.records.isEmpty && memory > 0 && responsibilityOK
        if jsonMode {
            printEnvelope(
                ok: ok,
                data: DoctorData(
                    sampling_ok: !snap.records.isEmpty, pid_count: snap.records.count,
                    memory_ok: memPct != nil, responsibility_ok: responsibilityOK,
                    binary: mrmAbsolutePath()
                ),
                error: ok ? nil : MRMError(
                    code: "doctor_failed",
                    message: MRMLang.pick("Sampling looks broken.", "采样看起来坏了。"),
                    hint: MRMLang.pick("Rebuild mrm and retry.", "重新构建 mrm 再试。"),
                    next_commands: nil, retryable: true
                ),
                command: "doctor", startedAt: startedAt
            )
        } else {
            print(ok
                ? MRMLang.pick("doctor: sampling OK (\(snap.records.count) procs).", "自检：采样正常（\(snap.records.count) 个进程）。")
                : MRMLang.pick("doctor: sampling looks broken.", "自检：采样看起来坏了。"))
        }
        exit(ok ? MRMExit.success.rawValue : MRMExit.failure.rawValue)
    }
    RunLoop.main.run()
}

// MARK: - doom

func runDoom(args: [String], startedAt: Date, jsonMode: Bool) {
    _ = rejectUnknownFlags(
        args: args,
        known: ["--dry-run", "--yes", "-y", "--force", "--exclude", "--include-caller", "--include-monitor"],
        command: "doom", startedAt: startedAt, jsonMode: jsonMode
    )
    if hasFlag(args, "-h", "--help") {
        if jsonMode { runDescribe(args: ["doom"], startedAt: startedAt, jsonMode: true) }
        else {
            print(MRMLang.pick(
                "Usage: mrm doom [--dry-run] [--yes] [--exclude NAME]... [--include-caller] [--include-monitor] [--json]",
                "用法：mrm doom [--dry-run] [--yes] [--exclude 名字]... [--include-caller] [--include-monitor] [--json]"
            ))
        }
        exit(MRMExit.success.rawValue)
    }
    let dryRun = hasFlag(args, "--dry-run")
    let yes = hasFlag(args, "--yes", "-y", "--force")
    let includeCaller = hasFlag(args, "--include-caller")
    let includeMonitor = hasFlag(args, "--include-monitor")
    let excludes = excludeValues(args)
    let binary = mrmAbsolutePath()

    Task {
        let snap = await collectSnapshot()
        let ancestors = ancestorPIDs()
        let selfPID = getpid()
        let plan = planDoom(
            rows: snap.rows, ancestors: ancestors, selfPID: selfPID,
            excludes: excludes, includeCaller: includeCaller, includeMonitor: includeMonitor
        )

        func emitDryRun() -> Never {
            let data = DoomDataDTO(
                dry_run: true,
                killed: [], failed: [],
                would_kill: plan.candidates.map(dto),
                skipped: plan.skipped.map {
                    DoomSkippedDTO(display_name: $0.row.displayName, kind: $0.row.kind.rawValue,
                                   pids: $0.row.memberPIDs.map { Int32($0) },
                                   reason: $0.reason, reason_tag: reasonTag($0.reason))
                },
                counts: DoomCountsDTO(scanned: snap.rawCount, candidates: plan.candidates.count, killed: 0, failed: 0, skipped: plan.skipped.count),
                note: MRMLang.pick(
                    "Dry run: nothing killed. Re-run without --dry-run + --yes to execute.",
                    "演习：什么都没关。去掉 --dry-run 并加 --yes 才会真关。"
                )
            )
            if jsonMode {
                printEnvelope(ok: true, data: data, error: nil, command: "doom", dryRun: true, startedAt: startedAt)
            } else {
                printDoomPlan(candidates: plan.candidates, skipped: plan.skipped.count, dryRun: true)
            }
            exit(MRMExit.success.rawValue)
        }

        func emitResult(killed: [ProcessRow], failed: [ProcessRow]) -> Never {
            let ok = failed.isEmpty
            let data = DoomDataDTO(
                dry_run: false,
                killed: killed.map(dto), failed: failed.map(dto), would_kill: [],
                skipped: plan.skipped.map {
                    DoomSkippedDTO(display_name: $0.row.displayName, kind: $0.row.kind.rawValue,
                                   pids: $0.row.memberPIDs.map { Int32($0) },
                                   reason: $0.reason, reason_tag: reasonTag($0.reason))
                },
                counts: DoomCountsDTO(scanned: snap.rawCount, candidates: plan.candidates.count, killed: killed.count, failed: failed.count, skipped: plan.skipped.count),
                note: ok
                    ? MRMLang.pick("Done. Run 'mrm status' to verify quiet.", "完事。用 'mrm status' 复核是否清静。")
                    : MRMLang.pick("Partial: some rows survived. Re-run 'mrm status' then 'mrm doom --yes' if they are still closable.", "只关掉一部分：有行还活着。先 'mrm status' 再看要不要重跑 'mrm doom --yes'。")
            )
            if jsonMode {
                printEnvelope(
                    ok: ok, data: data,
                    error: ok ? nil : MRMError(
                        code: "partial_failure",
                        message: MRMLang.pick("\(failed.count) of \(plan.candidates.count) rows survived.", "\(plan.candidates.count) 行里 \(failed.count) 个还活着。"),
                        hint: MRMLang.pick("Run 'mrm status --json' to see what remains.", "跑 'mrm status --json' 看还剩谁。"),
                        next_commands: ["\(binary) status --json"],
                        retryable: true
                    ),
                    command: "doom", dryRun: false, startedAt: startedAt
                )
            } else {
                printDoomResult(killed: killed, failed: failed, skipped: plan.skipped.count)
            }
            exit(ok ? MRMExit.success.rawValue : MRMExit.failure.rawValue)
        }

        // Nothing to do: converge to ok/unchanged (idempotency signal).
        if plan.candidates.isEmpty {
            let data = DoomDataDTO(
                dry_run: dryRun, killed: [], failed: [], would_kill: [],
                skipped: plan.skipped.map {
                    DoomSkippedDTO(display_name: $0.row.displayName, kind: $0.row.kind.rawValue,
                                   pids: $0.row.memberPIDs.map { Int32($0) },
                                   reason: $0.reason, reason_tag: reasonTag($0.reason))
                },
                counts: DoomCountsDTO(scanned: snap.rawCount, candidates: 0, killed: 0, failed: 0, skipped: plan.skipped.count),
                note: MRMLang.pick("Already quiet: nothing closable.", "已经很清静：没有可结束的行。")
            )
            if jsonMode {
                printEnvelope(ok: true, data: data, error: nil, command: "doom", dryRun: dryRun, startedAt: startedAt)
            } else {
                print(MRMLang.pick("Already quiet — nothing closable.", "已经很清静——没有可结束的行。"))
            }
            exit(MRMExit.success.rawValue)
        }

        if dryRun { emitDryRun() }

        // Authorization: TTY asks once; non-TTY must pass --yes (never hang).
        if !yes {
            if MRMTTY.interactive {
                if !jsonMode {
                    printDoomPlan(candidates: plan.candidates, skipped: plan.skipped.count, dryRun: false)
                }
                logStderr(MRMLang.pick(
                    "End \(plan.candidates.count) apps? Unsaved work will be lost. [y/N] ",
                    "要结束这 \(plan.candidates.count) 个应用吗？没保存的东西会丢。[y/N] "
                ))
                let answer = readLine(strippingNewline: true)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
                if answer != "y" && answer != "yes" {
                    let msg = MRMLang.pick("Cancelled — nothing killed.", "已取消——什么都没关。")
                    if jsonMode {
                        printEnvelope(
                            ok: false, data: Optional<String>.none as String?,
                            error: MRMError(code: "cancelled", message: msg, hint: nil, next_commands: nil, retryable: false),
                            command: "doom", dryRun: false, startedAt: startedAt
                        )
                    } else { logStderr("mrm: \(msg)") }
                    exit(MRMExit.failure.rawValue)
                }
            } else {
                let msg = MRMLang.pick(
                    "Refusing to doom without --yes in non-interactive mode.",
                    "非交互下缺 --yes，拒绝执行 doom。"
                )
                let hint = MRMLang.pick(
                    "Preview with --dry-run, then re-run with --yes.",
                    "先 --dry-run 预览，再加 --yes 真关。"
                )
                if jsonMode {
                    printEnvelope(
                        ok: false, data: Optional<String>.none as String?,
                        error: MRMError(
                            code: "confirmation_required", message: msg, hint: hint,
                            next_commands: ["\(binary) doom --dry-run --json", "\(binary) doom --yes --json"],
                            retryable: false
                        ),
                        command: "doom", dryRun: false, startedAt: startedAt
                    )
                } else {
                    logStderr("mrm: \(msg)")
                    logStderr(MRMLang.pick("Hint: \(hint)", "提示：\(hint)"))
                    logStderr("\(binary) doom --dry-run")
                    logStderr("\(binary) doom --yes")
                }
                exit(MRMExit.usage.rawValue)
            }
        }

        let result = await executeDoom(candidates: plan.candidates)
        emitResult(killed: result.killed, failed: result.failed)
    }
    RunLoop.main.run()
}

// MARK: - Human rendering

func printDoomPlan(candidates: [ProcessRow], skipped: Int, dryRun: Bool) {
    let title = dryRun
        ? MRMLang.pick("Would end \(candidates.count) apps (dry run, nothing killed):", "会结束 \(candidates.count) 个应用（演习，没真关）：")
        : MRMLang.pick("Will end \(candidates.count) apps:", "要结束 \(candidates.count) 个应用：")
    print(title)
    for row in candidates.prefix(20) {
        print("  \(row.displayName)  (\(row.memberPIDs.count) proc)")
    }
    if candidates.count > 20 {
        print(MRMLang.pick("  … \(candidates.count - 20) more", "  … 还有 \(candidates.count - 20) 个"))
    }
    print(MRMLang.pick(
        "Skipped \(skipped) (system / other user / self / caller / monitor / Finder / excluded).",
        "跳过 \(skipped) 个（系统/别人/自身/终端链/监控/访达/排除）。"
    ))
    if dryRun {
        print(MRMLang.pick("Re-run without --dry-run + --yes to execute.", "去掉 --dry-run 并加 --yes 才会真关。"))
    }
}

func printDoomResult(killed: [ProcessRow], failed: [ProcessRow], skipped: Int) {
    if failed.isEmpty {
        print(MRMLang.pick(
            "Doom done: ended \(killed.count), skipped \(skipped).",
            "清场完成：关了 \(killed.count) 个，跳过 \(skipped) 个。"
        ))
    } else {
        print(MRMLang.pick(
            "Doom partial: ended \(killed.count), \(failed.count) survived, skipped \(skipped).",
            "只关掉一部分：关了 \(killed.count) 个，\(failed.count) 个还活着，跳过 \(skipped) 个。"
        ))
        for row in failed.prefix(10) {
            print("  ✗ \(row.displayName)")
        }
    }
    for row in killed.prefix(10) {
        print("  ✓ \(row.displayName)")
    }
    print(MRMLang.pick("Run 'mrm status' to verify.", "用 'mrm status' 复核。"))
}

// Top-level entry (no @main: shared sources contain top-level lets).
await MRMMain.main()
