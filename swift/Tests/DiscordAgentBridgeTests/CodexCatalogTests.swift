import Testing
import Foundation
@testable import DiscordAgentBridge

// Fixture models_cache.json: two visible + one hidden + one empty-slug + one effort-less.
// Mirrors the shapes src/modes/codex/configSource.ts parses (visibility=list filter,
// configured-first, per-model effort order, hide-only lookup).
private let fixtureCache = """
{
  "models": [
    { "slug": "gpt-5.5", "display_name": "GPT-5.5", "visibility": "list", "default_reasoning_level": "high",
      "supported_reasoning_levels": [ {"effort":"low"}, {"effort":"medium"}, {"effort":"high"}, {"effort":"xhigh"} ] },
    { "slug": "gpt-5.4-mini", "display_name": "", "visibility": "list",
      "supported_reasoning_levels": [ {"effort":"minimal"}, {"effort":"low"} ] },
    { "slug": "gpt-legacy", "visibility": "hide",
      "supported_reasoning_levels": [ {"effort":"low"}, {"effort":"ultra"} ] },
    { "slug": "", "visibility": "list" },
    { "slug": "gpt-noeffort", "visibility": "list" }
  ]
}
"""

private func makeConfigSource(json: String = fixtureCache, mtime: LockedBox<Date> = LockedBox(Date(timeIntervalSince1970: 1)), statThrows: Bool = false, reads: LockedBox<Int>? = nil) -> CodexConfigSource {
    let readFile: @Sendable (String) throws -> String = { _ in
        reads?.withLock { $0 += 1 }
        return json
    }
    let statMtime: @Sendable (String) throws -> Date = { _ in
        if statThrows { throw CocoaError(.fileReadNoSuchFile) }
        return mtime.withLock { $0 }
    }
    return CodexConfigSource(readFile: readFile, statMtime: statMtime, codexHome: "/fake")
}

@Suite("CodexConfigSource — models_cache.json parsing")
struct CodexConfigSourceModelsTests {
    @Test func modelsListsVisibilityListOnlyPreservingOrder() async {
        let s = makeConfigSource()
        #expect(await s.models(configured: "") == [
            ModelChoice(value: "gpt-5.5", label: "GPT-5.5", supportedEffortLevels: ["low", "medium", "high", "xhigh"]),
            ModelChoice(value: "gpt-5.4-mini", label: "gpt-5.4-mini", supportedEffortLevels: ["minimal", "low"]),
            ModelChoice(value: "gpt-noeffort", label: "gpt-noeffort"),
        ])
    }

    @Test func configuredHiddenModelLeadsWithCacheLabelAndEfforts() async {
        let s = makeConfigSource()
        #expect(await s.models(configured: "gpt-legacy") == [
            ModelChoice(value: "gpt-legacy", label: "gpt-legacy", supportedEffortLevels: ["low", "ultra"]),
            ModelChoice(value: "gpt-5.5", label: "GPT-5.5", supportedEffortLevels: ["low", "medium", "high", "xhigh"]),
            ModelChoice(value: "gpt-5.4-mini", label: "gpt-5.4-mini", supportedEffortLevels: ["minimal", "low"]),
            ModelChoice(value: "gpt-noeffort", label: "gpt-noeffort"),
        ])
    }

    @Test func missingFileFallsBackToStaticModels() async {
        let s = makeConfigSource(statThrows: true)
        #expect(await s.models(configured: "").map(\.value) == CODEX_MODEL_FALLBACK)
    }

    @Test func brokenJsonFallsBackToStaticModels() async {
        let s = makeConfigSource(json: "not json {")
        #expect(await s.models(configured: "").map(\.value) == CODEX_MODEL_FALLBACK)
    }

    @Test func defaultModelPrefersConfiguredThenFirstListThenFallback() async {
        #expect(await makeConfigSource().defaultModel(configured: "  custom  ") == "custom")
        #expect(await makeConfigSource().defaultModel(configured: "") == "gpt-5.5")
        #expect(await makeConfigSource().defaultModel(configured: "   ") == "gpt-5.5")
        #expect(await makeConfigSource(statThrows: true).defaultModel(configured: "") == CODEX_MODEL_FALLBACK[0])
    }
}

@Suite("CodexConfigSource — effort levels")
struct CodexConfigSourceEffortTests {
    @Test func effortLevelsForKnownModelPreserveCacheOrder() async {
        #expect(await makeConfigSource().effortLevelsFor("gpt-5.5") == ["low", "medium", "high", "xhigh"])
        #expect(await makeConfigSource().effortLevelsFor("gpt-5.4-mini") == ["minimal", "low"])
    }

    @Test func effortLevelsForAbsentOrEffortlessModelFallBack() async {
        #expect(await makeConfigSource().effortLevelsFor("gpt-noeffort") == CODEX_EFFORT_FALLBACK)
        #expect(await makeConfigSource().effortLevelsFor("does-not-exist") == CODEX_EFFORT_FALLBACK)
        #expect(await makeConfigSource(statThrows: true).effortLevelsFor("gpt-5.5") == CODEX_EFFORT_FALLBACK)
    }

    @Test func defaultEffortMarkedThenMediumThenFirst() async {
        // marked default_reasoning_level in the listed levels.
        #expect(await makeConfigSource().defaultEffortFor("gpt-5.5") == "high")
        // no marked, no 'medium' in list → first listed level.
        #expect(await makeConfigSource().defaultEffortFor("gpt-5.4-mini") == "minimal")
        // effort-less model → fallback list contains 'medium'.
        #expect(await makeConfigSource().defaultEffortFor("gpt-noeffort") == "medium")
    }

    @Test func isKnownEffortUnionsCacheAndFallback() async {
        let s = makeConfigSource()
        #expect(await s.isKnownEffort("xhigh"))          // in fallback
        #expect(await s.isKnownEffort("ultra"))          // only in cache (hidden model)
        #expect(await s.isKnownEffort("nope") == false)
    }

    @Test func isKnownEffortWithoutCacheIsFallbackOnly() async {
        let s = makeConfigSource(statThrows: true)
        #expect(await s.isKnownEffort("minimal"))
        #expect(await s.isKnownEffort("ultra") == false)
    }
}

@Suite("CodexConfigSource — mtime-gated cache")
struct CodexConfigSourceCacheTests {
    @Test func sameMtimeDoesNotReReadFile() async {
        let reads = LockedBox(0)
        let s = makeConfigSource(mtime: LockedBox(Date(timeIntervalSince1970: 1)), reads: reads)
        _ = await s.models(configured: "")
        _ = await s.models(configured: "")
        #expect(reads.withLock { $0 } == 1)
    }

    @Test func changedMtimeReReadsFile() async {
        let reads = LockedBox(0)
        let mtime = LockedBox(Date(timeIntervalSince1970: 1))
        let s = makeConfigSource(mtime: mtime, reads: reads)
        _ = await s.models(configured: "")
        mtime.withLock { $0 = Date(timeIntervalSince1970: 2) }
        _ = await s.models(configured: "")
        #expect(reads.withLock { $0 } == 2)
    }
}

@Suite("parseCodexSandboxModes")
struct ParseCodexSandboxModesTests {
    @Test func picksTheSandboxBlockAmongDecoys() {
        let help = "--perm <MODE> [possible values: default, plan] --sandbox <S> [possible values: read-only, workspace-write, danger-full-access]"
        #expect(parseCodexSandboxModes(help) == ["read-only", "workspace-write", "danger-full-access"])
    }

    @Test func emptyWhenNoSandboxSentinelBlock() {
        #expect(parseCodexSandboxModes("[possible values: default, plan]").isEmpty)
        #expect(parseCodexSandboxModes("no blocks at all").isEmpty)
    }
}

@Suite("CodexPermissionSource — dynamic sandbox modes")
struct CodexPermissionSourceTests {
    private func make(identity: String, help: String, helpCalls: LockedBox<Int>? = nil) -> CodexPermissionSource {
        let runHelp: RunHelpFn = { helpCalls?.withLock { $0 += 1 }; return help }
        let resolveIdentity: ResolveIdentityFn = { identity }
        return CodexPermissionSource(runHelp: runHelp, resolveIdentity: resolveIdentity)
    }

    @Test func sandboxChoicesLabelsKnownHintsAndPassesThroughUnknown() async {
        let s = make(identity: "codex@1", help: "--sandbox [possible values: read-only, workspace-write, custom-mode]")
        #expect(await s.sandboxChoices() == [
            ModelChoice(value: "read-only", label: "read-only (read-only, ask to run)"),
            ModelChoice(value: "workspace-write", label: "workspace-write (write in workspace)"),
            ModelChoice(value: "custom-mode", label: "custom-mode"),
        ])
    }

    @Test func missingIdentityFallsBackToStaticSandboxModes() async {
        let s = make(identity: CLI_MISSING_IDENTITY, help: "[possible values: read-only, workspace-write]")
        #expect(await s.sandboxModes() == CODEX_SANDBOX_FALLBACK)
    }

    @Test func unparseableHelpFallsBackToStaticSandboxModes() async {
        let s = make(identity: "codex@1", help: "codex 1.0 — no possible values printed")
        #expect(await s.sandboxModes() == CODEX_SANDBOX_FALLBACK)
    }

    @Test func isKnownSandboxReflectsDynamicList() async {
        let s = make(identity: "codex@1", help: "[possible values: read-only, workspace-write, custom-mode]")
        #expect(await s.isKnownSandbox("custom-mode"))
        #expect(await s.isKnownSandbox("danger-full-access") == false)
    }

    @Test func identityChangeReProbesHelp() async {
        let identity = LockedBox("codex@1")
        let calls = LockedBox(0)
        let runHelp: RunHelpFn = { calls.withLock { $0 += 1 }; return "[possible values: read-only, workspace-write]" }
        let resolveIdentity: ResolveIdentityFn = { identity.withLock { $0 } }
        let s = CodexPermissionSource(runHelp: runHelp, resolveIdentity: resolveIdentity)
        _ = await s.sandboxModes()
        identity.withLock { $0 = "codex@2" }
        _ = await s.sandboxModes()
        #expect(calls.withLock { $0 } == 2)
    }
}

@Suite("CodexCatalog — effort choices (start == runtime)")
struct CodexCatalogEffortTests {
    @Test func effortChoicesFallBackWhenModelLevelsMissing() {
        let cat = CodexCatalog()
        #expect(cat.effortChoices(modelLevels: nil) == choices(CODEX_EFFORT_FALLBACK))
        #expect(cat.effortChoices(modelLevels: []) == choices(CODEX_EFFORT_FALLBACK))
    }

    @Test func effortChoicesUseModelLevelsVerbatimWhenPresent() {
        let cat = CodexCatalog()
        #expect(cat.effortChoices(modelLevels: ["low", "high"]) == choices(["low", "high"]))
    }

    @Test func runtimeEffortEqualsStartEffort() {
        let cat = CodexCatalog()
        #expect(cat.runtimeEffortChoices(modelLevels: ["low", "high"]) == cat.effortChoices(modelLevels: ["low", "high"]))
        #expect(cat.runtimeEffortChoices(modelLevels: nil) == cat.effortChoices(modelLevels: nil))
    }
}
