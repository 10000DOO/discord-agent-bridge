import Foundation

// Map one grok ACP session/update notification to a text step or mid-turn tool events.
// Text: src/modes/grok/agent/acpSession.ts:mapUpdate agent_message_chunk.
// Tools (W16-g residual): tool_call / tool_call_update → tool_use / tool_result.
//
// Completion/failure are NOT here: grok terminates a turn with the session/prompt RESPONSE, not an
// update (acpClient.ts:341-342, 470-475) — so GrokAcpClient.sessionPrompt's return/throw is the
// terminator. agent_thought_chunk / plan / user_message_chunk / available_commands_update stay
// out of the reply path (progress/thinking residual).

public enum GrokUpdateStep: Equatable {
    case appendText(String)   // session/update agent_message_chunk → update.content.text
    case ignore
}

public func grokUpdateStep(method: String, params: JSONValue?) -> GrokUpdateStep {
    // Both method names are live grok streams (acpClient.ts:504).
    guard method == "session/update" || method == "x.ai/session/update" else { return .ignore }
    let update = params?["update"] // extractUpdate: params.update (acpClient.ts:635-639)
    guard update?["sessionUpdate"]?.stringValue == "agent_message_chunk" else { return .ignore }
    let text = update?["content"]?["text"]?.stringValue ?? "" // acpSession.ts:270
    return text.isEmpty ? .ignore : .appendText(text)
}

// MARK: - Tool mid-turn events (W16-g residual / TS acpSession mapUpdate)

/// Map grok ACP session/update → tool_use / tool_result. Pure; never throws.
///
/// Gaps vs TS `acpSession.ts` (best-effort):
/// - plan / agent_thought_chunk not mapped (no live progress embed residual).
/// - Intermediate tool_call_update (no terminal status) skipped — same as TS.
public func grokToolEvents(
    method: String,
    params: JSONValue?,
    mintId: inout Int
) -> [AgentEvent] {
    guard method == "session/update" || method == "x.ai/session/update" else { return [] }
    guard let update = params?["update"] else { return [] }
    let kind = update["sessionUpdate"]?.stringValue ?? ""
    switch kind {
    case "tool_call":
        let parent = update["parentToolId"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let id: String = {
            if let tid = update["toolCallId"]?.stringValue, !tid.isEmpty { return tid }
            mintId += 1
            return "grok-tool-\(mintId)"
        }()
        let name = normalizeGrokToolName(
            title: update["title"]?.stringValue,
            kind: update["kind"]?.stringValue
        )
        let input = normalizeGrokToolInput(update["rawInput"])
        return [
            .toolUse(id: id, name: name, input: input, parentToolUseId: parent),
        ]

    case "tool_call_update":
        // grok 0.2.103: intermediate update (no status, may carry diff) then terminal
        // completed/failed. Only terminal → tool_result (TS acpSession.ts:293-318).
        let status = update["status"]?.stringValue
        guard status == "completed" || status == "failed" else { return [] }
        let parent = update["parentToolId"]?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
        let id = update["toolCallId"]?.stringValue ?? ""
        let content = stringifyGrokToolContent(
            update["content"] ?? update["rawOutput"] ?? .string("")
        )
        return [
            .toolResult(id: id, ok: status == "completed", content: content, parentToolUseId: parent),
        ]

    default:
        return []
    }
}

/// TS normalizeGrokToolName — Edit/Write aliases for DiffView FILE_EDIT_TOOLS.
func normalizeGrokToolName(title: String?, kind: String?) -> String {
    let t = (title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let k = (kind ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if k == "edit" || t.range(of: #"^edit\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
        return "Edit"
    }
    if k == "write" || t.range(of: #"^write\b"#, options: [.regularExpression, .caseInsensitive]) != nil {
        return "Write"
    }
    if !t.isEmpty { return t }
    if let kind, !kind.isEmpty { return kind }
    return "tool"
}

/// TS normalizeGrokToolInput — alias path/oldText/newText for DiffView.
func normalizeGrokToolInput(_ rawInput: JSONValue?) -> JSONValue {
    guard var out = rawInput?.objectValue else {
        return rawInput ?? .object([:])
    }
    if out["file_path"]?.stringValue == nil, let path = out["path"]?.stringValue {
        out["file_path"] = .string(path)
    }
    if out["old_string"]?.stringValue == nil, let old = out["oldText"]?.stringValue {
        out["old_string"] = .string(old)
    }
    if out["new_string"]?.stringValue == nil, let new = out["newText"]?.stringValue {
        out["new_string"] = .string(new)
    }
    return .object(out)
}

/// Flatten tool_call_update content/rawOutput to a plain string (TS stringifyContent).
func stringifyGrokToolContent(_ content: JSONValue) -> String {
    switch content {
    case .string(let s):
        return s
    case .null:
        return ""
    default:
        // Best-effort JSON encode; fall back to description.
        if let data = try? JSONEncoder().encode(content),
           let s = String(data: data, encoding: .utf8) {
            return s
        }
        return String(describing: content)
    }
}
