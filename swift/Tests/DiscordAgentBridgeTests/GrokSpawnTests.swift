import Testing
import Foundation
@testable import DiscordAgentBridge

// Mirrors TS acpClient.ts:246-256 augmentPath (M6-grok): child env PATH gets the well-known
// user/local bin dirs prepended so tools grok spawns internally still resolve.
@Suite("grokChildEnvironment")
struct GrokChildEnvironmentTests {
    @Test func prependsWellKnownDirsOntoExistingPath() {
        let env = grokChildEnvironment(
            baseEnv: ["PATH": "/usr/bin:/bin", "OTHER": "kept"],
            homeDir: "/Users/alice"
        )
        #expect(env["OTHER"] == "kept")
        let dirs = env["PATH"]?.split(separator: ":").map(String.init) ?? []
        // Well-known dirs come first, existing PATH entries are preserved at the end untouched.
        #expect(dirs.suffix(2) == ["/usr/bin", "/bin"])
        #expect(dirs.contains("/Users/alice/.local/bin"))
        #expect(dirs.contains("/Users/alice/.nvm/current/bin"))
    }

    @Test func doesNotDuplicateADirAlreadyOnPath() {
        let env = grokChildEnvironment(
            baseEnv: ["PATH": "/Users/alice/.cargo/bin:/usr/bin"],
            homeDir: "/Users/alice"
        )
        let dirs = env["PATH"]?.split(separator: ":").map(String.init) ?? []
        #expect(dirs.filter { $0 == "/Users/alice/.cargo/bin" }.count == 1)
    }
}
