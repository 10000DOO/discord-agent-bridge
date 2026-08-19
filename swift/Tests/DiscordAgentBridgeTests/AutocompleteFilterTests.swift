import Testing
@testable import DiscordAgentBridge

@Suite("G-P1-03 autocomplete filter")
struct AutocompleteFilterTests {
    private let sample: [ModelChoice] = [
        ModelChoice(value: "opus", label: "Opus"),
        ModelChoice(value: "sonnet", label: "Sonnet"),
        ModelChoice(value: "haiku", label: "Haiku"),
        ModelChoice(value: "claude-fable-5[1m]", label: "Fable 5"),
    ]

    @Test func emptyQueryReturnsAllAsNameValue() {
        #expect(filterAutocompleteChoices(sample, query: "") == [
            AutocompleteChoice(name: "Opus", value: "opus"),
            AutocompleteChoice(name: "Sonnet", value: "sonnet"),
            AutocompleteChoice(name: "Haiku", value: "haiku"),
            AutocompleteChoice(name: "Fable 5", value: "claude-fable-5[1m]"),
        ])
        #expect(filterAutocompleteChoices(sample, query: "   ") == filterAutocompleteChoices(sample, query: ""))
    }

    @Test func filtersCaseInsensitivelyOnValueOrLabel() {
        #expect(filterAutocompleteChoices(sample, query: "OP") == [
            AutocompleteChoice(name: "Opus", value: "opus"),
        ])
        #expect(filterAutocompleteChoices(sample, query: "fable") == [
            AutocompleteChoice(name: "Fable 5", value: "claude-fable-5[1m]"),
        ])
        #expect(filterAutocompleteChoices(sample, query: "SONNET") == [
            AutocompleteChoice(name: "Sonnet", value: "sonnet"),
        ])
        #expect(filterAutocompleteChoices(sample, query: "xyz").isEmpty)
    }

    @Test func capsAtDiscordLimitOf25() {
        let many = (0..<40).map { ModelChoice(value: "m-\($0)", label: "Model \($0)") }
        let all = filterAutocompleteChoices(many, query: "")
        #expect(all.count == discordAutocompleteChoiceLimit)
        #expect(all.first?.value == "m-0")
        #expect(all.last?.value == "m-24")
        #expect(filterAutocompleteChoices(many, query: "", limit: 3).count == 3)
        #expect(filterAutocompleteChoices(many, query: "", limit: 0).isEmpty)
    }

    @Test func effortRuntimeChoicesPassThroughFilter() {
        // Claude runtime set (narrowed at the catalog layer); filter only trims by query.
        let efforts = choices(["low", "medium", "high", "xhigh", "max"])
        // "med" uniquely hits medium; "hi" would also match xhigh (contains).
        #expect(filterAutocompleteChoices(efforts, query: "med") == [
            AutocompleteChoice(name: "medium", value: "medium"),
        ])
        #expect(filterAutocompleteChoices(efforts, query: "xhi") == [
            AutocompleteChoice(name: "xhigh", value: "xhigh"),
        ])
        #expect(filterAutocompleteChoices(efforts, query: "").map(\.value) == ["low", "medium", "high", "xhigh", "max"])
    }
}
