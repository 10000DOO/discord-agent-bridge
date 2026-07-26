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
}

@Suite("ProcessSidecarTransport.wellKnownUserBinDirs")
struct WellKnownUserBinDirsTests {
    @Test func macOSOrderIsHomeDirsThenHomebrewThenUsrLocal() {
        #expect(ProcessSidecarTransport.wellKnownUserBinDirs(homeDir: "/Users/alice") == [
            "/Users/alice/.local/bin",
            "/Users/alice/.grok/bin",
            "/Users/alice/.cargo/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
        ])
    }
}
