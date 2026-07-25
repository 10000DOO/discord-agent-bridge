import Testing
import Foundation
@testable import DiscordAgentBridge

// A representative "live" snapshot (as the sidecar RPC would return): real model ids with a
// per-model supportedEffortLevels, plus the SDK-bound perm/effort superset.
private func liveSnapshot() -> ClaudeCatalogSnapshot {
    ClaudeCatalogSnapshot(
        models: [
            ModelChoice(value: "claude-opus-4", label: "Opus 4", supportedEffortLevels: ["low", "high", "max"]),
            ModelChoice(value: "claude-sonnet-4", label: "Sonnet 4"),
        ],
        permissionModes: [ModelChoice(value: "default", label: "default (ask each time)")],
        effortLevels: ["low", "medium", "high", "xhigh", "max"],
        runtimeEffortLevels: ["low", "medium", "high", "xhigh"],
        defaultEffort: "high"
    )
}

@Suite("ClaudeCatalogSnapshot — fallback + mapping")
struct ClaudeCatalogSnapshotTests {
    // R4/R7: the degraded snapshot is alias models + the SDK PermissionMode enum with English
    // hints (mirror of providerCatalog.ts PERM_MODE_HINTS) — never a Swift-owned vocabulary.
    @Test func fallbackIsAliasModelsAndDegradedPermEffort() {
        let fb = ClaudeCatalogSnapshot.fallback
        #expect(fb.models == [
            ModelChoice(value: "opus", label: "opus"),
            ModelChoice(value: "sonnet", label: "sonnet"),
            ModelChoice(value: "haiku", label: "haiku"),
        ])
        #expect(fb.permissionModes.map(\.value) == ["default", "acceptEdits", "bypassPermissions", "plan", "dontAsk", "auto"])
        #expect(fb.permissionModes.first?.label == "default (ask each time)")
        #expect(fb.permissionModes.last?.label == "auto (model-classified)")
        #expect(fb.effortLevels == ["low", "medium", "high", "xhigh", "max"])
        #expect(fb.runtimeEffortLevels == ["low", "medium", "high", "xhigh"])
        #expect(fb.defaultEffort == "high")
    }

    @Test func initFromResultCopiesFields() {
        let result = ClaudeCatalogResult(
            models: [ModelChoice(value: "claude-opus-4", label: "Opus 4", supportedEffortLevels: ["high", "max"])],
            permissionModes: [ModelChoice(value: "plan", label: "plan (read-only planning)")],
            effortLevels: ["low", "high", "max"],
            runtimeEffortLevels: ["low", "high"],
            defaultEffort: "high"
        )
        let snap = ClaudeCatalogSnapshot(from: result)
        #expect(snap.models == result.models)
        #expect(snap.permissionModes == result.permissionModes)
        #expect(snap.effortLevels == result.effortLevels)
        #expect(snap.runtimeEffortLevels == result.runtimeEffortLevels)
        #expect(snap.defaultEffort == result.defaultEffort)
    }
}

@Suite("ClaudeCatalog — probe injection")
struct ClaudeCatalogTests {
    @Test func modelsPermsDefaultEffortComeFromProbe() async {
        let snap = liveSnapshot()
        let cat = ClaudeCatalog(probe: { snap })
        #expect(await cat.models(configured: nil) == snap.models)
        #expect(await cat.permissionChoices() == snap.permissionModes)
        #expect(await cat.defaultEffort() == "high")
    }

    @Test func effortChoicesUseCachedSnapshotAndNarrow() async {
        let snap = liveSnapshot()
        let cat = ClaudeCatalog(probe: { snap })
        // Warm the cache first (the sync effort methods read the cached snapshot).
        _ = await cat.models(configured: nil)
        // No model levels → full start list (max included), runtime list (max excluded).
        #expect(cat.effortChoices(modelLevels: nil) == choices(["low", "medium", "high", "xhigh", "max"]))
        #expect(cat.runtimeEffortChoices(modelLevels: nil) == choices(["low", "medium", "high", "xhigh"]))
        // Model levels narrow: start keeps them verbatim (max stays), runtime intersects (max dropped).
        #expect(cat.effortChoices(modelLevels: ["high", "max"]) == choices(["high", "max"]))
        #expect(cat.runtimeEffortChoices(modelLevels: ["high", "max"]) == choices(["high"]))
    }

    // Before any async method warms the cache, the sync effort methods fall back to the
    // degraded snapshot (they cannot probe). Deterministic: no method resolved yet.
    @Test func effortChoicesBeforeWarmUseFallback() {
        let cat = ClaudeCatalog(probe: { liveSnapshot() })
        #expect(cat.effortChoices(modelLevels: nil) == choices(["low", "medium", "high", "xhigh", "max"]))
        #expect(cat.runtimeEffortChoices(modelLevels: nil) == choices(["low", "medium", "high", "xhigh"]))
    }

    @Test func probeRunsOncePerOpenAcrossMethods() async {
        let count = LockedBox(0)
        let snap = liveSnapshot()
        let cat = ClaudeCatalog(probe: { count.withLock { $0 += 1 }; return snap })
        _ = await cat.models(configured: nil)
        _ = await cat.permissionChoices()
        _ = await cat.defaultEffort()
        #expect(count.withLock { $0 } == 1)
    }

    // In-flight dedup: concurrent method calls share a single probe (the LockedBox guard).
    @Test func concurrentCallsShareOneProbe() async {
        let count = LockedBox(0)
        let snap = liveSnapshot()
        let cat = ClaudeCatalog(probe: { count.withLock { $0 += 1 }; return snap })
        async let a = cat.models(configured: nil)
        async let b = cat.permissionChoices()
        async let c = cat.defaultEffort()
        _ = await (a, b, c)
        #expect(count.withLock { $0 } == 1)
    }
}

@Suite("ClaudeCatalog — degraded fallback (R4)")
struct ClaudeCatalogFallbackTests {
    // R4: when the probe resolves to `.fallback` (sidecar down / RPC throws), the catalog
    // still yields alias models + the SDK-enum degraded permission list.
    @Test func probeReturningFallbackYieldsAliasModelsAndDegradedPerms() async {
        let cat = ClaudeCatalog(probe: { .fallback })
        #expect(await cat.models(configured: nil) == [
            ModelChoice(value: "opus", label: "opus"),
            ModelChoice(value: "sonnet", label: "sonnet"),
            ModelChoice(value: "haiku", label: "haiku"),
        ])
        #expect(await cat.permissionChoices().map(\.value) == ["default", "acceptEdits", "bypassPermissions", "plan", "dontAsk", "auto"])
        #expect(await cat.defaultEffort() == "high")
        #expect(cat.effortChoices(modelLevels: nil) == choices(["low", "medium", "high", "xhigh", "max"]))
    }
}

@Suite("providerCatalog(for:) factory")
struct ProviderCatalogFactoryTests {
    // R1: the ONE backend→implementation mapping. Construction is side-effect-free (Claude's
    // probe is lazy), so this does not spawn a sidecar.
    @Test func factoryMapsBackendToCatalog() {
        #expect(providerCatalog(for: .claude) is ClaudeCatalog)
        #expect(providerCatalog(for: .codex) is CodexCatalog)
        #expect(providerCatalog(for: .grok) is GrokCatalog)
    }
}
