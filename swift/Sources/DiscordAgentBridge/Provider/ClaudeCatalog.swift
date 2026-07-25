import Foundation

// Claude's LIVE model / permission / effort catalog. Unlike Codex/Grok (local files + CLI
// help), Claude's vocabulary lives in the installed SDK, which is reachable only from the
// Node sidecar. So the single source of truth is the `claude.catalog` RPC (WO-5/6): the
// sidecar assembles the snapshot from the SDK-bound `providerCatalog` and Swift copies it.
// The `.fallback` alias list here is the degraded path ONLY (sidecar down / RPC throws).

// MARK: - Snapshot

/// One resolved Claude catalog. Field-for-field mirror of the sidecar `ClaudeCatalogResult`
/// (Sidecar/Protocol.swift) — this is the shape `ClaudeCatalog` caches per open.
public struct ClaudeCatalogSnapshot: Sendable, Equatable {
    public var models: [ModelChoice]
    public var permissionModes: [ModelChoice]
    public var effortLevels: [String]
    public var runtimeEffortLevels: [String]
    public var defaultEffort: String

    public init(
        models: [ModelChoice],
        permissionModes: [ModelChoice],
        effortLevels: [String],
        runtimeEffortLevels: [String],
        defaultEffort: String
    ) {
        self.models = models
        self.permissionModes = permissionModes
        self.effortLevels = effortLevels
        self.runtimeEffortLevels = runtimeEffortLevels
        self.defaultEffort = defaultEffort
    }

    /// Field-copy from the sidecar RPC result (DabSessionBridge maps a live probe through this).
    public init(from result: ClaudeCatalogResult) {
        self.init(
            models: result.models,
            permissionModes: result.permissionModes,
            effortLevels: result.effortLevels,
            runtimeEffortLevels: result.runtimeEffortLevels,
            defaultEffort: result.defaultEffort
        )
    }

    // ponytail: degraded-only. The normal path's single source of truth is the sidecar's
    // SDK-bound catalog (claude.catalog RPC); this hardcoded list is used ONLY when the
    // sidecar is down / the RPC throws — the same graceful degradation as the alias model
    // fallback (opus/sonnet/haiku). Do NOT treat it as the model/perm/effort vocabulary.
    // Permission labels mirror src/core/providerCatalog.ts PERM_MODE_HINTS (`mode (hint)`).
    public static var fallback: ClaudeCatalogSnapshot {
        ClaudeCatalogSnapshot(
            models: [
                ModelChoice(value: "opus", label: "opus"),
                ModelChoice(value: "sonnet", label: "sonnet"),
                ModelChoice(value: "haiku", label: "haiku"),
            ],
            permissionModes: [
                ModelChoice(value: "default", label: "default (ask each time)"),
                ModelChoice(value: "acceptEdits", label: "acceptEdits (auto-approve edits)"),
                ModelChoice(value: "bypassPermissions", label: "bypassPermissions (auto-approve all)"),
                ModelChoice(value: "plan", label: "plan (read-only planning)"),
                ModelChoice(value: "dontAsk", label: "dontAsk (deny if not pre-approved)"),
                ModelChoice(value: "auto", label: "auto (model-classified)"),
            ],
            effortLevels: ["low", "medium", "high", "xhigh", "max"],
            runtimeEffortLevels: ["low", "medium", "high", "xhigh"],
            defaultEffort: "high"
        )
    }
}

// MARK: - Catalog

/// Claude's `ProviderCatalog`. Probes the sidecar once per open and caches the snapshot;
/// concurrent method calls share a single in-flight probe (dedup). The factory creates a
/// fresh instance per open, so each wizard/slash open re-probes (no cross-invocation cache,
/// mirroring the TS behavior).
public final class ClaudeCatalog: ProviderCatalog, @unchecked Sendable {
    private let probe: @Sendable () async -> ClaudeCatalogSnapshot

    private struct State {
        var cached: ClaudeCatalogSnapshot?
        var inFlight: Task<ClaudeCatalogSnapshot, Never>?
    }
    // ponytail: LockedBox over (cached, in-flight) is enough — one probe per open, callers join
    // the in-flight task. Upgrade to an actor only if the probe grows re-entrant needs.
    private let state = LockedBox(State())

    public init(probe: @escaping @Sendable () async -> ClaudeCatalogSnapshot = { await DabSessionBridge.shared.claudeCatalog() }) {
        self.probe = probe
    }

    /// The probed snapshot for this open: cached after the first resolve; concurrent callers
    /// await the same in-flight probe instead of firing a second one.
    private func resolvedSnapshot() async -> ClaudeCatalogSnapshot {
        if let cached = state.withLock({ $0.cached }) { return cached }
        let probe = self.probe
        let task: Task<ClaudeCatalogSnapshot, Never> = state.withLock { s in
            if let inFlight = s.inFlight { return inFlight }
            let t = Task { await probe() }
            s.inFlight = t
            return t
        }
        let snap = await task.value
        state.withLock { s in
            s.cached = snap
            s.inFlight = nil
        }
        return snap
    }

    /// Snapshot for the SYNCHRONOUS effort methods (which cannot probe): the probed value if
    /// this open already resolved one, else `.fallback`. In the real flow models()/
    /// permissionChoices() run first, so the cache is warm by the effort step.
    private var cachedSnapshot: ClaudeCatalogSnapshot {
        state.withLock { $0.cached } ?? .fallback
    }

    public func models(configured: String?) async -> [ModelChoice] {
        await resolvedSnapshot().models
    }

    public func permissionChoices() async -> [ModelChoice] {
        await resolvedSnapshot().permissionModes
    }

    public func effortChoices(modelLevels: [String]?) -> [ModelChoice] {
        choices(narrowStartEffort(base: cachedSnapshot.effortLevels, modelLevels: modelLevels))
    }

    public func runtimeEffortChoices(modelLevels: [String]?) -> [ModelChoice] {
        choices(narrowRuntimeEffort(runtimeBase: cachedSnapshot.runtimeEffortLevels, modelLevels: modelLevels))
    }

    public func defaultEffort() async -> String? {
        await resolvedSnapshot().defaultEffort
    }
}
