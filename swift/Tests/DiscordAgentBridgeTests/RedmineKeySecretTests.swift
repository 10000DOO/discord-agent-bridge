import Foundation
import Testing
@testable import DiscordAgentBridge

@Suite("RedmineKeySecret")
struct RedmineKeySecretTests {
    private func tempEnvFile() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dab-redmine-secret-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("env")
    }

    @Test func usesProcessEnvWhenPresentWithoutTouchingFile() throws {
        let envFile = try tempEnvFile()
        var setEnvCalls: [(String, String)] = []
        let result = try RedmineKeySecret.ensure(
            environment: [RedmineKeySecret.envKey: "from-process"],
            envFileURL: envFile,
            setEnv: { name, value in setEnvCalls.append((name, value)) }
        )
        #expect(result.secret == "from-process")
        #expect(result.generated == false)
        #expect(setEnvCalls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: envFile.path))
    }

    @Test func usesFileWhenEnvMissingAndDoesNotOverwrite() throws {
        let envFile = try tempEnvFile()
        let existing = "from-file-secret-value"
        try "OTHER=1\n\(RedmineKeySecret.envKey)=\(existing)\n".write(to: envFile, atomically: true, encoding: .utf8)
        let before = try String(contentsOf: envFile, encoding: .utf8)

        var setEnvCalls: [(String, String)] = []
        let result = try RedmineKeySecret.ensure(
            environment: [:],
            envFileURL: envFile,
            setEnv: { name, value in setEnvCalls.append((name, value)) }
        )
        #expect(result.secret == existing)
        #expect(result.generated == false)
        #expect(setEnvCalls.count == 1)
        #expect(setEnvCalls[0].0 == RedmineKeySecret.envKey)
        #expect(setEnvCalls[0].1 == existing)
        let after = try String(contentsOf: envFile, encoding: .utf8)
        #expect(after == before)
    }

    @Test func generatesPersistsAndReusesWhenBothMissing() throws {
        let envFile = try tempEnvFile()
        var lastSet: String?
        let first = try RedmineKeySecret.ensure(
            environment: [:],
            envFileURL: envFile,
            setEnv: { _, value in lastSet = value }
        )
        #expect(first.generated == true)
        #expect(first.secret.count == 64)
        #expect(isHex64(first.secret))
        #expect(lastSet == first.secret)
        #expect(FileManager.default.fileExists(atPath: envFile.path))

        let content = try String(contentsOf: envFile, encoding: .utf8)
        #expect(content.contains("\(RedmineKeySecret.envKey)=\(first.secret)"))

        #if !os(Windows)
        let perms = try FileManager.default.attributesOfItem(atPath: envFile.path)[.posixPermissions] as? NSNumber
        #expect(perms?.intValue == 0o600)
        #endif

        var secondSetCalls = 0
        let second = try RedmineKeySecret.ensure(
            environment: [:],
            envFileURL: envFile,
            setEnv: { _, _ in secondSetCalls += 1 }
        )
        #expect(second.secret == first.secret)
        #expect(second.generated == false)
        #expect(secondSetCalls == 1)

        let contentAfter = try String(contentsOf: envFile, encoding: .utf8)
        #expect(contentAfter == content)
    }

    @Test func processEnvTakesPrecedenceOverFile() throws {
        let envFile = try tempEnvFile()
        try "\(RedmineKeySecret.envKey)=file-value\n".write(to: envFile, atomically: true, encoding: .utf8)
        let result = try RedmineKeySecret.ensure(
            environment: [RedmineKeySecret.envKey: "env-wins"],
            envFileURL: envFile,
            setEnv: { _, _ in Issue.record("setEnv must not run when process env has secret") }
        )
        #expect(result.secret == "env-wins")
        #expect(result.generated == false)
    }

    @Test func generateSecretIs64HexAndNotConstant() {
        let a = RedmineKeySecret.generateSecret()
        let b = RedmineKeySecret.generateSecret()
        #expect(a.count == 64)
        #expect(b.count == 64)
        #expect(isHex64(a))
        #expect(isHex64(b))
        #expect(a != b)
    }

    private func isHex64(_ s: String) -> Bool {
        s.count == 64 && s.utf8.allSatisfy { b in
            (b >= 48 && b <= 57) || (b >= 97 && b <= 102) // 0-9 a-f
        }
    }
}
