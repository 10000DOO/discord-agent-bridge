import Testing
import Foundation
@testable import DiscordAgentBridge

/// Throwaway cwd + outside dir (realpath-stable on macOS /var → /private/var).
private struct AttachFixture {
    let cwd: URL
    let outside: URL
}

private func makeAttachFixture() throws -> AttachFixture {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("dab-attach-\(UUID().uuidString)", isDirectory: true)
    let cwd = base.appendingPathComponent("cwd", isDirectory: true)
    let outside = base.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let realCwd = URL(fileURLWithPath: realpathOrResolve(cwd.path))
    let realOut = URL(fileURLWithPath: realpathOrResolve(outside.path))
    return AttachFixture(cwd: realCwd, outside: realOut)
}

@Suite("FileAttach — pure path confinement")
struct FileAttachPathTests {
    @Test func resolveAcceptsInsideRelative() throws {
        let fx = try makeAttachFixture()
        defer { try? FileManager.default.removeItem(at: fx.cwd.deletingLastPathComponent()) }
        try Data("hi".utf8).write(to: fx.cwd.appendingPathComponent("report.txt"))
        let resolved = resolveConfinedAttachPath(workspaceRoot: fx.cwd.path, requestedPath: "report.txt")
        #expect(resolved != nil)
        #expect(resolved.map { realpathOrResolve($0) } == realpathOrResolve(fx.cwd.appendingPathComponent("report.txt").path))
    }

    @Test func resolveRejectsDotDotEscape() throws {
        let fx = try makeAttachFixture()
        defer { try? FileManager.default.removeItem(at: fx.cwd.deletingLastPathComponent()) }
        #expect(resolveConfinedAttachPath(workspaceRoot: fx.cwd.path, requestedPath: "../../etc/passwd") == nil)
    }

    @Test func resolveRejectsAbsoluteOutside() throws {
        let fx = try makeAttachFixture()
        defer { try? FileManager.default.removeItem(at: fx.cwd.deletingLastPathComponent()) }
        try Data("x".utf8).write(to: fx.outside.appendingPathComponent("secret.txt"))
        let abs = fx.outside.appendingPathComponent("secret.txt").path
        #expect(resolveConfinedAttachPath(workspaceRoot: fx.cwd.path, requestedPath: abs) == nil)
    }

    @Test func confinedForwardsInsideAndNeverCallsOnEscape() async throws {
        let fx = try makeAttachFixture()
        defer { try? FileManager.default.removeItem(at: fx.cwd.deletingLastPathComponent()) }
        try Data("hi".utf8).write(to: fx.cwd.appendingPathComponent("report.txt"))

        let forwarded = LockedBox<[String]>([])
        let ok = await attachFileConfined(
            workspaceRoot: fx.cwd.path,
            sendFile: { abs, name in
                forwarded.withLock { $0.append(abs) }
                #expect(name == "custom.pdf")
                return "Sent custom.pdf to the channel."
            },
            requestedPath: "report.txt",
            filename: "custom.pdf"
        )
        #expect(ok.isError == false)
        #expect(ok.text == "Sent custom.pdf to the channel.")
        #expect(forwarded.withLock { $0 }.count == 1)

        let called = LockedBox(false)
        let bad = await attachFileConfined(
            workspaceRoot: fx.cwd.path,
            sendFile: { _, _ in
                called.withLock { $0 = true }
                return "ok"
            },
            requestedPath: "../../etc/passwd"
        )
        #expect(bad.isError == true)
        #expect(bad.text.contains("outside the session workspace"))
        #expect(called.withLock { $0 } == false)
    }

    @Test func confinedMapsSendThrowToIsError() async throws {
        let fx = try makeAttachFixture()
        defer { try? FileManager.default.removeItem(at: fx.cwd.deletingLastPathComponent()) }
        try Data("hi".utf8).write(to: fx.cwd.appendingPathComponent("a.txt"))
        let res = await attachFileConfined(
            workspaceRoot: fx.cwd.path,
            sendFile: { _, _ in
                throw FileAttachHostError.notWired
            },
            requestedPath: "a.txt"
        )
        #expect(res.isError == true)
        #expect(res.text.contains("Failed to attach file"))
    }
}

@Suite("FileAttach — host")
struct FileAttachHostTests {
    @Test func hostUnwiredThrows() async throws {
        let host = FileAttachHost()
        do {
            _ = try await host.attach(channelId: "c1", path: "/tmp/x", name: nil)
            Issue.record("expected notWired")
        } catch let err as FileAttachHostError {
            #expect(err == .notWired)
        }
    }

    @Test func hostDelegatesToHandler() async throws {
        let host = FileAttachHost()
        await host.setAttachHandler { channelId, path, name in
            #expect(channelId == "c9")
            #expect(path == "/ws/out.txt")
            #expect(name == "out.txt")
            return "Sent out.txt to the channel."
        }
        let msg = try await host.attach(channelId: "c9", path: "/ws/out.txt", name: "out.txt")
        #expect(msg == "Sent out.txt to the channel.")
    }
}
