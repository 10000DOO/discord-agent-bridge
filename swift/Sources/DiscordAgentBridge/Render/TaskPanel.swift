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

/// Tool names whose input carries a task list. Backend-specific, deliberately not extensible:
/// a name that is not here falls through to the normal tool rendering untouched.
public let taskPanelTools: Set<String> = ["TodoWrite", "update_plan"]

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

/// Discord permission bits the bot needs. Same set the README's invite link asks for, plus
/// `Manage Messages` (1 << 13) which pinning requires and the original invite never requested.
/// Summed here rather than hardcoded so the list stays readable next to the README table.
public var botRequiredPermissionBits: UInt64 {
    let bits: [UInt64] = [
        1 << 4,  // Manage Channels
        1 << 6,  // Add Reactions
        1 << 10, // View Channel
        1 << 11, // Send Messages
        1 << 13, // Manage Messages — pin/unpin
        1 << 14, // Embed Links
        1 << 15, // Attach Files
        1 << 16, // Read Message History
        1 << 34, // Manage Threads
        1 << 35, // Create Public Threads
        1 << 38, // Send Messages in Threads
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
