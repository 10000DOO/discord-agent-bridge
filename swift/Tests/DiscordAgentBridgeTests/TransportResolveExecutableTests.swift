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
}
