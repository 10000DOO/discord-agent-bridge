/// A single selectable option in a backend's model / permission / effort list.
/// 1:1 mirror of `src/core/contracts.ts:163` `ModelChoice`. `supportedEffortLevels` is
/// present only on Claude model choices (when the SDK reports them) so the effort step can
/// narrow to what the chosen model accepts.
///
/// `resolvedModel` / `description` are DISPLAY-ONLY: `value` (the SDK alias) is what gets
/// persisted and sent, while the screen names the concrete wire id the alias points at now.
public struct ModelChoice: Sendable, Equatable {
    public var value: String
    public var label: String
    public var supportedEffortLevels: [String]?
    /// Concrete wire id the alias resolves to today ('claude-opus-5[1m]'), when the SDK reports one.
    public var resolvedModel: String?
    /// The SDK's one-line blurb ('Opus 5 with 1M context · …'), for a dropdown's second line.
    public var description: String?

    public init(
        value: String,
        label: String,
        supportedEffortLevels: [String]? = nil,
        resolvedModel: String? = nil,
        description: String? = nil
    ) {
        self.value = value
        self.label = label
        self.supportedEffortLevels = supportedEffortLevels
        self.resolvedModel = resolvedModel
        self.description = description
    }
}

// MARK: - Model display (stored alias → concrete wire id)

/// Last-known `alias → resolvedModel` map, refreshed by every successful Claude catalog probe.
///
/// Storage keeps the SDK alias (native Claude Code behaviour), so the only way a compact surface
/// — a usage embed, a stats line, a `/model` confirmation — can name the concrete model is to look
/// it up. Probes already happen when the wizard / `/config` / autocomplete open, so this rides on
/// them instead of adding requests of its own. An alias re-pointed by a new release shows up on
/// the next probe, which is exactly how `claude-opus-5[1m]` becomes `claude-opus-6[1m]` on screen.
// ponytail: one process-wide dictionary, last-probe-wins, no TTL. A cold map degrades to printing
// the alias (today's behaviour); per-backend maps only if two backends ever collide on an id.
enum ModelDisplayCatalog {
    private static let box = LockedBox<[String: String]>([:])

    /// Record `alias → resolvedModel` for every row that reports one. Rows without a resolved id
    /// (Codex/Grok slugs, the degraded alias fallback) are skipped — they already read concretely.
    static func remember(_ choices: [ModelChoice]) {
        let pairs = choices.compactMap { c -> (String, String)? in
            guard let resolved = c.resolvedModel, !resolved.isEmpty else { return nil }
            return (c.value, resolved)
        }
        guard !pairs.isEmpty else { return }
        box.withLock { map in
            for (alias, resolved) in pairs { map[alias] = resolved }
        }
    }

    /// The wire id a stored model string names, or nil when unknown.
    static func resolved(_ stored: String) -> String? {
        box.withLock { map in
            if let hit = map[stored] { return hit }
            // config.json shipped the bare alias `opus`, which the SDK never lists (it lists
            // `opus[1m]`). Accept a bracket-suffixed alias, but only when exactly one matches —
            // printing the alias beats silently naming the wrong model.
            let widened = map.keys.filter { $0.hasPrefix(stored + "[") }
            guard widened.count == 1, let only = widened.first else { return nil }
            return map[only]
        }
    }

}

/// What a user should see for a stored model string: the concrete wire id when known, else the
/// stored string unchanged. The one funnel every compact model surface goes through.
public func modelDisplayText(_ stored: String) -> String {
    ModelDisplayCatalog.resolved(stored) ?? stored
}

/// Same, for surfaces that must print SOMETHING when no model is configured — an empty setting
/// means "follow the provider", which reads better than a blank or empty backticks.
public func modelDisplayTextOrAuto(_ stored: String) -> String {
    stored.isEmpty ? I18n.t("usage.model.auto") : modelDisplayText(stored)
}

/// The live-list row a configured/stored model value should preselect: the verbatim row when the
/// list has one, else a row that names the same wire id. Nil when nothing matches — the caller
/// mints its own row for a hand-typed or retired id.
///
/// The second lookup is what stops a duplicate: every row is now LABELLED with its wire id, so
/// minting a row for config.json's bare `opus` would print `claude-opus-5[1m]` twice — once for
/// `opus`, once for the SDK's `opus[1m]`. Preselecting the existing row shows it once.
public func modelRowMatching(_ configured: String, in models: [ModelChoice]) -> ModelChoice? {
    if let verbatim = models.first(where: { $0.value == configured }) { return verbatim }
    let named = modelDisplayText(configured)
    return models.first(where: { $0.resolvedModel == named || $0.value == named })
}

/// A dropdown option's first line: the concrete wire id when the SDK reported one, else the row's
/// own label (effort/permission rows and Codex/Grok slugs fall through unchanged).
public func modelOptionLabel(_ choice: ModelChoice) -> String {
    if let resolved = choice.resolvedModel, !resolved.isEmpty { return resolved }
    return choice.label
}

/// A dropdown option's second line: the friendly name plus the SDK blurb, clamped to Discord's
/// 100-char option description. Nil when the row carries neither (nothing worth a blank line).
public func modelOptionDescription(_ choice: ModelChoice) -> String? {
    guard choice.resolvedModel?.isEmpty == false || choice.description != nil else { return nil }
    var parts: [String] = []
    if choice.resolvedModel?.isEmpty == false { parts.append(choice.label) }
    if let blurb = choice.description, !blurb.isEmpty { parts.append(blurb) }
    let joined = parts.joined(separator: " · ")
    if joined.isEmpty { return nil }
    // Discord caps an option description at 100; ConfigPanel does not route through
    // capSelectOptions, so clamp here rather than trusting the caller.
    return joined.count <= 100 ? joined : String(joined.prefix(100))
}

/// Wizard-only value meaning "omit model from the provider request". It never reaches a persisted
/// binding: nil is the durable representation. The distinction that survives is which thing the
/// binding follows — an explicit alias keeps naming its family ('opus[1m]' rides each new Opus),
/// while nil tracks whatever the provider currently recommends, family and all.
public let providerDefaultModelSelection = "__provider_default__"

public func isProviderDefaultModelSelection(_ value: String?) -> Bool {
    value == nil || value?.isEmpty == true || value == providerDefaultModelSelection
}

public func modelForPersistedBinding(_ value: String?) -> String? {
    isProviderDefaultModelSelection(value) ? nil : value
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

// MARK: - Discord autocomplete (G-P1-03)

/// One Discord autocomplete suggestion (`name` is shown, `value` is submitted).
/// Mirrors the TS `{ name, value }` shape from `getModelAutocomplete` / `getEffortAutocomplete`.
public struct AutocompleteChoice: Sendable, Equatable {
    public var name: String
    public var value: String
    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// Discord's hard cap on application-command autocomplete results.
public let discordAutocompleteChoiceLimit = 25

/// Filter catalog choices by a partial query (case-insensitive match on `value`, `label` **or**
/// the resolved wire id — the id is what the suggestion shows, so it must also be searchable),
/// then cap at `limit` (default Discord max 25). Empty/whitespace query → unfiltered list.
/// Pure helper: no I/O, no DiscordBM — wired by dab on `applicationCommandAutocomplete`.
///
/// A suggestion's `name` leads with the concrete wire id and appends the SDK blurb; autocomplete
/// has no second line, so the two are joined on one. `value` stays the alias that gets persisted.
public func filterAutocompleteChoices(
    _ items: [ModelChoice],
    query: String,
    limit: Int = discordAutocompleteChoiceLimit
) -> [AutocompleteChoice] {
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let matches: [ModelChoice]
    if q.isEmpty {
        matches = items
    } else {
        matches = items.filter {
            $0.value.lowercased().contains(q)
                || $0.label.lowercased().contains(q)
                || ($0.resolvedModel?.lowercased().contains(q) ?? false)
        }
    }
    let capped = limit < 0 ? 0 : limit
    return matches.prefix(capped).map {
        AutocompleteChoice(name: autocompleteChoiceName($0), value: $0.value)
    }
}

/// One-line suggestion text: the wire id (else the label), plus the SDK blurb when there is one.
/// Clamped to Discord's 100-char choice name.
private func autocompleteChoiceName(_ choice: ModelChoice) -> String {
    var name = modelOptionLabel(choice)
    if let blurb = choice.description, !blurb.isEmpty {
        name += " · \(blurb)"
    }
    return name.count <= 100 ? name : String(name.prefix(100))
}

// MARK: - Factory

/// The ONE place a backend id maps to its catalog implementation (R1). Callers pick a catalog
/// by backend here and then use the `ProviderCatalog` interface — they never branch on the
/// backend to build a model/permission/effort list themselves.
public func providerCatalog(for backend: Backend) -> any ProviderCatalog {
    switch backend {
    case .claude, .custom:
        // custom reuses Claude SDK vocabulary (TS CustomMode.catalog === claudeCatalog).
        return ClaudeCatalog()
    case .codex: return CodexCatalog()
    case .grok: return GrokCatalog()
    }
}
