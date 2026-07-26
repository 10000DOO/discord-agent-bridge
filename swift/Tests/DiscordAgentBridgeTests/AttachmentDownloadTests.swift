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
