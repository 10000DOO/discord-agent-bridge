import Foundation

// Pure tool-summary helpers (TS `src/discord/format.ts` toolSummary / toolThreadName).
// Input is `JSONValue` (AgentEvent.toolUse) rather than `unknown`.

/// A short, human summary of a tool's input for the thread name. Falls back to a
/// clipped JSON stringify for unknown tools. Never throws on odd input.
public func toolSummary(toolName: String, input: JSONValue) -> String {
    let obj = input.objectValue ?? [:]
    func str(_ key: String) -> String? {
        guard let s = obj[key]?.stringValue, !s.isEmpty else { return nil }
        return s
    }
    switch toolName {
    case "Edit", "Write", "Read", "NotebookEdit":
        return str("file_path") ?? str("path") ?? ""
    case "Bash":
        let cmd = str("command") ?? ""
        return String(cmd.prefix(60))
    case "Glob", "Grep":
        return str("pattern") ?? ""
    case "Agent", "Task":
        if let d = str("description") { return d }
        let prompt = str("prompt") ?? ""
        return String(prompt.prefix(40))
    case "WebSearch", "WebFetch":
        return str("query") ?? str("url") ?? ""
    default:
        return String(jsonValueCompactString(input).prefix(60))
    }
}

/// A tool-call thread name from the tool + its input. Capped to Discord's 100-char limit.
public func toolThreadName(toolName: String, input: JSONValue) -> String {
    let summary = toolSummary(toolName: toolName, input: input)
    let name = summary.isEmpty ? toolName : "\(toolName): \(summary)"
    return DiscordText.truncate(name, DiscordText.threadNameLimit)
}

/// Format tool input for the thread's opening message (TS toolThread `formatInput`).
public func formatToolInput(_ input: JSONValue) -> String {
    if case .string(let s) = input { return s }
    let body = jsonValuePrettyString(input)
    return "```json\n\(body)\n```"
}

/// Compact single-line JSON (fallback for toolSummary).
func jsonValueCompactString(_ value: JSONValue) -> String {
    guard let data = try? JSONEncoder().encode(value),
          let s = String(data: data, encoding: .utf8)
    else { return "" }
    return s
}

/// Pretty-printed JSON for tool input fences.
func jsonValuePrettyString(_ value: JSONValue) -> String {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? enc.encode(value),
          let s = String(data: data, encoding: .utf8)
    else { return String(describing: value) }
    return s
}
