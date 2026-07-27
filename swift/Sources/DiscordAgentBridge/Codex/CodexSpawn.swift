import Foundation

/**
 Resolve how to spawn the Codex app-server process (mirrors TS CodexAppServerClient spawn).
 - `CODEX_CMD` space-split override (appends `app-server` if missing)
 - else `codexCommand` or `"codex"` with args `["app-server"]`
 */
public func resolveCodexSpawn(
    env: [String: String] = ProcessInfo.processInfo.environment,
    codexCommand: String? = nil
) -> SidecarSpawn {
    if let override = env["CODEX_CMD"]?.trimmingCharacters(in: .whitespacesAndNewlines),
       !override.isEmpty
    {
        let parts = override.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let command = parts.first ?? "codex"
        var args = Array(parts.dropFirst())
        if args.last != "app-server" {
            args.append("app-server")
        }
        return SidecarSpawn(command: command, args: args)
    }
    return SidecarSpawn(command: codexCommand ?? "codex", args: ["app-server"])
}

/**
 Build the child-process environment for the spawned `codex` process: prepend the well-known
 user/local bin dirs (`ProcessSidecarTransport.wellKnownUserBinDirs`, `Sidecar/Transport.swift`)
 onto `PATH` so nested tools `codex` itself spawns can find user-local CLIs even when the
 supervisor's own `PATH` is bare (mirrors TS `augmentPath`, `acpClient.ts:246-256`, and the
 identical `grokChildEnvironment` in `Grok/GrokSpawn.swift`). Existing `PATH` entries are kept in
 place and never duplicated.
 */
public func codexChildEnvironment(
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
