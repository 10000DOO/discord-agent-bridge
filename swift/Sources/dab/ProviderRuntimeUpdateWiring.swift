import DiscordAgentBridge
import Darwin
import Foundation

private let providerRuntimeLog = Logger(name: "provider-runtime-update")

/// Serializes a maintenance transaction ACROSS dab processes.  `ProviderRuntimeUpdateRegistry` only
/// covers one process, but a self-update keeps predecessor and successor alive at the same time
/// (Installer's readiness handoff), and the successor runs a boot check immediately — without this
/// lock it can read the predecessor's LIVE transaction journal as an interrupted one and roll back a
/// promotion still in progress, leaving the repo's package manifest and node_modules inconsistent.
/// `flock` is released by the kernel when the fd closes or the holder dies, so there is no stale
/// lock state to reap.
actor ProviderRuntimeMaintenanceLock {
    static let shared = ProviderRuntimeMaintenanceLock()

    private var descriptor: Int32 = -1

    func acquire(stateRoot: URL) -> Bool {
        guard descriptor < 0 else { return true }
        try? FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true)
        let path = stateRoot.appendingPathComponent("maintenance.lock").path
        let opened = open(path, O_CREAT | O_RDWR, 0o600)
        guard opened >= 0 else { return false }
        guard flock(opened, LOCK_EX | LOCK_NB) == 0 else {
            close(opened)
            return false
        }
        descriptor = opened
        return true
    }

    func release() {
        guard descriptor >= 0 else { return }
        flock(descriptor, LOCK_UN)
        close(descriptor)
        descriptor = -1
    }
}

/// A kill between the promotion renames orphans the staged tree (its `defer` cleanup never runs).
/// Nothing references a stage directory once its process is gone, so boot recovery — which already
/// holds the cross-process lock — is the safe place to reclaim it.
func sweepOrphanedClaudeStages(root: URL?, fileManager: FileManager = .default) -> Int {
    guard let root,
          let entries = try? fileManager.contentsOfDirectory(atPath: root.path)
    else { return 0 }
    var reclaimed = 0
    for entry in entries where entry.hasPrefix(".dab-provider-runtime-stage-") {
        if (try? fileManager.removeItem(at: root.appendingPathComponent(entry))) != nil { reclaimed += 1 }
    }
    return reclaimed
}

/// `autoUpdate.enabled` is the single master switch for bridge and provider maintenance.
func startProviderRuntimeUpdater() async {
    let coordinator = ProviderRuntimeUpdateCoordinator(deps: ProviderRuntimeUpdateCoordinatorDeps(
        enabled: { (try? await ConfigStore.shared.load())?.autoUpdate.enabled ?? true },
        beginMaintenance: {
            // Cross-process lock first: it has no side effects, so releasing it after the in-process
            // gate declines costs nothing — whereas claiming the gate and then bailing would leave
            // every waiting turn blocked with no one left to call `finish()`.
            guard await ProviderRuntimeMaintenanceLock.shared.acquire(stateRoot: providerRuntimeUpdateStateRoot()) else {
                providerRuntimeLog.info("provider-runtime: another dab process holds the maintenance lock; skipping this check")
                return false
            }
            let admitted = await ProviderRuntimeMaintenanceGate.shared.beginWhenIdle {
                let claude = await DabSessionBridge.shared.isAnyTurnRunning()
                let codex = await CodexSessionBridge.shared.isAnyTurnRunning()
                let grok = await GrokSessionBridge.shared.isAnyTurnRunning()
                return !claude && !codex && !grok
            }
            if !admitted { await ProviderRuntimeMaintenanceLock.shared.release() }
            return admitted
        },
        endMaintenance: {
            await ProviderRuntimeMaintenanceGate.shared.finish()
            await ProviderRuntimeMaintenanceLock.shared.release()
        },
        updateClaude: { await updateClaudeRuntime() },
        updateCodex: {
            let config = try? await ConfigStore.shared.load()
            // Must update the executable the bridge actually spawns: CODEX_CMD takes precedence
            // over the configured command in the same resolver used by CodexSessionBridge.
            let binary = resolveCodexSpawn(
                env: ProcessInfo.processInfo.environment,
                codexCommand: config?.defaults.codexCliCommand
            ).command
            return await updateCodexRuntime(
                binary: binary,
                catalogHealthy: { !(await CodexCatalog().models(configured: nil)).isEmpty },
                restartRuntime: { await CodexSessionBridge.shared.restartRuntimeAfterUpdate() }
            )
        },
        updateGrok: {
            // GROK_CMD is the bridge's sole runtime-command override; resolve it through the same
            // spawn policy instead of independently probing a bare `grok` from PATH.
            let binary = resolveGrokSpawn(env: ProcessInfo.processInfo.environment).command
            return await updateGrokRuntime(
                binary: binary,
                catalogHealthy: { !(await GrokCatalog().models(configured: nil)).isEmpty },
                restartRuntime: { await GrokSessionBridge.shared.restartRuntimeAfterUpdate() }
            )
        },
        onLog: { providerRuntimeLog.info($0) }
    ))
    await ProviderRuntimeUpdateRegistry.shared.replaceAfterCurrentCheck(with: coordinator) {
        let stateRoot = providerRuntimeUpdateStateRoot()
        // Recovery is rollback: without the cross-process lock a self-update successor would undo the
        // predecessor's still-running promotion.  A held lock means the other process owns recovery.
        guard await ProviderRuntimeMaintenanceLock.shared.acquire(stateRoot: stateRoot) else {
            providerRuntimeLog.info("provider-runtime: another dab process owns startup recovery; skipping")
            return
        }
        // Released at the end of this closure, NOT via `defer`: `defer` cannot await, and deferring it
        // to a detached Task could close the descriptor after the boot check has already re-claimed it.
        let repoRoot = findRepoRoot()
        let reclaimed = sweepOrphanedClaudeStages(root: repoRoot)
        if reclaimed > 0 {
            providerRuntimeLog.warn("provider-runtime: reclaimed \(reclaimed) orphaned Claude SDK stage directory(ies)")
        }
        switch recoverClaudeRuntimeTransactionIfNeeded(root: repoRoot) {
        case .none:
            break
        case .recovered:
            providerRuntimeLog.warn("provider-runtime: recovered interrupted Claude SDK promotion")
        case .failed(let detail):
            providerRuntimeLog.error("provider-runtime: interrupted Claude SDK promotion needs recovery: \(detail)")
        }
        for (provider, recovery) in [
            (ProviderRuntime.codex, recoverCodexRuntimeTransactionIfNeeded(stateRoot: stateRoot)),
            (ProviderRuntime.grok, recoverGrokRuntimeTransactionIfNeeded(stateRoot: stateRoot)),
            (ProviderRuntime.claude, recoverNpmGlobalTransactionIfNeeded(provider: .claude, package: .claudeCode, stateRoot: stateRoot)),
            (ProviderRuntime.claude, recoverShimRuntimeTransactionIfNeeded(provider: .claude, stateRoot: stateRoot)),
            (ProviderRuntime.codex, recoverShimRuntimeTransactionIfNeeded(provider: .codex, stateRoot: stateRoot)),
        ] {
            switch recovery {
            case .none:
                break
            case .recovered:
                providerRuntimeLog.warn("provider-runtime: recovered interrupted \(provider.rawValue) update")
            case .failed(let detail):
                providerRuntimeLog.error("provider-runtime: interrupted \(provider.rawValue) update needs recovery: \(detail)")
            }
        }
        await ProviderRuntimeMaintenanceLock.shared.release()
    }
}

struct RuntimeCommandResult {
    var code: Int32
    var output: String
    var timedOut: Bool
    /// A failed containment check means a descendant can still mutate an install tree.  Callers
    /// must retain their durable transaction journal instead of starting a rollback race.
    var descendantsExited: Bool = true
    var ok: Bool { code == 0 && !timedOut && descendantsExited }
}

private func processGroupMembers(_ groupID: pid_t) -> [pid_t] {
    // `kill(-pgid, 0)` can report EPERM for a recently reaped macOS process group even after all
    // members are gone.  libproc gives the authoritative member count for the group we created.
    var members = [pid_t](repeating: 0, count: 256)
    let byteCount = proc_listpids(
        UInt32(PROC_PGRP_ONLY),
        UInt32(groupID),
        &members,
        Int32(MemoryLayout<pid_t>.stride * members.count)
    )
    guard byteCount > 0 else { return [] }
    return Array(members.prefix(Int(byteCount) / MemoryLayout<pid_t>.stride)).filter { $0 > 0 }
}

private func signalProcessGroup(_ groupID: pid_t, signal: Int32) {
    _ = Darwin.kill(-groupID, signal)
    // Darwin can retain an ignored disposition inherited by a CLI's launcher.  Signal every
    // observed member as well, so containment does not depend on that process-group delivery.
    for member in processGroupMembers(groupID) {
        _ = Darwin.kill(member, signal)
    }
}

private func descendantProcessIDs(of root: pid_t) -> [pid_t] {
    let capacity = Int(proc_listallpids(nil, 0))
    guard capacity > 0 else { return [] }
    var pids = [pid_t](repeating: 0, count: capacity)
    let count = Int(proc_listallpids(&pids, Int32(MemoryLayout<pid_t>.stride * pids.count)))
    let candidates = pids.prefix(count).filter { $0 > 0 }
    var parents: [pid_t: pid_t] = [:]
    for pid in candidates {
        var info = proc_bsdinfo()
        if proc_pidinfo(pid, Int32(PROC_PIDTBSDINFO), 0, &info, Int32(MemoryLayout<proc_bsdinfo>.stride)) > 0 {
            parents[pid] = pid_t(info.pbi_ppid)
        }
    }
    var descendants: Set<pid_t> = [root]
    var changed = true
    while changed {
        changed = false
        for (pid, parent) in parents where !descendants.contains(pid) && descendants.contains(parent) {
            descendants.insert(pid)
            changed = true
        }
    }
    return Array(descendants)
}

/// Containment must re-probe every round instead of trusting one pre-signal snapshot: a member can
/// fork while we are signalling, and its ancestry link to the process we spawned disappears the
/// moment that process is reaped.  Process-group membership survives re-parenting, so it is the
/// authoritative check; ancestry is added only while the group leader is alive, to catch a member
/// that left the group via `setsid()`.  Reaping happens here so a leader zombie is never mistaken
/// for a process that can still mutate an install tree.
private func waitForRuntimeCommandContainment(
    leader: pid_t,
    signal: Int32?,
    timeout: TimeInterval,
    status: inout Int32?
) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if status == nil {
            var raw: Int32 = 0
            if waitpid(leader, &raw, WNOHANG) == leader { status = raw }
        }
        var remaining = Set(processGroupMembers(leader))
        if status == nil { remaining.formUnion(descendantProcessIDs(of: leader)) }
        if remaining.isEmpty { return true }
        if let signal {
            signalProcessGroup(leader, signal: signal)
            for member in remaining { _ = Darwin.kill(member, signal) }
        }
        usleep(20_000)
    } while Date() < deadline
    return status != nil && processGroupMembers(leader).isEmpty
}

private func waitForChildExit(_ pid: pid_t, timeout: TimeInterval) -> Int32? {
    let deadline = Date().addingTimeInterval(timeout)
    var status: Int32 = 0
    repeat {
        let result = waitpid(pid, &status, WNOHANG)
        if result == pid { return status }
        if result == -1 { return nil }
        usleep(20_000)
    } while Date() < deadline
    return nil
}

private func exitCode(fromWaitStatus status: Int32?) -> Int32 {
    guard let status else { return -1 }
    let signal = status & 0x7f
    return signal == 0 ? (status >> 8) & 0xff : -signal
}

/// Bounded command runner using the same PATH resolver as the sidecars (launchd-safe).  A fresh
/// process group is assigned by `posix_spawn` before the executable starts, so a timeout can kill
/// and verify every descendant before a caller restores a runtime snapshot.
func runRuntimeCommand(
    _ command: String,
    args: [String],
    cwd: URL? = nil,
    timeout: TimeInterval = 120
) -> RuntimeCommandResult {
    let executable = ProcessSidecarTransport.resolveExecutable(command)
    var descriptors: [Int32] = [0, 0]
    guard Darwin.pipe(&descriptors) == 0 else {
        return RuntimeCommandResult(code: -1, output: "pipe failed: \(String(cString: strerror(errno)))", timedOut: false)
    }
    let readHandle = FileHandle(fileDescriptor: descriptors[0], closeOnDealloc: true)
    let writeHandle = FileHandle(fileDescriptor: descriptors[1], closeOnDealloc: true)
    var actions: posix_spawn_file_actions_t?
    var attributes: posix_spawnattr_t?
    var defaultSignals = sigset_t()
    // Swift concurrency/libdispatch leaves SIGTERM blocked in this process, and `posix_spawn`
    // inherits the mask.  Without clearing it the graceful stop below can never be delivered and
    // every timeout has to escalate to SIGKILL.
    var deliverableSignals = sigset_t()
    guard posix_spawn_file_actions_init(&actions) == 0 else {
        try? readHandle.close()
        try? writeHandle.close()
        return RuntimeCommandResult(code: -1, output: "process action setup failed", timedOut: false)
    }
    defer { posix_spawn_file_actions_destroy(&actions) }
    let changeDirectoryResult = cwd.map {
        posix_spawn_file_actions_addchdir_np(&actions, $0.path)
    } ?? 0
    guard changeDirectoryResult == 0,
          posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDOUT_FILENO) == 0,
          posix_spawn_file_actions_adddup2(&actions, descriptors[1], STDERR_FILENO) == 0,
          posix_spawn_file_actions_addclose(&actions, descriptors[0]) == 0,
          posix_spawn_file_actions_addclose(&actions, descriptors[1]) == 0,
          posix_spawnattr_init(&attributes) == 0,
          sigemptyset(&defaultSignals) == 0,
          sigaddset(&defaultSignals, SIGTERM) == 0,
          posix_spawnattr_setsigdefault(&attributes, &defaultSignals) == 0,
          sigemptyset(&deliverableSignals) == 0,
          posix_spawnattr_setsigmask(&attributes, &deliverableSignals) == 0
    else {
        try? readHandle.close()
        try? writeHandle.close()
        return RuntimeCommandResult(code: -1, output: "process group setup failed", timedOut: false)
    }
    defer { posix_spawnattr_destroy(&attributes) }
    guard
          posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)) == 0,
          posix_spawnattr_setpgroup(&attributes, 0) == 0
    else {
        try? readHandle.close()
        try? writeHandle.close()
        return RuntimeCommandResult(code: -1, output: "process group setup failed", timedOut: false)
    }
    let argv = ([executable] + args).map { strdup($0) } + [nil]
    defer { argv.dropLast().forEach { free($0) } }
    var pid: pid_t = 0
    let spawnError = posix_spawn(&pid, executable, &actions, &attributes, argv, environ)
    try? writeHandle.close()
    guard spawnError == 0 else {
        try? readHandle.close()
        return RuntimeCommandResult(code: -1, output: "spawn failed: \(String(cString: strerror(spawnError)))", timedOut: false)
    }
    let outputBox = LockedBox(Data())
    let readDone = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .utility).async {
        let data = (try? readHandle.readToEnd()) ?? Data()
        outputBox.withLock { $0 = data }
        readDone.signal()
    }

    var status = waitForChildExit(pid, timeout: timeout)
    let timedOut = status == nil
    var descendantsExited = waitForRuntimeCommandContainment(
        leader: pid,
        signal: timedOut ? SIGTERM : nil,
        timeout: timedOut ? 0.25 : 0.1,
        status: &status
    )
    if !descendantsExited {
        descendantsExited = waitForRuntimeCommandContainment(leader: pid, signal: SIGKILL, timeout: 1, status: &status)
    }
    if readDone.wait(timeout: .now() + (descendantsExited ? 1 : 0.1)) == .timedOut {
        try? readHandle.close()
        _ = readDone.wait(timeout: .now() + 1)
    }
    return RuntimeCommandResult(
        code: exitCode(fromWaitStatus: status),
        output: String(data: outputBox.withLock { $0 }, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "",
        timedOut: timedOut,
        descendantsExited: descendantsExited
    )
}

typealias RuntimeCommandRunner = @Sendable (String, [String], URL?, TimeInterval) -> RuntimeCommandResult

private let defaultRuntimeCommandRunner: RuntimeCommandRunner = { command, args, cwd, timeout in
    runRuntimeCommand(command, args: args, cwd: cwd, timeout: timeout)
}

private func runtimeVersion(binary: String, command: RuntimeCommandRunner = defaultRuntimeCommandRunner) -> String? {
    let result = command(binary, ["--version"], nil, 10)
    guard result.ok, !result.output.isEmpty else { return nil }
    return result.output.split(whereSeparator: \.isNewline).first.map(String.init)
}

private func cliRuntimeHealthy(
    binary: String,
    command: RuntimeCommandRunner,
    catalogHealthy: @escaping @Sendable () async -> Bool
) async -> Bool {
    guard runtimeVersion(binary: binary, command: command) != nil else { return false }
    let help = command(binary, ["--help"], nil, 10)
    guard help.ok, !help.output.isEmpty else { return false }
    return await catalogHealthy()
}

/// Version each provider runtime's live children were last spawned against.  Grok and Codex both
/// ship their own background updaters, so a version that changed behind our back must still force a
/// restart — but an unchanged one must not: dropping a live ACP/app-server child costs the channel a
/// `session/load` round trip, and a failed resume is surfaced to the user.  An hourly no-op check
/// must therefore leave running sessions alone.
typealias SpawnedRuntimeVersions = LockedBox<[ProviderRuntime: String]>

let spawnedRuntimeVersions = SpawnedRuntimeVersions([:])

/// Restart the provider's children only when the on-disk version differs from the one they were
/// spawned against.  Returns false only when a needed restart actually failed.
private func reconcileRuntimeChildren(
    provider: ProviderRuntime,
    version: String,
    baseline: SpawnedRuntimeVersions,
    restartRuntime: @Sendable () async -> Bool
) async -> Bool {
    let previous = baseline.withLock { versions -> String? in
        let recorded = versions[provider]
        // First observation of this process: children are spawned lazily and will already pick up
        // this binary, so there is nothing to reconcile.
        if recorded == nil { versions[provider] = version }
        return recorded
    }
    guard let previous, previous != version else { return true }
    guard await restartRuntime() else { return false }
    baseline.withLock { $0[provider] = version }
    return true
}

/// Seed the baseline with the version observed BEFORE an update runs.  Boot resume opens ACP/
/// app-server children before the first check, so without this seed the post-update reconcile would
/// treat the very first check as "nothing to compare" and leave those children on the old binary.
private func recordRuntimeBaseline(provider: ProviderRuntime, version: String, baseline: SpawnedRuntimeVersions) {
    baseline.withLock { versions in
        if versions[provider] == nil { versions[provider] = version }
    }
}

// MARK: - Shim → version-named payload installs (Homebrew cask, Claude Code native installer)

/// Who owns the payload, and therefore which command may replace it.  A CLI's own updater refuses
/// to (or must not) write inside a Homebrew Caskroom, and Homebrew must not be asked to upgrade a
/// tree it never installed.
enum RuntimeInstallOwner: Equatable {
    /// The CLI updates itself in place (`<cli> update`).
    case selfManaged
    /// Homebrew installed it as a cask; `brew` relinks `<prefix>/bin/<name>` on upgrade.
    case homebrewCask(token: String)
}

/// An install whose executable shim is a symlink into a version-named payload: a Homebrew Caskroom
/// version directory and Claude Code's native `versions/<version>` file share this shape.  An
/// upgrade installs the NEW payload beside the old one and relinks, so the shim's link text alone is
/// a sufficient rollback record — no payload copy.
struct ManagedShimInstall: Equatable {
    var provider: ProviderRuntime
    var shim: URL
    var payload: URL
    var owner: RuntimeInstallOwner
}

/// Homebrew's prefix, derived from the `brew` shim through the same launchd-safe resolver every
/// other command uses.  Nil when Homebrew is not installed.
func homebrewPrefix(brewCommand: String = "brew", fileManager: FileManager = .default) -> URL? {
    let resolved = ProcessSidecarTransport.resolveExecutable(brewCommand)
    guard resolved.contains("/"), fileManager.isExecutableFile(atPath: resolved) else { return nil }
    let shim = URL(fileURLWithPath: resolved).standardizedFileURL
    guard shim.deletingLastPathComponent().lastPathComponent == "bin" else { return nil }
    return shim.deletingLastPathComponent().deletingLastPathComponent()
}

/// One layout the caller is willing to accept: the shim its owner rewrites, and the directory every
/// payload of that layout must live under.
struct ShimLayoutCandidate {
    var shim: URL
    var payloadRoot: URL
    var owner: RuntimeInstallOwner
}

/// Classify by where the payload actually lives, then anchor on the shim that layout's owner
/// rewrites — never on whichever indirection PATH happened to resolve first (an installer may drop
/// extra symlinks, and launchd's PATH order differs from a login shell's).  The binary the bridge
/// spawns must still resolve to the same payload, or its rollback boundary is unknown.
func managedShimInstall(
    provider: ProviderRuntime,
    binary: String,
    candidates: [ShimLayoutCandidate],
    fileManager: FileManager = .default
) -> ManagedShimInstall? {
    let spawned = URL(fileURLWithPath: ProcessSidecarTransport.resolveExecutable(binary))
        .resolvingSymlinksInPath().standardizedFileURL
    for candidate in candidates {
        let payload = candidate.shim.resolvingSymlinksInPath().standardizedFileURL
        let root = candidate.payloadRoot.resolvingSymlinksInPath().standardizedFileURL
        guard payload != candidate.shim.standardizedFileURL,
              payload.path.hasPrefix(root.path + "/"),
              spawned == payload,
              runtimeItemExists(candidate.shim, fileManager: fileManager),
              fileManager.fileExists(atPath: payload.path)
        else { continue }
        return ManagedShimInstall(provider: provider, shim: candidate.shim, payload: payload, owner: candidate.owner)
    }
    return nil
}

struct ShimRuntimeTransactionJournal: Codable, Equatable {
    var shim: String
    var payload: String
}

func shimTransactionJournalURL(stateRoot: URL, provider: ProviderRuntime) -> URL {
    stateRoot.appendingPathComponent("\(provider.rawValue)-shim-transaction.json")
}

func writeShimTransactionJournal(stateRoot: URL, install: ManagedShimInstall) throws {
    try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true)
    let journal = ShimRuntimeTransactionJournal(shim: install.shim.path, payload: install.payload.path)
    try JSONEncoder().encode(journal).write(to: shimTransactionJournalURL(stateRoot: stateRoot, provider: install.provider), options: .atomic)
}

/// Repoint the shim at the payload it had before the update.  Both versions coexist after an
/// upgrade, so this is the whole rollback — unless a cleanup already removed the old payload, which
/// is reported rather than papered over.
func restoreShimInstall(shim: URL, payload: URL, fileManager: FileManager = .default) -> String? {
    guard fileManager.fileExists(atPath: payload.path) else {
        return "previous payload is gone: \(payload.path)"
    }
    if runtimeItemExists(shim, fileManager: fileManager) {
        do { try fileManager.removeItem(at: shim) }
        catch { return "remove shim: \(error)" }
    }
    do { try fileManager.createSymbolicLink(atPath: shim.path, withDestinationPath: payload.path) }
    catch { return "relink shim: \(error)" }
    guard shim.resolvingSymlinksInPath().standardizedFileURL == payload.standardizedFileURL else {
        return "verify relinked shim"
    }
    return nil
}

func recoverShimRuntimeTransactionIfNeeded(
    provider: ProviderRuntime,
    stateRoot: URL = providerRuntimeUpdateStateRoot(),
    fileManager: FileManager = .default
) -> ProviderRuntimeTransactionRecovery {
    let journalURL = shimTransactionJournalURL(stateRoot: stateRoot, provider: provider)
    guard runtimeItemExists(journalURL, fileManager: fileManager) else { return .none }
    guard let data = try? Data(contentsOf: journalURL),
          let journal = try? JSONDecoder().decode(ShimRuntimeTransactionJournal.self, from: data),
          journal.shim.hasPrefix("/"), journal.payload.hasPrefix("/")
    else { return .failed("\(provider.rawValue) shim transaction journal is invalid: \(journalURL.path)") }
    if let failure = restoreShimInstall(
        shim: URL(fileURLWithPath: journal.shim),
        payload: URL(fileURLWithPath: journal.payload),
        fileManager: fileManager
    ) {
        return .failed("\(provider.rawValue) shim rollback incomplete; journal retained: \(failure)")
    }
    do {
        try fileManager.removeItem(at: journalURL)
        return .recovered
    } catch {
        return .failed("\(provider.rawValue) shim rollback succeeded but journal cleanup failed: \(error)")
    }
}

/// Update a shim-layout install: probe → snapshot the link → run the owner's updater → verify →
/// restart only on a real version change → relink on failure.
func updateShimRuntime(
    install: ManagedShimInstall,
    stateRoot: URL = providerRuntimeUpdateStateRoot(),
    command: RuntimeCommandRunner = defaultRuntimeCommandRunner,
    binary: String,
    parseVersion: @escaping @Sendable (String) -> String?,
    catalogHealthy: @escaping @Sendable () async -> Bool,
    restartRuntime: @escaping @Sendable () async -> Bool = { true },
    baseline: SpawnedRuntimeVersions = spawnedRuntimeVersions
) async -> ProviderRuntimeUpdateItem {
    let provider = install.provider
    switch recoverShimRuntimeTransactionIfNeeded(provider: provider, stateRoot: stateRoot) {
    case .none, .recovered:
        break
    case .failed(let detail):
        return ProviderRuntimeUpdateItem(provider: provider, status: .failed, detail: "interrupted update recovery failed: \(detail)")
    }
    guard let beforeLine = runtimeVersion(binary: binary, command: command),
          let before = parseVersion(beforeLine)
    else {
        return ProviderRuntimeUpdateItem(provider: provider, status: .failed, detail: "\(provider.rawValue) version probe failed")
    }
    recordRuntimeBaseline(provider: provider, version: before, baseline: baseline)

    // Homebrew can answer "is anything newer?" without touching the install, so an hourly no-op
    // check costs one query instead of a download.
    if case .homebrewCask(let token) = install.owner {
        let outdated = command("brew", ["outdated", "--cask", "--quiet", token], nil, 120)
        if outdated.ok, !outdated.output.contains(token) {
            let healthy = await cliRuntimeHealthy(binary: binary, command: command, catalogHealthy: catalogHealthy)
            guard healthy, await reconcileRuntimeChildren(provider: provider, version: before, baseline: baseline, restartRuntime: restartRuntime) else {
                return ProviderRuntimeUpdateItem(provider: provider, status: .failed, version: before, detail: "\(provider.rawValue) is already current but its runtime health check failed")
            }
            return ProviderRuntimeUpdateItem(provider: provider, status: .upToDate, version: before)
        }
    }

    let journalURL = shimTransactionJournalURL(stateRoot: stateRoot, provider: provider)
    var preserveJournal = false
    defer { if !preserveJournal { try? FileManager.default.removeItem(at: journalURL) } }
    do {
        try writeShimTransactionJournal(stateRoot: stateRoot, install: install)
    } catch {
        return ProviderRuntimeUpdateItem(provider: provider, status: .failed, version: before, detail: "\(provider.rawValue) transaction journal failed: \(error)")
    }

    let update: RuntimeCommandResult
    switch install.owner {
    case .selfManaged:
        update = command(binary, ["update"], nil, 600)
    case .homebrewCask(let token):
        update = command("brew", ["upgrade", "--cask", token], nil, 900)
    }
    guard update.descendantsExited else {
        preserveJournal = true
        return ProviderRuntimeUpdateItem(provider: provider, status: .failed, version: before, detail: "\(provider.rawValue) update process group did not exit; rollback record retained \(journalURL.path)")
    }
    let after = runtimeVersion(binary: binary, command: command).flatMap(parseVersion)
    let healthy = await cliRuntimeHealthy(binary: binary, command: command, catalogHealthy: catalogHealthy)
    let restarted: Bool
    if healthy, let after {
        restarted = await reconcileRuntimeChildren(provider: provider, version: after, baseline: baseline, restartRuntime: restartRuntime)
    } else {
        restarted = false
    }
    guard update.ok, let after, healthy, restarted else {
        let rollbackFailure = restoreShimInstall(shim: install.shim, payload: install.payload)
        let restoredHealth = await cliRuntimeHealthy(binary: binary, command: command, catalogHealthy: catalogHealthy)
        let restored = rollbackFailure == nil
            && runtimeVersion(binary: binary, command: command).flatMap(parseVersion) == before
            && restoredHealth
        if !restored { preserveJournal = true }
        return ProviderRuntimeUpdateItem(
            provider: provider,
            status: .failed,
            version: before,
            detail: restored
                ? "\(provider.rawValue) update failed; previous version relinked"
                : "\(provider.rawValue) update failed; rollback incomplete (record retained \(journalURL.path)): \(rollbackFailure ?? "post-rollback health check failed")"
        )
    }
    return ProviderRuntimeUpdateItem(provider: provider, status: after == before ? .upToDate : .updated, version: after)
}

struct ManagedCodexInstall {
    var packageDirectory: URL
    var shim: URL
}

struct CodexInstallSnapshot {
    var backupDirectory: URL
    var packageBackup: URL
    var shimBackup: URL
}

enum ProviderRuntimeTransactionRecovery: Equatable {
    case none
    case recovered
    case failed(String)
}

/// Runtime installers mutate global package trees, so their recovery authority must not live in
/// either of those mutable trees.  Keep it under the bridge's per-user application-support state.
func providerRuntimeUpdateStateRoot(
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
) -> URL {
    homeDirectory
        .appendingPathComponent("Library/Application Support", isDirectory: true)
        .appendingPathComponent("DiscordAgentBridge/provider-runtime-updates", isDirectory: true)
}

private func runtimeSnapshotDirectory(stateRoot: URL, provider: ProviderRuntime) throws -> URL {
    try FileManager.default.createDirectory(at: stateRoot, withIntermediateDirectories: true)
    return stateRoot.appendingPathComponent("\(provider.rawValue)-\(UUID().uuidString)", isDirectory: true)
}

private func runtimeItemExists(_ url: URL, fileManager: FileManager = .default) -> Bool {
    fileManager.fileExists(atPath: url.path) || (try? fileManager.destinationOfSymbolicLink(atPath: url.path)) != nil
}

/// A globally installed npm package the bridge may update: `<prefix>/lib/node_modules/<scope>/<name>`
/// with its shim at `<prefix>/bin/<binName>`.
struct NpmGlobalPackage: Equatable {
    var scope: String
    var name: String
    var binName: String

    static let codex = NpmGlobalPackage(scope: "@openai", name: "codex", binName: "codex")
    static let claudeCode = NpmGlobalPackage(scope: "@anthropic-ai", name: "claude-code", binName: "claude")

    /// Journal-validation suffix: the only package path this layout may ever roll back.
    var packageSuffix: String { "/lib/node_modules/\(scope)/\(name)" }
}

/// Only accept npm's standard global layout and a shim that resolves into that package.  Other
/// installation methods remain unsupported because their rollback boundaries are unknown.
/// The bin entry point is not always `<package>/bin/<file>` (`claude-code` exposes `cli.js` at its
/// root), so walk up from the executable to the package root instead of assuming a fixed depth.
func managedNpmGlobalInstall(
    binary: String,
    package: NpmGlobalPackage,
    fileManager: FileManager = .default
) -> ManagedCodexInstall? {
    let executable = URL(fileURLWithPath: ProcessSidecarTransport.resolveExecutable(binary))
        .resolvingSymlinksInPath().standardizedFileURL
    var candidate = executable.deletingLastPathComponent()
    var packageDirectory: URL?
    // `<prefix>/lib/node_modules/<scope>/<name>/…` — a handful of levels is more than any real bin path.
    for _ in 0..<8 {
        let scopeDirectory = candidate.deletingLastPathComponent()
        let nodeModules = scopeDirectory.deletingLastPathComponent()
        if candidate.lastPathComponent == package.name,
           scopeDirectory.lastPathComponent == package.scope,
           nodeModules.lastPathComponent == "node_modules",
           nodeModules.deletingLastPathComponent().lastPathComponent == "lib" {
            packageDirectory = candidate
            break
        }
        let parent = candidate.deletingLastPathComponent()
        if parent.path == candidate.path { break }
        candidate = parent
    }
    guard let packageDirectory else { return nil }
    // npm rewrites `<prefix>/bin/<binName>`, so that is the rollback boundary even when PATH resolved
    // an indirection symlink (e.g. `~/.local/bin/codex`) to it first.
    let prefix = packageDirectory
        .deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
    let shim = prefix.appendingPathComponent("bin/\(package.binName)").standardizedFileURL
    guard fileManager.fileExists(atPath: packageDirectory.path),
          fileManager.fileExists(atPath: executable.path),
          shim.resolvingSymlinksInPath().standardizedFileURL == executable
    else { return nil }
    return ManagedCodexInstall(packageDirectory: packageDirectory, shim: shim)
}

func managedCodexInstall(binary: String, fileManager: FileManager = .default) -> ManagedCodexInstall? {
    managedNpmGlobalInstall(binary: binary, package: .codex, fileManager: fileManager)
}

func snapshotManagedCodexInstall(
    _ install: ManagedCodexInstall,
    stateRoot: URL = providerRuntimeUpdateStateRoot(),
    provider: ProviderRuntime = .codex,
    fileManager: FileManager = .default
) throws -> CodexInstallSnapshot {
    // Backup directory name carries the provider so its recovery journal can validate ownership.
    let backupDirectory = try runtimeSnapshotDirectory(stateRoot: stateRoot, provider: provider)
    let packageBackup = backupDirectory.appendingPathComponent("codex-package")
    let shimBackup = backupDirectory.appendingPathComponent("codex-shim")
    try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: false)
    do {
        try fileManager.copyItem(at: install.packageDirectory, to: packageBackup)
        // `copyItem` follows a symlink here, which would turn npm's bin shim into a stale regular
        // file on rollback. Preserve the link text itself so the restored shim keeps resolving
        // through the package layout.
        let shimDestination = try fileManager.destinationOfSymbolicLink(atPath: install.shim.path)
        try fileManager.createSymbolicLink(atPath: shimBackup.path, withDestinationPath: shimDestination)
        return CodexInstallSnapshot(backupDirectory: backupDirectory, packageBackup: packageBackup, shimBackup: shimBackup)
    } catch {
        try? fileManager.removeItem(at: backupDirectory)
        throw error
    }
}

func restoreManagedCodexInstall(
    _ install: ManagedCodexInstall,
    snapshot: CodexInstallSnapshot,
    fileManager: FileManager = .default
) -> String? {
    var failures: [String] = []
    for (current, saved, name) in [
        (install.packageDirectory, snapshot.packageBackup, "package"),
        (install.shim, snapshot.shimBackup, "shim"),
    ] {
        if runtimeItemExists(current, fileManager: fileManager) {
            do { try fileManager.removeItem(at: current) }
            catch { failures.append("remove \(name): \(error)") }
        }
        guard runtimeItemExists(saved, fileManager: fileManager) else {
            failures.append("backup missing \(name)")
            continue
        }
        do { try fileManager.moveItem(at: saved, to: current) }
        catch { failures.append("restore \(name): \(error)") }
    }
    // Verify the shim resolves back INTO the restored package rather than to one fixed filename:
    // the bin entry point differs per package (`bin/codex.js` vs `cli.js` at the root).
    let restoredExecutable = install.shim.resolvingSymlinksInPath().standardizedFileURL
    let packageRoot = install.packageDirectory.standardizedFileURL
    if !fileManager.fileExists(atPath: install.packageDirectory.path) ||
        !fileManager.fileExists(atPath: install.shim.path) ||
        !restoredExecutable.path.hasPrefix(packageRoot.path + "/") {
        failures.append("verify restored package/shim")
    }
    return failures.isEmpty ? nil : failures.joined(separator: "; ")
}

struct CodexRuntimeTransactionJournal: Codable {
    var backupDirectory: String
    var packageDirectory: String
    var shim: String
}

/// Per-provider so two npm-global runtimes (Codex, Claude Code) never share a rollback record.
func npmGlobalTransactionJournalURL(stateRoot: URL, provider: ProviderRuntime) -> URL {
    stateRoot.appendingPathComponent("\(provider.rawValue)-npm-transaction.json")
}

func writeNpmGlobalTransactionJournal(
    stateRoot: URL,
    provider: ProviderRuntime,
    install: ManagedCodexInstall,
    snapshot: CodexInstallSnapshot
) throws {
    let journal = CodexRuntimeTransactionJournal(
        backupDirectory: snapshot.backupDirectory.lastPathComponent,
        packageDirectory: install.packageDirectory.path,
        shim: install.shim.path
    )
    try JSONEncoder().encode(journal).write(to: npmGlobalTransactionJournalURL(stateRoot: stateRoot, provider: provider), options: .atomic)
}

func codexTransactionJournalURL(stateRoot: URL) -> URL {
    npmGlobalTransactionJournalURL(stateRoot: stateRoot, provider: .codex)
}

func writeCodexTransactionJournal(
    stateRoot: URL,
    install: ManagedCodexInstall,
    snapshot: CodexInstallSnapshot
) throws {
    try writeNpmGlobalTransactionJournal(stateRoot: stateRoot, provider: .codex, install: install, snapshot: snapshot)
}

func recoverCodexRuntimeTransactionIfNeeded(
    stateRoot: URL = providerRuntimeUpdateStateRoot(),
    fileManager: FileManager = .default
) -> ProviderRuntimeTransactionRecovery {
    recoverNpmGlobalTransactionIfNeeded(provider: .codex, package: .codex, stateRoot: stateRoot, fileManager: fileManager)
}

func recoverNpmGlobalTransactionIfNeeded(
    provider: ProviderRuntime,
    package: NpmGlobalPackage,
    stateRoot: URL = providerRuntimeUpdateStateRoot(),
    fileManager: FileManager = .default
) -> ProviderRuntimeTransactionRecovery {
    let journalURL = npmGlobalTransactionJournalURL(stateRoot: stateRoot, provider: provider)
    guard runtimeItemExists(journalURL, fileManager: fileManager) else { return .none }
    guard let data = try? Data(contentsOf: journalURL),
          let journal = try? JSONDecoder().decode(CodexRuntimeTransactionJournal.self, from: data),
          !journal.backupDirectory.contains("/"),
          journal.backupDirectory.hasPrefix("\(provider.rawValue)-"),
          journal.packageDirectory.hasSuffix(package.packageSuffix),
          journal.shim.hasSuffix("/bin/\(package.binName)")
    else { return .failed("\(provider.rawValue) npm transaction journal is invalid: \(journalURL.path)") }
    let backup = stateRoot.appendingPathComponent(journal.backupDirectory, isDirectory: true)
    let snapshot = CodexInstallSnapshot(
        backupDirectory: backup,
        packageBackup: backup.appendingPathComponent("codex-package"),
        shimBackup: backup.appendingPathComponent("codex-shim")
    )
    guard runtimeItemExists(snapshot.packageBackup, fileManager: fileManager),
          runtimeItemExists(snapshot.shimBackup, fileManager: fileManager)
    else { return .failed("\(provider.rawValue) npm transaction snapshot is missing: \(backup.path)") }
    let install = ManagedCodexInstall(
        packageDirectory: URL(fileURLWithPath: journal.packageDirectory),
        shim: URL(fileURLWithPath: journal.shim)
    )
    if let failure = restoreManagedCodexInstall(install, snapshot: snapshot, fileManager: fileManager) {
        return .failed("\(provider.rawValue) rollback incomplete; snapshot retained \(backup.path): \(failure)")
    }
    do {
        try fileManager.removeItem(at: journalURL)
        try? fileManager.removeItem(at: backup)
        return .recovered
    } catch {
        return .failed("\(provider.rawValue) rollback succeeded but journal cleanup failed: \(error)")
    }
}

/// Update an npm-global runtime inside one snapshot/rollback transaction.  Shared by Codex and a
/// globally npm-installed Claude Code: same layout, same rollback boundary, same `<cli> update`.
func updateNpmGlobalRuntime(
    provider: ProviderRuntime,
    package: NpmGlobalPackage,
    install: ManagedCodexInstall,
    binary: String,
    stateRoot: URL = providerRuntimeUpdateStateRoot(),
    command: RuntimeCommandRunner = defaultRuntimeCommandRunner,
    parseVersion: @escaping @Sendable (String) -> String? = { $0 },
    catalogHealthy: @escaping @Sendable () async -> Bool,
    restartRuntime: @escaping @Sendable () async -> Bool = { true },
    baseline: SpawnedRuntimeVersions = spawnedRuntimeVersions
) async -> ProviderRuntimeUpdateItem {
    let label = provider.rawValue
    guard let beforeLine = runtimeVersion(binary: binary, command: command),
          let before = parseVersion(beforeLine)
    else {
        return ProviderRuntimeUpdateItem(provider: provider, status: .failed, detail: "\(label) version probe failed")
    }
    recordRuntimeBaseline(provider: provider, version: before, baseline: baseline)
    guard let snapshot = try? snapshotManagedCodexInstall(install, stateRoot: stateRoot, provider: provider) else {
        return ProviderRuntimeUpdateItem(provider: provider, status: .failed, version: before, detail: "\(label) rollback snapshot failed")
    }
    var preserveSnapshot = false
    let journalURL = npmGlobalTransactionJournalURL(stateRoot: stateRoot, provider: provider)
    defer {
        if !preserveSnapshot {
            try? FileManager.default.removeItem(at: journalURL)
            try? FileManager.default.removeItem(at: snapshot.backupDirectory)
        }
    }
    do {
        try writeNpmGlobalTransactionJournal(stateRoot: stateRoot, provider: provider, install: install, snapshot: snapshot)
    } catch {
        return ProviderRuntimeUpdateItem(provider: provider, status: .failed, version: before, detail: "\(label) transaction journal failed: \(error)")
    }

    let update = command(binary, ["update"], nil, 300)
    guard update.descendantsExited else {
        preserveSnapshot = true
        return ProviderRuntimeUpdateItem(provider: provider, status: .failed, version: before, detail: "\(label) update process group did not exit; snapshot retained \(snapshot.backupDirectory.path)")
    }
    let after = runtimeVersion(binary: binary, command: command).flatMap(parseVersion)
    let healthy = await cliRuntimeHealthy(binary: binary, command: command, catalogHealthy: catalogHealthy)
    let restarted: Bool
    if healthy, let after {
        restarted = await reconcileRuntimeChildren(provider: provider, version: after, baseline: baseline, restartRuntime: restartRuntime)
    } else {
        restarted = false
    }
    guard update.ok, let after, healthy, restarted else {
        let rollbackFailure = restoreManagedCodexInstall(install, snapshot: snapshot)
        let restoredHealth = await cliRuntimeHealthy(binary: binary, command: command, catalogHealthy: catalogHealthy)
        let restored = rollbackFailure == nil
            && runtimeVersion(binary: binary, command: command).flatMap(parseVersion) == before
            && restoredHealth
        if !restored { preserveSnapshot = true }
        return ProviderRuntimeUpdateItem(
            provider: provider,
            status: .failed,
            version: before,
            detail: restored
                ? "\(label) update failed; package and shim restored"
                : "\(label) update failed; rollback incomplete (snapshot retained \(snapshot.backupDirectory.path)): \(rollbackFailure ?? "post-rollback health check failed")"
        )
    }
    return ProviderRuntimeUpdateItem(provider: provider, status: after == before ? .upToDate : .updated, version: after)
}

/// Codex ships as a global npm package OR a Homebrew cask; both have a known rollback boundary, so
/// both are supported.  Anything else stays unsupported rather than guessing how to undo it.
func updateCodexRuntime(
    binary: String = "codex",
    stateRoot: URL = providerRuntimeUpdateStateRoot(),
    command: RuntimeCommandRunner = defaultRuntimeCommandRunner,
    brewPrefix: URL? = homebrewPrefix(),
    catalogHealthy: @escaping @Sendable () async -> Bool,
    restartRuntime: @escaping @Sendable () async -> Bool = { true },
    baseline: SpawnedRuntimeVersions = spawnedRuntimeVersions
) async -> ProviderRuntimeUpdateItem {
    switch recoverCodexRuntimeTransactionIfNeeded(stateRoot: stateRoot) {
    case .none, .recovered:
        break
    case .failed(let detail):
        return ProviderRuntimeUpdateItem(provider: .codex, status: .failed, detail: "interrupted update recovery failed: \(detail)")
    }
    if let install = managedNpmGlobalInstall(binary: binary, package: .codex) {
        return await updateNpmGlobalRuntime(
            provider: .codex, package: .codex, install: install, binary: binary, stateRoot: stateRoot,
            command: command, catalogHealthy: catalogHealthy, restartRuntime: restartRuntime, baseline: baseline
        )
    }
    if let brewPrefix, let install = managedShimInstall(
        provider: .codex,
        binary: binary,
        candidates: [ShimLayoutCandidate(
            shim: brewPrefix.appendingPathComponent("bin/codex"),
            payloadRoot: brewPrefix.appendingPathComponent("Caskroom/codex"),
            owner: .homebrewCask(token: "codex")
        )]
    ) {
        return await updateShimRuntime(
            install: install, stateRoot: stateRoot, command: command, binary: binary,
            parseVersion: { $0 }, catalogHealthy: catalogHealthy, restartRuntime: restartRuntime, baseline: baseline
        )
    }
    return ProviderRuntimeUpdateItem(provider: .codex, status: .unsupported, detail: "unmanaged Codex installation (expected a global npm package or a Homebrew cask); rollback boundary unavailable")
}

struct ManagedGrokInstall {
    var shim: URL
    var download: URL
}

struct GrokInstallSnapshot {
    var backupDirectory: URL
    var shimBackup: URL
    var downloadBackup: URL
}

func managedGrokInstall(
    binary: String,
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    fileManager: FileManager = .default
) -> ManagedGrokInstall? {
    let grokRoot = homeDirectory.appendingPathComponent(".grok")
    // `grok update` rewrites this shim, so it is the rollback boundary no matter which indirection
    // PATH happened to resolve: x.ai's install.sh also drops `~/.local/bin/grok` pointing here, and
    // the launchd PATH finds that copy first.
    let shim = grokRoot.appendingPathComponent("bin/grok").standardizedFileURL
    let download = shim.resolvingSymlinksInPath().standardizedFileURL
    let downloads = grokRoot.appendingPathComponent("downloads").standardizedFileURL
    // The binary the bridge actually spawns must be this same install, or its rollback boundary is
    // unknown.
    let spawned = URL(fileURLWithPath: ProcessSidecarTransport.resolveExecutable(binary))
        .resolvingSymlinksInPath().standardizedFileURL
    guard spawned == download,
          download.deletingLastPathComponent().standardizedFileURL == downloads,
          download.lastPathComponent.hasPrefix("grok-"),
          fileManager.fileExists(atPath: shim.path),
          fileManager.fileExists(atPath: download.path)
    else { return nil }
    return ManagedGrokInstall(shim: shim, download: download)
}

/// `grok update --check --json` reports `updateAvailable` without installing.  Anything
/// unparseable is treated as "maybe", so the caller still runs the full transactional update.
func grokUpdateUnavailable(_ result: RuntimeCommandResult) -> Bool {
    guard result.ok, let data = result.output.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return false }
    return json["updateAvailable"] as? Bool == false
}

func grokReleaseVersion(_ versionLine: String) -> String? {
    let parts = versionLine.split(whereSeparator: \.isWhitespace)
    guard parts.count >= 2, parts[0] == "grok" else { return nil }
    let candidate = String(parts[1])
    guard candidate.range(of: #"^\d+(?:\.\d+)+(?:-[A-Za-z0-9.]+)?$"#, options: .regularExpression) != nil else { return nil }
    return candidate
}

func snapshotManagedGrokInstall(
    _ install: ManagedGrokInstall,
    stateRoot: URL = providerRuntimeUpdateStateRoot(),
    fileManager: FileManager = .default
) throws -> GrokInstallSnapshot {
    let backupDirectory = try runtimeSnapshotDirectory(stateRoot: stateRoot, provider: .grok)
    let shimBackup = backupDirectory.appendingPathComponent("grok-shim")
    let downloadBackup = backupDirectory.appendingPathComponent("grok-download")
    try fileManager.createDirectory(at: backupDirectory, withIntermediateDirectories: false)
    do {
        let destination = try fileManager.destinationOfSymbolicLink(atPath: install.shim.path)
        try fileManager.createSymbolicLink(atPath: shimBackup.path, withDestinationPath: destination)
        try fileManager.copyItem(at: install.download, to: downloadBackup)
        return GrokInstallSnapshot(backupDirectory: backupDirectory, shimBackup: shimBackup, downloadBackup: downloadBackup)
    } catch {
        try? fileManager.removeItem(at: backupDirectory)
        throw error
    }
}

func restoreManagedGrokInstall(
    _ install: ManagedGrokInstall,
    snapshot: GrokInstallSnapshot,
    fileManager: FileManager = .default
) -> String? {
    var failures: [String] = []
    for (current, saved, name) in [
        (install.download, snapshot.downloadBackup, "download"),
        (install.shim, snapshot.shimBackup, "shim"),
    ] {
        if runtimeItemExists(current, fileManager: fileManager) {
            do { try fileManager.removeItem(at: current) }
            catch { failures.append("remove \(name): \(error)") }
        }
        guard runtimeItemExists(saved, fileManager: fileManager) else {
            failures.append("backup missing \(name)")
            continue
        }
        do { try fileManager.moveItem(at: saved, to: current) }
        catch { failures.append("restore \(name): \(error)") }
    }
    if !runtimeItemExists(install.download, fileManager: fileManager) ||
        !runtimeItemExists(install.shim, fileManager: fileManager) ||
        install.shim.resolvingSymlinksInPath().standardizedFileURL != install.download.standardizedFileURL {
        failures.append("verify restored download/shim")
    }
    return failures.isEmpty ? nil : failures.joined(separator: "; ")
}

private let grokTransactionJournalName = "grok-transaction.json"

struct GrokRuntimeTransactionJournal: Codable {
    var backupDirectory: String
    var shim: String
    var download: String
}

func grokTransactionJournalURL(stateRoot: URL) -> URL {
    stateRoot.appendingPathComponent(grokTransactionJournalName)
}

func writeGrokTransactionJournal(
    stateRoot: URL,
    install: ManagedGrokInstall,
    snapshot: GrokInstallSnapshot
) throws {
    let journal = GrokRuntimeTransactionJournal(
        backupDirectory: snapshot.backupDirectory.lastPathComponent,
        shim: install.shim.path,
        download: install.download.path
    )
    try JSONEncoder().encode(journal).write(to: grokTransactionJournalURL(stateRoot: stateRoot), options: .atomic)
}

func recoverGrokRuntimeTransactionIfNeeded(
    stateRoot: URL = providerRuntimeUpdateStateRoot(),
    fileManager: FileManager = .default
) -> ProviderRuntimeTransactionRecovery {
    let journalURL = grokTransactionJournalURL(stateRoot: stateRoot)
    guard runtimeItemExists(journalURL, fileManager: fileManager) else { return .none }
    guard let data = try? Data(contentsOf: journalURL),
          let journal = try? JSONDecoder().decode(GrokRuntimeTransactionJournal.self, from: data),
          !journal.backupDirectory.contains("/"),
          journal.backupDirectory.hasPrefix("grok-"),
          journal.shim.hasSuffix("/.grok/bin/grok"),
          journal.download.contains("/.grok/downloads/grok-")
    else { return .failed("Grok transaction journal is invalid: \(journalURL.path)") }
    let backup = stateRoot.appendingPathComponent(journal.backupDirectory, isDirectory: true)
    let snapshot = GrokInstallSnapshot(
        backupDirectory: backup,
        shimBackup: backup.appendingPathComponent("grok-shim"),
        downloadBackup: backup.appendingPathComponent("grok-download")
    )
    guard runtimeItemExists(snapshot.shimBackup, fileManager: fileManager),
          runtimeItemExists(snapshot.downloadBackup, fileManager: fileManager)
    else { return .failed("Grok transaction snapshot is missing: \(backup.path)") }
    let install = ManagedGrokInstall(
        shim: URL(fileURLWithPath: journal.shim),
        download: URL(fileURLWithPath: journal.download)
    )
    if let failure = restoreManagedGrokInstall(install, snapshot: snapshot, fileManager: fileManager) {
        return .failed("Grok rollback incomplete; snapshot retained \(backup.path): \(failure)")
    }
    do {
        try fileManager.removeItem(at: journalURL)
        try? fileManager.removeItem(at: backup)
        return .recovered
    } catch {
        return .failed("Grok rollback succeeded but journal cleanup failed: \(error)")
    }
}

func updateGrokRuntime(
    binary: String = "grok",
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    stateRoot: URL = providerRuntimeUpdateStateRoot(),
    command: RuntimeCommandRunner = defaultRuntimeCommandRunner,
    catalogHealthy: @escaping @Sendable () async -> Bool,
    restartRuntime: @escaping @Sendable () async -> Bool = { true },
    baseline: SpawnedRuntimeVersions = spawnedRuntimeVersions
) async -> ProviderRuntimeUpdateItem {
    switch recoverGrokRuntimeTransactionIfNeeded(stateRoot: stateRoot) {
    case .none, .recovered:
        break
    case .failed(let detail):
        return ProviderRuntimeUpdateItem(provider: .grok, status: .failed, detail: "interrupted update recovery failed: \(detail)")
    }
    guard let install = managedGrokInstall(binary: binary, homeDirectory: homeDirectory) else {
        return ProviderRuntimeUpdateItem(provider: .grok, status: .unsupported, detail: "unmanaged Grok installation; rollback boundary unavailable")
    }
    guard let beforeLine = runtimeVersion(binary: binary, command: command),
          let before = grokReleaseVersion(beforeLine)
    else {
        return ProviderRuntimeUpdateItem(provider: .grok, status: .failed, detail: "Grok version probe failed")
    }
    recordRuntimeBaseline(provider: .grok, version: before, baseline: baseline)
    // `grok update` re-downloads the release even when it is already current, so probe first:
    // skipping the 120MB+ rollback snapshot keeps an hourly no-op check nearly free.  The restart
    // still runs, because Grok's own background updater can swap the binary between our checks.
    if grokUpdateUnavailable(command(binary, ["update", "--check", "--json"], nil, 60)) {
        let healthy = await cliRuntimeHealthy(binary: binary, command: command, catalogHealthy: catalogHealthy)
        guard healthy, await reconcileRuntimeChildren(provider: .grok, version: before, baseline: baseline, restartRuntime: restartRuntime) else {
            return ProviderRuntimeUpdateItem(provider: .grok, status: .failed, version: before, detail: "Grok is already current but its runtime health check failed")
        }
        return ProviderRuntimeUpdateItem(provider: .grok, status: .upToDate, version: before)
    }
    guard let snapshot = try? snapshotManagedGrokInstall(install, stateRoot: stateRoot) else {
        return ProviderRuntimeUpdateItem(provider: .grok, status: .failed, version: before, detail: "Grok rollback snapshot failed")
    }
    var preserveSnapshot = false
    let journalURL = grokTransactionJournalURL(stateRoot: stateRoot)
    defer {
        if !preserveSnapshot {
            try? FileManager.default.removeItem(at: journalURL)
            try? FileManager.default.removeItem(at: snapshot.backupDirectory)
        }
    }
    do {
        try writeGrokTransactionJournal(stateRoot: stateRoot, install: install, snapshot: snapshot)
    } catch {
        return ProviderRuntimeUpdateItem(provider: .grok, status: .failed, version: before, detail: "Grok transaction journal failed: \(error)")
    }
    let update = command(binary, ["update"], nil, 300)
    guard update.descendantsExited else {
        preserveSnapshot = true
        return ProviderRuntimeUpdateItem(provider: .grok, status: .failed, version: before, detail: "Grok update process group did not exit; snapshot retained \(snapshot.backupDirectory.path)")
    }
    let afterLine = runtimeVersion(binary: binary, command: command)
    let healthy = await cliRuntimeHealthy(binary: binary, command: command, catalogHealthy: catalogHealthy)
    let after = afterLine.flatMap(grokReleaseVersion)
    let restarted: Bool
    if healthy, let after {
        restarted = await reconcileRuntimeChildren(provider: .grok, version: after, baseline: baseline, restartRuntime: restartRuntime)
    } else {
        restarted = false
    }
    guard update.ok, let after, healthy, restarted else {
        let rollbackFailure = restoreManagedGrokInstall(install, snapshot: snapshot)
        let restoredHealth = await cliRuntimeHealthy(binary: binary, command: command, catalogHealthy: catalogHealthy)
        let restored = rollbackFailure == nil && runtimeVersion(binary: binary, command: command).flatMap(grokReleaseVersion) == before && restoredHealth
        if !restored { preserveSnapshot = true }
        return ProviderRuntimeUpdateItem(
            provider: .grok,
            status: .failed,
            version: before,
            detail: restored ? "Grok update failed; managed download and shim restored" : "Grok update failed; rollback incomplete (snapshot retained \(snapshot.backupDirectory.path)): \(rollbackFailure ?? "post-rollback health check failed")"
        )
    }
    return ProviderRuntimeUpdateItem(provider: .grok, status: after == before ? .upToDate : .updated, version: after)
}

private let claudeSdkPackage = "@anthropic-ai/claude-agent-sdk"
let claudePromotionTargets = ["package.json", "package-lock.json", "node_modules"]
private let claudeTransactionJournalName = ".dab-provider-runtime-transaction.json"

struct ClaudeRuntimeTransactionJournal: Codable, Equatable {
    var backupDirectory: String
    var targets: [String]
}

enum ClaudeRuntimeTransactionRecovery: Equatable {
    case none
    case recovered
    case failed(String)
}

private func packageVersion(at url: URL) -> String? {
    guard let data = try? Data(contentsOf: url),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else { return nil }
    return json["version"] as? String
}

func claudeTransactionJournalURL(root: URL) -> URL {
    root.appendingPathComponent(claudeTransactionJournalName)
}

func writeClaudeTransactionJournal(root: URL, backup: URL, targets: [String]) throws {
    let journal = ClaudeRuntimeTransactionJournal(backupDirectory: backup.lastPathComponent, targets: targets)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try encoder.encode(journal).write(to: claudeTransactionJournalURL(root: root), options: .atomic)
}

/// Recovery is deliberately rollback-only: after a crash between sequential renames, retaining
/// the known old runtime is safer than trying to infer whether every staged artifact was promoted.
func recoverClaudeRuntimeTransactionIfNeeded(root: URL?) -> ClaudeRuntimeTransactionRecovery {
    guard let root else { return .none }
    let fm = FileManager.default
    let journalURL = claudeTransactionJournalURL(root: root)
    guard fm.fileExists(atPath: journalURL.path) else { return .none }
    guard let data = try? Data(contentsOf: journalURL),
          let journal = try? JSONDecoder().decode(ClaudeRuntimeTransactionJournal.self, from: data)
    else { return .failed("transaction journal is unreadable: \(journalURL.path)") }
    guard journal.backupDirectory.hasPrefix(".dab-provider-runtime-backup-"),
          !journal.backupDirectory.contains("/"),
          Set(journal.targets) == Set(claudePromotionTargets),
          journal.targets.count == claudePromotionTargets.count
    else { return .failed("transaction journal has invalid recovery targets") }
    let backup = root.appendingPathComponent(journal.backupDirectory)
    guard fm.fileExists(atPath: backup.path) else {
        return .failed("transaction backup is missing: \(backup.path)")
    }
    if let failure = rollbackClaudePromotion(root: root, backup: backup, targets: journal.targets) {
        return .failed("rollback incomplete; backup retained \(backup.path): \(failure)")
    }
    do {
        try fm.removeItem(at: journalURL)
    } catch {
        return .failed("rollback succeeded but journal cleanup failed; backup retained \(backup.path): \(error)")
    }
    // The journal is the recovery authority; once it is gone the now-empty backup is merely a
    // disposable artifact. A deletion failure is harmless and must not recreate a stale journal.
    try? fm.removeItem(at: backup)
    return .recovered
}

func rollbackClaudePromotion(root: URL, backup: URL, targets: [String]) -> String? {
    let fm = FileManager.default
    var failures: [String] = []
    for target in targets {
        let current = root.appendingPathComponent(target)
        let saved = backup.appendingPathComponent(target)
        guard fm.fileExists(atPath: saved.path) else { continue }
        if fm.fileExists(atPath: current.path) {
            do { try fm.removeItem(at: current) }
            catch {
                failures.append("remove \(target): \(error)")
                continue
            }
        }
        do { try fm.moveItem(at: saved, to: current) }
        catch { failures.append("restore \(target): \(error)") }
    }
    for target in targets {
        let current = root.appendingPathComponent(target)
        let saved = backup.appendingPathComponent(target)
        if !fm.fileExists(atPath: current.path) || fm.fileExists(atPath: saved.path) {
            failures.append("verify \(target)")
        }
    }
    return failures.isEmpty ? nil : failures.joined(separator: "; ")
}

private func writeRollbackJournal(backup: URL, root: URL, reason: String) {
    let journal = backup.appendingPathComponent("ROLLBACK_FAILED.txt")
    let text = """
    Provider runtime rollback incomplete
    root: \(root.path)
    time: \(ISO8601DateFormatter().string(from: Date()))
    reason: \(reason)
    """
    try? text.write(to: journal, atomically: true, encoding: .utf8)
}

/// `claude --version` prints `2.1.220 (Claude Code)`.
func claudeCliVersion(_ versionLine: String) -> String? {
    let first = versionLine.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
    guard first.range(of: #"^\d+(?:\.\d+)+$"#, options: .regularExpression) != nil else { return nil }
    return first
}

/// The Claude Agent SDK spawns the `claude` CLI — the SDK version alone does not decide which models
/// exist, so the CLI is a runtime that has to be kept current too.  It ships three ways, each with a
/// different owner and therefore a different rollback boundary:
///   - native installer: `~/.local/bin/claude` → `~/.local/share/claude/versions/<version>`
///   - Homebrew cask `claude-code`: `<prefix>/bin/claude` → `<prefix>/Caskroom/claude-code/<version>/…`
///   - global npm package `@anthropic-ai/claude-code`
func updateClaudeCliRuntime(
    binary: String = "claude",
    homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
    stateRoot: URL = providerRuntimeUpdateStateRoot(),
    command: RuntimeCommandRunner = defaultRuntimeCommandRunner,
    brewPrefix: URL? = homebrewPrefix(),
    catalogHealthy: @escaping @Sendable () async -> Bool = { true },
    restartRuntime: @escaping @Sendable () async -> Bool = { true },
    baseline: SpawnedRuntimeVersions = spawnedRuntimeVersions
) async -> ProviderRuntimeUpdateItem {
    switch recoverNpmGlobalTransactionIfNeeded(provider: .claude, package: .claudeCode, stateRoot: stateRoot) {
    case .none, .recovered:
        break
    case .failed(let detail):
        return ProviderRuntimeUpdateItem(provider: .claude, status: .failed, detail: "interrupted CLI update recovery failed: \(detail)")
    }
    var candidates: [ShimLayoutCandidate] = [ShimLayoutCandidate(
        shim: homeDirectory.appendingPathComponent(".local/bin/claude"),
        payloadRoot: homeDirectory.appendingPathComponent(".local/share/claude/versions"),
        owner: .selfManaged
    )]
    if let brewPrefix {
        candidates.append(ShimLayoutCandidate(
            shim: brewPrefix.appendingPathComponent("bin/claude"),
            payloadRoot: brewPrefix.appendingPathComponent("Caskroom/claude-code"),
            owner: .homebrewCask(token: "claude-code")
        ))
    }
    if let install = managedShimInstall(provider: .claude, binary: binary, candidates: candidates) {
        return await updateShimRuntime(
            install: install, stateRoot: stateRoot, command: command, binary: binary,
            parseVersion: claudeCliVersion, catalogHealthy: catalogHealthy,
            restartRuntime: restartRuntime, baseline: baseline
        )
    }
    if let install = managedNpmGlobalInstall(binary: binary, package: .claudeCode) {
        return await updateNpmGlobalRuntime(
            provider: .claude, package: .claudeCode, install: install, binary: binary, stateRoot: stateRoot,
            command: command, parseVersion: claudeCliVersion, catalogHealthy: catalogHealthy,
            restartRuntime: restartRuntime, baseline: baseline
        )
    }
    return ProviderRuntimeUpdateItem(provider: .claude, status: .unsupported, detail: "unmanaged Claude CLI installation (expected the native installer, a Homebrew cask, or a global npm package); rollback boundary unavailable")
}

/// The `claude` provider owns two runtimes — the in-repo Agent SDK and the `claude` CLI it spawns —
/// so one check covers both and reports the worse of the two.
private func updateClaudeRuntime() async -> ProviderRuntimeUpdateItem {
    let sdk = await updateClaudeSdkRuntime()
    // A live session holds an already-spawned `claude` process, so a new CLI only takes effect after
    // the sidecar is recycled — and that recycle is itself the health check (it re-probes the model
    // catalog through a freshly spawned CLI, so a broken update rolls back).
    let cli = await updateClaudeCliRuntime(
        restartRuntime: { await DabSessionBridge.shared.restartRuntimeAfterUpdate() }
    )
    let severity: [ProviderRuntimeUpdateStatus: Int] = [
        .failed: 4, .unsupported: 3, .updated: 2, .deferredBusy: 1, .upToDate: 0, .disabled: 0,
    ]
    let status = (severity[sdk.status] ?? 0) >= (severity[cli.status] ?? 0) ? sdk.status : cli.status
    let details = [sdk.detail.map { "sdk: \($0)" }, cli.detail.map { "cli: \($0)" }].compactMap { $0 }
    return ProviderRuntimeUpdateItem(
        provider: .claude,
        status: status,
        version: "sdk=\(sdk.version ?? "?") cli=\(cli.version ?? "?")",
        detail: details.isEmpty ? nil : details.joined(separator: "; ")
    )
}

/// Non-nil when this install's Claude SDK is owned by someone else, so the in-place staging
/// below must not run at all.
///
/// Homebrew is that case: the SDK lives in the keg's `libexec/node_modules`, which the formula
/// installs and `brew upgrade dab` replaces wholesale. Writing into a keg is wrong twice over —
/// the next upgrade silently reverts it, and the rollback boundary would straddle two owners.
///
/// Reported as `.unsupported`, the same status Codex/Grok use for an installation whose rollback
/// boundary we do not own. Before this existed the Homebrew path fell through to `findRepoRoot()`,
/// which searches upward from the process cwd — `/` under `brew services` — and so failed on every
/// single run, logging `Claude project root not found` forever (docs/node-discovery-and-homebrew-sdk-check.md 3-2).
func claudeSdkRuntimeUnmanagedReason(
    env: [String: String] = ProcessInfo.processInfo.environment
) -> ProviderRuntimeUpdateItem? {
    guard isHomebrewInstall(env: env) else { return nil }
    return ProviderRuntimeUpdateItem(
        provider: .claude,
        status: .unsupported,
        detail: "Claude SDK is owned by the Homebrew formula; it updates with `brew upgrade dab`"
    )
}

/// Stage package manifest/lock/dependencies, validate a real SDK import, then promote with rollback.
private func updateClaudeSdkRuntime() async -> ProviderRuntimeUpdateItem {
    if let item = claudeSdkRuntimeUnmanagedReason() {
        return item
    }
    guard let root = findRepoRoot() else {
        return ProviderRuntimeUpdateItem(provider: .claude, status: .failed, detail: "Claude project root not found")
    }
    switch recoverClaudeRuntimeTransactionIfNeeded(root: root) {
    case .none, .recovered:
        break
    case .failed(let detail):
        return ProviderRuntimeUpdateItem(provider: .claude, status: .failed, detail: "interrupted promotion recovery failed: \(detail)")
    }
    let fm = FileManager.default
    let installed = root.appendingPathComponent("node_modules/@anthropic-ai/claude-agent-sdk/package.json")
    guard let before = packageVersion(at: installed) else {
        return ProviderRuntimeUpdateItem(provider: .claude, status: .failed, detail: "installed Claude SDK metadata not found")
    }
    let npm = runRuntimeCommand("npm", args: ["view", claudeSdkPackage, "version"], cwd: root, timeout: 60)
    guard npm.ok, let latest = npm.output.split(whereSeparator: \.isNewline).last.map(String.init), !latest.isEmpty else {
        return ProviderRuntimeUpdateItem(provider: .claude, status: .failed, version: before, detail: "npm registry version check failed")
    }
    guard latest != before else {
        return ProviderRuntimeUpdateItem(provider: .claude, status: .upToDate, version: before)
    }

    let stage = root.appendingPathComponent(".dab-provider-runtime-stage-\(UUID().uuidString)")
    let backup = root.appendingPathComponent(".dab-provider-runtime-backup-\(UUID().uuidString)")
    let targets = claudePromotionTargets
    let transactionJournal = claudeTransactionJournalURL(root: root)
    var preserveBackup = false
    defer {
        try? fm.removeItem(at: stage)
        if !preserveBackup { try? fm.removeItem(at: backup) }
        if !preserveBackup { try? fm.removeItem(at: transactionJournal) }
    }
    do {
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        try fm.copyItem(at: root.appendingPathComponent("package.json"), to: stage.appendingPathComponent("package.json"))
        try fm.copyItem(at: root.appendingPathComponent("package-lock.json"), to: stage.appendingPathComponent("package-lock.json"))
    } catch {
        return ProviderRuntimeUpdateItem(provider: .claude, status: .failed, version: before, detail: "stage setup failed: \(error)")
    }
    let lockUpdate = runRuntimeCommand(
        "npm",
        args: ["install", "--package-lock-only", "--ignore-scripts", "\(claudeSdkPackage)@latest"],
        cwd: stage,
        timeout: 300
    )
    guard lockUpdate.ok else {
        return ProviderRuntimeUpdateItem(provider: .claude, status: .failed, version: before, detail: lockUpdate.output)
    }
    let install = runRuntimeCommand("npm", args: ["ci", "--ignore-scripts"], cwd: stage, timeout: 600)
    guard install.ok else {
        return ProviderRuntimeUpdateItem(provider: .claude, status: .failed, version: before, detail: install.output)
    }
    let healthScript = stage.appendingPathComponent(".dab-claude-sdk-health.mjs")
    do {
        try "import('@anthropic-ai/claude-agent-sdk');".write(to: healthScript, atomically: true, encoding: .utf8)
    } catch {
        return ProviderRuntimeUpdateItem(provider: .claude, status: .failed, version: before, detail: "stage health setup failed: \(error)")
    }
    let stagedHealth = runRuntimeCommand("node", args: [healthScript.path], cwd: stage, timeout: 60)
    guard stagedHealth.ok else {
        return ProviderRuntimeUpdateItem(provider: .claude, status: .failed, version: before, detail: "staged SDK health failed: \(stagedHealth.output)")
    }

    do {
        try fm.createDirectory(at: backup, withIntermediateDirectories: false)
        // Must be durable before the first sequential move: a kill here is recovered on boot.
        try writeClaudeTransactionJournal(root: root, backup: backup, targets: targets)
        for target in targets {
            let source = root.appendingPathComponent(target)
            guard fm.fileExists(atPath: source.path) else { throw CocoaError(.fileNoSuchFile) }
            try fm.moveItem(at: source, to: backup.appendingPathComponent(target))
        }
        for target in targets {
            try fm.moveItem(at: stage.appendingPathComponent(target), to: root.appendingPathComponent(target))
        }
    } catch {
        if let rollbackFailure = rollbackClaudePromotion(root: root, backup: backup, targets: targets) {
            preserveBackup = true
            writeRollbackJournal(backup: backup, root: root, reason: rollbackFailure)
            return ProviderRuntimeUpdateItem(provider: .claude, status: .failed, version: before, detail: "promotion failed; rollback incomplete (backup retained \(backup.path)): \(rollbackFailure)")
        }
        return ProviderRuntimeUpdateItem(provider: .claude, status: .failed, version: before, detail: "promotion failed and rolled back: \(error)")
    }
    let promotedVersion = packageVersion(at: installed) ?? latest
    guard await DabSessionBridge.shared.restartRuntimeAfterUpdate() else {
        if let rollbackFailure = rollbackClaudePromotion(root: root, backup: backup, targets: targets) {
            preserveBackup = true
            writeRollbackJournal(backup: backup, root: root, reason: rollbackFailure)
            return ProviderRuntimeUpdateItem(provider: .claude, status: .failed, version: before, detail: "restarted SDK health failed; rollback incomplete (backup retained \(backup.path)): \(rollbackFailure)")
        }
        _ = await DabSessionBridge.shared.restartRuntimeAfterUpdate()
        return ProviderRuntimeUpdateItem(provider: .claude, status: .failed, version: before, detail: "restarted SDK health failed; rolled back")
    }
    return ProviderRuntimeUpdateItem(provider: .claude, status: .updated, version: promotedVersion)
}
