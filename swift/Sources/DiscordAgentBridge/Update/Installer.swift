import Foundation

// Self-update install + restart (TS `src/update/installer.ts` + `environment.ts` parity).
// Pure plan steps are unit-testable; real OS touches go through injectable runners.
// Production path: git pull (repo layout) → `swift/scripts/install.sh` with
// `DAB_INSTALL_SKIP_LAUNCHCTL=1` (avoid unload killing this process mid-install) →
// supervised exit / launchctl kickstart. Full in-process binary self-mmap replace is
// intentionally NOT done (half-install risk).

// MARK: - Restart strategy

/// How to come back up after a successful install.
public enum RestartStrategy: String, Sendable, Equatable {
    /// launchd KeepAlive / systemd Restart=always — exit only; supervisor relaunches.
    case supervised
    /// No supervisor: try launchctl kickstart if a plist exists, else re-exec `dab` then exit.
    case respawn
}

public struct RestartDetectDeps: Sendable {
    public var platformIsDarwin: Bool
    public var platformIsWindows: Bool
    public var env: [String: String]
    public var home: String
    public var fileExists: @Sendable (String) -> Bool

    public init(
        platformIsDarwin: Bool = true,
        platformIsWindows: Bool = false,
        env: [String: String] = ProcessInfo.processInfo.environment,
        home: String = NSHomeDirectory(),
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) {
        self.platformIsDarwin = platformIsDarwin
        self.platformIsWindows = platformIsWindows
        self.env = env
        self.home = home
        self.fileExists = fileExists
    }
}

/// launchd LaunchAgent plist path for the Swift dab service.
public func launchdPlistPath(home: String = NSHomeDirectory()) -> String {
    (home as NSString).appendingPathComponent("Library/LaunchAgents/com.discord-agent-bridge.plist")
}

/// `brew services` writes its own LaunchAgent under Homebrew's label, not install.sh's.
public func homebrewServicePlistPath(home: String = NSHomeDirectory()) -> String {
    (home as NSString).appendingPathComponent("Library/LaunchAgents/homebrew.mxcl.dab.plist")
}

/// True when this process came from a Homebrew keg — the tap's `bin/dab` wrapper exports
/// `DAB_INSTALL_METHOD=homebrew`. Everything that inspects, restarts, or advises about the
/// background service must branch on this: a Homebrew install has neither the
/// `com.discord-agent-bridge` LaunchAgent nor the `swift/scripts/install.sh` checkout that the
/// source-install path assumes, so answering from those alone reports a running service as
/// absent and points the user at a file they do not have.
public func isHomebrewInstall(env: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
    env["DAB_INSTALL_METHOD"] == "homebrew"
}

/// systemd --user unit path for the Swift dab service (TS `service/systemd.ts` `systemdUnitPath`).
/// Old-install fallback signal for `detectRestartStrategy` on Linux — not full service support (H4, held back).
public func systemdUnitPath(home: String = NSHomeDirectory()) -> String {
    (home as NSString).appendingPathComponent(".config/systemd/user/discord-agent-bridge.service")
}

// MARK: - PID file (H17, TS `update/environment.ts:48` `pidFilePath` + `installer.ts:88-97`)

/// `<baseDir>/agent.pid` — lets an operator later `kill $(cat agent.pid)` a foreground/
/// detached instance. `baseDir` mirrors TS's `configStore.dir` (here: `ConfigStore.dir`).
public func pidFilePath(baseDir: URL) -> URL {
    baseDir.appendingPathComponent("agent.pid", isDirectory: false)
}

/// Record this process's PID (TS `writePidFile`). Throws on write failure — the caller
/// (`DabMain.onReady`) wraps this in a warn-and-continue, matching TS's `try/catch` at
/// `app.ts:611-619` (best-effort: a write failure never blocks boot).
public func writePidFile(baseDir: URL, pid: Int32) throws {
    try String(pid).write(to: pidFilePath(baseDir: baseDir), atomically: true, encoding: .utf8)
}

/// Remove the PID file. No-op when absent (never throws) — mirrors TS `removePidFile`
/// (`installer.ts:94-97`). Not wired to any shutdown path in production: TS itself only calls
/// this from `App.destroy()`, which nothing in `cli.ts`/`app.ts` invokes on a real process kill
/// (no SIGTERM/SIGINT handler exists there either) — so a stale file after `kill` is the TS
/// behavior being matched, not a gap (see swift-port-parity-gaps.md H17).
public func removePidFile(baseDir: URL) {
    let target = pidFilePath(baseDir: baseDir)
    guard FileManager.default.fileExists(atPath: target.path) else { return }
    try? FileManager.default.removeItem(at: target)
}

/// Decide restart strategy after in-place upgrade (TS `detectRestartStrategy`,
/// `src/update/environment.ts:27-44`).
/// - Windows → respawn always (scheduled task doesn't relaunch on exit; marker is irrelevant)
/// - `DAB_SUPERVISED=1` → supervised
/// - darwin + plist present → supervised (old-install fallback)
/// - linux (non-darwin, non-Windows) + systemd unit present → supervised (old-install fallback)
/// - otherwise → respawn
public func detectRestartStrategy(_ d: RestartDetectDeps) -> RestartStrategy {
    if d.platformIsWindows { return .respawn }
    if d.env["DAB_SUPERVISED"] == "1" { return .supervised }
    if d.platformIsDarwin, d.fileExists(launchdPlistPath(home: d.home)) {
        return .supervised
    }
    if !d.platformIsDarwin, d.fileExists(systemdUnitPath(home: d.home)) {
        return .supervised
    }
    return .respawn
}

// MARK: - Plan

public enum UpdateInstallStep: Sendable, Equatable {
    /// `git -C <repoRoot> pull --ff-only` (skipped when no .git).
    case gitPull(repoRoot: String)
    /// Run install.sh; env always includes non-interactive skip-launchctl when not dry-run of files only.
    case runInstallScript(path: String, dryRun: Bool)
    /// Optional: download a release asset into a staging path (configured URL only).
    case downloadReleaseAsset(url: String, dest: String)
}

public struct UpdateInstallPlan: Sendable, Equatable {
    public var steps: [UpdateInstallStep]
    public var repoRoot: String?
    public var installScriptPath: String?

    public init(steps: [UpdateInstallStep], repoRoot: String? = nil, installScriptPath: String? = nil) {
        self.steps = steps
        self.repoRoot = repoRoot
        self.installScriptPath = installScriptPath
    }
}

public struct UpdateInstallDiscover: Sendable {
    public var repoRoot: String?
    public var installScriptPath: String?
    public var hasGit: Bool
    public var releaseAssetURL: String?
    public var releaseAssetDest: String?
    public var dryRun: Bool

    public init(
        repoRoot: String? = nil,
        installScriptPath: String? = nil,
        hasGit: Bool = false,
        releaseAssetURL: String? = nil,
        releaseAssetDest: String? = nil,
        dryRun: Bool = false
    ) {
        self.repoRoot = repoRoot
        self.installScriptPath = installScriptPath
        self.hasGit = hasGit
        self.releaseAssetURL = releaseAssetURL
        self.releaseAssetDest = releaseAssetDest
        self.dryRun = dryRun
    }
}

/// Build ordered install steps. Returns nil when nothing actionable is configured.
/// Preference: configured release asset → else repo `install.sh` (+ optional git pull).
public func buildUpdateInstallPlan(_ d: UpdateInstallDiscover) -> UpdateInstallPlan? {
    // Configured asset path (no git build).
    if let url = d.releaseAssetURL, !url.isEmpty,
       let dest = d.releaseAssetDest, !dest.isEmpty
    {
        return UpdateInstallPlan(
            steps: [.downloadReleaseAsset(url: url, dest: dest)],
            repoRoot: d.repoRoot,
            installScriptPath: d.installScriptPath
        )
    }

    guard let script = d.installScriptPath, !script.isEmpty else { return nil }

    var steps: [UpdateInstallStep] = []
    if d.hasGit, let root = d.repoRoot, !root.isEmpty {
        steps.append(.gitPull(repoRoot: root))
    }
    steps.append(.runInstallScript(path: script, dryRun: d.dryRun))
    return UpdateInstallPlan(steps: steps, repoRoot: d.repoRoot, installScriptPath: script)
}

/// Discover a plan from the live filesystem / env (production).
public func discoverUpdateInstallPlan(
    env: [String: String] = ProcessInfo.processInfo.environment,
    fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
    dryRun: Bool = false
) -> UpdateInstallPlan? {
    let assetURL = env["DAB_UPDATE_RELEASE_ASSET"].flatMap { $0.isEmpty ? nil : $0 }
    let assetDest = env["DAB_UPDATE_RELEASE_DEST"].flatMap { $0.isEmpty ? nil : $0 }
        ?? (NSHomeDirectory() as NSString).appendingPathComponent(".dab/bin/dab.new")

    let root = findRepoRoot()?.path
    let script: String?
    if let root {
        let candidate = (root as NSString).appendingPathComponent("swift/scripts/install.sh")
        script = fileExists(candidate) ? candidate : nil
    } else {
        script = nil
    }
    let hasGit: Bool
    if let root {
        hasGit = fileExists((root as NSString).appendingPathComponent(".git"))
    } else {
        hasGit = false
    }

    return buildUpdateInstallPlan(UpdateInstallDiscover(
        repoRoot: root,
        installScriptPath: script,
        hasGit: hasGit,
        releaseAssetURL: assetURL,
        releaseAssetDest: assetURL == nil ? nil : assetDest,
        dryRun: dryRun || env["DAB_UPDATE_DRY_RUN"] == "1"
    ))
}

// MARK: - Execute

/// `(executable, args, extraEnv) → capture`. Never throws; spawn failure → exitCode nil.
public typealias UpdateCommandRunner = @Sendable (String, [String], [String: String]) async -> ProcessCapture

public struct UpdateInstallRunResult: Sendable, Equatable {
    public var ok: Bool
    public var code: Int
    public var stderr: String
    public var completedSteps: Int
    public var logLines: [String]

    public init(ok: Bool, code: Int = 0, stderr: String = "", completedSteps: Int = 0, logLines: [String] = []) {
        self.ok = ok
        self.code = code
        self.stderr = stderr
        self.completedSteps = completedSteps
        self.logLines = logLines
    }

    public var asInstallResult: UpdateInstallResult {
        UpdateInstallResult(ok: ok, code: code, stderr: stderr)
    }
}

/// Run plan steps in order. Stops on first failure; never throws.
public func runUpdateInstallPlan(
    _ plan: UpdateInstallPlan,
    runner: UpdateCommandRunner,
    onLog: @Sendable (String) -> Void = { _ in }
) async -> UpdateInstallRunResult {
    var logs: [String] = []
    func log(_ s: String) {
        logs.append(s)
        onLog(s)
    }

    guard !plan.steps.isEmpty else {
        log("auto-update: empty install plan")
        return UpdateInstallRunResult(ok: false, code: 1, stderr: "empty install plan", logLines: logs)
    }

    var completed = 0
    for step in plan.steps {
        switch step {
        case .gitPull(let repoRoot):
            log("auto-update: git pull --ff-only in \(repoRoot)")
            let cap = await runner("git", ["-C", repoRoot, "pull", "--ff-only"], [:])
            if cap.timedOut {
                log("auto-update: git pull timed out")
                return UpdateInstallRunResult(
                    ok: false, code: 124, stderr: "git pull timed out",
                    completedSteps: completed, logLines: logs
                )
            }
            guard let code = cap.exitCode.map(Int.init), code == 0 else {
                let err = clipInstallLog(cap.stderr.isEmpty ? cap.stdout : cap.stderr)
                log("auto-update: git pull failed: \(err)")
                return UpdateInstallRunResult(
                    ok: false,
                    code: cap.exitCode.map(Int.init) ?? 1,
                    stderr: err,
                    completedSteps: completed,
                    logLines: logs
                )
            }
            completed += 1

        case .runInstallScript(let path, let dryRun):
            var env: [String: String] = [
                // Never unload launchd from inside the running agent — restart is a separate step.
                "DAB_INSTALL_SKIP_LAUNCHCTL": "1",
            ]
            var args = [path]
            if dryRun {
                args.append("--dry-run")
                log("auto-update: install.sh --dry-run \(path)")
            } else {
                log("auto-update: install.sh \(path) (skip launchctl)")
            }
            let cap = await runner("/bin/bash", args, env)
            if cap.timedOut {
                log("auto-update: install.sh timed out")
                return UpdateInstallRunResult(
                    ok: false, code: 124, stderr: "install.sh timed out",
                    completedSteps: completed, logLines: logs
                )
            }
            guard let code = cap.exitCode.map(Int.init), code == 0 else {
                let err = clipInstallLog(cap.stderr.isEmpty ? cap.stdout : cap.stderr)
                log("auto-update: install.sh failed code=\(cap.exitCode.map(String.init) ?? "nil"): \(err)")
                return UpdateInstallRunResult(
                    ok: false,
                    code: cap.exitCode.map(Int.init) ?? 1,
                    stderr: err,
                    completedSteps: completed,
                    logLines: logs
                )
            }
            completed += 1

        case .downloadReleaseAsset(let url, let dest):
            log("auto-update: download release asset → \(dest)")
            // curl -fL --retry 2 -o dest URL (fail on HTTP errors).
            let cap = await runner(
                "/usr/bin/curl",
                ["-fL", "--retry", "2", "--connect-timeout", "30", "-o", dest, url],
                [:]
            )
            if cap.timedOut {
                return UpdateInstallRunResult(
                    ok: false, code: 124, stderr: "download timed out",
                    completedSteps: completed, logLines: logs
                )
            }
            guard let code = cap.exitCode.map(Int.init), code == 0 else {
                let err = clipInstallLog(cap.stderr.isEmpty ? cap.stdout : cap.stderr)
                log("auto-update: download failed: \(err)")
                return UpdateInstallRunResult(
                    ok: false,
                    code: cap.exitCode.map(Int.init) ?? 1,
                    stderr: err,
                    completedSteps: completed,
                    logLines: logs
                )
            }
            // Promote staging binary into ~/.dab/bin/dab when dest ends with .new
            if dest.hasSuffix(".new") {
                let finalPath = String(dest.dropLast(4))
                let mv = await runner("/bin/mv", ["-f", dest, finalPath], [:])
                guard let mvCode = mv.exitCode.map(Int.init), mvCode == 0 else {
                    let err = clipInstallLog(mv.stderr)
                    log("auto-update: mv promote failed: \(err)")
                    return UpdateInstallRunResult(
                        ok: false,
                        code: mv.exitCode.map(Int.init) ?? 1,
                        stderr: err,
                        completedSteps: completed,
                        logLines: logs
                    )
                }
                _ = await runner("/bin/chmod", ["0755", finalPath], [:])
            }
            completed += 1
        }
    }

    log("auto-update: install plan ok (\(completed) steps)")
    return UpdateInstallRunResult(ok: true, code: 0, stderr: "", completedSteps: completed, logLines: logs)
}

private func clipInstallLog(_ s: String, max: Int = 500) -> String {
    let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
    if t.count <= max { return t }
    return String(t.prefix(max)) + "…"
}

// MARK: - Production command runner

/// Spawn `executable args` with optional env overlay; harvest stdout/stderr; optional timeout.
public func runUpdateCommand(
    executable: String,
    args: [String],
    extraEnv: [String: String] = [:],
    timeoutMs: Int = 30 * 60 * 1000
) async -> ProcessCapture {
    await withCheckedContinuation { cont in
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            // Prefer absolute paths for known bins; fall back to /usr/bin/env for PATH lookup.
            if executable.hasPrefix("/") {
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = args
            } else {
                process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
                process.arguments = [executable] + args
            }
            var env = ProcessInfo.processInfo.environment
            for (k, v) in extraEnv { env[k] = v }
            process.environment = env
            let outPipe = Pipe()
            let errPipe = Pipe()
            process.standardOutput = outPipe
            process.standardError = errPipe

            do {
                try process.run()
            } catch {
                cont.resume(returning: ProcessCapture(
                    stdout: "",
                    stderr: error.localizedDescription,
                    exitCode: nil,
                    timedOut: false
                ))
                return
            }

            // Drain both child pipes while it runs. Reading after waitUntilExit can deadlock
            // once either pipe fills and the child blocks trying to write the other stream.
            let stdout = LockedBox(Data())
            let stderr = LockedBox(Data())
            let drains = DispatchGroup()
            func drain(_ pipe: Pipe, into buffer: LockedBox<Data>) {
                drains.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    buffer.withLock { $0 = pipe.fileHandleForReading.readDataToEndOfFile() }
                    drains.leave()
                }
            }
            drain(outPipe, into: stdout)
            drain(errPipe, into: stderr)

            let box = LockedBox<Process?>(process)
            let timedOutBox = LockedBox(false)
            let timeout = max(0.001, Double(timeoutMs) / 1000.0)
            let timer = DispatchSource.makeTimerSource(queue: .global(qos: .userInitiated))
            timer.schedule(deadline: .now() + timeout)
            timer.setEventHandler {
                box.withLock { proc in
                    if let p = proc, p.isRunning {
                        timedOutBox.withLock { $0 = true }
                        p.terminate()
                    }
                }
            }
            timer.resume()

            process.waitUntilExit()
            timer.cancel()
            box.withLock { $0 = nil }

            drains.wait()
            let out = String(data: stdout.withLock { $0 }, encoding: .utf8) ?? ""
            let err = String(data: stderr.withLock { $0 }, encoding: .utf8) ?? ""
            let timedOut = timedOutBox.withLock { $0 }
            cont.resume(returning: ProcessCapture(
                stdout: out,
                stderr: err,
                exitCode: timedOut ? nil : process.terminationStatus,
                timedOut: timedOut
            ))
        }
    }
}

// MARK: - Restart

public enum RestartResult: Sendable, Equatable {
    case handedOff
    case manualRestartRequired
}

public struct RestartPerformDeps: Sendable {
    public var strategy: RestartStrategy
    public var platformIsDarwin: Bool
    public var home: String
    public var dabBinaryPath: String
    public var fileExists: @Sendable (String) -> Bool
    public var launchdJobIsLoaded: @Sendable () -> Bool
    public var runKickstart: @Sendable () -> Bool
    public var spawnDetached: @Sendable (String, [String], [String: String]) -> Bool
    public var makeReadyMarker: @Sendable () -> URL?
    public var waitForReadyMarker: @Sendable (URL) -> Bool
    public var exitProcess: @Sendable (Int32) -> Void

    public init(
        strategy: RestartStrategy,
        platformIsDarwin: Bool = true,
        home: String = NSHomeDirectory(),
        dabBinaryPath: String = (NSHomeDirectory() as NSString).appendingPathComponent(".dab/bin/dab"),
        fileExists: @escaping @Sendable (String) -> Bool = { FileManager.default.fileExists(atPath: $0) },
        launchdJobIsLoaded: @escaping @Sendable () -> Bool = {
            isLaunchdJobLoaded()
        },
        runKickstart: @escaping @Sendable () -> Bool = { false },
        spawnDetached: @escaping @Sendable (String, [String], [String: String]) -> Bool = { _, _, _ in false },
        makeReadyMarker: @escaping @Sendable () -> URL? = {
            FileManager.default.temporaryDirectory.appendingPathComponent("dab-successor-\(UUID().uuidString).ready")
        },
        waitForReadyMarker: @escaping @Sendable (URL) -> Bool = { marker in
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline {
                if FileManager.default.fileExists(atPath: marker.path) { return true }
                Thread.sleep(forTimeInterval: 0.1)
            }
            return false
        },
        exitProcess: @escaping @Sendable (Int32) -> Void = { code in Foundation.exit(code) }
    ) {
        self.strategy = strategy
        self.platformIsDarwin = platformIsDarwin
        self.home = home
        self.dabBinaryPath = dabBinaryPath
        self.fileExists = fileExists
        self.launchdJobIsLoaded = launchdJobIsLoaded
        self.runKickstart = runKickstart
        self.spawnDetached = spawnDetached
        self.makeReadyMarker = makeReadyMarker
        self.waitForReadyMarker = waitForReadyMarker
        self.exitProcess = exitProcess
    }
}

/// Perform post-install restart.
/// - **supervised launchd**: exit normally and let the installed LaunchAgent's KeepAlive relaunch.
/// - **other supervised**: use the existing relaunch hook.
/// - **respawn** (foreground): spawn successor with READY marker, then exit.
public func performRestart(
    _ d: RestartPerformDeps,
    onLog: @Sendable (String) -> Void = { _ in },
    /// Called after successor READY in the foreground respawn path.
    onConfirmed: @escaping @Sendable () async -> Void = {}
) async -> RestartResult {
    switch d.strategy {
    case .supervised:
        if d.platformIsDarwin, d.fileExists(launchdPlistPath(home: d.home)) {
            if isLaunchdKeepAliveHandoff(d) {
                return launchdKeepAliveHandoff(d, onLog: onLog)
            }
            onLog("auto-update: launchd plist is not loaded; using foreground respawn")
            return await foregroundRespawn(d, onLog: onLog, onConfirmed: onConfirmed)
        }
        return await supervisedServiceRelaunch(d, onLog: onLog)

    case .respawn:
        if isLaunchdKeepAliveHandoff(d) {
            return launchdKeepAliveHandoff(d, onLog: onLog)
        }
        return await foregroundRespawn(d, onLog: onLog, onConfirmed: onConfirmed)
    }
}

private func isLaunchdKeepAliveHandoff(_ d: RestartPerformDeps) -> Bool {
    d.platformIsDarwin
        && d.fileExists(launchdPlistPath(home: d.home))
        && d.launchdJobIsLoaded()
}

private func launchdKeepAliveHandoff(
    _ d: RestartPerformDeps,
    onLog: @Sendable (String) -> Void
) -> RestartResult {
    onLog("auto-update: launchd KeepAlive handoff; exiting current bot")
    d.exitProcess(0)
    return .handedOff
}

private func foregroundRespawn(
    _ d: RestartPerformDeps,
    onLog: @Sendable (String) -> Void,
    onConfirmed: @escaping @Sendable () async -> Void
) async -> RestartResult {
    guard d.fileExists(d.dabBinaryPath) else {
        onLog("auto-update: respawn aborted (binary missing at \(d.dabBinaryPath)); current bot remains running")
        return .manualRestartRequired
    }

    guard let marker = d.makeReadyMarker() else {
        onLog("auto-update: respawn aborted (could not create successor readiness marker)")
        return .manualRestartRequired
    }
    defer { try? FileManager.default.removeItem(at: marker) }
    onLog("auto-update: starting successor \(d.dabBinaryPath) before handoff")
    guard d.spawnDetached(d.dabBinaryPath, [], ["DAB_SUCCESSOR_READY_FILE": marker.path]) else {
        onLog("auto-update: respawn aborted (successor launch failed)")
        return .manualRestartRequired
    }
    guard d.waitForReadyMarker(marker) else {
        onLog("auto-update: respawn aborted (successor did not reach gateway ready); current bot remains running")
        return .manualRestartRequired
    }
    onLog("auto-update: successor ready; exiting previous bot")
    await onConfirmed()
    d.exitProcess(0)
    return .handedOff
}

/// Other supervised environments keep the existing relaunch hook until they have a
/// platform-specific equivalent.
private func supervisedServiceRelaunch(
    _ d: RestartPerformDeps,
    onLog: @Sendable (String) -> Void
) async -> RestartResult {
    onLog("auto-update: supervised — full service stop+start via detached helper")
    guard d.runKickstart() else {
        onLog("auto-update: supervised relaunch spawn failed; current bot remains running")
        return .manualRestartRequired
    }
    onLog("auto-update: supervised relaunch helper spawned; exiting")
    d.exitProcess(0)
    return .handedOff
}

/// Whether the expected LaunchAgent is currently registered in this user's GUI domain.
/// A plist on disk alone can belong to a stopped foreground install, so it is not enough to
/// authorize an exit-only KeepAlive handoff.
public func isLaunchdJobLoaded(
    label: String = "com.discord-agent-bridge",
    uid: uid_t = getuid()
) -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = ["print", "gui/\(uid)/\(label)"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus == 0
    } catch {
        return false
    }
}

/// Production: fully stop then start the supervised service (detached).
/// - When `DAB_INSTALL_METHOD=homebrew`: `brew services restart dab` (only if not already using
///   `homebrewTrigger` — that path never reaches here).
/// - Else: launchd bootout/unload then bootstrap/load for the install.sh plist.
/// Optional Discord interaction token → webhook for final confirmed/failed (public channel).
public func relaunchSupervisedService(
    label: String = "com.discord-agent-bridge",
    home: String = NSHomeDirectory(),
    env: [String: String] = ProcessInfo.processInfo.environment,
    applicationId: String = "",
    interactionToken: String = "",
    spawnDetached: @escaping @Sendable (String, [String], [String: String]) -> Bool = { path, args, environment in
        spawnDetachedDab(path: path, args: args, environment: environment)
    }
) -> Bool {
    let extraEnv: [String: String] = [
        "DAB_RELAUNCH_APP_ID": applicationId,
        "DAB_RELAUNCH_TOKEN": interactionToken,
        "DAB_RELAUNCH_HOME": home,
        "DAB_RELAUNCH_LABEL": label,
    ]
    if env["DAB_INSTALL_METHOD"] == "homebrew" {
        return spawnTempBash(supervisedRelaunchScriptBrew(), extraEnv: extraEnv, spawnDetached: spawnDetached)
    }
    return spawnTempBash(
        supervisedRelaunchScriptLaunchd(label: label, home: home),
        extraEnv: extraEnv,
        spawnDetached: spawnDetached
    )
}

/// Backward-compatible name — full stop+start relaunch.
public func launchctlKickstart(label: String = "com.discord-agent-bridge") -> Bool {
    relaunchSupervisedService(label: label)
}

/// Shared shell helpers: log, webhook with retries, self-delete.
private let supervisedRelaunchShellPreamble = #"""
set -u
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/local/sbin:/usr/bin:/bin:$PATH"
LOG_DIR="${HOME}/.dab/logs"
LOG_FILE="${LOG_DIR}/supervised-relaunch.log"
mkdir -p "$LOG_DIR"
log() { printf '%s [supervised-relaunch] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG_FILE"; }
json_escape() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  printf '%s' "$s"
}
# Discord interaction followup webhook — retry on transient/404 (token propagation).
notify() {
  local msg="$1"
  log "notify: $msg"
  local app="${DAB_RELAUNCH_APP_ID:-}"
  local tok="${DAB_RELAUNCH_TOKEN:-}"
  if [ -z "$app" ] || [ -z "$tok" ]; then
    log "webhook skipped (no app id/token)"
    return 0
  fi
  local try code body
  for try in 1 2 3 4 5; do
    body="$(mktemp)"
    code="$(curl -sS -o "$body" -w '%{http_code}' -X POST \
      "https://discord.com/api/v10/webhooks/${app}/${tok}?wait=true" \
      -H "Content-Type: application/json" \
      -d "{\"content\": \"$(json_escape "$msg")\"}" 2>>"$LOG_FILE")" || code="curl-fail"
    log "webhook try=${try} HTTP=${code} body=$(head -c 200 "$body" 2>/dev/null | tr '\n' ' ')"
    rm -f "$body"
    case "$code" in
      200|204) return 0 ;;
    esac
    sleep $((try * 2))
  done
  log "webhook FAILED after retries"
  return 1
}
cleanup() { rm -f "$0" 2>/dev/null || true; }
trap cleanup EXIT
log "=== relaunch start pid=$$ ==="
"""#

private func supervisedRelaunchScriptBrew() -> String {
    // stop → start with retries; if still down, try start again (rollback of service state).
    supervisedRelaunchShellPreamble + #"""
sleep 2
brew_dab_started() {
  brew services list 2>/dev/null | awk '$1=="dab" && $2=="started" {found=1} END{exit !found}'
}
attempt_restart() {
  local n="$1"
  log "brew services restart dab (attempt $n)"
  brew services stop dab >>"$LOG_FILE" 2>&1 || true
  sleep 1
  brew services start dab >>"$LOG_FILE" 2>&1 || brew services restart dab >>"$LOG_FILE" 2>&1 || return 1
  local i
  for i in $(seq 1 30); do
    if brew_dab_started; then return 0; fi
    sleep 1
  done
  return 1
}
ok=0
for attempt in 1 2 3; do
  if attempt_restart "$attempt"; then
    ok=1
    break
  fi
  log "attempt $attempt failed; retrying"
  sleep 2
done
if [ "$ok" -eq 1 ]; then
  log "brew service started"
  exit 0
fi
log "FAILED: brew service not started after retries"
notify "⚠️ 설치는 완료됐지만 서비스 재기동/기동 확인에 실패했어요. \`brew services restart dab\` 를 수동 실행해 주세요. 로그: \`~/.dab/logs/supervised-relaunch.log\`"
exit 1
"""#
}

private func supervisedRelaunchScriptLaunchd(label: String, home: String) -> String {
    let plist = launchdPlistPath(home: home)
    let uid = getuid()
    let safePlist = plist.replacingOccurrences(of: "'", with: "'\\''")
    let safeLabel = label.replacingOccurrences(of: "'", with: "'\\''")
    // Full stop (bootout/unload) then start (bootstrap/load) with retries + final load recovery.
    return supervisedRelaunchShellPreamble + """
PLIST='\(safePlist)'
DOMAIN='gui/\(uid)'
LABEL='\(safeLabel)'
BIN="${HOME}/.dab/bin/dab"
service_running() {
  if [ -x "$BIN" ] && pgrep -f "$BIN" >/dev/null 2>&1; then return 0; fi
  if /bin/launchctl print "$DOMAIN/$LABEL" 2>/dev/null | grep -q "state = running"; then return 0; fi
  return 1
}
stop_service() {
  log "stop service DOMAIN=$DOMAIN LABEL=$LABEL"
  /bin/launchctl bootout "$DOMAIN/$LABEL" 2>>"$LOG_FILE" \\
    || /bin/launchctl unload "$PLIST" 2>>"$LOG_FILE" \\
    || true
  sleep 1
}
start_service() {
  log "start service"
  if /bin/launchctl bootstrap "$DOMAIN" "$PLIST" 2>>"$LOG_FILE"; then
    /bin/launchctl enable "$DOMAIN/$LABEL" 2>>"$LOG_FILE" || true
    /bin/launchctl kickstart -k "$DOMAIN/$LABEL" 2>>"$LOG_FILE" || true
    return 0
  fi
  /bin/launchctl load -w "$PLIST" 2>>"$LOG_FILE"
}
wait_running() {
  local i
  for i in $(seq 1 30); do
    if service_running; then return 0; fi
    sleep 1
  done
  return 1
}
sleep 2
ok=0
for attempt in 1 2 3; do
  log "relaunch attempt $attempt"
  stop_service
  if start_service && wait_running; then
    ok=1
    break
  fi
  log "attempt $attempt failed"
  sleep 2
done
# Recovery: one more load without stop (in case bootout left job missing).
if [ "$ok" -ne 1 ]; then
  log "recovery: final load -w"
  /bin/launchctl load -w "$PLIST" 2>>"$LOG_FILE" || true
  if wait_running; then ok=1; fi
fi
if [ "$ok" -eq 1 ]; then
  log "process/service running"
  exit 0
fi
log "FAILED: service down after stop+start retries"
notify "⚠️ 설치는 완료됐지만 서비스 재기동에 실패했어요(봇이 내려가 있을 수 있음). 수동: launchctl load -w $PLIST 또는 install.sh. 로그: ~/.dab/logs/supervised-relaunch.log"
exit 1
"""
}

private func spawnTempBash(
    _ script: String,
    extraEnv: [String: String] = [:],
    spawnDetached: @escaping @Sendable (String, [String], [String: String]) -> Bool
) -> Bool {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("dab-supervised-relaunch-\(UUID().uuidString).sh")
    do {
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    } catch {
        return false
    }
    return spawnDetached("/bin/bash", [url.path], extraEnv)
}

/// Detached re-exec of the installed dab binary (foreground / unsupervised runs).
public func spawnDetachedDab(path: String, args: [String] = [], environment: [String: String] = [:]) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.standardInput = FileHandle.nullDevice
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    // Inherit env so DISCORD_BOT_TOKEN etc. still apply for foreground restarts.
    p.environment = ProcessInfo.processInfo.environment.merging(environment, uniquingKeysWith: { _, new in new })
    do {
        try p.run()
        // Do not wait — hand off and let caller exit.
        return true
    } catch {
        return false
    }
}

/// Homebrew installs restart via `brew services` from a detached tap script — the process
/// being replaced cannot safely own upgrade → verify → rollback. Returns true once the script
/// has been spawned (never waits for it). Returns false when env is incomplete or spawn fails;
/// callers that detect Homebrew (`DAB_INSTALL_METHOD=homebrew`) must **not** fall through to the
/// source install path (dual-path block in `AutoUpdater.approve`).
public func triggerHomebrewSelfUpdateIfConfigured(
    applicationId: String,
    interactionToken: String,
    env: [String: String] = ProcessInfo.processInfo.environment,
    spawnDetached: @escaping @Sendable (String, [String], [String: String]) -> Bool = { path, args, environment in
        spawnDetachedDab(path: path, args: args, environment: environment)
    }
) -> Bool {
    guard env["DAB_INSTALL_METHOD"] == "homebrew" else { return false }
    guard let script = env["DAB_HOMEBREW_UPDATE_SCRIPT"], !script.isEmpty else { return false }
    // Refuse dual path early when the tap script is missing or not executable.
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: script, isDirectory: &isDir), !isDir.boolValue else {
        return false
    }
    return spawnDetached(script, [applicationId, interactionToken], [:])
}

/// A respawned foreground bot writes this only after Discord's gateway emits READY. The old
/// process waits for it before exiting, permitting the user-approved brief overlap safely.
public func signalSuccessorReadyIfRequested(env: [String: String] = ProcessInfo.processInfo.environment) {
    guard let path = env["DAB_SUCCESSOR_READY_FILE"], !path.isEmpty else { return }
    FileManager.default.createFile(atPath: path, contents: Data("ready".utf8))
}

// MARK: - High-level install entry (wiring)

/// Discover + run install plan. Returns install result; never throws.
public func installLatestSelfUpdate(
    dryRun: Bool = false,
    runner: UpdateCommandRunner? = nil,
    onLog: @escaping @Sendable (String) -> Void = { _ in }
) async -> UpdateInstallResult {
    guard let plan = discoverUpdateInstallPlan(dryRun: dryRun) else {
        onLog("auto-update: no install plan (missing repo install.sh / release asset)")
        return UpdateInstallResult(
            ok: false,
            code: 1,
            stderr: "no install plan: set up a full checkout with swift/scripts/install.sh or DAB_UPDATE_RELEASE_ASSET"
        )
    }
    let run = runner ?? { exe, args, env in
        await runUpdateCommand(executable: exe, args: args, extraEnv: env)
    }
    let result = await runUpdateInstallPlan(plan, runner: run, onLog: onLog)
    return result.asInstallResult
}
