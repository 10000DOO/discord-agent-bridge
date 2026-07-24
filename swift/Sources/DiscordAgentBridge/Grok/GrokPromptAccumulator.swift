import Foundation

// Map one grok ACP session/update notification to a text step. Text-only subset of
// src/modes/grok/agent/acpSession.ts:mapUpdate (agent_message_chunk → text).
//
// Completion/failure are NOT here: grok terminates a turn with the session/prompt RESPONSE, not an
// update (acpClient.ts:341-342, 470-475) — so GrokAcpClient.sessionPrompt's return/throw is the
// terminator, not this function. agent_thought_chunk / tool_call / plan / user_message_chunk /
// available_commands_update are intentionally out of scope for the minimal `!grok` reply path (W11).

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
