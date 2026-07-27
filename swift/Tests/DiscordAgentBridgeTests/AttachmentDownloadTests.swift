import Testing
import Foundation
@testable import DiscordAgentBridge

/// Throwaway workspace + outside dir (realpath-stable on macOS /var → /private/var).
private struct AttachDlFixture {
    let ws: URL
    let outside: URL
    let base: URL
}

private func makeAttachDlFixture() throws -> AttachDlFixture {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("dab-att-\(UUID().uuidString)", isDirectory: true)
    let ws = base.appendingPathComponent("ws", isDirectory: true)
    let outside = base.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    let realWs = URL(fileURLWithPath: realpathOrResolve(ws.path))
    let realOut = URL(fileURLWithPath: realpathOrResolve(outside.path))
    return AttachDlFixture(ws: realWs, outside: realOut, base: base)
}

@Suite("AttachmentDownload — sanitize / confine / download")
struct AttachmentDownloadTests {
    @Test func sanitizeStripsTraversalToBasename() {
        #expect(sanitizeAttachmentName("../../etc/passwd") == "passwd")
        #expect(sanitizeAttachmentName("note.txt") == "note.txt")
        #expect(sanitizeAttachmentName("") == "attachment")
        #expect(sanitizeAttachmentName(".") == "attachment")
        #expect(sanitizeAttachmentName("..") == "attachment")
        #expect(sanitizeAttachmentName("evil/name") == "name")
        // path separators remaining in basename become underscores
        let withSlashInBase = sanitizeAttachmentName("x")
        #expect(withSlashInBase == "x")
        #expect(!sanitizeAttachmentName("a/b").contains("/"))
    }

    @Test func happyPathWritesConfinedFileWithMime() async throws {
        let fx = try makeAttachDlFixture()
        defer { try? FileManager.default.removeItem(at: fx.base) }
        let bytes = Data([9, 9, 9])
        let files = try await downloadAttachments(
            cwd: fx.ws.path,
            attachments: [
                IncomingAttachment(url: "https://cdn/x", name: "note.txt", contentType: "text/plain"),
            ],
            fetchBytes: { _ in bytes }
        )
        #expect(files.count == 1)
        let file = try #require(files.first)
        #expect(file.mime == "text/plain")
        #expect(isWithin(root: realpathOrResolve(fx.ws.path), child: realpathOrResolve(file.path)))
        #expect((file.path as NSString).lastPathComponent == "note.txt")
        #expect(try Data(contentsOf: URL(fileURLWithPath: file.path)) == bytes)
        // Under .dab-attachments
        #expect(file.path.contains(attachmentDirName))
    }

    @Test func traversalFilenameStaysInsideWorkspace() async throws {
        let fx = try makeAttachDlFixture()
        defer { try? FileManager.default.removeItem(at: fx.base) }
        let files = try await downloadAttachments(
            cwd: fx.ws.path,
            attachments: [
                IncomingAttachment(url: "https://cdn/evil", name: "../../etc/passwd", contentType: nil),
            ],
            fetchBytes: { _ in Data([1]) }
        )
        let file = try #require(files.first)
        #expect(file.mime == nil)
        #expect((file.path as NSString).lastPathComponent == "passwd")
        #expect(isWithin(root: realpathOrResolve(fx.ws.path), child: realpathOrResolve(file.path)))
        #expect(!isWithin(root: realpathOrResolve(fx.outside.path), child: realpathOrResolve(file.path)))
    }

    @Test func rejectsAttachmentDirSymlinkEscape() async throws {
        let fx = try makeAttachDlFixture()
        defer { try? FileManager.default.removeItem(at: fx.base) }
        let link = fx.ws.appendingPathComponent(attachmentDirName)
        do {
            try FileManager.default.createSymbolicLink(
                atPath: link.path,
                withDestinationPath: fx.outside.path
            )
        } catch {
            // Platform forbids symlinks — skip (confinement still covered by path tests).
            return
        }

        do {
            _ = try await downloadAttachments(
                cwd: fx.ws.path,
                attachments: [
                    IncomingAttachment(url: "https://cdn/x", name: "evil.txt", contentType: "text/plain"),
                ],
                fetchBytes: { _ in Data([1]) }
            )
            Issue.record("expected escape throw")
        } catch let e as AttachmentDownloadError {
            #expect(e == .escapesWorkspace(link.path) || String(describing: e).contains("escapes the workspace"))
        } catch {
            Issue.record("unexpected error \(error)")
        }

        let outsideEntries = (try? FileManager.default.contentsOfDirectory(atPath: fx.outside.path)) ?? []
        #expect(outsideEntries.isEmpty)
    }

    @Test func concurrentDownloadsWithSameFilenameDoNotCollide() async throws {
        // Regression for the per-call UUID subdirectory (downloadAttachments doc comment,
        // AttachmentDownload.swift:92-95): two channel turns racing on the same sanitized
        // filename must not let one overwrite the other's in-flight file.
        let fx = try makeAttachDlFixture()
        defer { try? FileManager.default.removeItem(at: fx.base) }
        let bytesA = Data([1, 1, 1])
        let bytesB = Data([2, 2, 2])
        async let a = downloadAttachments(
            cwd: fx.ws.path,
            attachments: [IncomingAttachment(url: "https://cdn/a", name: "x.png", contentType: nil)],
            fetchBytes: { _ in bytesA }
        )
        async let b = downloadAttachments(
            cwd: fx.ws.path,
            attachments: [IncomingAttachment(url: "https://cdn/b", name: "x.png", contentType: nil)],
            fetchBytes: { _ in bytesB }
        )
        let (r1, r2) = try await (a, b)
        let f1 = try #require(r1.first)
        let f2 = try #require(r2.first)
        #expect(f1.path != f2.path)
        #expect(try Data(contentsOf: URL(fileURLWithPath: f1.path)) == bytesA)
        #expect(try Data(contentsOf: URL(fileURLWithPath: f2.path)) == bytesB)
    }

    @Test func emptyAttachmentsReturnsEmpty() async throws {
        let fx = try makeAttachDlFixture()
        defer { try? FileManager.default.removeItem(at: fx.base) }
        let files = try await downloadAttachments(cwd: fx.ws.path, attachments: [])
        #expect(files.isEmpty)
    }

    @Test func fileHintsAppendPathsToText() {
        #expect(DiscordAgentBridge.appendAttachedFileHints(text: "hi", files: []) == "hi")
        let f = [TurnFile(path: "/ws/.dab-attachments/a.txt")]
        #expect(DiscordAgentBridge.appendAttachedFileHints(text: "hi", files: f) == "hi\n\nAttached file: /ws/.dab-attachments/a.txt")
        #expect(DiscordAgentBridge.appendAttachedFileHints(text: "  ", files: f) == "Attached file: /ws/.dab-attachments/a.txt")
    }

    @Test func classifyTurnFilesDetectsImageByExtension() {
        let classified = classifyTurnFiles([TurnFile(path: "/x/photo.PNG", mime: nil)])
        #expect(classified[0].isImage)
        #expect(classified[0].mime == "image/png")
    }

    @Test func classifyTurnFilesDetectsImageByMimeOnly() {
        // No image extension, but a declared image mime still counts (TS: OR of ext/mime).
        let classified = classifyTurnFiles([TurnFile(path: "/x/blob", mime: "image/jpeg")])
        #expect(classified[0].isImage)
        #expect(classified[0].mime == "image/jpeg")
    }

    @Test func classifyTurnFilesNonImageKeepsMimeOrFallsBackToOctetStream() {
        let classified = classifyTurnFiles([
            TurnFile(path: "/x/note.txt", mime: "text/plain"),
            TurnFile(path: "/x/data.bin", mime: nil),
        ])
        #expect(!classified[0].isImage)
        #expect(classified[0].mime == "text/plain")
        #expect(!classified[1].isImage)
        #expect(classified[1].mime == "application/octet-stream")
    }

    @Test func readImageBase64EncodesFileBytes() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("dab-img-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.png")
        let bytes = Data([1, 2, 3, 4])
        try bytes.write(to: file)
        #expect(try readImageBase64(path: file.path) == bytes.base64EncodedString())
    }
}

@Suite("routeDecision — attachment-only bound")
struct RouteDecisionAttachmentTests {
    @Test func emptyBodyWithAttachmentsRoutesOnBoundChannel() {
        #expect(
            routeDecision(content: "", binding: SessionConfig(backend: .claude), hasAttachments: true)
                == .bound(.claude, "")
        )
        #expect(
            routeDecision(content: "   ", binding: SessionConfig(backend: .codex), hasAttachments: true)
                == .bound(.codex, "")
        )
        // Without attachments, empty still ignores
        #expect(routeDecision(content: "   ", binding: SessionConfig(backend: .codex)) == .ignore)
    }
}
