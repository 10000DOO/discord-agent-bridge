import Testing
import Foundation
@testable import DiscordAgentBridge

@Suite("AnswerDelivery")
struct AnswerDeliveryTests {
    private func fakeRenderer(failIfContains: String = "FAIL") -> ImageRenderFn {
        { seg in
            if seg.raw.contains(failIfContains) { return nil }
            return RenderedImage(data: Data("png:\(seg.kind)".utf8), name: "\(seg.kind).png")
        }
    }

    @Test func noRendererPlainChunkedText() async throws {
        let sends = LockedBox<[DeliverPayload]>([])
        try await deliverAnswer(
            "just text",
            options: DeliverOptions(
                renderImage: nil,
                emit: { p in sends.withLock { $0.append(p) } }
            )
        )
        let out = sends.withLock { $0 }
        #expect(out.count == 1)
        #expect(out[0].content == "just text")
        #expect(out[0].fileData == nil)
    }

    @Test func rendersTableBetweenProseInOrder() async throws {
        let sends = LockedBox<[DeliverPayload]>([])
        let md = "before\n\n| a | b |\n|---|---|\n| 1 | 2 |\n\nafter"
        try await deliverAnswer(
            md,
            options: DeliverOptions(
                renderImage: fakeRenderer(),
                emit: { p in sends.withLock { $0.append(p) } }
            )
        )
        let out = sends.withLock { $0 }
        #expect(out.count == 3)
        #expect(out[0].content == "before")
        #expect(out[1].fileName == "table.png")
        #expect(out[2].content == "after")
    }

    @Test func fallsBackToRawWhenRendererReturnsNil() async throws {
        let sends = LockedBox<[DeliverPayload]>([])
        let md = "```mermaid\nFAIL bad diagram\n```"
        try await deliverAnswer(
            md,
            options: DeliverOptions(
                renderImage: fakeRenderer(),
                emit: { p in sends.withLock { $0.append(p) } }
            )
        )
        let out = sends.withLock { $0 }
        #expect(out.count == 1)
        #expect(out[0].content == "```mermaid\nFAIL bad diagram\n```")
        #expect(out[0].fileData == nil)
    }

    @Test func emptyAnswerCallsClearEmpty() async throws {
        let cleared = LockedBox(false)
        try await deliverAnswer(
            "",
            options: DeliverOptions(
                renderImage: nil,
                emit: { _ in Issue.record("should not emit") },
                clearEmpty: { cleared.withLock { $0 = true } }
            )
        )
        #expect(cleared.withLock { $0 })
    }

    @Test func mermaidSuccessEmitsDiagramPng() async throws {
        let sends = LockedBox<[DeliverPayload]>([])
        let md = "```mermaid\nflowchart LR\n  A --> B\n```"
        try await deliverAnswer(
            md,
            options: DeliverOptions(
                renderImage: fakeRenderer(),
                emit: { p in sends.withLock { $0.append(p) } }
            )
        )
        let out = sends.withLock { $0 }
        #expect(out.count == 1)
        #expect(out[0].fileName == "mermaid.png")
    }
}
