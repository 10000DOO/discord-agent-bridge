import Testing
import Foundation
@testable import DiscordAgentBridge

/// Temp workspace + outside dir (realpath-stable on macOS /var → /private/var).
private struct FileDlFixture {
    let root: URL
    let outside: URL
    let base: URL
}

private func makeFileDlFixture() throws -> FileDlFixture {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("dab-fdl-\(UUID().uuidString)", isDirectory: true)
    let root = base.appendingPathComponent("ws", isDirectory: true)
    let outside = base.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let src = root.appendingPathComponent("src", isDirectory: true)
    try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
    try Data("export const a = 1;".utf8).write(to: src.appendingPathComponent("a.ts"))
    try Data("nope".utf8).write(to: outside.appendingPathComponent("secret.txt"))
    let realRoot = URL(fileURLWithPath: realpathOrResolve(root.path))
    let realOut = URL(fileURLWithPath: realpathOrResolve(outside.path))
    return FileDlFixture(root: realRoot, outside: realOut, base: base)
}

@Suite("FileDownload — browse / download / confine")
struct FileDownloadTests {
    @Test func downloadsInWorkspaceFile() throws {
        let fx = try makeFileDlFixture()
        defer { try? FileManager.default.removeItem(at: fx.base) }
        let dl = FileDownload(workspaceRoot: fx.root.path)
        let file = try dl.download(relativePath: "src/a.ts")
        #expect(file.path == realpathOrResolve(fx.root.appendingPathComponent("src/a.ts").path))
        #expect(file.name == "a.ts")
    }

    @Test func browsesInWorkspaceDirsFirstHidesDotfiles() throws {
        let fx = try makeFileDlFixture()
        defer { try? FileManager.default.removeItem(at: fx.base) }
        try FileManager.default.createDirectory(
            at: fx.root.appendingPathComponent(".git"),
            withIntermediateDirectories: true
        )
        try Data("x".utf8).write(to: fx.root.appendingPathComponent("z.txt"))
        let dl = FileDownload(workspaceRoot: fx.root.path)
        let entries = try dl.browse(relativeDir: ".")
        #expect(entries.map(\.name) == ["src", "z.txt"])
        #expect(entries[0].isDirectory == true)
        #expect(entries[1].isDirectory == false)
    }

    @Test func rejectsDotDotEscape() throws {
        let fx = try makeFileDlFixture()
        defer { try? FileManager.default.removeItem(at: fx.base) }
        let dl = FileDownload(workspaceRoot: fx.root.path)
        let rel = "../\(fx.outside.lastPathComponent)/secret.txt"
        #expect(throws: WorkspaceEscapeError.self) {
            try dl.download(relativePath: rel)
        }
    }

    @Test func rejectsAbsoluteOutside() throws {
        let fx = try makeFileDlFixture()
        defer { try? FileManager.default.removeItem(at: fx.base) }
        let dl = FileDownload(workspaceRoot: fx.root.path)
        let abs = fx.outside.appendingPathComponent("secret.txt").path
        #expect(throws: WorkspaceEscapeError.self) {
            try dl.download(relativePath: abs)
        }
    }

    @Test func rejectsSymlinkEscape() throws {
        let fx = try makeFileDlFixture()
        defer { try? FileManager.default.removeItem(at: fx.base) }
        let link = fx.root.appendingPathComponent("escape")
        do {
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fx.outside)
        } catch {
            return // symlinks unsupported — skip
        }
        let dl = FileDownload(workspaceRoot: fx.root.path)
        #expect(throws: WorkspaceEscapeError.self) {
            try dl.download(relativePath: "escape/secret.txt")
        }
    }

    @Test func throwsForMissingOrDirectory() throws {
        let fx = try makeFileDlFixture()
        defer { try? FileManager.default.removeItem(at: fx.base) }
        let dl = FileDownload(workspaceRoot: fx.root.path)
        do {
            _ = try dl.download(relativePath: "src/missing.ts")
            Issue.record("expected notFound")
        } catch let e as FileDownloadError {
            #expect(e == .notFound("src/missing.ts"))
        }
        do {
            _ = try dl.download(relativePath: "src")
            Issue.record("expected notAFile")
        } catch let e as FileDownloadError {
            #expect(e == .notAFile("src"))
        }
    }
}
