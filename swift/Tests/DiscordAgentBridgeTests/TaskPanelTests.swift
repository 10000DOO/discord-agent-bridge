import Testing
import Foundation
@testable import DiscordAgentBridge

// docs/task-panel-and-diff-view.md WO-1 · WO-2 (R1~R5, R9).

// MARK: - Parsing (WO-1)

@Suite struct TaskPanelParseTests {
    @Test func parsesClaudeTodoWrite() {
        let input = JSONValue.object([
            "todos": .array([
                .object(["content": .string("구조 파악"), "status": .string("completed"), "activeForm": .string("파악 중")]),
                .object(["content": .string("액터 추가"), "status": .string("in_progress")]),
                .object(["content": .string("테스트"), "status": .string("pending")]),
            ]),
        ])
        let items = parseTaskPanelInput(name: "TodoWrite", input: input)
        #expect(items?.count == 3)
        #expect(items?[0] == TaskPanelItem(text: "구조 파악", status: .completed))
        #expect(items?[1].status == .inProgress)
        #expect(items?[2].status == .pending)
    }

    @Test func parsesCodexUpdatePlan() {
        let input = JSONValue.object([
            "explanation": .string("무시됨"),
            "plan": .array([
                .object(["step": .string("read files"), "status": .string("completed")]),
                .object(["step": .string("write code"), "status": .string("in_progress")]),
            ]),
        ])
        let items = parseTaskPanelInput(name: "update_plan", input: input)
        #expect(items?.map(\.text) == ["read files", "write code"])
        #expect(items?.map(\.status) == [.completed, .inProgress])
    }

    @Test func unknownStatusFallsBackToPending() {
        let input = JSONValue.object([
            "todos": .array([.object(["content": .string("a"), "status": .string("weird")])]),
        ])
        #expect(parseTaskPanelInput(name: "TodoWrite", input: input)?[0].status == .pending)
    }

    @Test func otherToolsAndEmptyListsYieldNil() {
        let bash = JSONValue.object(["command": .string("ls")])
        #expect(parseTaskPanelInput(name: "Bash", input: bash) == nil)
        #expect(parseTaskPanelInput(name: "TodoWrite", input: .object(["todos": .array([])])) == nil)
        // An entry with no usable text is dropped, and a list of only those is nil, not an empty panel.
        let blank = JSONValue.object(["todos": .array([.object(["content": .string("   ")])])])
        #expect(parseTaskPanelInput(name: "TodoWrite", input: blank) == nil)
    }

    @Test func parsesGrokPlanUpdate() {
        let params = JSONValue.object([
            "update": .object([
                "sessionUpdate": .string("plan"),
                "entries": .array([
                    .object(["content": .string("설계"), "status": .string("completed")]),
                    .object(["content": .string("구현"), "status": .string("in_progress")]),
                ]),
            ]),
        ])
        let items = grokPlanItems(method: "session/update", params: params)
        #expect(items?.map(\.text) == ["설계", "구현"])
        // A non-plan update must fall through so the caller keeps its existing path.
        let thought = JSONValue.object([
            "update": .object(["sessionUpdate": .string("agent_thought_chunk"), "content": .object(["text": .string("hm")])]),
        ])
        #expect(grokPlanItems(method: "session/update", params: thought) == nil)
        #expect(grokPlanItems(method: "other/method", params: params) == nil)
    }
}

// MARK: - Formatting (WO-1)

@Suite struct TaskPanelFormatTests {
    @Test func marksMatchTheGrokPlanConvention() {
        // Same three marks the existing grok plan lines use — one convention across the product.
        #expect(TaskPanelStatus.completed.mark == planStatusMark("completed"))
        #expect(TaskPanelStatus.inProgress.mark == planStatusMark("in_progress"))
        #expect(TaskPanelStatus.pending.mark == planStatusMark(nil))
    }

    @Test func inProgressPanelCountsDoneAndStaysYellow() {
        let spec = formatTaskPanel(items: [
            TaskPanelItem(text: "a", status: .completed),
            TaskPanelItem(text: "b", status: .inProgress),
            TaskPanelItem(text: "c", status: .pending),
        ])
        #expect(spec.description == "✓ a\n▶ b\n• c")
        #expect(spec.color == DiscordColors.streaming)
        #expect(spec.title.contains("1/3"))
    }

    @Test func allDoneSwitchesTitleAndColor() {
        let spec = formatTaskPanel(items: [
            TaskPanelItem(text: "a", status: .completed),
            TaskPanelItem(text: "b", status: .completed),
        ])
        #expect(spec.color == DiscordColors.idle)
        #expect(spec.description == "✓ a\n✓ b")
    }

    @Test func longListIsTruncatedToTheEmbedLimit() {
        let items = (0..<600).map { TaskPanelItem(text: "task \($0) " + String(repeating: "x", count: 40), status: .pending) }
        #expect(formatTaskPanel(items: items).description.count <= taskPanelDescLimit)
    }
}

// MARK: - Boot adoption + permission bits (WO-4 · WO-5)

@Suite struct TaskPanelAdoptionTests {
    @Test func recognizesOwnPanelBodyInAnyLocale() {
        #expect(isTaskPanelDescription("✓ done\n▶ doing\n• todo"))
        // Blank lines are ignored, not treated as a mismatch.
        #expect(isTaskPanelDescription("✓ done\n\n• todo"))
    }

    @Test func rejectsForeignMessageBodies() {
        #expect(!isTaskPanelDescription(""))
        #expect(!isTaskPanelDescription("hello world"))
        #expect(!isTaskPanelDescription("✓ done\nplain line"))
    }

    @Test func requiredPermissionsIncludeManageMessages() {
        let bits = botRequiredPermissionBits
        #expect(bits & (1 << 13) != 0, "pinning needs Manage Messages")
        // The README's original invite set must still be covered.
        for shift in [4, 6, 10, 11, 14, 15, 16, 34, 35, 38] {
            #expect(bits & (1 << UInt64(shift)) != 0, "missing permission bit \(shift)")
        }
    }

    @Test func reinviteURLCarriesClientIdAndPermissions() {
        let url = botReinviteURL(applicationId: "12345")
        #expect(url.contains("client_id=12345"))
        #expect(url.contains("permissions=\(botRequiredPermissionBits)"))
        #expect(url.contains("scope=bot%20applications.commands"))
    }
}

// MARK: - Host lifecycle (WO-2)

private final class FakePanelSink: @unchecked Sendable {
    struct Call: Equatable {
        var channelId: String
        var messageId: String?
        var title: String
        var description: String
    }

    private let box = LockedBox([Call]())
    private let removals = LockedBox([String]())
    private let idBox = LockedBox(0)
    let failCreate: Bool

    init(failCreate: Bool = false) {
        self.failCreate = failCreate
    }

    var calls: [Call] { box.withLock { $0 } }
    var removed: [String] { removals.withLock { $0 } }

    func sink() -> TaskPanelSink {
        { channelId, messageId, spec in
            self.box.withLock {
                $0.append(Call(channelId: channelId, messageId: messageId, title: spec.title, description: spec.description))
            }
            if let messageId { return messageId }
            if self.failCreate { return nil }
            let next = self.idBox.withLock { value -> Int in
                value += 1
                return value
            }
            return "msg-\(next)"
        }
    }

    func remover() -> TaskPanelRemover {
        { _, messageId in
            self.removals.withLock { $0.append(messageId) }
        }
    }
}

@Suite struct TaskPanelHostTests {
    /// Zero debounce keeps the tests deterministic without sleeping out the real 1s interval.
    private func makeHost(_ fake: FakePanelSink) async -> TaskPanelHost {
        let host = TaskPanelHost(flushInterval: 0)
        await host.setSink(fake.sink())
        await host.setRemover(fake.remover())
        return host
    }

    private func settle() async throws {
        try await Task.sleep(nanoseconds: 80_000_000)
    }

    @Test func firstUpdateCreatesThenLaterUpdatesEdit() async throws {
        let fake = FakePanelSink()
        let host = await makeHost(fake)
        await host.noteItems(channelId: "c1", items: [TaskPanelItem(text: "a", status: .pending)])
        try await settle()
        await host.noteItems(channelId: "c1", items: [TaskPanelItem(text: "a", status: .completed)])
        try await settle()

        let calls = fake.calls
        #expect(calls.count == 2)
        // R2-1: the create is the only call without a message id — nothing re-pins afterwards.
        #expect(calls[0].messageId == nil)
        #expect(calls[1].messageId == "msg-1")
        #expect(await host.panelMessageId(channelId: "c1") == "msg-1")
    }

    @Test func identicalListDoesNotRepost() async throws {
        let fake = FakePanelSink()
        let host = await makeHost(fake)
        let items = [TaskPanelItem(text: "a", status: .inProgress)]
        await host.noteItems(channelId: "c1", items: items)
        try await settle()
        await host.noteItems(channelId: "c1", items: items)
        try await settle()
        #expect(fake.calls.count == 1)
    }

    @Test func emptyListIsIgnoredSoAPreviousPanelSurvives() async throws {
        // R2-2: a turn that publishes nothing must leave the standing list alone.
        let fake = FakePanelSink()
        let host = await makeHost(fake)
        await host.noteItems(channelId: "c1", items: [TaskPanelItem(text: "a", status: .pending)])
        try await settle()
        await host.noteItems(channelId: "c1", items: [])
        try await settle()
        #expect(fake.calls.count == 1)
    }

    @Test func disposeRemovesThePanelAndForgetsTheChannel() async throws {
        let fake = FakePanelSink()
        let host = await makeHost(fake)
        await host.noteItems(channelId: "c1", items: [TaskPanelItem(text: "a", status: .pending)])
        try await settle()
        await host.dispose(channelId: "c1")
        #expect(fake.removed == ["msg-1"])
        #expect(await host.panelMessageId(channelId: "c1") == nil)
        // A later update starts over with a create rather than editing the deleted message.
        await host.noteItems(channelId: "c1", items: [TaskPanelItem(text: "b", status: .pending)])
        try await settle()
        #expect(fake.calls.last?.messageId == nil)
    }

    @Test func adoptedPanelIsEditedInsteadOfRecreated() async throws {
        // R2-3: boot recovery hands the existing pinned message back to the host.
        let fake = FakePanelSink()
        let host = await makeHost(fake)
        await host.adopt(channelId: "c1", messageId: "pinned-9")
        await host.noteItems(channelId: "c1", items: [TaskPanelItem(text: "a", status: .pending)])
        try await settle()
        #expect(fake.calls.count == 1)
        #expect(fake.calls[0].messageId == "pinned-9")
    }

    @Test func failedCreateIsRetriedOnTheNextUpdate() async throws {
        let fake = FakePanelSink(failCreate: true)
        let host = await makeHost(fake)
        await host.noteItems(channelId: "c1", items: [TaskPanelItem(text: "a", status: .pending)])
        try await settle()
        await host.noteItems(channelId: "c1", items: [TaskPanelItem(text: "b", status: .pending)])
        try await settle()
        #expect(fake.calls.count == 2)
        #expect(fake.calls.allSatisfy { $0.messageId == nil })
    }

    @Test func channelsAreIndependent() async throws {
        let fake = FakePanelSink()
        let host = await makeHost(fake)
        await host.noteItems(channelId: "c1", items: [TaskPanelItem(text: "a", status: .pending)])
        await host.noteItems(channelId: "c2", items: [TaskPanelItem(text: "b", status: .pending)])
        try await settle()
        #expect(Set(fake.calls.map(\.channelId)) == ["c1", "c2"])
    }
}
