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
