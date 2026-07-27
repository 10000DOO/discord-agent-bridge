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
        self.runKickstart = runKickstart
        self.spawnDetached = spawnDetached
        self.makeReadyMarker = makeReadyMarker
        self.waitForReadyMarker = waitForReadyMarker
        self.exitProcess = exitProcess
    }
}

/// Perform post-install restart. launchd/systemd own one service slot, so `kickstart -k` first
/// terminates the old process and cannot prove a successor gateway READY marker. Keep the old bot
/// alive on every supervised path until a supervisor-level handoff protocol exists. A successful
/// foreground successor invokes `onHandoff` before the old process exits so its caller can publish
/// the installed status without claiming success for a deferred restart.
public func performRestart(
    _ d: RestartPerformDeps,
    onLog: @Sendable (String) -> Void = { _ in },
    onHandoff: @escaping @Sendable () async -> Void = {}
) async -> RestartResult {
    switch d.strategy {
    case .supervised:
        onLog("auto-update: supervised restart deferred; READY handoff is unavailable, current bot remains running")
        return .manualRestartRequired

    case .respawn:
        if d.platformIsDarwin, d.fileExists(launchdPlistPath(home: d.home)) {
            onLog("auto-update: launchd respawn deferred; READY handoff is unavailable, current bot remains running")
            return .manualRestartRequired
        }
        if d.fileExists(d.dabBinaryPath) {
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
        } else {
            onLog("auto-update: respawn aborted (binary missing at \(d.dabBinaryPath)); current bot remains running")
            return .manualRestartRequired
        }
        await onHandoff()
        d.exitProcess(0)
        return .handedOff
    }
}

/// Production kickstart: `launchctl kickstart -k gui/<uid>/com.discord-agent-bridge`.
public func launchctlKickstart(label: String = "com.discord-agent-bridge") -> Bool {
    let uid = getuid()
    let target = "gui/\(uid)/\(label)"
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = ["kickstart", "-k", target]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do {
        try p.run()
        p.waitUntilExit()
        return p.terminationStatus == 0
    } catch {
        return false
    }
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
