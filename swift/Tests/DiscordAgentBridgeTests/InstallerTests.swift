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

    @Test func performRestartSupervisedExitsAndMayKickstart() {
        let kick = LockedBox(0)
        let exits = LockedBox<[Int32]>([])
        let spawn = LockedBox(0)
        performRestart(
            RestartPerformDeps(
                strategy: .supervised,
                platformIsDarwin: true,
                home: "/h",
                fileExists: { $0 == launchdPlistPath(home: "/h") },
                runKickstart: { kick.withLock { $0 += 1 }; return true },
                spawnDetached: { _, _ in spawn.withLock { $0 += 1 }; return true },
                exitProcess: { code in exits.withLock { $0.append(code) } }
            )
        )
        #expect(kick.withLock { $0 } == 1)
        #expect(spawn.withLock { $0 } == 0)
        #expect(exits.withLock { $0 } == [0])
    }

    @Test func performRestartRespawnSpawnsBinary() {
        let spawn = LockedBox<[(String, [String])]>([])
        let exits = LockedBox<[Int32]>([])
        performRestart(
            RestartPerformDeps(
                strategy: .respawn,
                platformIsDarwin: true,
                home: "/h",
                dabBinaryPath: "/h/.dab/bin/dab",
                fileExists: { $0 == "/h/.dab/bin/dab" },
                runKickstart: { false },
                spawnDetached: { path, args in
                    spawn.withLock { $0.append((path, args)) }
                    return true
                },
                exitProcess: { code in exits.withLock { $0.append(code) } }
            )
        )
        #expect(spawn.withLock { $0.map(\.0) } == ["/h/.dab/bin/dab"])
        #expect(exits.withLock { $0 } == [0])
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
