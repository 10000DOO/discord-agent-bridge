import Foundation

// Per-turn work thread registry (TS `src/discord/renderers/turnThread.ts`).
// Discord I/O is injected via TurnThreadChannel / TurnThreadMessage ports.

// MARK: - Ports

/// Discord-agnostic thread: post text chunks.
public struct TurnThreadMessage: Sendable {
    public var id: String
    public var send: @Sendable (_ content: String) async throws -> Void

    public init(id: String, send: @escaping @Sendable (_ content: String) async throws -> Void) {
        self.id = id
        self.send = send
    }
}

/// Discord-agnostic channel that can open a work thread.
public struct TurnThreadChannel: Sendable {
    public var startThread: @Sendable (_ name: String) async throws -> TurnThreadMessage

    public init(startThread: @escaping @Sendable (_ name: String) async throws -> TurnThreadMessage) {
        self.startThread = startThread
    }
}

// MARK: - Holder (one thread, create-once)

/// One named thread for a turn. Concurrent first `get()` share a single create task.
public final class TurnThreadHolder: @unchecked Sendable {
    private let channel: TurnThreadChannel
    private let name: String
    private struct State {
        var creating: Task<TurnThreadMessage, Error>?
        /// Identity for the in-flight create; late rejection from a previous turn must not clear
        /// a newer turn's task (TS promise-identity guard).
        var createToken: UUID?
    }
    private let state = LockedBox(State())

    public init(channel: TurnThreadChannel, name: String) {
        self.channel = channel
        self.name = name
    }

    public var opened: Bool {
        state.withLock { $0.creating != nil }
    }

    public func get() async throws -> TurnThreadMessage {
        enum Acquire {
            case existing(Task<TurnThreadMessage, Error>)
            case fresh(Task<TurnThreadMessage, Error>, UUID)
        }
        let acquire: Acquire = state.withLock { s in
            if let existing = s.creating { return .existing(existing) }
            let token = UUID()
            let attempt = Task { try await self.channel.startThread(self.name) }
            s.creating = attempt
            s.createToken = token
            return .fresh(attempt, token)
        }
        switch acquire {
        case .existing(let task):
            return try await task.value
        case .fresh(let task, let token):
            do {
                return try await task.value
            } catch {
                state.withLock { s in
                    if s.createToken == token {
                        s.creating = nil
                        s.createToken = nil
                    }
                }
                throw error
            }
        }
    }

    public func reset() {
        state.withLock {
            $0.creating = nil
            $0.createToken = nil
        }
    }
}

// MARK: - Subagent helpers

/// Case-sensitive tool names that spawn a subagent.
public let SUBAGENT_SPAWN_TOOLS: Set<String> = ["Task", "Agent", "spawn_subagent", "spawnAgent"]

public func isSubagentSpawnTool(_ name: String) -> Bool {
    SUBAGENT_SPAWN_TOOLS.contains(name)
}

/// Display name for a spawn tool's Discord thread.
public func subagentThreadName(name: String, input: JSONValue) -> String {
    var raw = name
    if let o = input.objectValue {
        if let s = o["agentNickname"]?.stringValue, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { raw = s }
        else if let s = o["agent_name"]?.stringValue, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { raw = s }
        else if let s = o["agentName"]?.stringValue, !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { raw = s }
        else if let s = o["subagent_type"]?.stringValue, !s.isEmpty { raw = s }
        else if let s = o["subagentType"]?.stringValue, !s.isEmpty { raw = s }
        else if let s = o["agentRole"]?.stringValue, !s.isEmpty { raw = s }
        else if let s = o["nickname"]?.stringValue, !s.isEmpty { raw = s }
        else if let s = o["description"]?.stringValue, !s.isEmpty { raw = s }
    }
    let safe = raw.unicodeScalars.map { scalar -> Character in
        CharacterSet.controlCharacters.contains(scalar) ? " " : Character(String(scalar))
    }
    let normalized = String(safe).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    return DiscordText.truncate(normalized.isEmpty ? name : normalized, DiscordText.threadNameLimit)
}

/// Registry key for the main work thread.
public let MAIN_THREAD_KEY = "main"

// MARK: - Registry

/// Routes tool_use / tool_result to the correct per-turn Discord thread.
public final class TurnThreadRegistry: @unchecked Sendable {
    private let channel: TurnThreadChannel
    private let mainName: String
    private struct State {
        var holders: [String: TurnThreadHolder] = [:]
        var toolIdToKey: [String: String] = [:]
        var keyNames: [String: String] = [:]
    }
    private let state = LockedBox(State())

    public init(channel: TurnThreadChannel, mainName: String) {
        self.channel = channel
        self.mainName = mainName
    }

    public func getForToolUse(id: String, name: String, input: JSONValue, parentToolUseId: String?) async throws -> TurnThreadMessage {
        let key = bindToolUse(id: id, name: name, input: input, parentToolUseId: parentToolUseId)
        return try await get(key)
    }

    public func getForToolResult(id: String, parentToolUseId: String?) async throws -> TurnThreadMessage? {
        let key = resolveResultKey(id: id, parentToolUseId: parentToolUseId)
        guard hasOpened(key) else { return nil }
        return try await get(key)
    }

    public func get(_ key: String) async throws -> TurnThreadMessage {
        try await holderFor(key).get()
    }

    public func hasOpened(_ key: String) -> Bool {
        state.withLock { $0.holders[key]?.opened ?? false }
    }

    @discardableResult
    public func bindToolUse(id: String, name: String, input: JSONValue, parentToolUseId: String?) -> String {
        let key = keyForToolUse(name: name, id: id, parentToolUseId: parentToolUseId)
        state.withLock { s in
            s.toolIdToKey[id] = key
            if isSubagentSpawnTool(name), key != MAIN_THREAD_KEY, s.keyNames[key] == nil {
                let base = subagentThreadName(name: name, input: input)
                let used = Set(s.keyNames.values)
                var candidate = base
                var discriminator = 1
                // The short spawn-id suffix is not unique by itself; make the displayed
                // title the final collision key and add a stable ordinal when necessary.
                while used.contains(candidate) {
                    let ordinal = discriminator == 1 ? "" : "-\(discriminator)"
                    let suffix = " · \(key.suffix(6))\(ordinal)"
                    candidate = DiscordText.truncate(
                        base,
                        max(0, DiscordText.threadNameLimit - suffix.count)
                    ) + suffix
                    discriminator += 1
                }
                s.keyNames[key] = candidate
            }
        }
        return key
    }

    public func resolveResultKey(id: String, parentToolUseId: String?) -> String {
        state.withLock { s in
            if let remembered = s.toolIdToKey[id] { return remembered }
            if let p = parentToolUseId, !p.isEmpty { return p }
            return MAIN_THREAD_KEY
        }
    }

    public func reset() {
        let all = state.withLock { s -> [TurnThreadHolder] in
            let holders = Array(s.holders.values)
            s.holders.removeAll()
            s.toolIdToKey.removeAll()
            s.keyNames.removeAll()
            return holders
        }
        for h in all { h.reset() }
    }

    private func keyForToolUse(name: String, id: String, parentToolUseId: String?) -> String {
        if let p = parentToolUseId, !p.isEmpty { return p }
        if isSubagentSpawnTool(name) { return id }
        return MAIN_THREAD_KEY
    }

    private func holderFor(_ key: String) -> TurnThreadHolder {
        state.withLock { s in
            if let h = s.holders[key] { return h }
            let name: String
            if key == MAIN_THREAD_KEY {
                name = mainName
            } else {
                name = s.keyNames[key] ?? DiscordText.truncate(key, DiscordText.threadNameLimit)
            }
            let h = TurnThreadHolder(channel: channel, name: name)
            s.holders[key] = h
            return h
        }
    }
}
