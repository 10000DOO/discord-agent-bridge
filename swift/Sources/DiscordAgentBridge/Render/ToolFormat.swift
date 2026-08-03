import Foundation

// Pure tool-summary helpers (TS `src/discord/format.ts` toolSummary / toolThreadName).
// Input is `JSONValue` (AgentEvent.toolUse) rather than `unknown`.

/// A short, human summary of a tool's input for the thread name. Falls back to a
/// clipped JSON stringify for unknown tools. Never throws on odd input.
/// `limit` clips only the free-form fields (Bash command, unknown-tool JSON): the 100-char
/// thread name keeps the default, while the work-log call line passes a wider budget so a
/// long command stays readable instead of being cut mid-flag.
public func toolSummary(toolName: String, input: JSONValue, limit: Int = 60) -> String {
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
        return String(cmd.prefix(limit))
    case "Glob", "Grep":
        return str("pattern") ?? ""
    case "Agent", "Task":
        if let d = str("description") { return d }
        let prompt = str("prompt") ?? ""
        return String(prompt.prefix(40))
    case "WebSearch", "WebFetch":
        return str("query") ?? str("url") ?? ""
    default:
        return String(jsonValueCompactString(input).prefix(limit))
    }
}

// MARK: - Work-log lines (CLI transcript shape)

/// Widest summary the call line will show before clipping.
let toolCallSummaryLimit = 200
/// Successful output at or under this length is inlined verbatim; longer output collapses to its size.
let toolResultInlineLimit = 300
/// A failed result is always shown, but never beyond this much of its head.
let toolResultErrorLimit = 1000

/// Collapse to a single line and neutralize backticks so an inline code span can't break out.
private func inlineSafe(_ s: String) -> String {
    s.split(whereSeparator: { $0.isWhitespace })
        .joined(separator: " ")
        .replacingOccurrences(of: "`", with: "'")
}

/// Neutralize fences so a result body can't terminate the code block that wraps it.
private func fenced(_ s: String) -> String {
    "```\n\(s.replacingOccurrences(of: "```", with: "'''"))\n```"
}

/// One-line tool call, CLI transcript style: ``● **Bash** `ls -la` ``.
/// Replaces the old pretty-printed JSON dump — the input's identifying part is already
/// what `toolSummary` extracts, so the dump only repeated it at ten times the height.
public func formatToolCallLine(toolName: String, input: JSONValue) -> String {
    let summary = inlineSafe(toolSummary(toolName: toolName, input: input, limit: toolCallSummaryLimit))
    guard !summary.isEmpty else { return "● **\(toolName)**" }
    return "● **\(toolName)** `\(summary)`"
}

/// One-line tool result, CLI transcript style: `⎿ Bash · 7줄`.
/// Success collapses to its size (short output is inlined verbatim); failure always keeps its
/// body, clipped — an error message is the one result a human actually has to read.
/// `toolName` is repeated here because parallel tool calls interleave call and result lines.
public func formatToolResult(toolName: String?, content: String, ok: Bool) -> String {
    let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
    var parts: [String] = []
    if let toolName, !toolName.isEmpty { parts.append(toolName) }
    if !ok { parts.append(ToolThreadLabels.error) }

    guard !trimmed.isEmpty else {
        parts.append(I18n.t("tool.noOutput"))
        return "⎿ \(parts.joined(separator: " · "))"
    }

    let lineCount = trimmed.split(separator: "\n", omittingEmptySubsequences: false).count
    parts.append(I18n.t("tool.lines", ["n": "\(lineCount)"]))
    let head = "⎿ \(parts.joined(separator: " · "))"

    if !ok {
        return "\(head)\n\(fenced(DiscordText.truncate(trimmed, toolResultErrorLimit)))"
    }
    if DiscordText.utf16Len(trimmed) <= toolResultInlineLimit {
        return "\(head)\n\(fenced(trimmed))"
    }
    return head
}

/// Format tool input for the thread's opening message (TS toolThread `formatInput`).
/// Still the permission-prompt detail (`DabSessionBridge.permissionDetail`) — approving a
/// tool call needs the whole input, unlike the after-the-fact work log.
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
