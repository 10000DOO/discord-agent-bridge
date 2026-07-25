import Foundation

// File-change diff view (TS `src/discord/renderers/diffView.ts`).
// Pure parse/render + handler that posts into TurnThreadRegistry.

/// Tools whose input this handler renders as a pretty diff. ToolThreadHandler skips their raw input.
public let FILE_EDIT_TOOLS: Set<String> = ["Edit", "Write", "NotebookEdit", "apply_patch"]

public struct EditInput: Sendable, Equatable {
    public var filePath: String
    public var oldString: String?
    public var newString: String?
    public var content: String?
    /// Pre-formatted unified diff body (Codex apply_patch).
    public var unifiedDiff: String?

    public init(
        filePath: String,
        oldString: String? = nil,
        newString: String? = nil,
        content: String? = nil,
        unifiedDiff: String? = nil
    ) {
        self.filePath = filePath
        self.oldString = oldString
        self.newString = newString
        self.content = content
        self.unifiedDiff = unifiedDiff
    }
}

/// Build a unified-ish diff body (no headers) from an edit input.
public func renderDiff(_ edit: EditInput) -> String? {
    if let u = edit.unifiedDiff, !u.isEmpty { return u }
    let header = "--- \(edit.filePath)"
    if edit.oldString != nil || edit.newString != nil {
        let removed = (edit.oldString ?? "").split(separator: "\n", omittingEmptySubsequences: false).map { "- \($0)" }
        let added = (edit.newString ?? "").split(separator: "\n", omittingEmptySubsequences: false).map { "+ \($0)" }
        return ([header] + removed + added).joined(separator: "\n")
    }
    if let content = edit.content {
        let added = content.split(separator: "\n", omittingEmptySubsequences: false).map { "+ \($0)" }
        return ([header] + added).joined(separator: "\n")
    }
    return nil
}

/// Parse tool_use input into EditInput. Returns nil when no usable path/diff.
public func parseEditInput(_ input: JSONValue) -> EditInput? {
    guard let obj = input.objectValue else { return nil }

    // Codex apply_patch: { changes: [{ path, kind, diff }, ...] }
    if let changes = obj["changes"]?.arrayValue {
        var parts: [String] = []
        for c in changes {
            guard let rec = c.objectValue else { continue }
            let pathStr = rec["path"]?.stringValue ?? ""
            let diff = rec["diff"]?.stringValue ?? ""
            if !diff.isEmpty {
                parts.append(pathStr.isEmpty ? diff : "--- \(pathStr)\n\(diff)")
            } else if !pathStr.isEmpty {
                parts.append(pathStr)
            }
        }
        if parts.isEmpty { return nil }
        let firstPath: String = {
            if let first = changes.first?.objectValue, let p = first["path"]?.stringValue, !p.isEmpty {
                return p
            }
            return "patch"
        }()
        return EditInput(filePath: firstPath, unifiedDiff: parts.joined(separator: "\n\n"))
    }

    let filePath = obj["file_path"]?.stringValue ?? obj["path"]?.stringValue
    guard let filePath, !filePath.isEmpty else { return nil }
    var out = EditInput(filePath: filePath)
    if let s = obj["old_string"]?.stringValue { out.oldString = s }
    else if let s = obj["oldText"]?.stringValue { out.oldString = s }
    if let s = obj["new_string"]?.stringValue { out.newString = s }
    else if let s = obj["newText"]?.stringValue { out.newString = s }
    if let s = obj["content"]?.stringValue { out.content = s }
    return out
}

// MARK: - Handler

/// Records edit tool_use inputs and posts a ```diff``` on successful tool_result.
/// Mutable; intended for single-owner use (ToolActivityHost / tests).
public final class DiffViewHandler: @unchecked Sendable {
    private let registry: TurnThreadRegistry
    private var edits: [String: EditInput] = [:]

    public init(registry: TurnThreadRegistry) {
        self.registry = registry
    }

    public func noteToolUse(id: String, name: String, input: JSONValue, parentToolUseId: String?) {
        guard FILE_EDIT_TOOLS.contains(name) else { return }
        if let parsed = parseEditInput(input) {
            edits[id] = parsed
        }
        registry.bindToolUse(id: id, name: name, input: input, parentToolUseId: parentToolUseId)
    }

    public func handleResult(id: String, ok: Bool, content: String, parentToolUseId: String?) async {
        guard let edit = edits.removeValue(forKey: id) else { return }
        guard ok else { return }
        guard let diff = renderDiff(edit) else { return }
        let key = registry.resolveResultKey(id: id, parentToolUseId: parentToolUseId)
        do {
            let thread = try await registry.get(key)
            for chunk in DiscordText.chunkMessage("```diff\n\(diff)\n```") {
                try await thread.send(chunk)
            }
        } catch {
            // swallow — fire-and-forget like TS
        }
    }

    public func resetTurn() {
        edits.removeAll()
    }
}
