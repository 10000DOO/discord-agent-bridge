import Testing
@testable import DiscordAgentBridge

@Suite("SlashCatalog autocomplete filtering")
struct SlashCatalogTests {
    // Fixture shape mirrors the 2026-08-05 live measurements recorded in
    // docs/cli-slash-command-parity.md §3-5-3 (Claude 86 / Grok 78 / Codex 14).
    private let entries = [
        SlashCatalogEntry(name: "compact", description: "Free up context by summarizing", argumentHint: "<optional custom summarization instructions>"),
        SlashCatalogEntry(name: "context", description: "Show context window usage"),
        SlashCatalogEntry(name: "code-review", description: "Review the current diff", argumentHint: "[<target>]"),
        SlashCatalogEntry(name: "ponytail:ponytail-help", description: "Quick-reference card"),
        SlashCatalogEntry(name: "xcode-build-verify", description: "Verify the build compiles cleanly"),
    ]

    @Test func emptyQueryReturnsEverythingInOrder() {
        let out = filterSlashCatalogChoices(entries, query: "")
        #expect(out.count == entries.count)
        #expect(out.map(\.value) == entries.map(\.name))
    }

    @Test func whitespaceOnlyQueryIsTreatedAsEmpty() {
        #expect(filterSlashCatalogChoices(entries, query: "   ").count == entries.count)
    }

    @Test func queryMatchesNameCaseInsensitively() {
        let out = filterSlashCatalogChoices(entries, query: "PONY")
        #expect(out.map(\.value) == ["ponytail:ponytail-help"])
    }

    @Test func queryAlsoMatchesDescription() {
        // A user who remembers the blurb but not the command name still finds it.
        let out = filterSlashCatalogChoices(entries, query: "summarizing")
        #expect(out.map(\.value) == ["compact"])
    }

    @Test func choiceNameCarriesDescriptionAndHint() {
        let out = filterSlashCatalogChoices(entries, query: "compact")
        #expect(out.first?.name == "compact — Free up context by summarizing · <optional custom summarization instructions>")
        // The submitted value stays the bare command name — that is what gets sent as "/name".
        #expect(out.first?.value == "compact")
    }

    @Test func hintIsOmittedWhenBackendReportsNone() {
        // "context" also hits compact's blurb ("...summarizing" mentions context), which is the
        // intended description match — so select by value rather than assuming a single hit.
        let out = filterSlashCatalogChoices(entries, query: "context")
        #expect(out.first(where: { $0.value == "context" })?.name == "context — Show context window usage")
    }

    @Test func emptyDescriptionLeavesTheBareName() {
        let out = filterSlashCatalogChoices([SlashCatalogEntry(name: "wrap", description: "")], query: "")
        #expect(out.first?.name == "wrap")
    }

    @Test func choiceNameIsClampedToDiscordLimit() {
        let long = SlashCatalogEntry(name: "impact-analysis", description: String(repeating: "가", count: 200))
        let out = filterSlashCatalogChoices([long], query: "")
        #expect(out.first?.name.count == 100)
        // The value must survive intact even when the display name is truncated.
        #expect(out.first?.value == "impact-analysis")
    }

    @Test func resultsAreCappedAtDiscordLimit() {
        // Grok reports 78 commands live; Discord accepts at most 25 suggestions.
        let many = (0..<78).map { SlashCatalogEntry(name: "cmd\($0)", description: "d") }
        #expect(filterSlashCatalogChoices(many, query: "").count == discordAutocompleteChoiceLimit)
    }

    @Test func negativeLimitYieldsNothingRatherThanTrapping() {
        #expect(filterSlashCatalogChoices(entries, query: "", limit: -1).isEmpty)
    }
}
