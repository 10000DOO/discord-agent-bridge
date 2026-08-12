import Testing
import Foundation
@testable import DiscordAgentBridge

// Mirrors src/core/resolveCli.test.ts (resolveCliCommand / wellKnownUserBinDirs behaviour).
// All cases inject env/homeDir/isExecutable so this never touches the real PATH or filesystem
// (see GrokSessionBridgeTests ConfigStore.shared incident, commit 63def8e, for why that matters).
@Suite("ProcessSidecarTransport.resolveExecutable")
struct ResolveExecutableTests {
    private func resolve(_ command: String, path: String, homeDir: String = "/home/alice", existing: Set<String>) -> String {
        ProcessSidecarTransport.resolveExecutable(command, env: ["PATH": path], homeDir: homeDir, isExecutable: { existing.contains($0) })
    }

    @Test func pathHitWinsOverWellKnown() {
        let pathHit = "/opt/tools/bin/grok"
        let wellKnownHit = "/home/alice/.grok/bin/grok"
        let found = resolve("grok", path: "/opt/tools/bin", existing: [pathHit, wellKnownHit])
        #expect(found == pathHit)
    }

    @Test func fallsBackToWellKnownDirWhenPathMisses() {
        let wellKnownHit = "/home/alice/.local/bin/grok"
        let found = resolve("grok", path: "/usr/bin:/bin", existing: [wellKnownHit])
        #expect(found == wellKnownHit)
    }

    @Test func macOSHomebrewDirIsSearched() {
        // #if os(macOS) branch — this test target builds for macOS, so it's exercised for real.
        let brewHit = "/opt/homebrew/bin/grok"
        let found = resolve("grok", path: "/usr/bin:/bin", existing: [brewHit])
        #expect(found == brewHit)
    }

    @Test func returnsBareCommandWhenNotFoundAnywhere() {
        let found = resolve("grok", path: "/usr/bin:/bin", existing: [])
        #expect(found == "grok")
    }

    @Test func commandWithSlashBypassesSearchEntirely() {
        let found = ProcessSidecarTransport.resolveExecutable(
            "./grok",
            env: ["PATH": "/usr/bin"],
            homeDir: "/home/alice",
            isExecutable: { _ in false }
        )
        #expect(found == "./grok")
    }

    // M5: a directory can carry the execute (search) bit, so the production default must not
    // mistake it for a runnable command — exercises the real `isExecutable` default (no override),
    // against a real temp dir, with a random command name so no real system PATH entry can collide.
    @Test func directoryIsNotMistakenForExecutable() throws {
        let fm = FileManager.default
        let command = "dab-test-\(UUID().uuidString)"
        let binDir = fm.temporaryDirectory.appendingPathComponent("dab-test-bin-\(UUID().uuidString)")
        let collidingDir = binDir.appendingPathComponent(command)
        try fm.createDirectory(at: collidingDir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: binDir) }

        let found = ProcessSidecarTransport.resolveExecutable(
            command,
            env: ["PATH": binDir.path],
            homeDir: "/nonexistent-home-\(UUID().uuidString)"
        )
        #expect(found == command)
    }
}

@Suite("ProcessSidecarTransport.wellKnownUserBinDirs")
struct WellKnownUserBinDirsTests {
    @Test func macOSOrderIsHomeDirsThenNodeManagersThenHomebrewThenUsrLocal() {
        #expect(ProcessSidecarTransport.wellKnownUserBinDirs(homeDir: "/Users/alice", env: [:]) == [
            "/Users/alice/.local/bin",
            "/Users/alice/.grok/bin",
            "/Users/alice/.cargo/bin",
            "/Users/alice/.nvm/current/bin",
            "/Users/alice/.local/share/fnm/aliases/default/bin",
            "/Users/alice/.volta/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ])
    }

    // H1: nvm/fnm export env vars pointing at the active version's dir directly; prefer those
    // over the static default fallback when present.
    @Test func nvmBinAndFnmDirEnvVarsOverrideDefaults() {
        let dirs = ProcessSidecarTransport.wellKnownUserBinDirs(
            homeDir: "/Users/alice",
            env: ["NVM_BIN": "/Users/alice/.nvm/versions/node/v20.11.0/bin", "FNM_DIR": "/Users/alice/.fnm"]
        )
        #expect(dirs.contains("/Users/alice/.nvm/versions/node/v20.11.0/bin"))
        #expect(dirs.contains("/Users/alice/.fnm/aliases/default/bin"))
        #expect(!dirs.contains("/Users/alice/.nvm/current/bin"))
    }

    // A launchd/systemd spawn exports neither NVM_BIN nor NVM_DIR. `current/bin` alone resolved
    // nothing there because nvm-sh does not create that symlink, so the `default` alias and the
    // installed-version scan have to carry it (mirrors scripts/find-node.sh:93-103).
    @Test func nvmDefaultAliasResolvesWithoutNvmBin() throws {
        let root = try makeFakeNvm(versions: ["v20.11.0", "v24.12.0"], defaultAlias: "20.11.0")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let dirs = ProcessSidecarTransport.wellKnownUserBinDirs(homeDir: "/Users/alice", env: ["NVM_DIR": root])
        // The alias wins over the newer install, and both stay ahead of the legacy symlink.
        let nvmDirs = dirs.filter { $0.hasPrefix(root) }
        #expect(nvmDirs == [
            "\(root)/versions/node/v20.11.0/bin",
            "\(root)/versions/node/v24.12.0/bin",
            "\(root)/current/bin",
        ])
    }

    @Test func newestInstalledVersionLeadsWhenAliasIsUnresolvable() throws {
        // "lts/*" points at another alias — not resolvable without running nvm itself.
        let root = try makeFakeNvm(versions: ["v9.1.0", "v24.12.0", "v20.11.0"], defaultAlias: "lts/*")
        defer { try? FileManager.default.removeItem(atPath: root) }
        let dirs = ProcessSidecarTransport.wellKnownUserBinDirs(homeDir: "/Users/alice", env: ["NVM_DIR": root])
        let nvmDirs = dirs.filter { $0.hasPrefix(root) }
        // Semver order, not lexical — v9.1.0 must not outrank v24.12.0.
        #expect(nvmDirs == [
            "\(root)/versions/node/v24.12.0/bin",
            "\(root)/versions/node/v20.11.0/bin",
            "\(root)/versions/node/v9.1.0/bin",
            "\(root)/current/bin",
        ])
    }

    @Test func nvmDirsKeepTheirSlotInTheOverallOrder() throws {
        let root = try makeFakeNvm(versions: ["v24.12.0"], defaultAlias: nil)
        defer { try? FileManager.default.removeItem(atPath: root) }
        let dirs = ProcessSidecarTransport.wellKnownUserBinDirs(homeDir: "/Users/alice", env: ["NVM_DIR": root])
        #expect(dirs.prefix(3) == ["/Users/alice/.local/bin", "/Users/alice/.grok/bin", "/Users/alice/.cargo/bin"])
        #expect(dirs[3] == "\(root)/versions/node/v24.12.0/bin")
        #expect(dirs.suffix(2) == ["/opt/homebrew/bin", "/usr/local/bin"])
    }

    /// Real temp tree — the alias file read is a plain `String(contentsOfFile:)` inside the
    /// resolver, so a fake `listDir` alone would not exercise it.
    private func makeFakeNvm(versions: [String], defaultAlias: String?) throws -> String {
        let fm = FileManager.default
        let root = NSTemporaryDirectory() + "dab-nvm-\(UUID().uuidString)"
        for version in versions {
            try fm.createDirectory(atPath: "\(root)/versions/node/\(version)/bin", withIntermediateDirectories: true)
        }
        if let defaultAlias {
            try fm.createDirectory(atPath: "\(root)/alias", withIntermediateDirectories: true)
            try Data("\(defaultAlias)\n".utf8).write(to: URL(fileURLWithPath: "\(root)/alias/default"))
        }
        return root
    }
}

// Claude had no PATH augmentation at all until this suite's subject was wired in — a launchd
// `brew services` spawn left every stdio MCP server unresolvable. Mirrors GrokSpawnTests.
@Suite("claudeChildEnvironment")
struct ClaudeChildEnvironmentTests {
    @Test func prependsWellKnownDirsOntoExistingPath() {
        let env = claudeChildEnvironment(
            baseEnv: ["PATH": "/usr/bin:/bin", "OTHER": "kept"],
            homeDir: "/Users/alice"
        )
        #expect(env["OTHER"] == "kept")
        let dirs = env["PATH"]?.split(separator: ":").map(String.init) ?? []
        #expect(dirs.suffix(2) == ["/usr/bin", "/bin"])
        #expect(dirs.contains("/Users/alice/.local/bin"))
        #expect(dirs.contains("/opt/homebrew/bin"))
    }

    @Test func doesNotDuplicateADirAlreadyOnPath() {
        let env = claudeChildEnvironment(
            baseEnv: ["PATH": "/Users/alice/.cargo/bin:/usr/bin"],
            homeDir: "/Users/alice"
        )
        let dirs = env["PATH"]?.split(separator: ":").map(String.init) ?? []
        #expect(dirs.filter { $0 == "/Users/alice/.cargo/bin" }.count == 1)
    }

    // The launchd case the fix exists for: a bare supervisor PATH must still gain the user dirs.
    @Test func augmentsEvenABareLaunchdPath() {
        let env = claudeChildEnvironment(
            baseEnv: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "NVM_BIN": "/Users/alice/.nvm/versions/node/v24.12.0/bin"],
            homeDir: "/Users/alice"
        )
        let dirs = env["PATH"]?.split(separator: ":").map(String.init) ?? []
        #expect(dirs.first == "/Users/alice/.local/bin")
        #expect(dirs.contains("/Users/alice/.nvm/versions/node/v24.12.0/bin"))
        #expect(dirs.suffix(4) == ["/usr/bin", "/bin", "/usr/sbin", "/sbin"])
    }
}
