import Foundation

// Map one `codex app-server` notification to a text-turn step. Text-only subset of
// src/modes/codex/eventMapper.ts (item/agentMessage/delta, item/completed agentMessage,
// turn/completed, turn|thread/failed, error). Pure: no state, never throws.
// tool_use / progress / thinking / context_usage are intentionally out of scope for the
// minimal `!codex` reply path (W11).

public enum CodexTurnStep: Equatable {
    case appendText(String)   // item/agentMessage/delta → params.delta
    case fullText(String)     // item/completed agentMessage → item.text (fallback when no deltas)
    case finished             // turn/completed
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
        // eventMapper.ts:109-135
        return .finished

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
