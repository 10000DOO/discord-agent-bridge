import Foundation

/**
 Resolve how to spawn the Grok ACP process (mirrors TS GrokAcpClient spawn).
 - `GROK_CMD` space-split override (appends `stdio` if missing; prepends `agent` only when args empty)
 - else `grokCommand` or `"grok"` with args `agent` [flags…] `stdio`
 Agent-wide options go BEFORE the `stdio` subcommand (TS acpClient / 15-agent-mode.md).
 `-m` is only added when `isGrokModel` accepts the model (TS catalog guard — drop a leaked Claude id).
 When `isGrokModel` is nil, any non-empty model is accepted (callers/tests inject the catalog predicate).
 */
public func resolveGrokSpawn(
    env: [String: String] = ProcessInfo.processInfo.environment,
    grokCommand: String? = nil,
    model: String? = nil,
    effort: String? = nil,
    bypassPermissions: Bool = false,
    isGrokModel: ((String) -> Bool)? = nil
) -> SidecarSpawn {
    if let override = env["GROK_CMD"]?.trimmingCharacters(in: .whitespacesAndNewlines),
       !override.isEmpty
    {
        let parts = override.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let command = parts.first ?? "grok"
        var args = Array(parts.dropFirst())
        if args.last != "stdio" {
            // Mirror CODEX_CMD: append missing subcommand(s) at the end.
            if !args.contains("agent") {
                args.append("agent")
            }
            args.append("stdio")
        }
        return SidecarSpawn(command: command, args: args)
    }

    var args: [String] = ["agent"]
    if let model, !model.isEmpty {
        let known = isGrokModel?(model) ?? true
        if known {
            args.append(contentsOf: ["-m", model])
        }
    }
    if let effort {
        let trimmed = effort.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            args.append(contentsOf: ["--reasoning-effort", trimmed])
        }
    }
    if bypassPermissions {
        args.append("--always-approve")
    }
    args.append("stdio")
    return SidecarSpawn(command: grokCommand ?? "grok", args: args)
}

/**
 Build the child-process environment for the spawned `grok` process: prepend the well-known
 user/local bin dirs (`ProcessSidecarTransport.wellKnownUserBinDirs`, `Sidecar/Transport.swift`)
 onto `PATH` so nested tools `grok` itself spawns can find user-local CLIs even when the
 supervisor's own `PATH` is bare (mirrors TS `augmentPath`, `acpClient.ts:246-256`). Existing
 `PATH` entries are kept in place and never duplicated.
 */
public func grokChildEnvironment(
    baseEnv: [String: String] = ProcessInfo.processInfo.environment,
    homeDir: String = NSHomeDirectory()
) -> [String: String] {
    let existing = (baseEnv["PATH"] ?? "").split(separator: ":").map(String.init)
    var seen = Set(existing)
    var prepend: [String] = []
    for dir in ProcessSidecarTransport.wellKnownUserBinDirs(homeDir: homeDir, env: baseEnv) {
        guard !dir.isEmpty, !seen.contains(dir) else { continue }
        seen.insert(dir)
        prepend.append(dir)
    }
    var env = baseEnv
    env["PATH"] = (prepend + existing).joined(separator: ":")
    return env
}
