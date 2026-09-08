import Foundation

nonisolated enum DisplayClassifier {
    private static let interpreterNames: Set<String> = [
        "node", "nodejs", "python", "python3", "python2", "ruby", "java", "perl", "php",
        "deno", "bun", "mainthread", "pwsh", "bash", "zsh", "sh", "dash", "fish"
    ]

    private static let terminalAppNames: Set<String> = [
        "terminal", "iterm", "iterm2", "alacritty", "ghostty", "kitty", "warp", "prompt",
        "tmux", "sshd", "login", "cursor"
    ]

    static let protectedNames: Set<String> = [
        "kernel_task", "launchd", "WindowServer", "loginwindow", "opendirectoryd",
        "fseventsd", "syslogd", "configd", "coreaudiod", "hidd", "diskarbitrationd",
        "logd", "UserEventAgent", "systemstats", "cfprefsd", "securityd", "tccd",
        "runningboardd", "coreservicesd", "watchdogd", "kernelmanagerd", "powerd",
        "thermald", "notifyd", "mds", "mds_stores"
    ]

    static func rows(
        from processes: [RawProcess],
        currentUID: uid_t,
        physicalMemory: UInt64
    ) -> [ProcessRow] {
        let byPID = Dictionary(uniqueKeysWithValues: processes.map { ($0.pid, $0) })
        var buckets: [String: [RawProcess]] = [:]

        for process in processes {
            if isMCPMemory(process) {
                continue
            }
            let key = rowKey(for: process, byPID: byPID)
            buckets[key, default: []].append(process)
        }

        for process in processes where isMCPMemory(process) {
            let parent = byPID[process.responsiblePID] ?? byPID[process.ppid]
            let key = parent.map { rowKey(for: $0, byPID: byPID) } ?? rowKey(for: process, byPID: byPID)
            buckets[key, default: []].append(process)
        }

        let memory = max(physicalMemory, 1)
        return buckets.map { key, members in
            makeRow(id: key, members: members, currentUID: currentUID, physicalMemory: memory, byPID: byPID)
        }
        .sorted { lhs, rhs in
            if lhs.cpuPercent != rhs.cpuPercent {
                return lhs.cpuPercent > rhs.cpuPercent
            }
            return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
        }
    }

    static func toolHint(path: String, arguments: [String], executableName: String) -> String? {
        let tokens = arguments.isEmpty ? [path] : arguments
        for token in tokens {
            let base = basename(token)
            if base.isEmpty { continue }
            if token.hasPrefix("-") { continue }
            if base.contains("=") { continue }
            if isInterpreterName(base) { continue }
            // argv0 常等于短名（WindowServer 等）；那不是「具名脚本」，跳过以免放开结束边界。
            if base == executableName { continue }
            return base
        }
        return nil
    }

    static func isProtected(name: String, path: String, pid: pid_t) -> Bool {
        if pid <= 1 { return true }
        if protectedNames.contains(name) { return true }
        if path.hasPrefix("/System/") { return true }
        if path.hasPrefix("/usr/libexec/") { return true }
        if path.hasPrefix("/usr/sbin/") { return true }
        if path.hasPrefix("/sbin/") { return true }
        return false
    }

    // MARK: - Keys

    private static func rowKey(for process: RawProcess, byPID: [pid_t: RawProcess]) -> String {
        // 系统保护进程禁止折进桌面应用行，否则结束应用时会连带 SIGKILL。
        if isProtected(name: process.executableName, path: process.path, pid: process.pid) {
            return "proc:\(process.pid)"
        }
        if isChatGPTFamily(process, byPID: byPID) {
            return "chatgpt"
        }
        if isCursorAgent(process, byPID: byPID) {
            return "cursor-agent:\(process.pid)"
        }
        if isPi(process) {
            return "pi:\(process.pid)"
        }
        if isCorral(process) {
            return "corral"
        }
        if let hint = toolHint(path: process.path, arguments: process.arguments, executableName: process.executableName),
           isStandaloneNamedTool(process, hint: hint, byPID: byPID) {
            return "tool:\(hint):\(process.pid)"
        }
        if let bundle = owningBundlePath(process, byPID: byPID) {
            return "app:\(bundle)"
        }
        return "proc:\(process.pid)"
    }

    private static func makeRow(
        id: String,
        members: [RawProcess],
        currentUID: uid_t,
        physicalMemory: UInt64,
        byPID: [pid_t: RawProcess]
    ) -> ProcessRow {
        let lead = members.max(by: { $0.cpuPercent < $1.cpuPercent }) ?? members[0]
        let kind = kindForRow(id: id, lead: lead, byPID: byPID)
        let bundle = owningBundlePath(lead, byPID: byPID)
        let display = displayName(kind: kind, lead: lead, bundlePath: bundle)
        let icon = iconPath(kind: kind, lead: lead, bundlePath: bundle, byPID: byPID)
        let cpu = min(100, members.reduce(0) { $0 + $1.cpuPercent })
        let memoryBytes = members.reduce(UInt64(0)) { $0 + $1.memoryBytes }
        let memoryPercent = min(100, Double(memoryBytes) / Double(physicalMemory) * 100)
        let allCurrentUser = members.allSatisfy { $0.uid == currentUID }
        let protected = members.contains {
            isProtected(name: $0.executableName, path: $0.path, pid: $0.pid)
        }
        // 系统进程即使被误认成「具名工具」也必须锁死结束。人话行（桌面应用 / ChatGPT 等）不整行锁死。
        let lockEnd: Bool
        switch kind {
        case .chatgpt, .desktopApp, .corral, .pi, .cursorAgent:
            lockEnd = false
        case .namedTool, .other:
            lockEnd = protected
        }
        return ProcessRow(
            id: id,
            displayName: display,
            bundlePath: bundle,
            iconPath: icon,
            memberIdentities: members.map(\.identity),
            cpuPercent: cpu,
            memoryPercent: memoryPercent,
            kind: kind,
            isCurrentUser: allCurrentUser,
            isSystemProtected: lockEnd
        )
    }

    private static func kindForRow(id: String, lead: RawProcess, byPID: [pid_t: RawProcess]) -> RowKind {
        if id == "chatgpt" { return .chatgpt }
        if id.hasPrefix("cursor-agent:") { return .cursorAgent }
        if id.hasPrefix("pi:") { return .pi }
        if id == "corral" { return .corral }
        if id.hasPrefix("tool:") { return .namedTool }
        if id.hasPrefix("app:") { return .desktopApp }
        // proc: 独立行：即使责任 PID 指向某 .app，也不升成 desktopApp（否则保护行会解锁结束）。
        if id.hasPrefix("proc:") { return .other }
        if owningBundlePath(lead, byPID: byPID) != nil { return .desktopApp }
        return .other
    }

    private static func displayName(kind: RowKind, lead: RawProcess, bundlePath: String?) -> String {
        switch kind {
        case .chatgpt:
            return "ChatGPT"
        case .cursorAgent:
            return "Cursor Agent"
        case .pi:
            return "pi"
        case .corral:
            return "Corral"
        case .namedTool:
            return toolHint(path: lead.path, arguments: lead.arguments, executableName: lead.executableName)
                ?? lead.executableName
        case .desktopApp:
            if let bundlePath, let name = bundleDisplayName(bundlePath) {
                return name
            }
            return lead.executableName
        case .other:
            return toolHint(path: lead.path, arguments: lead.arguments, executableName: lead.executableName)
                ?? lead.executableName
        }
    }

    private static func iconPath(
        kind: RowKind,
        lead: RawProcess,
        bundlePath: String?,
        byPID: [pid_t: RawProcess]
    ) -> String? {
        if kind == .cursorAgent {
            let cursor = "/Applications/Cursor.app"
            if FileManager.default.fileExists(atPath: cursor) {
                return cursor
            }
        }
        if let bundlePath, !isInterpreterBundle(bundlePath) {
            return bundlePath
        }
        if let responsible = byPID[lead.responsiblePID], let path = appBundlePath(in: responsible.path),
           !isInterpreterBundle(path) {
            return path
        }
        return lead.path
    }

    // MARK: - Family tests

    static func isChatGPTFamily(_ process: RawProcess, byPID: [pid_t: RawProcess]) -> Bool {
        if pathLooksLikeChatGPT(process.path) { return true }
        if argumentsContain(process.arguments, token: "cua_node") { return true }
        if let hint = toolHint(path: process.path, arguments: process.arguments, executableName: process.executableName),
           hint == "cua_node" {
            return true
        }
        if let responsible = byPID[process.responsiblePID], pathLooksLikeChatGPT(responsible.path) {
            return true
        }
        if isMCPMemory(process), let responsible = byPID[process.responsiblePID], pathLooksLikeChatGPT(responsible.path) {
            return true
        }
        return false
    }

    static func isMCPMemory(_ process: RawProcess) -> Bool {
        if argumentsContain(process.arguments, token: "mcp-server-memory") { return true }
        if let hint = toolHint(path: process.path, arguments: process.arguments, executableName: process.executableName) {
            return hint == "mcp-server-memory"
        }
        return false
    }

    static func isCursorAgent(_ process: RawProcess, byPID: [pid_t: RawProcess]) -> Bool {
        if process.path.contains("Cursor.app") { return false }
        let name = process.executableName.lowercased()
        let looksLikeAgent = name == "agent"
            || name == "mainthread"
            || process.path.localizedCaseInsensitiveContains("cursor-agent")
            || argumentsContain(process.arguments, token: "cursor-agent")
        guard looksLikeAgent else { return false }
        return hasAncestor(named: "tmux", from: process, byPID: byPID)
    }

    static func isPi(_ process: RawProcess) -> Bool {
        if process.executableName.lowercased() == "pi" { return true }
        return toolHint(path: process.path, arguments: process.arguments, executableName: process.executableName) == "pi"
    }

    static func isCorral(_ process: RawProcess) -> Bool {
        if process.executableName.lowercased() == "corral" { return true }
        if process.path.localizedCaseInsensitiveContains("/corral") { return true }
        if argumentsContain(process.arguments, token: "corral") { return true }
        if let hint = toolHint(path: process.path, arguments: process.arguments, executableName: process.executableName),
           hint.lowercased() == "corral" {
            return true
        }
        return false
    }

    private static func isStandaloneNamedTool(_ process: RawProcess, hint: String, byPID: [pid_t: RawProcess]) -> Bool {
        if hint == "cua_node" || hint == "mcp-server-memory" { return false }
        if isProtected(name: process.executableName, path: process.path, pid: process.pid) { return false }
        if process.path.contains(".app/Contents") { return false }
        if isChatGPTFamily(process, byPID: byPID) { return false }
        if let bundle = owningBundlePath(process, byPID: byPID) {
            let appName = URL(fileURLWithPath: bundle).deletingPathExtension().lastPathComponent.lowercased()
            return terminalAppNames.contains(appName)
        }
        return true
    }

    private static func owningBundlePath(_ process: RawProcess, byPID: [pid_t: RawProcess]) -> String? {
        if let path = appBundlePath(in: process.path), !isInterpreterBundle(path) {
            return path
        }
        if let responsible = byPID[process.responsiblePID], let path = appBundlePath(in: responsible.path) {
            let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent.lowercased()
            if terminalAppNames.contains(name) { return nil }
            if isInterpreterBundle(path) { return nil }
            return path
        }
        return nil
    }

    private static func isInterpreterBundle(_ bundlePath: String) -> Bool {
        let name = URL(fileURLWithPath: bundlePath).deletingPathExtension().lastPathComponent.lowercased()
        return name.hasPrefix("python") || name == "node" || name == "nodejs"
    }

    static func appBundlePath(in executablePath: String) -> String? {
        var url = URL(fileURLWithPath: executablePath)
        var best: String?
        while url.path != "/" {
            url.deleteLastPathComponent()
            if url.pathExtension == "app" {
                best = url.path
            }
        }
        return best
    }

    static func bundleDisplayName(_ bundlePath: String) -> String? {
        guard let bundle = Bundle(url: URL(fileURLWithPath: bundlePath)) else {
            return URL(fileURLWithPath: bundlePath).deletingPathExtension().lastPathComponent
        }
        return (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? URL(fileURLWithPath: bundlePath).deletingPathExtension().lastPathComponent
    }

    private static func pathLooksLikeChatGPT(_ path: String) -> Bool {
        path.localizedCaseInsensitiveContains("ChatGPT.app")
    }

    private static func argumentsContain(_ arguments: [String], token: String) -> Bool {
        arguments.contains { $0.localizedCaseInsensitiveContains(token) }
    }

    private static func hasAncestor(named name: String, from process: RawProcess, byPID: [pid_t: RawProcess]) -> Bool {
        var current = process.ppid
        var hops = 0
        while current > 1, hops < 8 {
            guard let parent = byPID[current] else { return false }
            if parent.executableName.lowercased() == name.lowercased() { return true }
            current = parent.ppid
            hops += 1
        }
        return false
    }

    private static func isInterpreterName(_ name: String) -> Bool {
        let lower = name.lowercased()
        if interpreterNames.contains(lower) { return true }
        if lower.hasPrefix("python") { return true }
        if lower.hasPrefix("node") { return true }
        return false
    }

    private static func basename(_ path: String) -> String {
        if let slash = path.lastIndex(of: "/") {
            return String(path[path.index(after: slash)...])
        }
        return path
    }
}
