import Foundation

/// Resolved spawn command for the Claude sidecar process.
public struct SidecarSpawn: Sendable, Equatable {
    public var command: String
    public var args: [String]

    public init(command: String, args: [String]) {
        self.command = command
        self.args = args
    }
}

/// Locate the monorepo root (parent of `swift/` or directory with package.json + src/sidecar).
public func findRepoRoot(
    startingAt start: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
) -> URL? {
    var dir = start.standardizedFileURL
    let fm = FileManager.default
    for _ in 0..<12 {
        let packageJSON = dir.appendingPathComponent("package.json")
        let sidecarSrc = dir.appendingPathComponent("src/sidecar/claude/cli.ts")
        if fm.fileExists(atPath: packageJSON.path),
           fm.fileExists(atPath: sidecarSrc.path) || fm.fileExists(atPath: dir.appendingPathComponent("src/sidecar/claude/cli.js").path)
        {
            return dir
        }
        // Package lives in swift/ — parent may be repo root
        let parent = dir.deletingLastPathComponent()
        if parent.path == dir.path { break }
        dir = parent
    }
    return nil
}

/**
 Resolve how to spawn the Claude sidecar process (mirrors TS resolveClaudeSidecarSpawn).
 - `DAB_CLAUDE_SIDECAR_CMD` space-split override
 - else `node dist/sidecar/claude/cli.js` when built
 - else `node node_modules/tsx/... src/sidecar/claude/cli.ts` for dev
 */
public func resolveClaudeSidecarSpawn(
    env: [String: String] = ProcessInfo.processInfo.environment,
    repoRoot: URL? = nil
) -> SidecarSpawn {
    if let override = env["DAB_CLAUDE_SIDECAR_CMD"]?.trimmingCharacters(in: .whitespacesAndNewlines),
       !override.isEmpty
    {
        let parts = override.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let command = parts.first ?? "node"
        return SidecarSpawn(command: command, args: Array(parts.dropFirst()))
    }

    let root = repoRoot ?? findRepoRoot() ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    let fm = FileManager.default
    let distCli = root.appendingPathComponent("dist/sidecar/claude/cli.js")
    if fm.fileExists(atPath: distCli.path) {
        return SidecarSpawn(command: "node", args: [distCli.path])
    }

    let srcCli = root.appendingPathComponent("src/sidecar/claude/cli.ts")
    let tsxCli = root.appendingPathComponent("node_modules/tsx/dist/cli.mjs")
    if fm.fileExists(atPath: srcCli.path), fm.fileExists(atPath: tsxCli.path) {
        return SidecarSpawn(command: "node", args: [tsxCli.path, srcCli.path])
    }

    // Last resort: dist path (spawn will fail with ENOENT — clearer than silent wrong path)
    return SidecarSpawn(command: "node", args: [distCli.path])
}
