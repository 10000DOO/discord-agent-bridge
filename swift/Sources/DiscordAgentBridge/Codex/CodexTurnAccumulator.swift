import Foundation

// Map one `codex app-server` notification to a text-turn step. Text path of
// src/modes/codex/eventMapper.ts (item/agentMessage/delta, item/completed agentMessage,
// turn/completed, turn|thread/failed, error). Pure: no state, never throws.
//
// Tool mid-turn events live in `codexToolEvents` (W16-g residual) so the text fold stays simple.
// Progress (`item/started` / `turn/started`) lives in `codexProgressEvents` (G-P1-02).

public enum CodexTurnStep: Equatable {
    case appendText(String)   // item/agentMessage/delta → params.delta
    case fullText(String)     // item/completed agentMessage → item.text (fallback when no deltas)
    case finished(TurnUsage?) // turn/completed (+ optional token usage)
    case failed(String)       // turn/failed | thread/failed | error
    case ignore
}

public func codexTurnStep(method: String, params: JSONValue?) -> CodexTurnStep {
    switch method {
    case "item/agentMessage/delta":
        // eventMapper.ts:78-86
        let delta = params?["delta"]?.stringValue ?? ""
        return delta.isEmpty ? .ignore : .appendText(delta)

    case "item/completed":
        // eventMapper.ts:265, 270-276 — item lives at params.item (fall back to params).
        let item = params?["item"] ?? params
        let type = item?["type"]?.stringValue
        if type == "agentMessage" || type == "agent_message",
           let text = item?["text"]?.stringValue, !text.isEmpty {
            return .fullText(text)
        }
        return .ignore

    case "turn/completed":
        // eventMapper.ts:109-135 — surface tokensIn/Out when present (W11-g slice1).
        return .finished(turnUsage(fromCodexCompleted: params))

    case "turn/failed", "thread/failed", "error":
        // eventMapper.ts:137-152
        let message = params?["error"]?["message"]?.stringValue
            ?? params?["message"]?.stringValue
            ?? "Codex turn failed."
        return .failed(message)

    default:
        return .ignore
    }
}

// MARK: - Turn id verification (H2 / TS eventMapper.ts:74 `optString(p.turnId)` +
// appSession.ts:220 `if (!mapped.turnId || mapped.turnId === turnId) settle()`)

/// Extract the turnId a notification carries at its top-level `params.turnId` (present on
/// `turn/completed`/`turn/failed`/`thread/failed`/`error` among others). `nil` when absent.
public func codexNotificationTurnId(params: JSONValue?) -> String? {
    params?["turnId"]?.stringValue
}

/// True when a finishing notification (`turn/completed`/`turn/failed`/`thread/failed`/`error`)
/// belongs to the turn currently tracked as active for this channel. A notification without a
/// turnId always passes (some app-server builds omit it, matching TS `!mapped.turnId`); no
/// recorded active turn yet also passes (a Swift-only race window — TS always resolves its local
/// `turnId` before it starts listening, so this case doesn't exist there). Only a PRESENT,
/// MISMATCHED turnId is rejected — this is what guards against a stale `turn/completed` from an
/// already-finished/interrupted turn incorrectly completing a newer one.
public func codexNotificationMatchesActiveTurn(params: JSONValue?, activeTurnId: String?) -> Bool {
    guard let notifTurnId = codexNotificationTurnId(params: params) else { return true }
    guard let activeTurnId else { return true }
    return notifTurnId == activeTurnId
}

// MARK: - Progress mid-turn (G-P1-02 / TS eventMapper mapItemStarted + turn/started)

/// TS PROGRESS_LABELS (eventMapper.ts) — KO status lines for TranscriptFeed / StreamStatusHost.
public enum CodexProgressLabels {
    public static let working = "작업 중"
    public static let commandExecution = "명령 실행 중"
    public static let fileChange = "파일 수정 중"
    public static let fileSearch = "파일 탐색 중"
    public static let webSearch = "웹 검색 중"
    public static let image = "이미지 생성 중"
    public static let mcpToolCall = "도구 실행 중"
    public static let collabAgentToolCall = "서브에이전트 작업 중"
}

/// Map codex app-server notifications → `progress` / `thinking` AgentEvents.
/// Pure; never throws. Unknown methods / non-progress items → `[]`.
///
/// TS: `item/started` → progressForItem; `turn/started` → `{kind:'progress', label:'작업 중'}`;
/// `item/reasoning/delta`(+3 aliases) → `{kind:'thinking'}` (eventMapper.ts:171-184, C1).
/// Swift surfaces these via `StreamStatusHost.noteProgress` / `.noteThinking` (mirrors
/// `grokProgressEvents` mixing progress+thinking in one mapper).
public func codexProgressEvents(method: String, params: JSONValue?) -> [AgentEvent] {
    switch method {
    case "turn/started":
        return [.progress(label: CodexProgressLabels.working, detail: nil)]
    case "item/started":
        let item = params?["item"] ?? params
        guard let item else { return [] }
        let type = item["type"]?.stringValue ?? ""
        if let ev = codexProgressForItem(type: type, item: item) {
            return [ev]
        }
        return []
    case "item/reasoning/delta", "item/agentReasoning/delta",
         "item/reasoning/textDelta", "item/reasoning/summaryTextDelta":
        // C1 / eventMapper.ts:171-184 — 4 method names (1 primary + 3 aliases) map identically.
        let delta = params?["delta"]?.stringValue ?? ""
        return delta.isEmpty ? [] : [.thinking(text: delta, delta: true)]
    default:
        return []
    }
}

private func codexProgressForItem(type: String, item: JSONValue) -> AgentEvent? {
    switch type {
    case "commandExecution", "command_execution":
        return .progress(label: CodexProgressLabels.commandExecution, detail: item["command"]?.stringValue)
    case "fileChange", "file_change":
        return .progress(label: CodexProgressLabels.fileChange, detail: codexFileChangeProgressDetail(item))
    case "webSearch", "web_search":
        return .progress(label: CodexProgressLabels.webSearch, detail: item["query"]?.stringValue)
    case "mcpToolCall", "mcp_tool_call":
        let detail = item["tool"]?.stringValue
            ?? item["server"]?.stringValue
            ?? item["name"]?.stringValue
        return .progress(label: CodexProgressLabels.mcpToolCall, detail: detail)
    case "collabAgentToolCall", "collab_agent_tool_call":
        let detail = item["agentRole"]?.stringValue ?? item["tool"]?.stringValue
        return .progress(label: CodexProgressLabels.collabAgentToolCall, detail: detail)
    case "image":
        return .progress(label: CodexProgressLabels.image, detail: nil)
    case "fileSearch", "file_search":
        return .progress(label: CodexProgressLabels.fileSearch, detail: nil)
    default:
        return nil
    }
}

/// TS fileChangeDetail: one path, or "N개 파일".
private func codexFileChangeProgressDetail(_ item: JSONValue) -> String? {
    guard let arr = item["changes"]?.arrayValue else { return nil }
    let paths = arr.compactMap { $0["path"]?.stringValue }.filter { !$0.isEmpty }
    if paths.isEmpty { return nil }
    if paths.count == 1 { return paths[0] }
    return "\(paths.count)개 파일"
}

// MARK: - Context usage (C2 / TS eventMapper.ts:186-208 thread/tokenUsage/updated)

/// Map `thread/tokenUsage/updated` → a context-usage snapshot. Pure; never throws.
/// Fires many times per turn (TS comment: "Do NOT emit context_usage here — app-server
/// streams this many times per turn") — the caller keeps only the latest snapshot and
/// surfaces it once via `TurnResult.contextUsage` at turn end (appSession.ts:211-219).
/// App-server does not report a resolved model here, so use only the explicitly configured
/// session model. When it is absent, leave `model` nil rather than guessing the CLI default.
public func codexContextUsage(
    method: String,
    params: JSONValue?,
    model: String? = nil
) -> ContextUsageInfo? {
    guard method == "thread/tokenUsage/updated" else { return nil }
    guard let usage = params?["tokenUsage"] else { return nil }
    guard let totalTokens = usage["total"]?["totalTokens"]?.numberValue else { return nil }
    guard let maxTokens = usage["modelContextWindow"]?.numberValue, maxTokens > 0 else { return nil }
    let percentage = min(100.0, (totalTokens / maxTokens * 100).rounded())
    let configuredModel = model?.trimmingCharacters(in: .whitespacesAndNewlines)
    return ContextUsageInfo(
        totalTokens: Int(totalTokens),
        maxTokens: Int(maxTokens),
        percentage: percentage,
        model: configuredModel?.isEmpty == false ? configuredModel : nil
    )
}

// MARK: - Tool mid-turn events (W16-g residual / TS eventMapper mapItemCompleted)

/// Map codex app-server notifications → tool_use / tool_result / subagent_result AgentEvents.
/// Pure aside from `mintId` / `parentByThread` mutation; never throws. Unknown methods /
/// non-tool items → `[]`.
///
/// `parentByThread` (childThreadId → spawn tool_use id) matches TS `MapContext.parentByThread`
/// + `onSpawnThread`: collab `spawnAgent` registers the child; later items whose notification
/// `threadId` is a child get `parentToolUseId` so TurnThreadRegistry routes into the spawn thread.
///
/// Remaining gaps vs TS `eventMapper.ts`:
/// - Tool events fire on `item/completed` only (TS same for tools) — not on `item/started`.
public func codexToolEvents(
    method: String,
    params: JSONValue?,
    mintId: inout Int,
    parentByThread: inout [String: String]
) -> [AgentEvent] {
    guard method == "item/completed" else { return [] }
    let item = params?["item"] ?? params
    guard let item else { return [] }
    let type = item["type"]?.stringValue ?? ""
    let id = codexItemId(item, mintId: &mintId)
    // TS resolveParent(params.threadId, parentByThread) — notification-level thread, not item.
    let parentToolUseId = resolveCodexParent(threadId: params?["threadId"]?.stringValue, parentByThread: parentByThread)

    switch type {
    case "commandExecution", "command_execution":
        let command = item["command"]?.stringValue ?? ""
        let output = item["aggregatedOutput"]?.stringValue
            ?? item["aggregated_output"]?.stringValue
            ?? ""
        let exitCode = item["exitCode"]?.numberValue.map { Int($0) }
            ?? item["exit_code"]?.numberValue.map { Int($0) }
        let ok = exitCode == 0
        return [
            .toolUse(id: id, name: "shell", input: .object(["command": .string(command)]), parentToolUseId: parentToolUseId),
            .toolResult(id: id, ok: ok, content: output, parentToolUseId: parentToolUseId),
        ]

    case "fileChange", "file_change":
        let changes = item["changes"] ?? .array([])
        let body = formatCodexFileChangeDiffs(changes)
        let status = item["status"]?.stringValue
        let ok = status != "failed" && status != "declined"
        return [
            .toolUse(id: id, name: "apply_patch", input: .object(["changes": changes]), parentToolUseId: parentToolUseId),
            .toolResult(id: id, ok: ok, content: body, parentToolUseId: parentToolUseId),
        ]

    case "mcpToolCall", "mcp_tool_call":
        let name = item["tool"]?.stringValue
            ?? item["name"]?.stringValue
            ?? "mcp_tool_call"
        let input = item["arguments"] ?? item["input"] ?? .object([:])
        var events: [AgentEvent] = [
            .toolUse(id: id, name: name, input: input, parentToolUseId: parentToolUseId),
        ]
        if let result = item["result"]?.stringValue ?? item["output"]?.stringValue {
            let status = item["status"]?.stringValue
            let ok = status != "failed" && item["error"] == nil
            events.append(.toolResult(id: id, ok: ok, content: result, parentToolUseId: parentToolUseId))
        }
        return events

    case "webSearch", "web_search":
        var input: [String: JSONValue] = [:]
        if let query = item["query"]?.stringValue {
            input["query"] = .string(query)
        }
        return [
            .toolUse(id: id, name: "web_search", input: .object(input), parentToolUseId: parentToolUseId),
        ]

    case "collabAgentToolCall", "collab_agent_tool_call":
        return mapCodexCollabAgent(
            item: item,
            id: id,
            parentToolUseId: parentToolUseId,
            parentByThread: &parentByThread
        )

    case "subAgentActivity", "sub_agent_activity":
        let statusRaw = item["status"]?.stringValue ?? item["state"]?.stringValue
        let summary = item["summary"]?.stringValue
            ?? item["message"]?.stringValue
            ?? item["text"]?.stringValue
            ?? "subagent activity"
        if statusRaw == "completed" || statusRaw == "failed" || statusRaw == "stopped",
           let st = AgentEvent.SubagentStatus(rawValue: statusRaw ?? "") {
            let taskId = item["taskId"]?.stringValue
                ?? item["id"]?.stringValue
                ?? "subagent"
            // TS: toolUseId ?? parentToolUseId(item) ?? resolved parent from thread map.
            let toolUseId = item["toolUseId"]?.stringValue
                ?? item["parentToolUseId"]?.stringValue
                ?? parentToolUseId
            return [
                .subagentResult(
                    taskId: taskId,
                    status: st,
                    summary: summary,
                    toolUseId: toolUseId,
                    durationMs: nil,
                    toolUses: nil
                ),
            ]
        }
        return []

    default:
        return []
    }
}

private func resolveCodexParent(threadId: String?, parentByThread: [String: String]) -> String? {
    guard let threadId, !threadId.isEmpty else { return nil }
    return parentByThread[threadId]
}

private func codexItemId(_ item: JSONValue, mintId: inout Int) -> String {
    if let id = item["id"]?.stringValue, !id.isEmpty { return id }
    if let id = item["itemId"]?.stringValue, !id.isEmpty { return id }
    mintId += 1
    return "codex-tool-\(mintId)"
}

private func mapCodexCollabAgent(
    item: JSONValue,
    id: String,
    parentToolUseId: String?,
    parentByThread: inout [String: String]
) -> [AgentEvent] {
    let tool = item["tool"]?.stringValue
        ?? item["name"]?.stringValue
        ?? item["toolName"]?.stringValue
        ?? ""
    let isSpawn =
        tool == "spawnAgent"
        || tool == "spawn_agent"
        || item["action"]?.stringValue == "spawnAgent"
        || tool.isEmpty

    if isSpawn {
        var input: [String: JSONValue] = [:]
        let agentRole = item["agentRole"]?.stringValue ?? item["agent_role"]?.stringValue
        let agentNickname = item["agentNickname"]?.stringValue
            ?? item["agent_nickname"]?.stringValue
            ?? item["nickname"]?.stringValue
        let subagentType = agentRole
            ?? item["subagent_type"]?.stringValue
            ?? item["subagentType"]?.stringValue
        if let subagentType { input["subagent_type"] = .string(subagentType) }
        if let agentNickname { input["agentNickname"] = .string(agentNickname) }
        if let agentRole { input["agentRole"] = .string(agentRole) }
        if let description = item["description"]?.stringValue {
            input["description"] = .string(description)
        }
        // TS mapCollabAgent + onSpawnThread(childThreadId, spawnToolId).
        if let child = item["threadId"]?.stringValue
            ?? item["childThreadId"]?.stringValue
            ?? item["agentThreadId"]?.stringValue
            ?? item["thread"]?["id"]?.stringValue {
            input["threadId"] = .string(child)
            parentByThread[child] = id
        }
        var events: [AgentEvent] = [
            .toolUse(id: id, name: "spawnAgent", input: .object(input), parentToolUseId: parentToolUseId),
        ]
        let status = item["status"]?.stringValue
        let resultText = item["result"]?.stringValue ?? item["output"]?.stringValue
        if resultText != nil || status == "completed" || status == "failed" {
            let ok = status != "failed" && item["error"] == nil
            events.append(.toolResult(
                id: id,
                ok: ok,
                content: resultText ?? (ok ? "spawned" : "failed"),
                parentToolUseId: parentToolUseId
            ))
        }
        return events
    }

    let name = tool.isEmpty ? "collabAgentToolCall" : tool
    let input = item["arguments"] ?? item["input"] ?? item
    var events: [AgentEvent] = [
        .toolUse(id: id, name: name, input: input, parentToolUseId: parentToolUseId),
    ]
    if let result = item["result"]?.stringValue ?? item["output"]?.stringValue {
        let status = item["status"]?.stringValue
        let ok = status != "failed" && item["error"] == nil
        events.append(.toolResult(id: id, ok: ok, content: result, parentToolUseId: parentToolUseId))
    }
    return events
}

/// Join FileUpdateChange entries into a tool_result body (TS formatFileChangeDiffs).
private func formatCodexFileChangeDiffs(_ changes: JSONValue) -> String {
    guard let arr = changes.arrayValue else { return "" }
    var parts: [String] = []
    for c in arr {
        guard let rec = c.objectValue else { continue }
        let pathStr = rec["path"]?.stringValue ?? ""
        let diff = rec["diff"]?.stringValue ?? ""
        if !diff.isEmpty {
            parts.append(pathStr.isEmpty ? diff : "--- \(pathStr)\n\(diff)")
        } else if !pathStr.isEmpty {
            parts.append(pathStr)
        }
    }
    return parts.joined(separator: "\n\n")
}
