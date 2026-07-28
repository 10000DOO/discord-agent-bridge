import Foundation
import Testing
@testable import DiscordAgentBridge

@Suite("buildUpdateInstallPlan")
struct BuildUpdateInstallPlanTests {
    @Test func repoScriptWithGit() {
        let plan = buildUpdateInstallPlan(UpdateInstallDiscover(
            repoRoot: "/repo",
            installScriptPath: "/repo/swift/scripts/install.sh",
            hasGit: true
        ))
        #expect(plan?.steps == [
            .gitPull(repoRoot: "/repo"),
            .runInstallScript(path: "/repo/swift/scripts/install.sh", dryRun: false),
        ])
    }

    @Test func repoScriptWithoutGitSkipsPull() {
        let plan = buildUpdateInstallPlan(UpdateInstallDiscover(
            repoRoot: "/repo",
            installScriptPath: "/repo/swift/scripts/install.sh",
            hasGit: false
        ))
        #expect(plan?.steps == [
            .runInstallScript(path: "/repo/swift/scripts/install.sh", dryRun: false),
        ])
    }

    @Test func dryRunFlagOnScript() {
        let plan = buildUpdateInstallPlan(UpdateInstallDiscover(
            installScriptPath: "/x/install.sh",
            dryRun: true
        ))
        #expect(plan?.steps == [.runInstallScript(path: "/x/install.sh", dryRun: true)])
    }

    @Test func nilWhenNoScriptAndNoAsset() {
        #expect(buildUpdateInstallPlan(UpdateInstallDiscover()) == nil)
    }

    @Test func releaseAssetPreferredOverScript() {
        let plan = buildUpdateInstallPlan(UpdateInstallDiscover(
            repoRoot: "/repo",
            installScriptPath: "/repo/swift/scripts/install.sh",
            hasGit: true,
            releaseAssetURL: "https://example.com/dab",
            releaseAssetDest: "/tmp/dab.new"
        ))
        #expect(plan?.steps == [
            .downloadReleaseAsset(url: "https://example.com/dab", dest: "/tmp/dab.new"),
        ])
    }
}

@Suite("runUpdateInstallPlan")
struct RunUpdateInstallPlanTests {
    @Test func commandDrainsLargeStdoutAndStderrConcurrently() async {
        let result = await runUpdateCommand(
            executable: "/bin/sh",
            args: ["-c", "(yes stdout | head -c 131072) & (yes stderr | head -c 131072 >&2) & wait"],
            timeoutMs: 5_000
        )
        #expect(!result.timedOut)
        #expect(result.exitCode == 0)
        #expect(result.stdout.utf8.count == 131_072)
        #expect(result.stderr.utf8.count == 131_072)
    }

    @Test func successRunsAllStepsInOrder() async {
        let calls = LockedBox<[(String, [String], [String: String])]>([])
        let plan = UpdateInstallPlan(steps: [
            .gitPull(repoRoot: "/repo"),
            .runInstallScript(path: "/repo/swift/scripts/install.sh", dryRun: false),
        ])
        let result = await runUpdateInstallPlan(plan, runner: { exe, args, env in
            calls.withLock { $0.append((exe, args, env)) }
            return ProcessCapture(stdout: "ok", stderr: "", exitCode: 0, timedOut: false)
        })
        #expect(result.ok)
        #expect(result.completedSteps == 2)
        let c = calls.withLock { $0 }
        #expect(c.count == 2)
        #expect(c[0].0 == "git")
        #expect(c[0].1 == ["-C", "/repo", "pull", "--ff-only"])
        #expect(c[1].0 == "/bin/bash")
        #expect(c[1].1 == ["/repo/swift/scripts/install.sh"])
        #expect(c[1].2["DAB_INSTALL_SKIP_LAUNCHCTL"] == "1")
    }

    @Test func gitFailureStopsBeforeInstall() async {
        let calls = LockedBox(0)
        let plan = UpdateInstallPlan(steps: [
            .gitPull(repoRoot: "/repo"),
            .runInstallScript(path: "/s", dryRun: false),
        ])
        let result = await runUpdateInstallPlan(plan, runner: { _, _, _ in
            let n = calls.withLock { v -> Int in v += 1; return v }
            if n == 1 {
                return ProcessCapture(stdout: "", stderr: "conflict", exitCode: 1, timedOut: false)
            }
            return ProcessCapture(exitCode: 0)
        })
        #expect(!result.ok)
        #expect(result.completedSteps == 0)
        #expect(result.stderr.contains("conflict"))
        #expect(calls.withLock { $0 } == 1)
    }

    @Test func installFailureSurfacesStderr() async {
        let plan = UpdateInstallPlan(steps: [
            .runInstallScript(path: "/s", dryRun: false),
        ])
        let result = await runUpdateInstallPlan(plan, runner: { _, _, _ in
            ProcessCapture(stdout: "", stderr: "build boom", exitCode: 2, timedOut: false)
        })
        #expect(!result.ok)
        #expect(result.code == 2)
        #expect(result.stderr.contains("build boom"))
        #expect(result.asInstallResult.ok == false)
    }

    @Test func dryRunPassesFlag() async {
        let argsBox = LockedBox<[String]>([])
        let plan = UpdateInstallPlan(steps: [
            .runInstallScript(path: "/s", dryRun: true),
        ])
        let result = await runUpdateInstallPlan(plan, runner: { _, args, _ in
            argsBox.withLock { $0 = args }
            return ProcessCapture(exitCode: 0)
        })
        #expect(result.ok)
        #expect(argsBox.withLock { $0 } == ["/s", "--dry-run"])
    }

    @Test func emptyPlanFails() async {
        let result = await runUpdateInstallPlan(UpdateInstallPlan(steps: []), runner: { _, _, _ in
            ProcessCapture(exitCode: 0)
        })
        #expect(!result.ok)
        #expect(result.stderr.contains("empty"))
    }

    @Test func downloadThenPromoteNew() async {
        let calls = LockedBox<[String]>([])
        let plan = UpdateInstallPlan(steps: [
            .downloadReleaseAsset(url: "https://ex/dab", dest: "/tmp/dab.new"),
        ])
        let result = await runUpdateInstallPlan(plan, runner: { exe, args, _ in
            calls.withLock { $0.append(exe + " " + args.joined(separator: " ")) }
            return ProcessCapture(exitCode: 0)
        })
        #expect(result.ok)
        let c = calls.withLock { $0 }
        #expect(c.contains { $0.contains("curl") && $0.contains("https://ex/dab") })
        #expect(c.contains { $0.contains("mv") && $0.contains("/tmp/dab.new") && $0.contains("/tmp/dab") })
        #expect(c.contains { $0.contains("chmod") })
    }
}

@Suite("detectRestartStrategy / performRestart")
struct RestartStrategyTests {
    @Test func supervisedWhenMarkerSet() {
        let s = detectRestartStrategy(RestartDetectDeps(
            platformIsDarwin: true,
            env: ["DAB_SUPERVISED": "1"],
            home: "/home/u",
            fileExists: { _ in false }
        ))
        #expect(s == .supervised)
    }

    @Test func supervisedWhenPlistExists() {
        let plist = launchdPlistPath(home: "/home/u")
        let s = detectRestartStrategy(RestartDetectDeps(
            platformIsDarwin: true,
            env: [:],
            home: "/home/u",
            fileExists: { $0 == plist }
        ))
        #expect(s == .supervised)
    }

    @Test func respawnWhenUnsupervised() {
        let s = detectRestartStrategy(RestartDetectDeps(
            platformIsDarwin: true,
            env: [:],
            home: "/home/u",
            fileExists: { _ in false }
        ))
        #expect(s == .respawn)
    }

    @Test func windowsAlwaysRespawnsEvenWithMarkerSet() {
        let s = detectRestartStrategy(RestartDetectDeps(
            platformIsDarwin: false,
            platformIsWindows: true,
            env: ["DAB_SUPERVISED": "1"],
            home: "/home/u",
            fileExists: { _ in true }
        ))
        #expect(s == .respawn)
    }

    @Test func linuxRespawnsWhenNoSystemdUnit() {
        let s = detectRestartStrategy(RestartDetectDeps(
            platformIsDarwin: false,
            env: [:],
            home: "/home/u",
            fileExists: { _ in false }
        ))
        #expect(s == .respawn)
    }

    @Test func linuxSupervisedWhenSystemdUnitExists() {
        let unit = systemdUnitPath(home: "/home/u")
        let s = detectRestartStrategy(RestartDetectDeps(
            platformIsDarwin: false,
            env: [:],
            home: "/home/u",
            fileExists: { $0 == unit }
        ))
        #expect(s == .supervised)
    }

    @Test func performRestartSupervisedRelaunchesAndExits() async {
        let relaunch = LockedBox(0)
        let exits = LockedBox<[Int32]>([])
        let confirmed = LockedBox(0)
        let result = await performRestart(
            RestartPerformDeps(
                strategy: .supervised,
                platformIsDarwin: true,
                home: "/h",
                fileExists: { $0 == launchdPlistPath(home: "/h") },
                runKickstart: { relaunch.withLock { $0 += 1 }; return true },
                spawnDetached: { _, _, _ in true },
                exitProcess: { code in exits.withLock { $0.append(code) } }
            ),
            onConfirmed: { confirmed.withLock { $0 += 1 } }
        )
        // Confirmed comes from detached webhook, not onConfirmed, for supervised.
        #expect(confirmed.withLock { $0 } == 0)
        #expect(relaunch.withLock { $0 } == 1)
        #expect(exits.withLock { $0 } == [0])
        #expect(result == .handedOff)
    }

    @Test func performRestartSupervisedRelaunchFailureIsManual() async {
        let result = await performRestart(
            RestartPerformDeps(
                strategy: .supervised,
                platformIsDarwin: true,
                home: "/h",
                runKickstart: { false },
                exitProcess: { _ in }
            )
        )
        #expect(result == .manualRestartRequired)
    }

    @Test func performRestartRespawnSpawnsBinary() async {
        let spawn = LockedBox<[(String, [String])]>([])
        let exits = LockedBox<[Int32]>([])
        let confirmed = LockedBox(0)
        let result = await performRestart(
            RestartPerformDeps(
                strategy: .respawn,
                platformIsDarwin: true,
                home: "/h",
                dabBinaryPath: "/h/.dab/bin/dab",
                fileExists: { $0 == "/h/.dab/bin/dab" },
                runKickstart: { false },
                spawnDetached: { path, args, _ in
                    spawn.withLock { $0.append((path, args)) }
                    return true
                },
                makeReadyMarker: { URL(fileURLWithPath: "/tmp/dab-ready") },
                waitForReadyMarker: { _ in true },
                exitProcess: { code in exits.withLock { $0.append(code) } }
            ),
            onConfirmed: { confirmed.withLock { $0 += 1 } }
        )
        #expect(spawn.withLock { $0.map(\.0) } == ["/h/.dab/bin/dab"])
        #expect(confirmed.withLock { $0 } == 1)
        #expect(exits.withLock { $0 } == [0])
        #expect(result == .handedOff)
    }

    @Test func performRestartRespawnWithLaunchdPlistUsesServiceRelaunch() async {
        let relaunch = LockedBox(0)
        let exits = LockedBox<[Int32]>([])
        let confirmed = LockedBox(0)
        let result = await performRestart(
            RestartPerformDeps(
                strategy: .respawn,
                platformIsDarwin: true,
                home: "/h",
                fileExists: { $0 == launchdPlistPath(home: "/h") },
                runKickstart: { relaunch.withLock { $0 += 1 }; return true },
                exitProcess: { code in exits.withLock { $0.append(code) } }
            ),
            onConfirmed: { confirmed.withLock { $0 += 1 } }
        )
        #expect(confirmed.withLock { $0 } == 0)
        #expect(relaunch.withLock { $0 } == 1)
        #expect(exits.withLock { $0 } == [0])
        #expect(result == .handedOff)
    }

    @Test func performRestartKeepsCurrentBotWhenSuccessorNeverBecomesReady() async {
        let exits = LockedBox<[Int32]>([])
        let result = await performRestart(
            RestartPerformDeps(
                strategy: .respawn,
                platformIsDarwin: false,
                dabBinaryPath: "/tmp/dab",
                fileExists: { $0 == "/tmp/dab" },
                spawnDetached: { _, _, _ in true },
                makeReadyMarker: { URL(fileURLWithPath: "/tmp/dab-not-ready") },
                waitForReadyMarker: { _ in false },
                exitProcess: { code in exits.withLock { $0.append(code) }
                }
            )
        )
        #expect(exits.withLock { $0 }.isEmpty)
        #expect(result == .manualRestartRequired)
    }
}

@Suite("triggerHomebrewSelfUpdateIfConfigured")
struct TriggerHomebrewSelfUpdateTests {
    private func tempExecutableScript() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dab-hb-self-update-\(UUID().uuidString).sh")
        try "#!/bin/bash\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test func spawnsDetachedScriptWhenBothEnvVarsSet() throws {
        let script = try tempExecutableScript()
        defer { try? FileManager.default.removeItem(at: script) }
        let spawnCalls = LockedBox<[(String, [String], [String: String])]>([])
        let handled = triggerHomebrewSelfUpdateIfConfigured(
            applicationId: "app-1",
            interactionToken: "token-1",
            env: ["DAB_INSTALL_METHOD": "homebrew", "DAB_HOMEBREW_UPDATE_SCRIPT": script.path],
            spawnDetached: { path, args, environment in
                spawnCalls.withLock { $0.append((path, args, environment)) }
                return true
            }
        )
        #expect(handled)
        let calls = spawnCalls.withLock { $0 }
        #expect(calls.count == 1)
        #expect(calls[0].0 == script.path)
        #expect(calls[0].1 == ["app-1", "token-1"])
    }

    @Test func returnsFalseWhenScriptFileMissing() {
        let spawnCalls = LockedBox(0)
        let handled = triggerHomebrewSelfUpdateIfConfigured(
            applicationId: "app-1",
            interactionToken: "token-1",
            env: [
                "DAB_INSTALL_METHOD": "homebrew",
                "DAB_HOMEBREW_UPDATE_SCRIPT": "/tmp/dab-missing-self-update-\(UUID().uuidString).sh",
            ],
            spawnDetached: { _, _, _ in spawnCalls.withLock { $0 += 1 }; return true }
        )
        #expect(!handled)
        #expect(spawnCalls.withLock { $0 } == 0)
    }

    @Test func returnsFalseWhenNotInstalledViaHomebrew() throws {
        let script = try tempExecutableScript()
        defer { try? FileManager.default.removeItem(at: script) }
        let spawnCalls = LockedBox(0)
        let handled = triggerHomebrewSelfUpdateIfConfigured(
            applicationId: "app-1",
            interactionToken: "token-1",
            env: ["DAB_HOMEBREW_UPDATE_SCRIPT": script.path],
            spawnDetached: { _, _, _ in spawnCalls.withLock { $0 += 1 }; return true }
        )
        #expect(!handled)
        #expect(spawnCalls.withLock { $0 } == 0)
    }

    @Test func returnsFalseWhenScriptEnvMissing() {
        let spawnCalls = LockedBox(0)
        let handled = triggerHomebrewSelfUpdateIfConfigured(
            applicationId: "app-1",
            interactionToken: "token-1",
            env: ["DAB_INSTALL_METHOD": "homebrew"],
            spawnDetached: { _, _, _ in spawnCalls.withLock { $0 += 1 }; return true }
        )
        #expect(!handled)
        #expect(spawnCalls.withLock { $0 } == 0)
    }

    @Test func returnsFalseWhenScriptEnvEmpty() {
        let spawnCalls = LockedBox(0)
        let handled = triggerHomebrewSelfUpdateIfConfigured(
            applicationId: "app-1",
            interactionToken: "token-1",
            env: ["DAB_INSTALL_METHOD": "homebrew", "DAB_HOMEBREW_UPDATE_SCRIPT": ""],
            spawnDetached: { _, _, _ in spawnCalls.withLock { $0 += 1 }; return true }
        )
        #expect(!handled)
        #expect(spawnCalls.withLock { $0 } == 0)
    }
}

/// E2E-ish: capture generated supervised relaunch scripts and assert recovery/webhook contracts.
@Suite("supervised relaunch script contracts")
struct SupervisedRelaunchScriptContractTests {
    private func captureScript(
        env: [String: String],
        applicationId: String = "app-e2e",
        interactionToken: String = "tok-e2e"
    ) -> (ok: Bool, path: String, args: [String], extra: [String: String], body: String) {
        let captured = LockedBox<(String, [String], [String: String], String)>(("", [], [:], ""))
        let ok = relaunchSupervisedService(
            label: "com.discord-agent-bridge.test",
            home: "/tmp/dab-e2e-home",
            env: env,
            applicationId: applicationId,
            interactionToken: interactionToken,
            spawnDetached: { path, args, extra in
                var body = ""
                if let scriptPath = args.first,
                   let text = try? String(contentsOfFile: scriptPath, encoding: .utf8)
                {
                    body = text
                    // Clean up temp script so the suite does not litter /tmp.
                    try? FileManager.default.removeItem(atPath: scriptPath)
                }
                captured.withLock { $0 = (path, args, extra, body) }
                return true
            }
        )
        let snap = captured.withLock { $0 }
        return (ok, snap.0, snap.1, snap.2, snap.3)
    }

    @Test func launchdScriptHasWebhookRetriesAndLoadRecovery() {
        let r = captureScript(env: [:])
        #expect(r.ok)
        #expect(r.path == "/bin/bash")
        #expect(r.args.count == 1)
        #expect(r.extra["DAB_RELAUNCH_APP_ID"] == "app-e2e")
        #expect(r.extra["DAB_RELAUNCH_TOKEN"] == "tok-e2e")
        #expect(!r.body.isEmpty)
        #expect(r.body.contains("wait=true"))
        #expect(r.body.contains("for try in 1 2 3 4 5"))
        #expect(r.body.contains("recovery: final load -w"))
        #expect(r.body.contains("launchctl load -w"))
        #expect(r.body.contains("bootout"))
        #expect(r.body.contains("for attempt in 1 2 3"))
        #expect(r.body.contains("trap cleanup EXIT"))
        #expect(r.body.contains("json_escape"))
    }

    @Test func brewScriptHasStopStartRetriesAndWebhookRetries() {
        let r = captureScript(env: ["DAB_INSTALL_METHOD": "homebrew"])
        #expect(r.ok)
        #expect(!r.body.isEmpty)
        #expect(r.body.contains("wait=true"))
        #expect(r.body.contains("for try in 1 2 3 4 5"))
        #expect(r.body.contains("brew services stop dab"))
        #expect(r.body.contains("brew services start dab"))
        #expect(r.body.contains("for attempt in 1 2 3"))
        #expect(r.body.contains("brew_dab_started"))
    }

    @Test func webhookSkippedWhenTokenEmptyStillSpawns() {
        let r = captureScript(env: [:], applicationId: "", interactionToken: "")
        #expect(r.ok)
        #expect(r.body.contains("webhook skipped (no app id/token)"))
    }
}

@Suite("PID file (H17)")
struct PidFileTests {
    private func tempDir() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("dab-pidfile-\(UUID().uuidString)", isDirectory: true)
    }

    @Test func writePidFileWritesPidAsString() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try writePidFile(baseDir: dir, pid: 4242)
        let written = try String(contentsOf: pidFilePath(baseDir: dir), encoding: .utf8)
        #expect(written == "4242")
        #expect(pidFilePath(baseDir: dir).lastPathComponent == "agent.pid")
    }

    @Test func removePidFileDeletesExistingFile() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try writePidFile(baseDir: dir, pid: 1)
        removePidFile(baseDir: dir)
        #expect(!FileManager.default.fileExists(atPath: pidFilePath(baseDir: dir).path))
    }

    @Test func removePidFileNoOpWhenMissing() throws {
        let dir = tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        removePidFile(baseDir: dir) // must not throw/crash when agent.pid was never written
        #expect(!FileManager.default.fileExists(atPath: pidFilePath(baseDir: dir).path))
    }
}
