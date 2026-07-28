import Foundation
import Testing
@testable import DiscordAgentBridge

@Suite("RedmineStatusResolver")
struct RedmineStatusResolverTests {
    private let statuses = [
        RedmineStatusDTO(id: 1, name: "신규"),
        RedmineStatusDTO(id: 2, name: "New"),
        RedmineStatusDTO(id: 3, name: "진행"),
        RedmineStatusDTO(id: 4, name: "Doing"),
        RedmineStatusDTO(id: 5, name: "완료"),
        RedmineStatusDTO(id: 6, name: "Closed"),
    ]

    /// RSupport-style bilingual labels (live API: `신규(New)`, `진행(Doing)`).
    private let bilingualStatuses = [
        RedmineStatusDTO(id: 1, name: "신규(New)"),
        RedmineStatusDTO(id: 2, name: "진행(Doing)"),
        RedmineStatusDTO(id: 3, name: "해결(Complete)"),
        RedmineStatusDTO(id: 7, name: "보류(Pause)"),
    ]

    @Test func targetStatusNamesIsFourTerms() {
        #expect(RedmineStatusResolver.targetStatusNames == ["신규", "New", "진행", "Doing"])
    }

    @Test func resolvesNewAndInProgressIdsOnly() {
        let ids = RedmineStatusResolver.resolveTargetIds(statuses: statuses)
        #expect(ids == [1, 2, 3, 4])
    }

    @Test func matchesRegardlessOfCase() {
        let ids = RedmineStatusResolver.resolveIds(statuses: statuses, names: ["new", "NEW"])
        #expect(ids == [2])
    }

    @Test func excludesNamesNotInCandidates() {
        let ids = RedmineStatusResolver.resolveIds(statuses: statuses, names: RedmineStatusResolver.newStatusNames)
        #expect(!ids.contains(5))
        #expect(!ids.contains(6))
    }

    @Test func resolvesBilingualLabelsLikeRSupport() {
        let ids = RedmineStatusResolver.resolveTargetIds(statuses: bilingualStatuses)
        #expect(ids == [1, 2])
        #expect(!ids.contains(3))
        #expect(!ids.contains(7))
    }

    @Test func bilingualMatchesEnglishParentheticalCandidate() {
        // candidate "New" must match status "신규(New)" via (new)
        #expect(RedmineStatusResolver.name("신규(New)", matches: "New"))
        #expect(RedmineStatusResolver.name("진행(Doing)", matches: "Doing"))
        #expect(RedmineStatusResolver.name("신규(New)", matches: "신규"))
        #expect(!RedmineStatusResolver.name("해결(Complete)", matches: "New"))
    }
}
