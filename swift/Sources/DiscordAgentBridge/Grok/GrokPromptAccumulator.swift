import Foundation

// Map one grok ACP session/update notification to a text step, progress notes, or mid-turn tools.
// Text: src/modes/grok/agent/acpSession.ts:mapUpdate agent_message_chunk.
// Progress (W16-g gap): agent_thought_chunk → thinking; plan → progress (WO-11).
// Tools (W16-g residual): tool_call / tool_call_update → tool_use / tool_result.
//
// Completion/failure are NOT here: grok terminates a turn with the session/prompt RESPONSE, not an
// update (acpClient.ts:341-342, 470-475) — so GrokAcpClient.sessionPrompt's return/throw is the
// terminator. user_message_chunk / available_commands_update stay out of the reply path.

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

// MARK: - available_commands_update → slash catalog (WO-3, docs/cli-slash-command-parity.md §3-5-3)

/// Map grok ACP `session/update` → the slash commands this session advertises. Pure; never throws.
///
/// Returns nil for every other notification, so a caller can tell "not a catalog push" apart from
/// "a catalog push that happens to be empty" — grok re-pushes the WHOLE list on every change, so an
/// empty array means "no commands", not "no news".
///
/// Wire shape (grok 0.2.118, measured 2026-08-05 — the deleted TS `AcpAvailableCommandsUpdate` was a
/// field-less stub, so this envelope existed nowhere in the repo and was captured off a live
/// `grok agent stdio` child; same "measured" convention as `AppServerClient.swift`'s header):
///
///     params.update = {
///       "sessionUpdate": "available_commands_update",
///       "availableCommands": [ {"name": …, "description": …, "input": {"hint": …} | null}, … ],
///       "_meta": {…}
///     }
///
/// The array key is `availableCommands` (camelCase) and the hint lives one level down under `input`,
/// which is `null` for commands that take no argument. Pushed right after `session/new` — i.e.
/// OUTSIDE any turn.
///
/// STORED ONLY. This is the echo path the file header warns about (`user_message_chunk` /
/// `available_commands_update` stay out of the reply path): nothing here reaches a render path.
public func grokSlashCatalog(method: String, params: JSONValue?) -> [SlashCatalogEntry]? {
    guard method == "session/update" || method == "x.ai/session/update" else { return nil }
    guard let update = params?["update"],
          update["sessionUpdate"]?.stringValue == "available_commands_update",
          let items = update["availableCommands"]?.arrayValue
    else { return nil }
    return items.compactMap { item in
        guard let name = item["name"]?.stringValue, !name.isEmpty else { return nil }
        let hint = item["input"]?["hint"]?.stringValue
        return SlashCatalogEntry(
            name: name,
            description: item["description"]?.stringValue ?? "",
            argumentHint: (hint?.isEmpty ?? true) ? nil : hint
        )
    }
}

// MARK: - Thought / plan → AgentEvent (W16-g gap / TS acpSession mapUpdate)

/// Map grok ACP session/update → thinking / progress. Pure; never throws.
/// Mirrors TS `mapUpdate` agent_thought_chunk + plan (acpSession.ts:274-332).
/// Intermediate / unknown kinds → []. Empty thought text skipped (TS parity).
public func grokProgressEvents(method: String, params: JSONValue?) -> [AgentEvent] {
    guard method == "session/update" || method == "x.ai/session/update" else { return [] }
    guard let update = params?["update"] else { return [] }
    let kind = update["sessionUpdate"]?.stringValue ?? ""
    switch kind {
    case "agent_thought_chunk":
        // TS acpSession.ts:274-277 — empty thought chunks are skipped.
        let text = update["content"]?["text"]?.stringValue ?? ""
        guard !text.isEmpty else { return [] }
        return [.thinking(text: text, delta: true)]

    case "plan":
        // TS acpSession.ts:320-332 (WO-11): reuse progress kind; status-marked lines; bare "Plan"
        // when every entry lacks content / list empty.
        let entries = update["entries"]?.arrayValue ?? []
        let lines: [String] = entries.compactMap { entry in
            let content = (entry["content"]?.stringValue ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { return nil }
            let mark = planStatusMark(entry["status"]?.stringValue)
            return "\(mark) \(content)".trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if lines.isEmpty {
            return [.progress(label: "Plan", detail: nil)]
        }
        return [.progress(label: "Plan", detail: lines.joined(separator: "\n"))]

    default:
        return []
    }
}

/// Compact marker for one plan entry status (TS planStatusMark, acpSession.ts:408-416).
func planStatusMark(_ status: String?) -> String {
    switch status {
    case "completed": return "✓"
    case "in_progress": return "▶"
    default: return "•"
    }
}

// MARK: - Tool mid-turn events (W16-g residual / TS acpSession mapUpdate)

/// M19: lift `parentToolId` from top-level (camelCase/snake_case) or `_meta`, in that order, so a
/// server that only sets it under `_meta` still routes nested tool calls correctly (TS
/// `extractUpdate`, acpClient.ts:635-662). Empty strings count as absent.
func grokParentToolId(_ update: JSONValue) -> String? {
    func nonEmpty(_ v: JSONValue?) -> String? {
        v?.stringValue.flatMap { $0.isEmpty ? nil : $0 }
    }
    if let v = nonEmpty(update["parentToolId"]) { return v }
    if let v = nonEmpty(update["parent_tool_use_id"]) { return v }
    let meta = update["_meta"]
    if let v = nonEmpty(meta?["parentToolId"]) { return v }
    if let v = nonEmpty(meta?["parent_tool_use_id"]) { return v }
    return nil
}

/// Map grok ACP session/update → tool_use / tool_result. Pure; never throws.
/// Intermediate tool_call_update (no terminal status) skipped — same as TS.
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
        let parent = grokParentToolId(update)
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
        let parent = grokParentToolId(update)
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
