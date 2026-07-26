import Foundation

// Map one `codex app-server` notification to a text-turn step. Text path of
// src/modes/codex/eventMapper.ts (item/agentMessage/delta, item/completed agentMessage,
// turn/completed, turn|thread/failed, error). Pure: no state, never throws.
//
// Tool mid-turn events live in `codexToolEvents` (W16-g residual) so the text fold stays simple.

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

// MARK: - Tool mid-turn events (W16-g residual / TS eventMapper mapItemCompleted)

/// Map codex app-server notifications → tool_use / tool_result / subagent_result AgentEvents.
/// Pure; never throws. Unknown methods / non-tool items → `[]`.
///
/// Gaps vs TS `eventMapper.ts` (documented, best-effort):
/// - No `parentByThread` / collab spawn child-thread routing (single-thread channel model).
/// - No progress / thinking / mid-turn tokenUsage (text + tools only for Discord activity).
/// - Tool events fire on `item/completed` only (TS same) — not on `item/started`.
public func codexToolEvents(
    method: String,
    params: JSONValue?,
    mintId: inout Int
) -> [AgentEvent] {
    guard method == "item/completed" else { return [] }
    let item = params?["item"] ?? params
    guard let item else { return [] }
    let type = item["type"]?.stringValue ?? ""
    let id = codexItemId(item, mintId: &mintId)

    switch type {
    case "commandExecution", "command_execution":
        let command = item["command"]?.stringValue ?? ""
        let output = item["aggregatedOutput"]?.stringValue
            ?? item["aggregated_output"]?.stringValue
            ?? ""
        let exitCode = item["exitCode"]?.numberValue.map { Int($0) }
            ?? item["exit_code"]?.numberValue.map { Int($0) }
        let ok = (exitCode ?? 0) == 0
        return [
            .toolUse(id: id, name: "shell", input: .object(["command": .string(command)]), parentToolUseId: nil),
            .toolResult(id: id, ok: ok, content: output, parentToolUseId: nil),
        ]

    case "fileChange", "file_change":
        let changes = item["changes"] ?? .array([])
        let body = formatCodexFileChangeDiffs(changes)
        let status = item["status"]?.stringValue
        let ok = status != "failed" && status != "declined"
        return [
            .toolUse(id: id, name: "apply_patch", input: .object(["changes": changes]), parentToolUseId: nil),
            .toolResult(id: id, ok: ok, content: body, parentToolUseId: nil),
        ]

    case "mcpToolCall", "mcp_tool_call":
        let name = item["tool"]?.stringValue
            ?? item["name"]?.stringValue
            ?? "mcp_tool_call"
        let input = item["arguments"] ?? item["input"] ?? .object([:])
        var events: [AgentEvent] = [
            .toolUse(id: id, name: name, input: input, parentToolUseId: nil),
        ]
        if let result = item["result"]?.stringValue ?? item["output"]?.stringValue {
            let status = item["status"]?.stringValue
            let ok = status != "failed" && item["error"] == nil
            events.append(.toolResult(id: id, ok: ok, content: result, parentToolUseId: nil))
        }
        return events

    case "webSearch", "web_search":
        var input: [String: JSONValue] = [:]
        if let query = item["query"]?.stringValue {
            input["query"] = .string(query)
        }
        return [
            .toolUse(id: id, name: "web_search", input: .object(input), parentToolUseId: nil),
        ]

    case "collabAgentToolCall", "collab_agent_tool_call":
        return mapCodexCollabAgent(item: item, id: id)

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
            let toolUseId = item["toolUseId"]?.stringValue
                ?? item["parentToolUseId"]?.stringValue
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

private func codexItemId(_ item: JSONValue, mintId: inout Int) -> String {
    if let id = item["id"]?.stringValue, !id.isEmpty { return id }
    if let id = item["itemId"]?.stringValue, !id.isEmpty { return id }
    mintId += 1
    return "codex-tool-\(mintId)"
}

private func mapCodexCollabAgent(item: JSONValue, id: String) -> [AgentEvent] {
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
        if let child = item["threadId"]?.stringValue
            ?? item["childThreadId"]?.stringValue
            ?? item["agentThreadId"]?.stringValue
            ?? item["thread"]?["id"]?.stringValue {
            input["threadId"] = .string(child)
        }
        var events: [AgentEvent] = [
            .toolUse(id: id, name: "spawnAgent", input: .object(input), parentToolUseId: nil),
        ]
        let status = item["status"]?.stringValue
        let resultText = item["result"]?.stringValue ?? item["output"]?.stringValue
        if resultText != nil || status == "completed" || status == "failed" {
            let ok = status != "failed" && item["error"] == nil
            events.append(.toolResult(
                id: id,
                ok: ok,
                content: resultText ?? (ok ? "spawned" : "failed"),
                parentToolUseId: nil
            ))
        }
        return events
    }

    let name = tool.isEmpty ? "collabAgentToolCall" : tool
    let input = item["arguments"] ?? item["input"] ?? item
    var events: [AgentEvent] = [
        .toolUse(id: id, name: name, input: input, parentToolUseId: nil),
    ]
    if let result = item["result"]?.stringValue ?? item["output"]?.stringValue {
        let status = item["status"]?.stringValue
        let ok = status != "failed" && item["error"] == nil
        events.append(.toolResult(id: id, ok: ok, content: result, parentToolUseId: nil))
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
