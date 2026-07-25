import Testing
import Foundation
@testable import DiscordAgentBridge

/// Throwaway cwd + outside dir (realpath-stable on macOS /var → /private/var).
private struct DocFixture {
    let cwd: URL
    let outside: URL
}

private func makeDocFixture() throws -> DocFixture {
    let base = FileManager.default.temporaryDirectory
        .appendingPathComponent("dab-doc-\(UUID().uuidString)", isDirectory: true)
    let cwd = base.appendingPathComponent("cwd", isDirectory: true)
    let outside = base.appendingPathComponent("out", isDirectory: true)
    try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
    // realpath so comparisons hold on macOS.
    let realCwd = URL(fileURLWithPath: realpathOrResolve(cwd.path))
    let realOut = URL(fileURLWithPath: realpathOrResolve(outside.path))
    return DocFixture(cwd: realCwd, outside: realOut)
}

private func opts(_ over: (inout DocumentShareOptions) -> Void = { _ in }) -> DocumentShareOptions {
    var o = DocumentShareOptions.default
    over(&o)
    return o
}

/// Fake channel: records thread name + sends; channel-level send is unused.
private final class FakeShareSink: @unchecked Sendable {
    var threadNames: [String] = []
    var sends: [(content: String?, fileName: String?)] = []
    var starts = 0

    func channel() -> DocumentShareChannel {
        DocumentShareChannel { [self] name in
            self.starts += 1
            self.threadNames.append(name)
            return DocumentShareThread { content, file in
                self.sends.append((content: content, fileName: file?.name))
            }
        }
    }
}

@Suite("DocumentShare — load + error codes")
struct DocumentShareLoadTests {
    @Test func notFoundMissingFile() throws {
        let fx = try makeDocFixture()
        defer { try? FileManager.default.removeItem(at: fx.cwd.deletingLastPathComponent()) }
        let r = loadShareableDocument(cwd: fx.cwd.path, path: "nope.md", options: opts())
        guard case .failure(let res) = r else {
            Issue.record("expected failure")
            return
        }
        #expect(res == ShareResult.reject(.notFound))
    }

    @Test func notFileForDirectory() throws {
        let fx = try makeDocFixture()
        defer { try? FileManager.default.removeItem(at: fx.cwd.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(
            at: fx.cwd.appendingPathComponent("adir"), withIntermediateDirectories: true
        )
        let r = loadShareableDocument(cwd: fx.cwd.path, path: "adir", options: opts())
        guard case .failure(let res) = r else {
            Issue.record("expected failure")
            return
        }
        #expect(res.code == .notFile)
    }

    @Test func tooLarge() throws {
        let fx = try makeDocFixture()
        defer { try? FileManager.default.removeItem(at: fx.cwd.deletingLastPathComponent()) }
        try Data(repeating: 0x61, count: 200).write(to: fx.cwd.appendingPathComponent("big.md"))
        let r = loadShareableDocument(cwd: fx.cwd.path, path: "big.md", options: opts { $0.maxBytes = 100 })
        guard case .failure(let res) = r else {
            Issue.record("expected failure")
            return
        }
        #expect(res.code == .tooLarge)
        #expect(res.max?.hasSuffix("KiB") == true)
    }

    @Test func notMarkdownExtension() throws {
        let fx = try makeDocFixture()
        defer { try? FileManager.default.removeItem(at: fx.cwd.deletingLastPathComponent()) }
        try Data("plain".utf8).write(to: fx.cwd.appendingPathComponent("notes.txt"))
        let r = loadShareableDocument(cwd: fx.cwd.path, path: "notes.txt", options: opts())
        guard case .failure(let res) = r else {
            Issue.record("expected failure")
            return
        }
        #expect(res.code == .notMarkdown)
    }

    @Test func notFileForBinaryNul() throws {
        let fx = try makeDocFixture()
        defer { try? FileManager.default.removeItem(at: fx.cwd.deletingLastPathComponent()) }
        // '#', space, NUL, 'a'
        try Data([0x23, 0x20, 0x00, 0x61]).write(to: fx.cwd.appendingPathComponent("bin.md"))
        let r = loadShareableDocument(cwd: fx.cwd.path, path: "bin.md", options: opts())
        guard case .failure(let res) = r else {
            Issue.record("expected failure")
            return
        }
        #expect(res.code == .notFile)
    }

    @Test func notFileForEmptyPathWorkspaceRoot() throws {
        let fx = try makeDocFixture()
        defer { try? FileManager.default.removeItem(at: fx.cwd.deletingLastPathComponent()) }
        // path "" resolves to cwd (directory) → notFile
        let r = loadShareableDocument(cwd: fx.cwd.path, path: "", options: opts())
        guard case .failure(let res) = r else {
            Issue.record("expected failure")
            return
        }
        #expect(res.code == .notFile)
    }

    @Test func allowsAbsoluteOutsideWorkspace() throws {
        let fx = try makeDocFixture()
        defer { try? FileManager.default.removeItem(at: fx.cwd.deletingLastPathComponent()) }
        let abs = fx.outside.appendingPathComponent("abs.md")
        try Data("outside absolute".utf8).write(to: abs)
        let r = loadShareableDocument(cwd: fx.cwd.path, path: abs.path, options: opts())
        guard case .success(let doc) = r else {
            Issue.record("expected success")
            return
        }
        #expect(doc.displayPath == abs.path)
        #expect(doc.basename == "abs.md")
    }

    @Test func allowsRelativeEscapeWhenTargetValid() throws {
        let fx = try makeDocFixture()
        defer { try? FileManager.default.removeItem(at: fx.cwd.deletingLastPathComponent()) }
        try Data("top secret".utf8).write(to: fx.outside.appendingPathComponent("secret.md"))
        let rel = "../\(fx.outside.lastPathComponent)/secret.md"
        let r = loadShareableDocument(cwd: fx.cwd.path, path: rel, options: opts())
        guard case .success(let doc) = r else {
            Issue.record("expected success for outside path (share is not confined)")
            return
        }
        #expect(doc.displayPath == fx.outside.appendingPathComponent("secret.md").path)
    }

    @Test func relativeDisplayPathWhenUnderCwd() throws {
        let fx = try makeDocFixture()
        defer { try? FileManager.default.removeItem(at: fx.cwd.deletingLastPathComponent()) }
        let sub = fx.cwd.appendingPathComponent("sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("body".utf8).write(to: sub.appendingPathComponent("doc.md"))
        let r = loadShareableDocument(cwd: fx.cwd.path, path: "sub/doc.md", options: opts())
        guard case .success(let doc) = r else {
            Issue.record("expected success")
            return
        }
        #expect(doc.displayPath == "sub/doc.md")
    }

    @Test func markdownExtensionCaseInsensitive() throws {
        let fx = try makeDocFixture()
        defer { try? FileManager.default.removeItem(at: fx.cwd.deletingLastPathComponent()) }
        try Data("body".utf8).write(to: fx.cwd.appendingPathComponent("DOC.MARKDOWN"))
        let r = loadShareableDocument(cwd: fx.cwd.path, path: "DOC.MARKDOWN", options: opts())
        #expect(r.isSuccess)
    }

    @Test func fiveShareErrorCodesExist() {
        let codes = ShareErrorCode.allCases.map(\.rawValue)
        #expect(Set(codes) == Set(["notFound", "escape", "tooLarge", "notMarkdown", "notFile"]))
    }

    @Test func escapeCodeRetainedButNotProduced() throws {
        // Paths outside cwd still succeed — escape is i18n-only residual (TS).
        let fx = try makeDocFixture()
        defer { try? FileManager.default.removeItem(at: fx.cwd.deletingLastPathComponent()) }
        try Data("x".utf8).write(to: fx.outside.appendingPathComponent("x.md"))
        let r = loadShareableDocument(
            cwd: fx.cwd.path,
            path: fx.outside.appendingPathComponent("x.md").path,
            options: opts()
        )
        if case .failure(let res) = r {
            #expect(res.code != .escape)
        }
    }

    @Test func asJSONValueRoundTripShape() {
        let ok = ShareResult(ok: true, threadName: "📄 a.md", path: "a.md")
        #expect(ok.asJSONValue()["ok"]?.boolValue == true)
        #expect(ok.asJSONValue()["path"]?.stringValue == "a.md")
        let fail = ShareResult.reject(.tooLarge, max: "1.0 KiB")
        #expect(fail.asJSONValue()["code"]?.stringValue == "tooLarge")
        #expect(fail.asJSONValue()["max"]?.stringValue == "1.0 KiB")
    }
}

@Suite("DocumentShare — shareDocument sink")
struct DocumentSharePostTests {
    @Test func attachmentOnlyNoBody() async throws {
        let fx = try makeDocFixture()
        defer { try? FileManager.default.removeItem(at: fx.cwd.deletingLastPathComponent()) }
        try Data("# Title\n\nbody".utf8).write(to: fx.cwd.appendingPathComponent("doc.md"))
        let sink = FakeShareSink()
        let res = try await shareDocument(
            cwd: fx.cwd.path,
            path: "doc.md",
            options: opts { $0.bodyMode = "attachment_only" },
            channel: sink.channel()
        )
        #expect(res.ok)
        #expect(res.threadName == "📄 doc.md")
        #expect(res.path == "doc.md")
        #expect(sink.starts == 1)
        #expect(sink.sends.count == 1)
        #expect(sink.sends[0].fileName == "doc.md")
        #expect(sink.sends[0].content?.contains("doc.md") == true)
    }

    @Test func previewClipsAndNotices() async throws {
        let fx = try makeDocFixture()
        defer { try? FileManager.default.removeItem(at: fx.cwd.deletingLastPathComponent()) }
        try Data(String(repeating: "A", count: 50).utf8).write(to: fx.cwd.appendingPathComponent("doc.md"))
        let sink = FakeShareSink()
        _ = try await shareDocument(
            cwd: fx.cwd.path,
            path: "doc.md",
            options: opts { $0.previewMaxChars = 10 },
            channel: sink.channel()
        )
        #expect(sink.sends.count == 2)
        let body = sink.sends[1].content ?? ""
        #expect(body.hasPrefix(String(repeating: "A", count: 10)))
        #expect(!body.contains(String(repeating: "A", count: 11)))
        #expect(body.contains("preview truncated"))
    }

    @Test func fullPostsEntireBody() async throws {
        let fx = try makeDocFixture()
        defer { try? FileManager.default.removeItem(at: fx.cwd.deletingLastPathComponent()) }
        let content = "# Full\n\n" + String(repeating: "line\n", count: 20)
        try Data(content.utf8).write(to: fx.cwd.appendingPathComponent("doc.md"))
        let sink = FakeShareSink()
        _ = try await shareDocument(
            cwd: fx.cwd.path,
            path: "doc.md",
            options: opts {
                $0.bodyMode = "full"
                $0.previewMaxChars = 5
            },
            channel: sink.channel()
        )
        #expect(sink.sends[1].content == content)
    }

    @Test func rejectionDoesNotOpenThread() async throws {
        let fx = try makeDocFixture()
        defer { try? FileManager.default.removeItem(at: fx.cwd.deletingLastPathComponent()) }
        let sink = FakeShareSink()
        let res = try await shareDocument(
            cwd: fx.cwd.path,
            path: "missing.md",
            options: opts(),
            channel: sink.channel()
        )
        #expect(res.ok == false)
        #expect(res.code == .notFound)
        #expect(sink.starts == 0)
    }

    @Test func longThreadNameClippedToLimit() async throws {
        let fx = try makeDocFixture()
        defer { try? FileManager.default.removeItem(at: fx.cwd.deletingLastPathComponent()) }
        let longBase = String(repeating: "a", count: 200) + ".md"
        try Data("body".utf8).write(to: fx.cwd.appendingPathComponent(longBase))
        let sink = FakeShareSink()
        let res = try await shareDocument(
            cwd: fx.cwd.path,
            path: longBase,
            options: opts(),
            channel: sink.channel()
        )
        #expect(res.ok)
        #expect(sink.threadNames[0].utf16.count <= documentThreadNameLimit)
        #expect(sink.threadNames[0].hasPrefix("📄 "))
        #expect(sink.threadNames[0].hasSuffix("…"))
    }
}

@Suite("DocumentShare — host + slash spec")
struct DocumentShareHostAndSpecTests {
    @Test func hostUnwiredReturnsNoSession() async throws {
        let host = DocumentShareHost()
        let res = try await host.share(channelId: "c1", path: "x.md")
        #expect(res == .noSession)
        #expect(res.code == nil)
    }

    @Test func hostDelegatesToHandler() async throws {
        let host = DocumentShareHost()
        await host.setShareHandler { channelId, path in
            #expect(channelId == "c9")
            #expect(path == "docs/a.md")
            return ShareResult(ok: true, threadName: "📄 a.md", path: "docs/a.md")
        }
        let res = try await host.share(channelId: "c9", path: "docs/a.md")
        #expect(res.ok)
        #expect(res.path == "docs/a.md")
    }

    @Test func docCommandSpecShape() {
        let doc = docCommandSpec()
        #expect(doc.name == "doc")
        #expect(doc.subcommands.isEmpty)
        #expect(doc.options.map(\.name) == ["path"])
        #expect(doc.options[0].required == true)
        #expect(doc.options[0].choices.isEmpty)
        #expect(doc.requiresAdministrator == false)
    }

    @Test func allSpecsIncludesDoc() {
        let names = allSlashCommandSpecs().map(\.name)
        #expect(names.contains("doc"))
        #expect(names == [
            "agent", "mode", "model", "effort", "stop", "clear", "stop-all", "setup", "doc",
        ])
    }
}

private extension Result {
    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }
}
