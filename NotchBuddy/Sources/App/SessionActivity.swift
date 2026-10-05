import Foundation

// MARK: - SessionActivity
// What the ticker shows for a Claude Code pill: the prompt being worked on (top row),
// the live action (bottom row), the plan step and the turn timer (header).
// HookServer feeds it hook events; the formatting rules live here.

struct PlanStep: Equatable {
    var id: String
    var subject: String
    var status: String   // pending, in_progress, completed, deleted
}

struct SessionActivity: Equatable {
    /// Latest substantial prompt — short replies ("yes", "8 b") keep the previous one.
    var prompt: String = ""
    /// Bottom row text, without the subagent prefix.
    var line: String = ""
    /// Bumps whenever a new line starts; a merged update keeps it (no slide animation).
    var lineID: Int = 0
    /// True while Claude is working (shimmer); false when done or waiting on you.
    var busy: Bool = false
    /// True while the line is a question Claude asked you.
    var asking: Bool = false
    var turnStart: Date? = nil
    var turnEnd: Date? = nil
    var plan: [PlanStep] = []
    var subagents: Int = 0
    var runningTools: Int = 0
    /// Claude's final reply for the last finished turn.
    var lastReply: String? = nil

    private var lineBeforeApproval: String? = nil
    private var mergeKey: String? = nil
    private var mergeCount: Int = 0

    var isEmpty: Bool { line.isEmpty && prompt.isEmpty }

    /// Bottom row as shown, with running subagents folded in.
    var displayLine: String {
        guard busy, subagents > 0 else { return line }
        let action = line.hasPrefix("Agent · ") ? String(line.dropFirst(8)) : line
        return "\(subagents) agent\(subagents == 1 ? "" : "s") · \(action)"
    }

    /// "Step 3/6" while the plan has unfinished steps, nil otherwise.
    var planLabel: String? {
        let steps = plan.filter { $0.status != "deleted" }
        guard !steps.isEmpty, steps.contains(where: { $0.status != "completed" }) else { return nil }
        let current = steps.firstIndex { $0.status == "in_progress" }
            ?? steps.filter { $0.status == "completed" }.count
        return "Step \(min(current + 1, steps.count))/\(steps.count)"
    }

    // MARK: Turn lifecycle

    mutating func beginTurn(prompt raw: String) {
        let cleaned = Self.collapseWhitespace(raw)
        if !cleaned.isEmpty && (prompt.isEmpty || !Self.isShortReply(cleaned)) {
            prompt = cleaned
        }
        turnStart = Date()
        turnEnd = nil
        runningTools = 0
        subagents = 0
        lastReply = nil
        setLine("Thinking…", busy: true)
    }

    mutating func markThinking() {
        setLine("Thinking…", busy: true)
    }

    mutating func finish(reply: String?) {
        endTurn()
        let summary = reply.map(Self.firstSentence) ?? ""
        lastReply = reply
        setLine(summary.isEmpty ? "Done" : "Done · \(summary)", busy: false)
    }

    mutating func fail(errorType: String?) {
        endTurn()
        let reason = errorType.map { $0.replacingOccurrences(of: "_", with: " ") } ?? ""
        setLine(reason.isEmpty || reason == "unknown" ? "Stopped" : "Stopped · \(reason)", busy: false)
    }

    mutating func needsApproval(tool: String) {
        if busy { lineBeforeApproval = line }
        setLine(tool.isEmpty ? "Needs approval" : "Needs approval · \(Self.toolName(tool))", busy: false)
    }

    /// Claude is asking you something: the line is the question itself (shown with a "?" icon).
    mutating func question(_ text: String) {
        setLine(text.isEmpty ? "Question" : text, busy: false)
        asking = true
    }

    /// AskUserQuestion: the first question itself, with how many more follow.
    mutating func askUser(_ input: [String: Any]) {
        let questions = input["questions"] as? [[String: Any]] ?? []
        let first = questions.first
        let text = (first?["question"] as? String) ?? (first?["header"] as? String) ?? ""
        let more = questions.count > 1 ? " (+\(questions.count - 1) more)" : ""
        question(Self.collapseWhitespace(text) + more)
    }

    /// Claude is idle at the prompt. A finished turn keeps its "Done" line.
    mutating func waitingForYou() {
        guard !line.hasPrefix("Done") else { return }
        endTurn()
        setLine("Waiting for you", busy: false)
    }

    /// After an approval is answered, the approved tool runs: back to its line.
    mutating func resume() {
        setLine(lineBeforeApproval ?? "Thinking…", busy: true)
        lineBeforeApproval = nil
    }

    private mutating func endTurn() {
        if turnStart != nil && turnEnd == nil { turnEnd = Date() }
        runningTools = 0
        subagents = 0
    }

    // MARK: Tools

    mutating func toolStarted(tool: String, input: [String: Any]) {
        runningTools += 1
        switch tool {
        case "TaskCreate", "TaskUpdate", "TaskList", "TaskGet", "TaskOutput", "TaskStop", "TodoWrite":
            if tool == "TaskUpdate" { updatePlan(input) }
            return   // plan bookkeeping: the counter moves, the line stays
        case "AskUserQuestion":
            askUser(input)
            return
        default:
            break
        }
        let (key, label) = Self.describe(tool: tool, input: input)
        if let key, key == mergeKey, busy {
            mergeCount += 1
            line = Self.counted(label, key: key, count: mergeCount)
        } else {
            setLine(label, busy: true)
            mergeKey = key
            mergeCount = 1
        }
    }

    mutating func toolFinished(tool: String, response: Any?, failed: Bool) {
        runningTools = max(0, runningTools - 1)
        if tool == "TaskCreate" && !failed { addPlanStep(response: response) }
        if failed && tool != "AskUserQuestion" {
            setLine("\(Self.toolName(tool)) failed", busy: true)
        }
    }

    mutating func subagentStarted() { subagents += 1 }
    mutating func subagentStopped() { subagents = max(0, subagents - 1) }

    private mutating func setLine(_ text: String, busy: Bool) {
        if text != line { lineID &+= 1 }
        line = text
        self.busy = busy
        asking = false
        mergeKey = nil
        mergeCount = 0
    }

    // MARK: Plan

    /// A new session in this pill starts without a plan.
    mutating func resetPlan() { plan = [] }

    /// TaskCreate replies "Task #3 created successfully: <subject>".
    private mutating func addPlanStep(response: Any?) {
        let text = response.map { String(describing: $0) } ?? ""
        let dict = response as? [String: Any]
        let task = (dict?["task"] as? [String: Any]) ?? dict
        let structuredId = (task?["id"] as? String) ?? (task?["id"] as? Int).map(String.init)
        let id = structuredId
            ?? text.range(of: #"#(\d+)"#, options: .regularExpression).map { String(text[$0].dropFirst()) }
            ?? String((plan.compactMap { Int($0.id) }.max() ?? 0) + 1)
        let subject = text.range(of: "created successfully: ")
            .map { String(text[$0.upperBound...]).trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) } ?? ""
        if let idx = plan.firstIndex(where: { $0.id == id }) {
            plan[idx] = PlanStep(id: id, subject: subject, status: "pending")
        } else {
            plan.append(PlanStep(id: id, subject: subject, status: "pending"))
        }
    }

    private mutating func updatePlan(_ input: [String: Any]) {
        let id = (input["taskId"] as? String) ?? (input["taskId"] as? Int).map(String.init) ?? ""
        guard let status = input["status"] as? String,
              let idx = plan.firstIndex(where: { $0.id == id }) else { return }
        plan[idx].status = status
    }

    // MARK: - Formatting

    /// Merge key (consecutive calls with the same key share one line) and label.
    static func describe(tool: String, input: [String: Any]) -> (String?, String) {
        let file = (input["file_path"] as? String) ?? (input["notebook_path"] as? String)
            ?? (input["path"] as? String)
        let fileName = file.map { URL(fileURLWithPath: $0).lastPathComponent }

        switch tool {
        case "Read", "LS":
            return ("explore", "Exploring · \(fileName ?? "files")")
        case "Grep", "Glob":
            let pattern = (input["pattern"] as? String).map { "“\(truncate($0, 30))”" }
            return ("explore", "Exploring · \(pattern ?? fileName ?? "files")")
        case "WebFetch":
            let host = (input["url"] as? String).flatMap { URL(string: $0)?.host } ?? "the web"
            return ("explore", "Exploring · \(host)")
        case "ToolSearch":
            return ("explore", "Exploring · tools")
        case "WebSearch":
            let query = (input["query"] as? String).map { truncate($0, 40) } ?? ""
            return (nil, query.isEmpty ? "Searching the web" : "Searching the web · \(query)")
        case "Edit", "Write", "MultiEdit", "NotebookEdit":
            let name = fileName ?? "file"
            return ("edit:\(file ?? name)", "Editing \(name)")
        case "Bash", "BashOutput":
            return (nil, bashLabel(input))
        case "Agent", "Task":
            let what = (input["description"] as? String) ?? (input["subagent_type"] as? String) ?? ""
            return (nil, what.isEmpty ? "Starting an agent" : "Agent · \(what)")
        case "Skill":
            let name = (input["skill"] as? String) ?? (input["skill_name"] as? String) ?? ""
            return (nil, name.isEmpty ? "Using a skill" : "Using skill · \(name)")
        case "EnterPlanMode", "ExitPlanMode":
            return (nil, "Planning")
        default:
            return (nil, toolName(tool))
        }
    }

    /// "Exploring · AppState.swift (5)", "Editing HookServer.swift (×3)".
    static func counted(_ label: String, key: String, count: Int) -> String {
        guard count > 1 else { return label }
        return key.hasPrefix("edit:") ? "\(label) (×\(count))" : "\(label) (\(count))"
    }

    /// Claude's own description of the command, else "Running git status".
    static func bashLabel(_ input: [String: Any]) -> String {
        if let desc = input["description"] as? String, !desc.isEmpty { return desc }
        guard let command = input["command"] as? String else { return "Running a command" }
        // Drop leading "cd … &&" and env assignments, keep the first command of a pipeline.
        var words = command
            .components(separatedBy: "&&").map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.hasPrefix("cd ") && !$0.isEmpty }?
            .components(separatedBy: "|").first?
            .split(separator: " ").map(String.init) ?? []
        while let first = words.first, first.contains("="), !first.hasPrefix("-") { words.removeFirst() }
        guard let program = words.first.map({ URL(fileURLWithPath: $0).lastPathComponent }) else {
            return "Running a command"
        }
        // First plain word that isn't a flag's value: "git -C dir status" → status.
        let args = Array(words.dropFirst())
        let sub = args.indices.first { i in
            let w = args[i]
            return !w.hasPrefix("-") && (i == 0 || !args[i - 1].hasPrefix("-"))
                && !w.contains("/") && !w.contains("\"") && !w.contains("'")
        }.map { i in
            // "npm run test" → test
            args[i] == "run" && i + 1 < args.count && !args[i + 1].hasPrefix("-") ? args[i + 1] : args[i]
        }
        let subcommandTools: Set<String> = ["git", "gh", "npm", "yarn", "pnpm", "bun", "cargo", "swift",
                                            "xcodebuild", "brew", "docker", "kubectl", "go", "make", "npx"]
        if let sub, subcommandTools.contains(program) { return "Running \(program) \(sub)" }
        return "Running \(program)"
    }

    /// "mcp__claude_ai_Linear__save_issue" → "Linear · save issue"; "ScheduleWakeup" → "Schedule wakeup".
    static func toolName(_ tool: String) -> String {
        if tool.hasPrefix("mcp__") {
            let parts = tool.dropFirst(5).components(separatedBy: "__")
            var server = parts.first ?? ""
            if server.hasPrefix("claude_ai_") { server = String(server.dropFirst(10)) }
            server = server.replacingOccurrences(of: "_", with: " ")
            let action = parts.dropFirst().joined(separator: " ").replacingOccurrences(of: "_", with: " ")
            return action.isEmpty ? server : "\(server) · \(action)"
        }
        var out = ""
        for (i, ch) in tool.enumerated() {
            if ch.isUppercase && i > 0 { out += " " + ch.lowercased() } else { out.append(ch) }
        }
        return out
    }

    /// First sentence (or line) of Claude's reply, without markdown markers.
    static func firstSentence(_ text: String) -> String {
        let firstBlock = text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty && !$0.hasPrefix("```") && !$0.hasPrefix("|") && !$0.hasPrefix("#") } ?? ""
        var line = firstBlock
            .replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "`", with: "")
            .replacingOccurrences(of: #"^(#+|[-*]|\d+\.)\s+"#, with: "", options: .regularExpression)
        if let end = line.range(of: #"[.!?](\s|$)"#, options: .regularExpression) {
            line = String(line[..<end.lowerBound])
        }
        return truncate(line, 140)
    }

    /// Short replies are follow-ups ("yes", "8 b", "looks good"), not a new task.
    static func isShortReply(_ prompt: String) -> Bool {
        prompt.split(whereSeparator: \.isWhitespace).count < 5
    }

    static func collapseWhitespace(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func truncate(_ text: String, _ max: Int) -> String {
        text.count > max ? String(text.prefix(max - 1)) + "…" : text
    }
}
