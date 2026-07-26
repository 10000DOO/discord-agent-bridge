import Foundation

// Render-capability flags (TS `src/core/contracts.ts` Capabilities).
// Sole role: decide which Discord renderers fire for a backend/session.
// Pure resolve: backend defaults ← global config ← server config ← DAB_CAPS env.

// MARK: - Flags

/// Subset used by Swift render hosts (toolThreads / fileDiff / streaming / usagePanel).
public struct Capabilities: Sendable, Equatable {
    public var streaming: Bool
    public var toolThreads: Bool
    public var fileDiff: Bool
    public var usagePanel: Bool

    public init(
        streaming: Bool = true,
        toolThreads: Bool = true,
        fileDiff: Bool = true,
        usagePanel: Bool = true
    ) {
        self.streaming = streaming
        self.toolThreads = toolThreads
        self.fileDiff = fileDiff
        self.usagePanel = usagePanel
    }

    /// All render paths on (host default when channel caps unset).
    public static let allEnabled = Capabilities()
}

/// Partial override block for config.json / servers/<guild>.json / DAB_CAPS.
/// Absent fields leave the previous layer unchanged.
public struct CapabilitiesPartial: Codable, Sendable, Equatable {
    public var streaming: Bool?
    public var toolThreads: Bool?
    public var fileDiff: Bool?
    public var usagePanel: Bool?

    public init(
        streaming: Bool? = nil,
        toolThreads: Bool? = nil,
        fileDiff: Bool? = nil,
        usagePanel: Bool? = nil
    ) {
        self.streaming = streaming
        self.toolThreads = toolThreads
        self.fileDiff = fileDiff
        self.usagePanel = usagePanel
    }

    public var isEmpty: Bool {
        streaming == nil && toolThreads == nil && fileDiff == nil && usagePanel == nil
    }
}

// MARK: - Backend defaults (TS mode.capabilities)

/// Mode-level defaults from ClaudeMode / CodexMode / GrokBuildMode / CustomMode.
public func defaultCapabilities(for backend: Backend) -> Capabilities {
    switch backend {
    case .claude, .custom, .codex, .grok:
        // All four current backends declare streaming/toolThreads/fileDiff/usagePanel = true
        // (Codex usagePanel is context % + tools HUD; rate-limit windows may still be empty).
        return .allEnabled
    }
}

// MARK: - Resolve

/// Apply a partial onto a mutable base (only non-nil fields).
public func applyCapabilitiesPartial(_ partial: CapabilitiesPartial?, to base: inout Capabilities) {
    guard let partial else { return }
    if let v = partial.streaming { base.streaming = v }
    if let v = partial.toolThreads { base.toolThreads = v }
    if let v = partial.fileDiff { base.fileDiff = v }
    if let v = partial.usagePanel { base.usagePanel = v }
}

/// Pure resolve: backend defaults ← global ← server ← env partial (later wins).
public func resolveCapabilities(
    backend: Backend,
    global: CapabilitiesPartial? = nil,
    server: CapabilitiesPartial? = nil,
    envCaps: CapabilitiesPartial? = nil
) -> Capabilities {
    var caps = defaultCapabilities(for: backend)
    applyCapabilitiesPartial(global, to: &caps)
    applyCapabilitiesPartial(server, to: &caps)
    applyCapabilitiesPartial(envCaps, to: &caps)
    return caps
}

/// Resolve using a process env map (`DAB_CAPS` key).
public func resolveCapabilities(
    backend: Backend,
    global: CapabilitiesPartial? = nil,
    server: CapabilitiesPartial? = nil,
    env: [String: String]
) -> Capabilities {
    resolveCapabilities(
        backend: backend,
        global: global,
        server: server,
        envCaps: parseCapabilitiesEnv(env["DAB_CAPS"])
    )
}

// MARK: - DAB_CAPS env

/// Parse `DAB_CAPS` env.
/// Accepts JSON object (`{"toolThreads":false}`) or comma-separated `key=value` pairs
/// (`toolThreads=false,fileDiff=0,usagePanel=true`). Unknown keys ignored.
public func parseCapabilitiesEnv(_ raw: String?) -> CapabilitiesPartial? {
    guard let raw else { return nil }
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    if trimmed.hasPrefix("{") {
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return partialFromDict(obj)
    }

    var dict: [String: Any] = [:]
    for part in trimmed.split(separator: ",") {
        let piece = part.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !piece.isEmpty else { continue }
        let kv: [Substring]
        if piece.contains("=") {
            kv = piece.split(separator: "=", maxSplits: 1)
        } else if piece.contains(":") {
            kv = piece.split(separator: ":", maxSplits: 1)
        } else {
            continue
        }
        guard kv.count == 2 else { continue }
        let key = kv[0].trimmingCharacters(in: .whitespacesAndNewlines)
        let val = kv[1].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let b = parseBoolToken(val) else { continue }
        dict[key] = b
    }
    if dict.isEmpty { return nil }
    return partialFromDict(dict)
}

private func partialFromDict(_ obj: [String: Any]) -> CapabilitiesPartial? {
    var p = CapabilitiesPartial()
    for (k, v) in obj {
        let key = k.lowercased()
        let boolVal: Bool?
        if let b = v as? Bool {
            boolVal = b
        } else if let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() {
            boolVal = n.boolValue
        } else if let s = v as? String {
            boolVal = parseBoolToken(s)
        } else if let n = v as? NSNumber {
            // 0/1 from JSON numbers
            boolVal = n.intValue != 0
        } else {
            boolVal = nil
        }
        guard let b = boolVal else { continue }
        switch key {
        case "streaming": p.streaming = b
        case "toolthreads": p.toolThreads = b
        case "filediff": p.fileDiff = b
        case "usagepanel": p.usagePanel = b
        default: break
        }
    }
    return p.isEmpty ? nil : p
}

private func parseBoolToken(_ raw: String) -> Bool? {
    switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
    case "1", "true", "yes", "on": return true
    case "0", "false", "no", "off": return false
    default: return nil
    }
}
