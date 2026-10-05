import AppKit

/// The app a Claude Code session runs in: VS Code, or a terminal (Ghostty, iTerm, Terminal…).
struct SessionHost: Equatable {
    /// `__CFBundleIdentifier` of the app that launched `claude` (survives tmux), may be empty.
    let bundleId: String
    /// `TERM_PROGRAM` of the shell, may be empty.
    let termProgram: String

    var isVSCode: Bool {
        termProgram.lowercased().contains("vscode") || bundleId.lowercased().contains("vscode")
    }

    private static let termProgramBundleIds: [String: String] = [
        "apple_terminal": "com.apple.Terminal",
        "iterm.app":      "com.googlecode.iterm2",
        "ghostty":        "com.mitchellh.ghostty",
        "wezterm":        "com.github.wez.wezterm",
        "warpterminal":   "dev.warp.Warp-Stable",
        "vscode":         "com.microsoft.VSCode",
    ]

    /// Bundle IDs to try, most specific first.
    var candidateBundleIds: [String] {
        var ids: [String] = []
        if !bundleId.isEmpty { ids.append(bundleId) }
        if let mapped = Self.termProgramBundleIds[termProgram.lowercased()], !ids.contains(mapped) {
            ids.append(mapped)
        }
        return ids
    }

    var displayName: String {
        if isVSCode { return "VS Code" }
        for id in candidateBundleIds {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first,
               let name = app.localizedName { return name }
        }
        switch termProgram.lowercased() {
        case "apple_terminal": return "Terminal"
        case "iterm.app":      return "iTerm"
        case "ghostty":        return "Ghostty"
        case "":               return "Terminal"
        default:               return termProgram
        }
    }
}

/// One pill per worktree for Claude Code sessions running in VS Code or a terminal.
/// The `integration_claude` (VS Code) pill is hidden while any of them exists.
@MainActor
enum ClaudeSessionPills {
    static let vsCodePillId = "integration_claude"
    static let idPrefix  = "claude_"

    /// Idle pills are removed after this long without an event; busy ones after `staleTimeout`
    /// (a crashed session never sends SessionEnd).
    private static let idleTimeout: TimeInterval  = 30 * 60
    private static let staleTimeout: TimeInterval = 2 * 60 * 60

    private static var cleanupTimers: [String: DispatchWorkItem] = [:]

    static func isSessionPill(_ id: String) -> Bool { id.hasPrefix(idPrefix) }

    /// Pill that already owns this session, if any.
    static func existingPill(sessionId: String) -> String? {
        AppState.shared.tasks.first { $0.sessionIds.contains(sessionId) }?.id
    }

    /// Finds or creates the pill for this session's worktree, records the event and returns its ID.
    /// A session keeps its pill even if its cwd moves to a subfolder.
    static func upsert(sessionId: String, cwd: String, host: SessionHost,
                       name: (String) -> String) -> String {
        let state = AppState.shared
        let id: String
        if let owned = existingPill(sessionId: sessionId) {
            id = owned
        } else {
            let root = worktreeRoot(for: cwd)
            id = pillId(for: root)
            if !state.tasks.contains(where: { $0.id == id }) {
                let leaf = URL(fileURLWithPath: root).lastPathComponent
                let title = name(leaf.isEmpty ? "Session" : leaf)
                let color = peacockColor(worktree: root) ?? IslandConst.colorForProject(title)
                var task = AgentTask(id: id, name: title, color: color,
                                     state: .idle, steps: [], source: .claudeCode)
                task.sessionCwd = root
                insert(task)
            }
        }
        guard let idx = state.tasks.firstIndex(where: { $0.id == id }) else { return id }
        state.tasks[idx].sessionIds.insert(sessionId)
        state.tasks[idx].sessionHost = host
        state.tasks[idx].lastEventAt = Date()
        scheduleCleanup(id: id)
        return id
    }

    /// SessionEnd: drop the session; remove the pill once no session is left in it.
    static func endSession(_ sessionId: String, pillId: String) {
        let state = AppState.shared
        guard let idx = state.tasks.firstIndex(where: { $0.id == pillId }) else { return }
        state.tasks[idx].sessionIds.remove(sessionId)
        if state.tasks[idx].sessionIds.isEmpty { remove(pillId) }
    }

    static func remove(_ id: String) {
        cleanupTimers.removeValue(forKey: id)?.cancel()
        AppState.shared.removeTask(id: id)
    }

    /// The VS Code pill stands in for Claude Code only while no worktree pill exists.
    /// Removes it from a pill list whenever worktree pills are showing.
    static func hidingVSCodePill(_ tasks: [AgentTask]) -> [AgentTask] {
        guard tasks.contains(where: { isSessionPill($0.id) }) else { return tasks }
        return tasks.filter { $0.id != vsCodePillId }
    }

    /// Focus to use instead of `id` when it points at the hidden VS Code pill:
    /// the worktree that most needs attention, else the most recently active. Nil to keep `id`.
    /// Takes `tasks` rather than reading `AppState.shared`: it runs from AppState's own
    /// property observer, including while `shared` is still being created.
    static func focusReplacing(_ id: String?, in tasks: [AgentTask]) -> String? {
        guard id == vsCodePillId else { return nil }
        let sessions = tasks.filter { isSessionPill($0.id) }
        return sessions.max { a, b in
            if urgency(a.state) != urgency(b.state) { return urgency(a.state) < urgency(b.state) }
            return (a.lastEventAt ?? .distantPast) < (b.lastEventAt ?? .distantPast)
        }?.id
    }

    /// Brings the session's window forward: VS Code opens the worktree folder (which focuses
    /// its window), a terminal app is activated. Returns false when no host is known.
    @discardableResult
    static func openHost(of task: AgentTask) -> Bool {
        guard let host = task.sessionHost else { return false }
        let ids = host.isVSCode
            ? host.candidateBundleIds + ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders", "com.vscodium.codium"]
            : host.candidateBundleIds
        if host.isVSCode, let cwd = task.sessionCwd, !cwd.isEmpty,
           let appURL = ids.lazy.compactMap({ NSWorkspace.shared.urlForApplication(withBundleIdentifier: $0) }).first {
            NSWorkspace.shared.open([URL(fileURLWithPath: cwd)], withApplicationAt: appURL,
                                    configuration: .init(), completionHandler: nil)
            return true
        }
        for id in ids {
            if let app = NSRunningApplication.runningApplications(withBundleIdentifier: id).first {
                app.activate(options: .activateIgnoringOtherApps)
                return true
            }
        }
        return false
    }

    // MARK: - Private

    private static func urgency(_ s: BotState) -> Int {
        switch s {
        case .approval:  return 9
        case .question:  return 8
        case .error:     return 7
        case .ratelimit: return 6
        case .working, .searching: return 5
        case .thinking:  return 4
        case .finished:  return 3
        case .dizzy:     return 2
        case .idle, .sleeping: return 0
        }
    }

    /// Inserts after the other worktree pills (or the VS Code pill) so sessions sit together.
    private static func insert(_ task: AgentTask) {
        let state = AppState.shared
        let anchor = state.tasks.lastIndex(where: { isSessionPill($0.id) })
            ?? state.tasks.firstIndex(where: { $0.id == vsCodePillId })
            ?? state.tasks.firstIndex(where: { $0.id == state.mainPillId })
        if let anchor { state.tasks.insert(task, at: anchor + 1) } else { state.tasks.append(task) }
        // The VS Code pill hides once a worktree pill exists, so move focus off it.
        if state.focusId == nil || state.focusId == vsCodePillId { state.focusId = task.id }
        state.syncMode()
    }

    private static func scheduleCleanup(id: String) {
        cleanupTimers[id]?.cancel()
        let item = DispatchWorkItem { MainActor.assumeIsolated { expire(id: id) } }
        cleanupTimers[id] = item
        DispatchQueue.main.asyncAfter(deadline: .now() + idleTimeout, execute: item)
    }

    private static func expire(id: String) {
        let state = AppState.shared
        guard let task = state.tasks.first(where: { $0.id == id }) else {
            cleanupTimers[id] = nil; return
        }
        let quietFor = Date().timeIntervalSince(task.lastEventAt ?? .distantPast)
        let waitingOnUser = state.pendingApproval?.pillId == id
        let busy = urgency(task.state) >= urgency(.thinking)
        if waitingOnUser || (busy && quietFor < staleTimeout) {
            let item = DispatchWorkItem { MainActor.assumeIsolated { expire(id: id) } }
            cleanupTimers[id] = item
            DispatchQueue.main.asyncAfter(deadline: .now() + idleTimeout, execute: item)
            return
        }
        remove(id)
    }

    /// The enclosing git worktree (a folder holding `.git`, file or directory), else `cwd`.
    private static func worktreeRoot(for cwd: String) -> String {
        guard !cwd.isEmpty else { return "" }
        let fm = FileManager.default
        var url = URL(fileURLWithPath: cwd).standardizedFileURL
        while url.path != "/" {
            if fm.fileExists(atPath: url.appendingPathComponent(".git").path) { return url.path }
            url.deleteLastPathComponent()
        }
        return URL(fileURLWithPath: cwd).standardizedFileURL.path
    }

    /// The worktree's Peacock color, so the pill matches its VS Code window. Looks in
    /// `<root>/<name>.code-workspace`, any other `.code-workspace` at the root, then
    /// `.vscode/settings.json`. Matched with a regex because these files are JSONC.
    private static func peacockColor(worktree root: String) -> String? {
        guard !root.isEmpty else { return nil }
        let rootURL = URL(fileURLWithPath: root)
        var files = [rootURL.appendingPathComponent(rootURL.lastPathComponent + ".code-workspace")]
        let others = (try? FileManager.default.contentsOfDirectory(atPath: root)) ?? []
        files += others.filter { $0.hasSuffix(".code-workspace") }.sorted()
            .map { rootURL.appendingPathComponent($0) }
        files.append(rootURL.appendingPathComponent(".vscode/settings.json"))

        let pattern = ##""peacock\.color"\s*:\s*"#?([0-9A-Fa-f]{6})""##
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        for file in files {
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let hex = Range(match.range(at: 1), in: text) else { continue }
            return "#" + text[hex].uppercased()
        }
        return nil
    }

    /// Stable across launches (FNV-1a), unlike `hashValue`.
    private static func pillId(for root: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in root.utf8 { hash = (hash ^ UInt64(byte)) &* 0x100000001b3 }
        return idPrefix + String(hash, radix: 16)
    }
}
