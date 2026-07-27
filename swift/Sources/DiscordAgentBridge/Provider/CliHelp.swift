import Foundation

// Shared CLI help/version probe + `[possible values: …]` parser.
// 1:1 port of `src/core/cliPossibleValues.ts` + `src/modes/shared/cliHelpCatalog.ts`.
// Used by the Codex sandbox and Grok permission dynamic catalogs to discover an
// installed CLI's option vocabulary without hardcoding (fallback aside). Must NOT
// import providerCatalog-type modules (circular).

// MARK: - possible-values parser (mirror of cliPossibleValues.ts)

/// Split a single "a, b, c" list into trimmed, non-empty tokens.
private func splitPossibleValues(_ list: Substring) -> [String] {
    list.split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
}

/// Extract values from the first clap-style `[possible values: a, b, c]` block.
/// Case-insensitive on the label; malformed / no match → `[]` (never throws).
func parsePossibleValues(_ text: String) -> [String] {
    guard !text.isEmpty else { return [] }
    let re = #/\[possible values:\s*([^\]]+)\]/#.ignoresCase()
    guard let match = text.firstMatch(of: re) else { return [] }
    return splitPossibleValues(match.output.1)
}

/// Extract every clap-style `[possible values: …]` block in document order
/// (empty-after-split blocks are dropped).
func parseAllPossibleValueBlocks(_ text: String) -> [[String]] {
    guard !text.isEmpty else { return [] }
    let re = #/\[possible values:\s*([^\]]+)\]/#.ignoresCase()
    var blocks: [[String]] = []
    for match in text.matches(of: re) {
        let values = splitPossibleValues(match.output.1)
        if !values.isEmpty { blocks.append(values) }
    }
    return blocks
}

/// First possible-values block whose members satisfy `predicate` (e.g. contains a
/// known sentinel like `workspace-write` / `bypassPermissions`); `nil` if none.
func findPossibleValuesBlock(_ text: String, where predicate: ([String]) -> Bool) -> [String]? {
    for block in parseAllPossibleValueBlocks(text) where predicate(block) { return block }
    return nil
}

// MARK: - CLI help/version runner (mirror of cliHelpCatalog.ts)

private let cliHelpTimeout: TimeInterval = 3.0
private let cliVersionTimeout: TimeInterval = 2.0

/// Injectable help-text producer (tests supply fixture help; default runs `<bin> --help`).
public typealias RunHelpFn = @Sendable () -> String
/// Injectable CLI identity (path@version). Empty string = CLI missing/unavailable.
public typealias ResolveIdentityFn = @Sendable () -> String

/// Identity when the CLI binary cannot be resolved or `--version` fails hard.
let CLI_MISSING_IDENTITY = ""

/// Spawn `<path> args`, harvesting merged stdout+stderr (trimmed). Returns "" on spawn
/// failure or hang. A watchdog terminates the child if it outlives `timeout`.
private func runCapturingOutput(_ path: String, _ args: [String], timeout: TimeInterval) -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = args
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    do { try process.run() } catch { return "" }

    // ponytail: fire-and-forget timeout watchdog — terminate if still running after
    // `timeout`. No cancel; on normal exit it sees isRunning==false and no-ops.
    // Box makes the Process capture Sendable. Upgrade path: none needed, probes are rare.
    let box = LockedBox<Process?>(process)
    DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
        box.withLock { if $0?.isRunning == true { $0?.terminate() } }
    }

    let data = (try? pipe.fileHandleForReading.readToEnd()) ?? Data()
    process.waitUntilExit()
    box.withLock { $0 = nil }

    return String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
}

/// Default spawn-based help + identity resolvers for a CLI binary name (e.g. `"codex"`,
/// `"grok"`). Tests inject their own fns instead. Reuses the host's PATH resolution
/// (`ProcessSidecarTransport.resolveExecutable`); an unresolved bare name is treated as
/// missing so a later install re-triggers a real probe.
func createCliHelpRunner(_ binaryName: String) -> (runHelp: RunHelpFn, resolveIdentity: ResolveIdentityFn) {
    let runHelp: RunHelpFn = {
        let path = ProcessSidecarTransport.resolveExecutable(binaryName)
        guard path.contains("/") else { return "" }
        return runCapturingOutput(path, ["--help"], timeout: cliHelpTimeout)
    }
    let resolveIdentity: ResolveIdentityFn = {
        let path = ProcessSidecarTransport.resolveExecutable(binaryName)
        guard path.contains("/") else { return CLI_MISSING_IDENTITY }
        let ver = runCapturingOutput(path, ["--version"], timeout: cliVersionTimeout)
        // Version failure still treated as "present" (path@) so help can run and a later
        // working version invalidates the cache.
        return ver.isEmpty ? "\(path)@" : "\(path)@\(ver)"
    }
    return (runHelp, resolveIdentity)
}

/// Identity-cached CLI help value catalog. `values()` never throws: re-checks identity
/// every call, re-runs help only when identity changes. Missing CLI / empty parse /
/// probe failure → static fallback.
public actor CliHelpValueSource {
    private let runHelp: RunHelpFn
    private let resolveIdentity: ResolveIdentityFn
    private let fallback: [String]
    private let parseHelp: @Sendable (String) -> [String]
    private let filter: (@Sendable ([String]) -> [String])?
    private var cache: (identity: String, values: [String])?

    public init(fallback: [String], parseHelp: @escaping @Sendable (String) -> [String], filter: (@Sendable ([String]) -> [String])? = nil, runHelp: @escaping RunHelpFn, resolveIdentity: @escaping ResolveIdentityFn) {
        self.fallback = fallback
        self.parseHelp = parseHelp
        self.filter = filter
        self.runHelp = runHelp
        self.resolveIdentity = resolveIdentity
    }

    /// Catalog values (parsed or fallback). Never throws.
    public func values() -> [String] {
        let identity = resolveIdentity()
        if let cache, cache.identity == identity { return cache.values }
        let result = probe(identity)
        cache = (identity, result)
        return result
    }

    private func applyFilter(_ modes: [String]) -> [String] {
        filter.map { $0(modes) } ?? modes
    }

    private func probe(_ identity: String) -> [String] {
        // Not installed yet → fallback. Next call re-checks identity, so a later install
        // (identity becomes path@version) triggers a real help probe.
        if identity == CLI_MISSING_IDENTITY { return applyFilter(fallback) }
        // ponytail: blocking spawn on the actor executor — probes are rare (help/version,
        // §8), so no offloading. Upgrade path: hop to a detached task if this ever runs hot.
        let parsed = applyFilter(parseHelp(runHelp()))
        return parsed.isEmpty ? applyFilter(fallback) : parsed
    }
}
