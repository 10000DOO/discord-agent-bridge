import Testing
import Foundation
@testable import DiscordAgentBridge

/// A throwaway workspace: `base/ws` is the cwd, `base` is the escape target.
private struct Fixture {
    let base: URL
    let ws: URL
}

private func makeFixture() throws -> Fixture {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("dab-confine-\(UUID().uuidString)", isDirectory: true)
    let ws = base.appendingPathComponent("ws", isDirectory: true)
    try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
    return Fixture(base: base, ws: ws)
}

@Suite("Confinement")
struct ConfinementTests {
    @Test func emptyFilesReturnsNil() {
        #expect(findConfinementViolation(cwd: "/ws", files: []) == nil)
    }

    @Test func fileInsideWorkspacePasses() throws {
        let fx = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fx.base) }
        try Data("hi".utf8).write(to: fx.ws.appendingPathComponent("notes.txt"))
        #expect(findConfinementViolation(cwd: fx.ws.path, files: ["notes.txt"]) == nil)
    }

    @Test func nonexistentTailInsideWorkspaceAllowed() throws {
        let fx = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fx.base) }
        // File does not exist yet; its deepest existing ancestor (ws) resolves under root → allowed.
        #expect(findConfinementViolation(cwd: fx.ws.path, files: ["sub/dir/new.txt"]) == nil)
    }

    @Test func dotDotEscapeDetected() throws {
        let fx = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fx.base) }
        #expect(findConfinementViolation(cwd: fx.ws.path, files: ["../escape.txt"]) == "../escape.txt")
    }

    @Test func symlinkEscapeDetected() throws {
        let fx = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fx.base) }
        let outside = fx.base.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: outside.appendingPathComponent("secret.txt"))
        // ws/link → base/outside: a literal `..` is absent, only the symlink escapes.
        let link = fx.ws.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        #expect(findConfinementViolation(cwd: fx.ws.path, files: ["link/secret.txt"]) == "link/secret.txt")
    }

    @Test func sharedPrefixSiblingIsViolation() throws {
        // /base/ws vs /base/ws-evil: a naive string-prefix check would falsely pass this.
        let fx = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fx.base) }
        let evil = fx.base.appendingPathComponent("ws-evil", isDirectory: true)
        try FileManager.default.createDirectory(at: evil, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: evil.appendingPathComponent("f.txt"))
        #expect(findConfinementViolation(cwd: fx.ws.path, files: ["../ws-evil/f.txt"]) == "../ws-evil/f.txt")
    }

    @Test func absoluteFileOutsideWorkspaceDetected() throws {
        let fx = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fx.base) }
        // An absolute path wins in path.resolve → stays outside → violation.
        #expect(findConfinementViolation(cwd: fx.ws.path, files: ["/etc/hosts"]) == "/etc/hosts")
    }

    @Test func isWithinComponentBoundaries() {
        #expect(isWithin(root: "/ws", child: "/ws") == true)        // root itself
        #expect(isWithin(root: "/ws", child: "/ws/sub/a.txt") == true)
        #expect(isWithin(root: "/ws", child: "/ws-evil") == false)  // shared string prefix, not nested
        #expect(isWithin(root: "/ws", child: "/") == false)         // parent is not within child
        #expect(isWithin(root: "/", child: "/anything") == true)    // everything is within the fs root
    }
}
