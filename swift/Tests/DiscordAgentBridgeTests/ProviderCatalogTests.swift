import Testing
@testable import DiscordAgentBridge

@Suite("ProviderCatalog effort narrowing")
struct ProviderCatalogEffortTests {
    // Mirrors src/core/providerCatalog.ts:157-185 narrowing.

    @Test func startEffortFallsBackToBaseWhenLevelsMissing() {
        let base = ["minimal", "low", "medium", "high", "xhigh"]
        #expect(narrowStartEffort(base: base, modelLevels: nil) == base)
        #expect(narrowStartEffort(base: base, modelLevels: []) == base)
    }

    @Test func startEffortUsesModelLevelsVerbatimWhenPresent() {
        let base = ["minimal", "low", "medium", "high"]
        #expect(narrowStartEffort(base: base, modelLevels: ["low", "high"]) == ["low", "high"])
        // Model levels win as-is even when not a subset of base (start-time keeps 'max').
        #expect(narrowStartEffort(base: base, modelLevels: ["max"]) == ["max"])
    }

    @Test func runtimeEffortFallsBackToRuntimeBaseWhenLevelsMissing() {
        let runtimeBase = ["low", "medium", "high", "xhigh"]
        #expect(narrowRuntimeEffort(runtimeBase: runtimeBase, modelLevels: nil) == runtimeBase)
        #expect(narrowRuntimeEffort(runtimeBase: runtimeBase, modelLevels: []) == runtimeBase)
    }

    @Test func runtimeEffortIntersectsPreservingRuntimeOrder() {
        let runtimeBase = ["low", "medium", "high", "xhigh"]
        // Partial intersection: shared levels only, in runtimeBase order; 'max' dropped.
        #expect(narrowRuntimeEffort(runtimeBase: runtimeBase, modelLevels: ["high", "low", "max"]) == ["low", "high"])
        // Full intersection: every runtime level survives, order preserved.
        #expect(narrowRuntimeEffort(runtimeBase: runtimeBase, modelLevels: ["xhigh", "low", "medium", "high"]) == runtimeBase)
        // Disjoint: empty.
        #expect(narrowRuntimeEffort(runtimeBase: runtimeBase, modelLevels: ["max"]) == [])
    }

    @Test func choicesWrapValuesAsLabelEqualsValueWithNoNestedLevels() {
        // RHS uses the default nil supportedEffortLevels, so equality also asserts nil.
        #expect(choices(["low", "high"]) == [
            ModelChoice(value: "low", label: "low"),
            ModelChoice(value: "high", label: "high"),
        ])
        #expect(choices([]).isEmpty)
    }
}

// Storage keeps the SDK alias; every user-facing surface names the wire id it points at.
// Keys here are deliberately unique so the process-wide map cannot collide with another suite.
@Suite("ProviderCatalog model display")
struct ProviderCatalogDisplayTests {
    @Test func remembersAliasToWireIdAndPrintsIt() {
        ModelDisplayCatalog.remember([
            ModelChoice(value: "zzopus[1m]", label: "Opus (1M context)", resolvedModel: "claude-zzopus-5[1m]"),
        ])
        #expect(modelDisplayText("zzopus[1m]") == "claude-zzopus-5[1m]")
    }

    @Test func repointedAliasChangesTheTextWithoutTouchingStorage() {
        let stored = "zzfollow[1m]"
        ModelDisplayCatalog.remember([ModelChoice(value: stored, label: "Opus", resolvedModel: "claude-zzfollow-5[1m]")])
        #expect(modelDisplayText(stored) == "claude-zzfollow-5[1m]")
        // Next release re-points the same alias — the later probe wins, stored value untouched.
        ModelDisplayCatalog.remember([ModelChoice(value: stored, label: "Opus", resolvedModel: "claude-zzfollow-6[1m]")])
        #expect(modelDisplayText(stored) == "claude-zzfollow-6[1m]")
    }

    @Test func bareAliasMatchesTheBracketedRowWhenUnambiguous() {
        // config.json shipped `opus`, which the SDK never lists — only `opus[1m]` does.
        ModelDisplayCatalog.remember([
            ModelChoice(value: "zzbare[1m]", label: "Opus (1M context)", resolvedModel: "claude-zzbare-5[1m]"),
        ])
        #expect(modelDisplayText("zzbare") == "claude-zzbare-5[1m]")
    }

    @Test func ambiguousBareAliasPrintsTheStoredStringInstead() {
        ModelDisplayCatalog.remember([
            ModelChoice(value: "zzdup[1m]", label: "A", resolvedModel: "claude-zzdup-5[1m]"),
            ModelChoice(value: "zzdup[2m]", label: "B", resolvedModel: "claude-zzdup-5[2m]"),
        ])
        // Two candidates: naming the wrong model is worse than showing the alias.
        #expect(modelDisplayText("zzdup") == "zzdup")
    }

    @Test func unknownStoredValuePassesThroughUnchanged() {
        #expect(modelDisplayText("zz-never-probed") == "zz-never-probed")
    }

    @Test func rowsWithoutAResolvedIdAreNotRemembered() {
        // Codex/Grok slugs and the degraded alias fallback already read concretely.
        ModelDisplayCatalog.remember([ModelChoice(value: "zzslug", label: "Slug")])
        #expect(modelDisplayText("zzslug") == "zzslug")
    }

    @Test func dropdownLeadsWithTheWireIdAndDescribesWithNamePlusBlurb() {
        let row = ModelChoice(
            value: "opus[1m]",
            label: "Opus (1M context)",
            resolvedModel: "claude-opus-5[1m]",
            description: "Opus 5 with 1M context · Best for everyday, complex tasks"
        )
        #expect(modelOptionLabel(row) == "claude-opus-5[1m]")
        #expect(modelOptionDescription(row)
            == "Opus (1M context) · Opus 5 with 1M context · Best for everyday, complex tasks")
    }

    @Test func dropdownFallsBackToTheRowLabelWithoutAResolvedId() {
        // Effort/permission rows and Codex/Grok models keep their own label and get no second line.
        let effort = ModelChoice(value: "high", label: "high")
        #expect(modelOptionLabel(effort) == "high")
        #expect(modelOptionDescription(effort) == nil)
    }

    @Test func dropdownDescriptionClampsToDiscordLimit() {
        let row = ModelChoice(
            value: "a",
            label: String(repeating: "n", count: 80),
            resolvedModel: "claude-a-1",
            description: String(repeating: "d", count: 80)
        )
        #expect(modelOptionDescription(row)?.count == 100)
    }

    @Test func autocompleteShowsTheWireIdAndStaysSearchableByIt() {
        let rows = [
            ModelChoice(
                value: "opus[1m]",
                label: "Opus (1M context)",
                resolvedModel: "claude-opus-5[1m]",
                description: "Opus 5 with 1M context"
            ),
            ModelChoice(value: "haiku", label: "Haiku", resolvedModel: "claude-haiku-4-5", description: "Haiku 4.5"),
        ]
        // The suggestion names the wire id; the submitted value stays the alias that gets persisted.
        #expect(filterAutocompleteChoices(rows, query: "") == [
            AutocompleteChoice(name: "claude-opus-5[1m] · Opus 5 with 1M context", value: "opus[1m]"),
            AutocompleteChoice(name: "claude-haiku-4-5 · Haiku 4.5", value: "haiku"),
        ])
        // Typing what is on screen must match, even though it is not the row's value or label.
        #expect(filterAutocompleteChoices(rows, query: "claude-haiku").map(\.value) == ["haiku"])
    }
}

@Suite("ProviderCatalog configured-row matching")
struct ProviderCatalogRowMatchTests {
    private var rows: [ModelChoice] {
        [
            ModelChoice(value: "zzmatch[1m]", label: "Opus (1M context)", resolvedModel: "claude-zzmatch-5[1m]"),
            ModelChoice(value: "zzsonnet", label: "Sonnet", resolvedModel: "claude-zzsonnet-5"),
        ]
    }

    @Test func verbatimValueWins() {
        #expect(modelRowMatching("zzsonnet", in: rows)?.value == "zzsonnet")
    }

    @Test func bareAliasPreselectsTheRowNamingTheSameWireId() {
        ModelDisplayCatalog.remember(rows)
        // config.json holds `opus`; the SDK only lists `opus[1m]`. Both name one model, so the
        // picker must preselect that row instead of minting a second row with the same wire id.
        #expect(modelRowMatching("zzmatch", in: rows)?.value == "zzmatch[1m]")
    }

    @Test func storedWireIdPreselectsTheAliasRowThatCoversIt() {
        // A previously pinned explicit id still finds its alias row.
        #expect(modelRowMatching("claude-zzsonnet-5", in: rows)?.value == "zzsonnet")
    }

    @Test func unknownValueMatchesNothingSoTheCallerMintsARow() {
        #expect(modelRowMatching("zz-retired-model", in: rows) == nil)
    }
}

@Suite("ProviderCatalog display-or-auto")
struct ProviderCatalogDisplayOrAutoTests {
    @Test func emptySettingReadsAsAutoSelectedRatherThanBlank() {
        // Panel body / save summary must print something when no model is configured.
        #expect(modelDisplayTextOrAuto("") == I18n.t("usage.model.auto"))
    }

    @Test func configuredValueStillResolvesToTheWireId() {
        ModelDisplayCatalog.remember([
            ModelChoice(value: "zzauto[1m]", label: "Opus", resolvedModel: "claude-zzauto-5[1m]"),
        ])
        #expect(modelDisplayTextOrAuto("zzauto[1m]") == "claude-zzauto-5[1m]")
    }
}
