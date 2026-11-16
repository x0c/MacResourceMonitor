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
        // 编译型二进制（mrm / git / serve 等）：身份就是二进制自身；argv1 起是子命令
        // （mrm doom、git status），禁止拿子命令当工具名，否则 mrm 会显示成 "doom"。
        // 解释器（node / python / bash 等）才继续往后找脚本名。
        if !isInterpreterName(executableName) {
            let tokens = arguments.isEmpty ? [path] : arguments
            guard let first = tokens.first else { return nil }
            let base = basename(first)
            if base.isEmpty { return nil }
            if first.hasPrefix("-") { return nil }
            if base.contains("=") || base.contains(",") { return nil }
            if base.allSatisfy(\.isNumber) { return nil }
            if isInterpreterName(base) { return nil }
            // argv0 就是二进制自身（WindowServer / mrm / git）→ 不是具名脚本，返回 nil
            // 调用方回退到 executableName。argv0 被改写（如测试里的 yes → 别名）才当 hint。
            if base == executableName { return nil }
            return base
        }
        let tokens = arguments.isEmpty ? [path] : arguments
        for token in tokens {
            let base = basename(token)
            if base.isEmpty { continue }
            if token.hasPrefix("-") { continue }
            if base.contains("=") { continue }
            if base.contains(",") { continue }
            if base.allSatisfy(\.isNumber) { continue }
            if isInterpreterName(base) { continue }
            // argv0 常等于短名（WindowServer 等）；那不是「具名脚本」，跳过以免放开结束边界。
            if base == executableName { continue }
            return base
        }
        return nil
    }

    /// Apple apps ship under /System (Safari inside the App cryptex since Ventura).
    private static let systemAppRoots = [
        "/System/Applications/",
        "/System/Volumes/Preboot/Cryptexes/App/System/Applications/",
        "/System/Cryptexes/App/System/Applications/",
        "/System/Library/CoreServices/",
    ]

    /// Single-row end is fine (macOS relaunches it), but bulk end / doom skip it.
    private static let autoRelaunchedBundles: Set<String> = [
        "/System/Library/CoreServices/Finder.app",
    ]

    static func isProtected(name: String, path: String, pid: pid_t) -> Bool {
        if pid <= 1 { return true }
        if protectedNames.contains(name) { return true }
        if isUserFacingSystemApp(path: path) { return false }
        if path.hasPrefix("/System/") { return true }
        if path.hasPrefix("/usr/libexec/") { return true }
        if path.hasPrefix("/usr/sbin/") { return true }
        if path.hasPrefix("/sbin/") { return true }
        return false
    }

    /// Main executable of a top-level Apple app with a regular activation policy
    /// (Dock app, listed in Force Quit): no LSUIElement / LSBackgroundOnly.
    /// Agents such as Dock, Control Center and loginwindow, framework-embedded
    /// apps, extensions and XPC helpers stay protected.
    static func isUserFacingSystemApp(path: String) -> Bool {
        guard let root = systemAppRoots.first(where: { path.hasPrefix($0) }) else { return false }
        let parts = path.dropFirst(root.count).split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 4 || parts.count == 5 else { return false }
        if parts.count == 5, parts[0] != "Utilities", parts[0] != "Applications" { return false }
        let appIndex = parts.count - 4
        guard parts[appIndex].hasSuffix(".app"),
              parts[appIndex + 1] == "Contents",
              parts[appIndex + 2] == "MacOS" else { return false }
        let bundlePath = root + parts[...appIndex].joined(separator: "/")
        guard let info = Bundle(url: URL(fileURLWithPath: bundlePath, isDirectory: true))?.infoDictionary,
              info["CFBundleExecutable"] as? String == String(parts[appIndex + 3]) else { return false }
        return !isPlistTrue(info["LSUIElement"]) && !isPlistTrue(info["LSBackgroundOnly"])
    }

    static func relaunchesAutomatically(bundlePath: String?) -> Bool {
        guard let bundlePath else { return false }
        return autoRelaunchedBundles.contains(bundlePath)
    }

    private static func isPlistTrue(_ value: Any?) -> Bool {
        switch value {
        case let flag as Bool: return flag
        case let number as NSNumber: return number.boolValue
        case let text as String: return ["1", "true", "yes"].contains(text.lowercased())
        default: return false
        }
    }

    // MARK: - Keys

    private static func rowKey(for process: RawProcess, byPID: [pid_t: RawProcess]) -> String {
        // 系统保护进程禁止折进桌面应用行，否则结束应用时会连带 SIGKILL。
          if isProtected(name: process.executableName, path: process.path, pid: process.pid) {
              return "proc:\(process.pid)"
          }
          if NettopStreamSampler.isSamplerProcess(path: process.path, arguments: process.arguments) {
              if let host = byPID.values.first(where: { $0.path.contains("/Mac Resource Monitor.app/") }),
                 let bundle = appBundlePath(in: host.path) {
                  return "app:\(bundle)"
              }
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
            return corralRowKey(process, byPID: byPID)
        }
        if let owner = agentOwner(of: process, byPID: byPID) {
            return isPi(owner) ? "pi:\(owner.pid)" : "cursor-agent:\(owner.pid)"
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
            ?? (id.hasPrefix("app:") ? String(id.dropFirst("app:".count)) : nil)
        let display = displayName(
            kind: kind,
            lead: lead,
            members: members,
            bundlePath: bundle,
            id: id,
            byPID: byPID
        )
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
            executablePath: lead.path,
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
        if id.hasPrefix("corral") { return .corral }
        if id.hasPrefix("tool:") { return .namedTool }
        if id.hasPrefix("app:") { return .desktopApp }
        // proc: 独立行：即使责任 PID 指向某 .app，也不升成 desktopApp（否则保护行会解锁结束）。
        if id.hasPrefix("proc:") { return .other }
        if owningBundlePath(lead, byPID: byPID) != nil { return .desktopApp }
        return .other
    }

    private static func displayName(
        kind: RowKind,
        lead: RawProcess,
        members: [RawProcess],
        bundlePath: String?,
        id: String,
        byPID: [pid_t: RawProcess]
    ) -> String {
        switch kind {
        case .chatgpt:
            return "ChatGPT"
        case .cursorAgent:
            return agentDisplayName("Cursor Agent", members: members, byPID: byPID)
        case .pi:
            return agentDisplayName("pi", members: members, byPID: byPID)
        case .corral:
            // `Corral.app` keeps its own desktop row; only TUI / remote servers land here.
            return id.hasPrefix("corral-remote:") ? "Corral Remote" : "Corral TUI"
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
        // Synthetic kernel_task has no executable on disk; use the generic icon.
        if lead.pid == 0 {
            return nil
        }
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
        // Never absorb the keep-alive server or any terminal: `tmux -D -L corral-keepalive`
        // hosts every agent session, and ending it would take them all down.
        if process.executableName.lowercased() == "tmux" { return false }
        // Corral.app is a desktop app; `python -m corral` runs inside Python.app and stays Corral.
        if let bundle = appBundlePath(in: process.path), !isInterpreterBundle(bundle) { return false }
        if process.executableName.lowercased() == "corral" { return true }
        guard let hint = toolHint(
            path: process.path,
            arguments: process.arguments,
            executableName: process.executableName
        )?.lowercased() else { return false }
        // `corral.*` modules are the app's internal workers; they fold into their parent row.
        return hint == "corral" || hint.hasPrefix("corral.")
    }

    /// One row per Corral instance instead of one bucket for the whole family.
    private static func corralRowKey(_ process: RawProcess, byPID: [pid_t: RawProcess]) -> String {
        if isCorralWorker(process),
           let parent = byPID[process.ppid],
           parent.pid != process.pid,
           isCorral(parent) {
            return isCorralRemote(parent) ? "corral-remote:\(parent.pid)" : "corral-tui:\(parent.pid)"
        }
        return isCorralRemote(process) ? "corral-remote:\(process.pid)" : "corral-tui:\(process.pid)"
    }

    private static func isCorralRemote(_ process: RawProcess) -> Bool {
        process.arguments.contains("remote") && process.arguments.contains("_serve")
    }

    private static func isCorralWorker(_ process: RawProcess) -> Bool {
        process.arguments.contains { $0.hasPrefix("corral.") }
    }

    /// Build and test children of a CLI agent belong to that agent's row (方案 A):
    /// the row and its end action cover the whole burst instead of scattering
    /// `tsc` / `node test`. The walk stops at terminals, tmux, Corral and desktop apps.
    static func agentOwner(of process: RawProcess, byPID: [pid_t: RawProcess]) -> RawProcess? {
        if isProtected(name: process.executableName, path: process.path, pid: process.pid) { return nil }
        if let bundle = appBundlePath(in: process.path), !isInterpreterBundle(bundle) { return nil }
        var current = process.ppid
        var hops = 0
        while current > 1, hops < 6 {
            guard let parent = byPID[current] else { return nil }
            if isPi(parent) { return parent }
            if isCursorAgent(parent, byPID: byPID) { return parent }
            if isCorral(parent) || isFoldingBarrier(parent) { return nil }
            current = parent.ppid
            hops += 1
        }
        return nil
    }

    /// Terminals and tmux end the fold: commands they start belong to themselves, not
    /// to an assistant row. Plain shells (`zsh -c`, `bash`) are traversed on purpose.
    private static let foldingBarrierNames: Set<String> = [
        "tmux", "terminal", "iterm", "iterm2", "alacritty", "ghostty", "kitty", "warp",
        "prompt", "sshd", "cursor"
    ]

    private static func isFoldingBarrier(_ process: RawProcess) -> Bool {
        if foldingBarrierNames.contains(process.executableName.lowercased()) { return true }
        guard let bundle = appBundlePath(in: process.path), !isInterpreterBundle(bundle) else {
            return false
        }
        let app = URL(fileURLWithPath: bundle, isDirectory: true)
            .deletingPathExtension()
            .lastPathComponent
            .lowercased()
        return foldingBarrierNames.contains(app)
    }

    /// Cheap pre-check so the sampler only reads cwd for assistant processes.
    static func needsWorkspaceContext(path: String, arguments: [String]) -> Bool {
        let name = URL(fileURLWithPath: path, isDirectory: false).lastPathComponent.lowercased()
        if ["pi", "corral", "agent", "mainthread"].contains(name) { return true }
        if path.localizedCaseInsensitiveContains("cursor-agent") { return true }
        if arguments.contains(where: { $0.localizedCaseInsensitiveContains("corral") }) { return true }
        guard let hint = toolHint(path: path, arguments: arguments, executableName: name)?.lowercased() else {
            return false
        }
        return hint == "pi" || hint == "corral" || hint.hasPrefix("corral.")
    }

    private static let genericWorkspaceLeaves: Set<String> = [
        "cli", "src", "app", "app-macos", "app-ios", "app-android",
        "server", "agent", "web", "docs", "tests"
    ]

    private static func agentDisplayName(
        _ base: String,
        members: [RawProcess],
        byPID: [pid_t: RawProcess]
    ) -> String {
        // Prefer the session owner's cwd so folded child tasks (e.g. tsc) becoming lead
        // never strip the workspace suffix from the row name.
        let directory = members.first(where: {
            $0.workingDirectory != nil && (isPi($0) || isCursorAgent($0, byPID: byPID))
        })?.workingDirectory
            ?? members.compactMap(\.workingDirectory).first
        guard let workspace = workspaceLabel(directory) else { return base }
        return "\(base) (\(workspace))"
    }

    /// Folder label for parallel sessions; generic leaves (`cli`, `src`, ...) include
    /// their parent folder so `Corral/cli` and `AgentSync/cli` stay distinguishable.
    static func workspaceLabel(_ directory: String?) -> String? {
        guard var path = directory, !path.isEmpty else { return nil }
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        guard path != "/", path != home else {
            return nil
        }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        let name = url.lastPathComponent
        guard !name.isEmpty else { return nil }
        if genericWorkspaceLeaves.contains(name.lowercased()) {
            let parentURL = url.deletingLastPathComponent()
            let parentName = parentURL.lastPathComponent
            if parentURL.path != "/", parentURL.path != home, !parentName.isEmpty {
                return "\(parentName)/\(name)"
            }
        }
        return name
    }

    private static func isStandaloneNamedTool(_ process: RawProcess, hint: String, byPID: [pid_t: RawProcess]) -> Bool {
        if hint == "cua_node" || hint == "mcp-server-memory" { return false }
        if isProtected(name: process.executableName, path: process.path, pid: process.pid) { return false }
        if process.path.contains(".app/Contents") { return false }
        if isChatGPTFamily(process, byPID: byPID) { return false }
        if let bundle = owningBundlePath(process, byPID: byPID) {
            let appName = URL(fileURLWithPath: bundle, isDirectory: true).deletingPathExtension().lastPathComponent.lowercased()
            return terminalAppNames.contains(appName)
        }
        return true
    }

    private static func owningBundlePath(_ process: RawProcess, byPID: [pid_t: RawProcess]) -> String? {
        if let path = appBundlePath(in: process.path), !isInterpreterBundle(path) {
            return path
        }
        if let responsible = byPID[process.responsiblePID], let path = appBundlePath(in: responsible.path) {
            let name = URL(fileURLWithPath: path, isDirectory: true).deletingPathExtension().lastPathComponent.lowercased()
            if terminalAppNames.contains(name) { return nil }
            if isInterpreterBundle(path) { return nil }
            return path
        }
        return nil
    }

    private static func isInterpreterBundle(_ bundlePath: String) -> Bool {
        let name = URL(fileURLWithPath: bundlePath, isDirectory: true).deletingPathExtension().lastPathComponent.lowercased()
        return name.hasPrefix("python") || name == "node" || name == "nodejs"
    }

    static func appBundlePath(in executablePath: String) -> String? {
        var url = URL(fileURLWithPath: executablePath, isDirectory: false)
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
        guard let bundle = Bundle(url: URL(fileURLWithPath: bundlePath, isDirectory: true)) else {
            return URL(fileURLWithPath: bundlePath, isDirectory: true).deletingPathExtension().lastPathComponent
        }
        return (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? URL(fileURLWithPath: bundlePath, isDirectory: true).deletingPathExtension().lastPathComponent
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
