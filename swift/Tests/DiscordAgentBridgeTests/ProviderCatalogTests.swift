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
