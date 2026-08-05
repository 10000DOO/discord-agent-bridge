import Testing
import Foundation
@testable import DiscordAgentBridge

// MARK: - Fake channel

private final class FakePosts: @unchecked Sendable {
    private struct State {
        var posts: [(threadName: String, content: String)] = []
        var names: [String] = []
        var creates = 0
        var failTimes: Int
    }
    private let box: LockedBox<State>

    init(failTimes: Int = 0) {
        box = LockedBox(State(failTimes: failTimes))
    }

    var posts: [(threadName: String, content: String)] {
        box.withLock { $0.posts }
    }
    var names: [String] {
        box.withLock { $0.names }
    }
    var createCount: Int {
        box.withLock { $0.creates }
    }

    func channel() -> TurnThreadChannel {
        TurnThreadChannel { [self] name in
            let (n, shouldFail): (Int, Bool) = self.box.withLock { s in
                s.creates += 1
                s.names.append(name)
                let fail = s.failTimes > 0
                if fail { s.failTimes -= 1 }
                return (s.creates, fail)
            }
            if shouldFail {
                throw NSError(domain: "fake", code: 1, userInfo: [NSLocalizedDescriptionKey: "open failed"])
            }
            let threadName = name
            return TurnThreadMessage(id: "t\(n)") { content in
                self.box.withLock { $0.posts.append((threadName, content)) }
            }
        }
    }
}

// MARK: - Pure formatters

@Suite("toolSummary / work-log lines / truncate")
struct ToolFormatTests {
    @Test func toolSummaryPerTool() {
        #expect(toolSummary(toolName: "Edit", input: .object(["file_path": .string("/ws/a.ts")])) == "/ws/a.ts")
        #expect(toolSummary(toolName: "Bash", input: .object(["command": .string("ls -la")])) == "ls -la")
        #expect(toolSummary(toolName: "Grep", input: .object(["pattern": .string("foo")])) == "foo")
        #expect(toolSummary(toolName: "WebSearch", input: .object(["query": .string("swift")])) == "swift")
    }

    @Test func toolSummaryClipsFreeFormFieldsAtLimit() {
        let cmd = String(repeating: "x", count: 120)
        #expect(toolSummary(toolName: "Bash", input: .object(["command": .string(cmd)])).count == 60)
        #expect(toolSummary(toolName: "Bash", input: .object(["command": .string(cmd)]), limit: 200).count == 120)
        // A path is never clipped by `limit` — the call line needs the whole thing.
        let longPath = "/" + String(repeating: "p", count: 200)
        #expect(toolSummary(toolName: "Read", input: .object(["file_path": .string(longPath)])) == longPath)
    }

    @Test func callLineIsOneLineWithBackticksNeutralized() {
        #expect(formatToolCallLine(toolName: "Bash", input: .object(["command": .string("ls -la")])) == "● **Bash** `ls -la`")
        // Multi-line command must not break the inline code span.
        let line = formatToolCallLine(toolName: "Bash", input: .object(["command": .string("cd /ws \\\n  && `id`")]))
        #expect(!line.contains("\n"))
        #expect(line == "● **Bash** `cd /ws \\ && 'id'`")
        // No summarizable field → bare tool name, no empty code span.
        #expect(formatToolCallLine(toolName: "Read", input: .object([:])) == "● **Read**")
    }

    @Test func resultCollapsesOnSuccessAndKeepsBodyOnError() {
        // Short success → size + verbatim body.
        let short = formatToolResult(toolName: "Bash", content: "a\nb\nc", ok: true)
        #expect(short.hasPrefix("⎿ Bash · 3줄"))
        #expect(short.contains("```\na\nb\nc\n```"))

        // Long success → size + the whole body, nothing clipped.
        let long = formatToolResult(toolName: "Read", content: String(repeating: "line\n", count: 600), ok: true)
        #expect(long.hasPrefix("⎿ Read · 600줄"))
        #expect(!long.contains("…"))
        #expect(long.components(separatedBy: "line").count - 1 == 600)
        // Over 2000 chars → chunked, not truncated: the pieces still hold every line.
        let chunks = DiscordText.chunkMessage(long)
        #expect(chunks.count > 1)
        #expect(chunks.joined().components(separatedBy: "line").count - 1 == 600)

        // Failure → same, body kept in full.
        let failed = formatToolResult(toolName: "Bash", content: String(repeating: "boom\n", count: 200), ok: false)
        #expect(failed.hasPrefix("⎿ Bash · 오류 · 200줄"))
        #expect(failed.components(separatedBy: "boom").count - 1 == 200)

        #expect(formatToolResult(toolName: "Bash", content: "   ", ok: true) == "⎿ Bash · 출력 없음")
        #expect(formatToolResult(toolName: nil, content: "x", ok: true).hasPrefix("⎿ 1줄"))
    }

    @Test func resultBodyCannotEscapeItsFence() {
        let out = formatToolResult(toolName: "Read", content: "before\n```\nfenced\n```\nafter", ok: true)
        // Exactly the opening and closing fence this formatter added — none from the content.
        #expect(out.components(separatedBy: "```").count - 1 == 2)
    }

    @Test func truncateAlias() {
        #expect(DiscordText.truncate("abcdef", 4) == "abc…")
        #expect(DiscordText.truncate("abc", 5) == "abc")
    }
}

@Suite("parseEditInput / renderDiff")
struct DiffPureTests {
    @Test func editOldNew() {
        let input = JSONValue.object([
            "file_path": .string("/ws/a.ts"),
            "old_string": .string("a"),
            "new_string": .string("b"),
        ])
        let edit = parseEditInput(input)!
        let diff = renderDiff(edit)!
        #expect(diff.contains("--- /ws/a.ts"))
        #expect(diff.contains("- a"))
        #expect(diff.contains("+ b"))
    }

    @Test func writeContent() {
        let input = JSONValue.object([
            "file_path": .string("/ws/n.ts"),
            "content": .string("line1\nline2"),
        ])
        let diff = renderDiff(parseEditInput(input)!)!
        #expect(diff.contains("+ line1"))
        #expect(diff.contains("+ line2"))
    }

    @Test func applyPatchChanges() {
        let input = JSONValue.object([
            "changes": .array([
                .object([
                    "path": .string("src/a.ts"),
                    "diff": .string("- old\n+ new"),
                ]),
            ]),
        ])
        let edit = parseEditInput(input)!
        #expect(edit.filePath == "src/a.ts")
        let diff = renderDiff(edit)!
        #expect(diff.contains("--- src/a.ts"))
        #expect(diff.contains("- old"))
        #expect(diff.contains("+ new"))
    }

    @Test func nonObjectNil() {
        #expect(parseEditInput(.string("x")) == nil)
        #expect(parseEditInput(.object(["no_path": .string("x")])) == nil)
    }
}

// MARK: - Handlers with fakes

@Suite("TurnThreadHolder / Registry")
struct TurnThreadTests {
    @Test func createsOnceAcrossConcurrentGet() async throws {
        let fake = FakePosts()
        let holder = TurnThreadHolder(channel: fake.channel(), name: "work")
        async let a = holder.get()
        async let b = holder.get()
        let (ta, tb) = try await (a, b)
        #expect(fake.createCount == 1)
        #expect(ta.id == tb.id)
    }

    @Test func resetOpensFreshThread() async throws {
        let fake = FakePosts()
        let holder = TurnThreadHolder(channel: fake.channel(), name: "work")
        _ = try await holder.get()
        #expect(holder.opened)
        holder.reset()
        #expect(!holder.opened)
        _ = try await holder.get()
        #expect(fake.createCount == 2)
    }

    @Test func retriesAfterFailedOpen() async throws {
        let fake = FakePosts(failTimes: 1)
        let holder = TurnThreadHolder(channel: fake.channel(), name: "work")
        do {
            _ = try await holder.get()
            Issue.record("expected failure")
        } catch {
            #expect(!holder.opened)
        }
        let t = try await holder.get()
        #expect(t.id == "t2")
        #expect(fake.createCount == 2)
    }

    @Test func registryMainAndSubagent() async throws {
        let fake = FakePosts()
        let reg = TurnThreadRegistry(channel: fake.channel(), mainName: "작업 내역")
        _ = try await reg.getForToolUse(id: "t1", name: "Bash", input: .object(["command": .string("ls")]), parentToolUseId: nil)
        _ = try await reg.getForToolUse(
            id: "spawn1", name: "Task",
            input: .object(["subagent_type": .string("reviewer")]),
            parentToolUseId: nil
        )
        #expect(fake.names == ["작업 내역", "reviewer"])
        #expect(isSubagentSpawnTool("Task"))
        #expect(subagentThreadName(name: "Task", input: .object(["description": .string("do it")])) == "do it")
    }

    @Test func subagentTitlePrefersNicknameAndNormalizesUnsafeLongInput() {
        let nickname = "  Scout\n\u{0000}" + String(repeating: "x", count: 150)
        let title = subagentThreadName(name: "Task", input: .object([
            "agentNickname": .string(nickname),
            "agentName": .string("other"),
            "subagent_type": .string("developer"),
        ]))
        #expect(title.hasPrefix("Scout "))
        #expect(!title.contains("\n"))
        #expect(!title.contains("\u{0000}"))
        #expect(title.count <= DiscordText.threadNameLimit)
    }

    @Test func collidingLongNicknamesKeepSpawnSuffix() async throws {
        let fake = FakePosts()
        let reg = TurnThreadRegistry(channel: fake.channel(), mainName: "작업 내역")
        let nickname = String(repeating: "Scout ", count: 30)
        _ = try await reg.getForToolUse(id: "spawn-abcdef", name: "Task", input: .object(["agentNickname": .string(nickname)]), parentToolUseId: nil)
        _ = try await reg.getForToolUse(id: "spawn-123456", name: "Task", input: .object(["agentNickname": .string(nickname)]), parentToolUseId: nil)
        _ = try await reg.getForToolUse(id: "other-123456", name: "Task", input: .object(["agentNickname": .string(nickname)]), parentToolUseId: nil)
        #expect(fake.names.count == 3)
        #expect(Set(fake.names).count == 3)
        #expect(fake.names[1].hasSuffix(" · 123456"))
        #expect(fake.names[2].hasSuffix(" · 123456-2"))
        #expect(fake.names.allSatisfy { $0.count <= DiscordText.threadNameLimit })
    }
}

@Suite("ToolThreadHandler")
struct ToolThreadHandlerTests {
    @Test func postsSummaryAndResultIntoSharedThread() async {
        let fake = FakePosts()
        let reg = TurnThreadRegistry(channel: fake.channel(), mainName: "작업 내역")
        let h = ToolThreadHandler(registry: reg)
        await h.handleToolUse(id: "t1", name: "Bash", input: .object(["command": .string("ls -la")]), parentToolUseId: nil)
        await h.handleToolResult(id: "t1", ok: true, content: "output", parentToolUseId: nil)
        #expect(fake.names == ["작업 내역"])
        let contents = fake.posts.map(\.content)
        #expect(contents.contains { $0.contains("● **Bash** `ls -la`") })
        #expect(contents.contains { $0.hasPrefix("⎿ Bash · 1줄") })
        #expect(contents.contains { $0.contains("output") })
        // The old JSON dump of the input is gone.
        #expect(!contents.contains { $0.contains("\"command\"") })
    }

    @Test func reusesOneThreadForMultipleMainTools() async {
        let fake = FakePosts()
        let reg = TurnThreadRegistry(channel: fake.channel(), mainName: "작업 내역")
        let h = ToolThreadHandler(registry: reg)
        await h.handleToolUse(id: "t1", name: "Bash", input: .object(["command": .string("ls")]), parentToolUseId: nil)
        await h.handleToolUse(id: "t2", name: "Grep", input: .object(["pattern": .string("x")]), parentToolUseId: nil)
        #expect(fake.names.count == 1)
    }

    @Test func buffersEarlyResultAndFlushesOnToolUse() async {
        let fake = FakePosts()
        let reg = TurnThreadRegistry(channel: fake.channel(), mainName: "작업 내역")
        let h = ToolThreadHandler(registry: reg)
        await h.handleToolResult(id: "t9", ok: true, content: "early", parentToolUseId: nil)
        #expect(fake.posts.isEmpty)
        await h.handleToolUse(id: "t9", name: "Read", input: .object(["file_path": .string("/ws/x")]), parentToolUseId: nil)
        let contents = fake.posts.map(\.content)
        #expect(contents.contains { $0.contains("early") })
        #expect(contents.contains { $0.contains("Read") })
    }

    @Test func skipsRawInputForEditButPostsResult() async {
        let fake = FakePosts()
        let reg = TurnThreadRegistry(channel: fake.channel(), mainName: "작업 내역")
        let h = ToolThreadHandler(registry: reg)
        await h.handleToolUse(
            id: "t1", name: "Edit",
            input: .object([
                "file_path": .string("/ws/a.ts"),
                "old_string": .string("a"),
                "new_string": .string("b"),
            ]),
            parentToolUseId: nil
        )
        await h.handleToolResult(id: "t1", ok: true, content: "done", parentToolUseId: nil)
        let contents = fake.posts.map(\.content)
        #expect(!contents.contains { $0.contains("\"file_path\"") })
        #expect(contents.contains { $0.hasPrefix("⎿ Edit · 1줄") })
    }

    @Test func errorHeaderOnFailedResult() async {
        let fake = FakePosts()
        let reg = TurnThreadRegistry(channel: fake.channel(), mainName: "작업 내역")
        let h = ToolThreadHandler(registry: reg)
        await h.handleToolUse(id: "t1", name: "Bash", input: .object(["command": .string("nope")]), parentToolUseId: nil)
        await h.handleToolResult(id: "t1", ok: false, content: "boom", parentToolUseId: nil)
        let contents = fake.posts.map(\.content)
        #expect(contents.contains { $0.contains("오류") })
        #expect(contents.contains { $0.contains("boom") })
    }

    @Test func resetTurnDropsBufferedResult() async {
        let fake = FakePosts()
        let reg = TurnThreadRegistry(channel: fake.channel(), mainName: "작업 내역")
        let h = ToolThreadHandler(registry: reg)
        await h.handleToolResult(id: "t1", ok: true, content: "stale", parentToolUseId: nil)
        h.resetTurn()
        reg.reset()
        await h.handleToolUse(id: "t2", name: "Bash", input: .object(["command": .string("ls")]), parentToolUseId: nil)
        let contents = fake.posts.map(\.content)
        #expect(!contents.contains { $0.contains("stale") })
    }
}

@Suite("DiffViewHandler")
struct DiffViewHandlerTests {
    @Test func rendersEditDiffIntoSharedThread() async {
        let fake = FakePosts()
        let reg = TurnThreadRegistry(channel: fake.channel(), mainName: "작업 내역")
        let h = DiffViewHandler(registry: reg)
        h.noteToolUse(
            id: "t1", name: "Edit",
            input: .object([
                "file_path": .string("/ws/a.ts"),
                "old_string": .string("a"),
                "new_string": .string("b"),
            ]),
            parentToolUseId: nil
        )
        await h.handleResult(id: "t1", ok: true, content: "ok", parentToolUseId: nil)
        #expect(fake.names == ["작업 내역"])
        #expect(fake.posts.count == 1)
        let body = fake.posts[0].content
        #expect(body.contains("```diff"))
        #expect(body.contains("- a"))
        #expect(body.contains("+ b"))
    }

    @Test func skipsNonEditAndFailed() async {
        let fake = FakePosts()
        let reg = TurnThreadRegistry(channel: fake.channel(), mainName: "작업 내역")
        let h = DiffViewHandler(registry: reg)
        h.noteToolUse(id: "t3", name: "Bash", input: .object(["command": .string("ls")]), parentToolUseId: nil)
        await h.handleResult(id: "t3", ok: true, content: "files", parentToolUseId: nil)
        #expect(fake.posts.isEmpty)
        h.noteToolUse(
            id: "t4", name: "Edit",
            input: .object([
                "file_path": .string("/ws/a.ts"),
                "old_string": .string("a"),
                "new_string": .string("b"),
            ]),
            parentToolUseId: nil
        )
        await h.handleResult(id: "t4", ok: false, content: "error", parentToolUseId: nil)
        #expect(fake.posts.isEmpty)
    }

    @Test func nestedEditIntoParentSpawnThread() async {
        let fake = FakePosts()
        let reg = TurnThreadRegistry(channel: fake.channel(), mainName: "작업 내역")
        let h = DiffViewHandler(registry: reg)
        _ = try? await reg.getForToolUse(
            id: "spawn1", name: "Task",
            input: .object(["subagent_type": .string("reviewer")]),
            parentToolUseId: nil
        )
        h.noteToolUse(
            id: "e1", name: "Edit",
            input: .object([
                "file_path": .string("/ws/a.ts"),
                "old_string": .string("x"),
                "new_string": .string("y"),
            ]),
            parentToolUseId: "spawn1"
        )
        await h.handleResult(id: "e1", ok: true, content: "ok", parentToolUseId: "spawn1")
        #expect(fake.names == ["reviewer"])
        #expect(fake.posts[0].content.contains("+ y"))
    }
}
