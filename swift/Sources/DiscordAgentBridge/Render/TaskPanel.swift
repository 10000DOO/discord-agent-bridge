import Foundation

// Task checklist panel: pure model / parse / format (docs/task-panel-and-diff-view.md WO-1).
//
// The three backends all publish a task list, each in its own shape, and all of it already
// reaches us: Claude's `TodoWrite` and Codex's `update_plan` arrive as ordinary tool calls
// (`AgentEvent.toolUse` carries the whole input), and grok sends ACP `plan` session updates.
// Until now the list was spent as a one-line "used a tool" log entry and dropped.
//
// Discord I/O lives in TaskPanelHost's injected sink; this file is format-only.

/// One checklist entry's state. Raw values match the wire strings all three backends use.
public enum TaskPanelStatus: String, Sendable, Equatable {
    case pending
    case inProgress = "in_progress"
    case completed

    /// Same marks the grok plan lines already use (`planStatusMark`) — one convention, not two.
    public var mark: String {
        switch self {
        case .completed: return "✓"
        case .inProgress: return "▶"
        case .pending: return "•"
        }
    }
}

public struct TaskPanelItem: Sendable, Equatable {
    public var text: String
    public var status: TaskPanelStatus

    public init(text: String, status: TaskPanelStatus) {
        self.text = text
        self.status = status
    }
}

/// Pure payload for the pinned panel message (same shape as `StreamEmbedSpec`).
public struct TaskPanelSpec: Sendable, Equatable {
    public var title: String
    public var description: String
    public var color: Int

    public init(title: String, description: String, color: Int) {
        self.title = title
        self.description = description
        self.color = color
    }
}

/// Tool names whose input carries a WHOLE task list, replaced on every call.
/// `TodoWrite` is Claude's older shape; `update_plan` is Codex's. A name that is not here falls
/// through to the normal tool rendering untouched.
public let taskPanelTools: Set<String> = ["TodoWrite", "update_plan"]

/// Claude's current task tools (measured on claude-agent-sdk 0.3.223): instead of resending the
/// whole list, `TaskCreate` adds one task and `TaskUpdate` mutates one by id. The id is not in
/// either input — it only comes back in `TaskCreate`'s result — so the panel has to keep the list
/// itself and link ids as results arrive (`TaskPanelHost`).
public let taskCreateToolName = "TaskCreate"
public let taskUpdateToolName = "TaskUpdate"

/// Discord embed description limit, shared with the stream embed.
let taskPanelDescLimit = streamEmbedDescLimit

private func taskPanelStatus(_ raw: String?) -> TaskPanelStatus {
    guard let raw else { return .pending }
    return TaskPanelStatus(rawValue: raw) ?? .pending
}

/// Parse a task list out of a tool call's input. `nil` when this tool carries no list (the
/// common case) or when the input holds no usable entry — never an empty-list panel.
public func parseTaskPanelInput(name: String, input: JSONValue) -> [TaskPanelItem]? {
    guard taskPanelTools.contains(name), let obj = input.objectValue else { return nil }
    // Claude `TodoWrite`: { todos: [{ content, status, activeForm }] }
    // Codex `update_plan`: { plan: [{ step, status }], explanation? }
    let entries = obj["todos"]?.arrayValue ?? obj["plan"]?.arrayValue
    guard let entries else { return nil }
    let items = taskPanelItems(entries: entries, textKeys: ["content", "step"])
    return items.isEmpty ? nil : items
}

/// One task's title from a `TaskCreate` call. `nil` for any other tool or a blank subject.
public func parseTaskCreateSubject(name: String, input: JSONValue) -> String? {
    guard name == taskCreateToolName, let obj = input.objectValue else { return nil }
    let subject = (obj["subject"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    return subject.isEmpty ? nil : subject
}

/// A `TaskUpdate` call reduced to what the panel shows. `status: "deleted"` is not a display state,
/// so it is carried separately rather than smuggled into `TaskPanelStatus`.
public struct TaskPanelUpdate: Sendable, Equatable {
    public var taskId: String
    public var status: TaskPanelStatus?
    public var deleted: Bool
    public var subject: String?

    public init(taskId: String, status: TaskPanelStatus? = nil, deleted: Bool = false, subject: String? = nil) {
        self.taskId = taskId
        self.status = status
        self.deleted = deleted
        self.subject = subject
    }
}

/// Parse a `TaskUpdate` call. `nil` for any other tool, a blank id, or an update that changes
/// nothing the panel displays (owner, blockers, metadata — those must not force a redraw).
public func parseTaskUpdateInput(name: String, input: JSONValue) -> TaskPanelUpdate? {
    guard name == taskUpdateToolName, let obj = input.objectValue else { return nil }
    let taskId = (obj["taskId"]?.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    guard !taskId.isEmpty else { return nil }
    let rawStatus = obj["status"]?.stringValue
    let subject = obj["subject"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    let update = TaskPanelUpdate(
        taskId: taskId,
        status: rawStatus.flatMap { TaskPanelStatus(rawValue: $0) },
        deleted: rawStatus == "deleted",
        subject: (subject?.isEmpty ?? true) ? nil : subject
    )
    guard update.status != nil || update.deleted || update.subject != nil else { return nil }
    return update
}

/// `Task #12 created successfully: <subject>` — the measured shape of a `TaskCreate` tool result
/// (claude-agent-sdk 0.3.223). The declared SDK type is `{ task: { id, subject } }`, so a future CLI
/// may send JSON instead; both are accepted and anything else yields nil (the panel then keeps
/// showing the task, it just can't follow later status changes for it).
public func parseTaskCreateResultId(_ content: String) -> String? {
    if let hash = content.firstIndex(of: "#") {
        let digits = content[content.index(after: hash)...].prefix { $0.isNumber }
        if !digits.isEmpty { return String(digits) }
    }
    guard let data = content.data(using: .utf8),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    let task = root["task"] as? [String: Any]
    if let id = task?["id"] ?? root["id"] {
        let text = String(describing: id)
        return text.isEmpty ? nil : text
    }
    return nil
}

/// Parse a task list out of a grok ACP `session/update` notification. `nil` when this update is
/// not a plan or carries no usable entry, so the caller can fall through to its existing path.
public func grokPlanItems(method: String, params: JSONValue?) -> [TaskPanelItem]? {
    guard method == "session/update" || method == "x.ai/session/update" else { return nil }
    guard let update = params?["update"],
          update["sessionUpdate"]?.stringValue == "plan",
          let entries = update["entries"]?.arrayValue
    else { return nil }
    let items = taskPanelItems(entries: entries, textKeys: ["content"])
    return items.isEmpty ? nil : items
}

/// Shared entry mapper: first non-empty text key wins, unknown/absent status → pending.
private func taskPanelItems(entries: [JSONValue], textKeys: [String]) -> [TaskPanelItem] {
    entries.compactMap { entry in
        let text = textKeys
            .compactMap { entry[$0]?.stringValue }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard let text else { return nil }
        return TaskPanelItem(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines),
            status: taskPanelStatus(entry["status"]?.stringValue)
        )
    }
}

/// Recognize one of our own panel bodies among a channel's pinned messages (D3-3 boot adoption).
/// Structural, not textual: every non-empty line starts with one of the three status marks, so this
/// holds in any locale and no invisible marker has to be smuggled into the embed. A false negative
/// only costs a fresh panel; a false positive needs a bot-authored embed shaped exactly like this.
public func isTaskPanelDescription(_ text: String) -> Bool {
    let lines = text
        .split(separator: "\n", omittingEmptySubsequences: true)
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    guard !lines.isEmpty else { return false }
    let marks = Set(TaskPanelStatus.allMarks)
    return lines.allSatisfy { line in
        guard let first = line.first else { return false }
        return marks.contains(String(first))
    }
}

extension TaskPanelStatus {
    static var allMarks: [String] { ["✓", "▶", "•"] }
}

// MARK: - Pin permission (R9)

/// Discord permission bits the bot asks for. Deliberately broad: every re-authorization costs the
/// user a manual click in the browser, so a set that only just covers today's features guarantees
/// another round trip the first time a feature needs one more bit. Everything text/thread-shaped is
/// requested up front. Member moderation (kick/ban/timeout), voice, and Administrator are left out —
/// nothing here drives them, and they are what makes a server owner refuse the invite.
/// Summed here rather than hardcoded so the list stays readable next to the README table.
public var botRequiredPermissionBits: UInt64 {
    let bits: [UInt64] = [
        1 << 0,  // Create Instant Invite
        1 << 4,  // Manage Channels
        1 << 5,  // Manage Guild
        1 << 6,  // Add Reactions
        1 << 7,  // View Audit Log
        1 << 10, // View Channel
        1 << 11, // Send Messages
        1 << 13, // Manage Messages — pin/unpin on older servers, plus edit/delete
        1 << 14, // Embed Links
        1 << 15, // Attach Files
        1 << 16, // Read Message History
        1 << 17, // Mention Everyone — @everyone/@here and role pings in alerts
        1 << 18, // Use External Emojis
        1 << 26, // Change Nickname
        1 << 28, // Manage Roles — pairing/allowlist automation
        1 << 29, // Manage Webhooks
        1 << 31, // Use Application Commands
        1 << 34, // Manage Threads
        1 << 35, // Create Public Threads
        1 << 36, // Create Private Threads
        1 << 37, // Use External Stickers
        1 << 38, // Send Messages in Threads
        1 << 46, // Send Voice Messages
        1 << 49, // Send Polls
        1 << 50, // Use External Apps
        1 << 51, // Pin Messages — Discord split pinning out of Manage Messages
        1 << 52, // Bypass Slowmode — a long agent answer must not be rate-limited away
    ]
    return bits.reduce(0, |)
}

/// Re-authorization URL that grants the permissions above to a bot already in the guild. Clicking
/// it updates the existing integration role — the bot does not leave and rejoin. This is the whole
/// automation: Discord refuses to let a bot add a permission it does not already hold to its own
/// role, so one click is the floor, not zero.
public func botReinviteURL(applicationId: String) -> String {
    "https://discord.com/api/oauth2/authorize"
        + "?client_id=\(applicationId)"
        + "&scope=bot%20applications.commands"
        + "&permissions=\(botRequiredPermissionBits)"
}

/// Build the panel body. All-done switches title and color so a finished list reads as finished
/// at a glance without opening it.
public func formatTaskPanel(items: [TaskPanelItem]) -> TaskPanelSpec {
    let done = items.filter { $0.status == .completed }.count
    let total = items.count
    let allDone = total > 0 && done == total
    let body = items.map { "\($0.status.mark) \($0.text)" }.joined(separator: "\n")
    return TaskPanelSpec(
        title: allDone
            ? I18n.t("taskPanel.title.done", ["total": "\(total)"])
            : I18n.t("taskPanel.title", ["done": "\(done)", "total": "\(total)"]),
        description: DiscordText.truncate(body, taskPanelDescLimit),
        color: allDone ? DiscordColors.idle : DiscordColors.streaming
    )
}
