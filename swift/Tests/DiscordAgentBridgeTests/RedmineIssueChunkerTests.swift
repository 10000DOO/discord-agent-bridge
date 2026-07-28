import Foundation
import Testing
@testable import DiscordAgentBridge

@Suite("RedmineIssueChunker")
struct RedmineIssueChunkerTests {
    private func issue(id: Int) -> RedmineIssueDTO {
        RedmineIssueDTO(
            id: id,
            subject: "Issue \(id)",
            description: "desc",
            projectName: "Sample",
            projectId: 1,
            statusId: 1,
            createdOn: "2026-07-28T00:00:00Z",
            url: "https://redmine.example.com/issues/\(id)"
        )
    }

    @Test func emptyInputProducesNoChunks() {
        #expect(RedmineIssueChunker.chunk([]).isEmpty)
    }

    @Test func atLimitProducesOneChunkUnchanged() {
        let issues = (1...25).map { issue(id: $0) }
        let chunks = RedmineIssueChunker.chunk(issues)
        #expect(chunks.count == 1)
        #expect(chunks[0].count == 25)
    }

    @Test func aboveLimitSplitsIntoFullChunkPlusRemainder() {
        let issues = (1...26).map { issue(id: $0) }
        let chunks = RedmineIssueChunker.chunk(issues)
        #expect(chunks.count == 2)
        #expect(chunks[0].map(\.id) == Array(1...25))
        #expect(chunks[1].map(\.id) == [26])
    }

    @Test func exactMultipleOfLimitProducesNoEmptyTrailingChunk() {
        let issues = (1...50).map { issue(id: $0) }
        let chunks = RedmineIssueChunker.chunk(issues)
        #expect(chunks.count == 2)
        #expect(chunks[0].count == 25)
        #expect(chunks[1].count == 25)
    }

    @Test func everyIssueIsPreservedAcrossChunksNoneDropped() {
        let issues = (1...77).map { issue(id: $0) }
        let chunks = RedmineIssueChunker.chunk(issues)
        #expect(chunks.flatMap { $0 }.map(\.id) == Array(1...77))
    }

    @Test func genericChunkWorksForNonIssueTypes() {
        let numbers = Array(1...30)
        let chunks = RedmineIssueChunker.chunk(numbers)
        #expect(chunks.count == 2)
        #expect(chunks[0].count == 25)
        #expect(chunks[1].count == 5)
    }

    // WO-5c (2026-07-28 user directive, reverses 3-3 D3): buildRedmineSessionSelectMenus appends
    // the "신규 세션" sentinel to EVERY chunk (not just the last), so a user can start a new
    // session from any page without paging to the last one. Chunk size stays at
    // (maxOptionsPerMenu - 1) from WO-5b — that already leaves room for the sentinel on the
    // largest chunk. Mirrors the chunk-then-append-sentinel-to-every-chunk logic in
    // RedmineSessionPicker.buildRedmineSessionSelectMenus.
    @Test func sentinelAppendedToEveryChunkKeepsAllMenusAtOrUnderCap() {
        let sentinelChunkSize = RedmineIssueChunker.maxOptionsPerMenu - 1
        let cases: [(sessionCount: Int, expectedMenuOptionCounts: [Int])] = [
            (0, [1]),
            (24, [25]),
            (25, [25, 2]),
            (48, [25, 25]),
        ]
        for testCase in cases {
            let sessions = Array(repeating: 0, count: testCase.sessionCount)
            let chunks = RedmineIssueChunker.chunk(sessions, size: sentinelChunkSize)
            let sessionChunks = chunks.isEmpty ? [[]] : chunks
            let menuOptionCounts = sessionChunks.map { $0.count + 1 } // +1 for the sentinel on every chunk
            #expect(menuOptionCounts == testCase.expectedMenuOptionCounts)
            #expect(menuOptionCounts.allSatisfy { $0 <= RedmineIssueChunker.maxOptionsPerMenu })
        }
    }
}
