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
