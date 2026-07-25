import Foundation

// Tool-activity feed (TS `src/discord/renderers/toolThread.ts`).
// Posts tool_use input + tool_result headers into TurnThreadRegistry threads.

/// Labels (ko; TS i18n `tool.result` / `tool.error` / `thread.work`).
public enum ToolThreadLabels {
    public static let result = "결과"
    public static let error = "오류"
    public static let workThread = "작업 내역"
}

public final class ToolThreadHandler: @unchecked Sendable {
    private let registry: TurnThreadRegistry
    private struct PendingResult {
        var id: String
        var ok: Bool
        var content: String
        var parentToolUseId: String?
    }
    private struct State {
        var toolNames: [String: String] = [:]
        var pending: [PendingResult] = []
    }
    private let state = LockedBox(State())

    public init(registry: TurnThreadRegistry) {
        self.registry = registry
    }

    public func handleToolUse(id: String, name: String, input: JSONValue, parentToolUseId: String?) async {
        state.withLock { $0.toolNames[id] = name }

        do {
            let thread = try await registry.getForToolUse(
                id: id, name: name, input: input, parentToolUseId: parentToolUseId
            )
            // Edit/Write/… rendered by DiffViewHandler — skip raw input.
            if !FILE_EDIT_TOOLS.contains(name) {
                let header = "**\(toolThreadName(toolName: name, input: input))**"
                let body = "\(header)\n\(formatToolInput(input))"
                for chunk in DiscordText.chunkMessage(body) {
                    try await thread.send(chunk)
                }
            }
        } catch {
            // swallow open/send failure
        }
        await flushPending()
    }

    public func handleToolResult(id: String, ok: Bool, content: String, parentToolUseId: String?) async {
        let result = PendingResult(id: id, ok: ok, content: content, parentToolUseId: parentToolUseId)
        do {
            if let thread = try await registry.getForToolResult(id: id, parentToolUseId: parentToolUseId) {
                await postResult(thread, result)
                return
            }
        } catch {
            // treat as not-open → buffer
        }
        state.withLock { $0.pending.append(result) }
    }

    public func resetTurn() {
        state.withLock {
            $0.pending = []
            $0.toolNames.removeAll()
        }
    }

    private func flushPending() async {
        let batch = state.withLock { s -> [PendingResult] in
            let b = s.pending
            s.pending = []
            return b
        }
        guard !batch.isEmpty else { return }
        var remain: [PendingResult] = []
        for r in batch {
            do {
                if let thread = try await registry.getForToolResult(id: r.id, parentToolUseId: r.parentToolUseId) {
                    await postResult(thread, r)
                } else {
                    remain.append(r)
                }
            } catch {
                remain.append(r)
            }
        }
        if !remain.isEmpty {
            state.withLock { $0.pending.append(contentsOf: remain) }
        }
    }

    private func postResult(_ thread: TurnThreadMessage, _ r: PendingResult) async {
        let name = state.withLock { $0.toolNames[r.id] }
        let label = r.ok ? ToolThreadLabels.result : ToolThreadLabels.error
        let header = name.map { "**\($0) · \(label)**" } ?? "**\(label)**"
        for chunk in DiscordText.chunkMessage("\(header)\n\(r.content)") {
            try? await thread.send(chunk)
        }
    }
}
