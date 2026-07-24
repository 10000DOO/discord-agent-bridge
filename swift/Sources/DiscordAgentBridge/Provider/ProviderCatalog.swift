/// A single selectable option in a backend's model / permission / effort list.
/// 1:1 mirror of `src/core/contracts.ts:159` `ModelChoice`. `supportedEffortLevels` is
/// present only on Claude model choices (when the SDK reports them) so the effort step can
/// narrow to what the chosen model accepts.
public struct ModelChoice: Sendable, Equatable {
    public var value: String
    public var label: String
    public var supportedEffortLevels: [String]?

    public init(value: String, label: String, supportedEffortLevels: [String]? = nil) {
        self.value = value
        self.label = label
        self.supportedEffortLevels = supportedEffortLevels
    }
}

/// The per-backend "vocabulary" a mode contributes to the Discord UI (wizard, /config,
/// /effort): its model list, permission options, and reasoning-effort options. 1:1 mirror
/// of `src/core/contracts.ts:171` `ModeCatalog`. Each backend OWNS its catalog so callers
/// never branch on the backend id to pick a list (R1). `models`/`permissionChoices`/
/// `defaultEffort` are async (Claude probes the SDK live); the effort methods are pure.
/// An empty `effortChoices()` → the wizard skips the effort step; an empty
/// `runtimeEffortChoices()` → no /effort for that backend.
public protocol ProviderCatalog: Sendable {
    func models(configured: String?) async -> [ModelChoice]
    func permissionChoices() async -> [ModelChoice]
    func effortChoices(modelLevels: [String]?) -> [ModelChoice]
    func runtimeEffortChoices(modelLevels: [String]?) -> [ModelChoice]
    func defaultEffort() async -> String?
}

// MARK: - Effort narrowing (pure helpers reused by the catalog implementations)
// Mirror of `src/core/providerCatalog.ts:157-185` (effortChoicesFor / runtimeEffortChoicesFor).

/// Start-time effort levels: the chosen model's advertised levels when it reports any,
/// otherwise the backend's base list.
func narrowStartEffort(base: [String], modelLevels: [String]?) -> [String] {
    if let m = modelLevels, !m.isEmpty { return m }
    return base
}

/// Runtime (/effort) levels: the backend's runtime-settable base intersected with the
/// chosen model's advertised levels when reported (preserving runtime-base order, so e.g.
/// Claude's 'max' is dropped at runtime), else the full runtime base.
func narrowRuntimeEffort(runtimeBase: [String], modelLevels: [String]?) -> [String] {
    if let m = modelLevels, !m.isEmpty { return runtimeBase.filter { m.contains($0) } }
    return runtimeBase
}

/// Wrap plain effort/value strings as `ModelChoice`es (label == value, no nested levels).
func choices(_ values: [String]) -> [ModelChoice] {
    values.map { ModelChoice(value: $0, label: $0, supportedEffortLevels: nil) }
}
