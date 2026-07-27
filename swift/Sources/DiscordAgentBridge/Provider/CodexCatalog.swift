import Foundation

// Codex's DYNAMIC model / effort / sandbox catalog. 1:1 port of
// `src/modes/codex/{resolveHome,configSource,permissionSource}.ts` + the `codexCatalog`
// assembly in `src/core/providerCatalog.ts`. Instead of hardcoding the vocabulary, models
// and per-model effort come from codex's local `${codexHome}/models_cache.json` and the
// sandbox modes come from the installed `codex --help` — so an account/CLI change surfaces
// without a bridge restart. Every read is fail-safe: a missing/unreadable/malformed source
// falls back to static constants and NEVER throws. Must NOT change Codex/CodexPolicy.swift
// (the permMode→approval/sandbox runtime mapping is a separate concern).

// MARK: - codexHome resolution (resolveHome.ts:6)

/// Resolve the configured codexHome to an absolute path: default `<home>/.codex` when
/// unset/empty, expanding a leading `~`/`~/` (config stores it as `~/.codex`).
public func resolveCodexHome(_ configured: String?) -> String {
    guard let configured, !configured.isEmpty else {
        return (NSHomeDirectory() as NSString).appendingPathComponent(".codex")
    }
    if configured == "~" { return NSHomeDirectory() }
    if configured.hasPrefix("~/") {
        return (NSHomeDirectory() as NSString).appendingPathComponent(String(configured.dropFirst(2)))
    }
    return configured
}

// MARK: - Static fallbacks (configSource.ts:18·28, permissionSource.ts:25)

/// Same ids as the former providerCatalog CODEX_MODEL_DEFAULTS list.
let CODEX_MODEL_FALLBACK = ["gpt-5.5", "gpt-5.4", "gpt-5.4-mini", "gpt-5.2-codex"]

/// Canonical codex effort enum (model_reasoning_effort). Fallback when a model is absent
/// from the cache, and the isKnownEffort union base. Unlike Grok, Codex always offers a list.
let CODEX_EFFORT_FALLBACK = ["minimal", "low", "medium", "high", "xhigh"]

/// Static fallback = current documented `-s`/`--sandbox` values (matches `codex --help` today).
let CODEX_SANDBOX_FALLBACK = ["read-only", "workspace-write", "danger-full-access"]

// MARK: - models_cache.json subset (all optional so a partial/older cache degrades
// gracefully; a type mismatch fails the whole JSON decode → static fallback, never throws).

private struct CodexReasoningLevel: Decodable {
    var effort: String?
}

private struct CodexModelEntry: Decodable {
    var slug: String?
    var display_name: String?
    var visibility: String?
    var default_reasoning_level: String?
    var supported_reasoning_levels: [CodexReasoningLevel]?
}

private struct CodexModelsCache: Decodable {
    var models: [CodexModelEntry]?
}

/// Effort ids for a model, in the cache's order (supported_reasoning_levels[].effort). (configSource.ts:220)
private func effortIdsFrom(_ entry: CodexModelEntry) -> [String] {
    guard let levels = entry.supported_reasoning_levels else { return [] }
    var ids: [String] = []
    for level in levels {
        if let e = level.effort, !e.isEmpty { ids.append(e) }
    }
    return ids
}

// MARK: - CodexConfigSource (configSource.ts:57)

/// Serves the Codex model/effort catalog from `${codexHome}/models_cache.json`. A stat()
/// mtime check re-reads only when the file actually changed; the parse is fail-safe. An
/// `actor` so the mtime-gated cache is thread-safe under Swift concurrency. Injectable
/// readFile/statMtime/codexHome for tests (defaults hit the real filesystem).
public actor CodexConfigSource {
    public static let shared = CodexConfigSource()

    private let readFile: @Sendable (String) throws -> String
    private let statMtime: @Sendable (String) throws -> Date
    private let codexHome: String

    // Parsed models_cache.json (nil → use the static fallback), plus the mtime it was read
    // at so a later call re-reads only when the file changed.
    private var cache: CodexModelsCache?
    private var cacheMtime: Date?

    public init(
        readFile: @escaping @Sendable (String) throws -> String = { try String(contentsOfFile: $0, encoding: .utf8) },
        statMtime: @escaping @Sendable (String) throws -> Date = { path in
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            guard let date = attrs[.modificationDate] as? Date else { throw CocoaError(.fileReadUnknown) }
            return date
        },
        codexHome: String = resolveCodexHome(nil)
    ) {
        self.readFile = readFile
        self.statMtime = statMtime
        self.codexHome = codexHome
    }

    // Visible models from the cache (visibility === 'list'), each carrying its own effort
    // levels. Empty/absent cache → static fallback. `configured` non-empty is always first
    // even when its visibility is hide (persisted binding). (configSource.ts:79)
    public func models(configured: String?) -> [ModelChoice] {
        ensureCacheLoaded()
        let derived = listModels()
        let base = derived.isEmpty ? CODEX_MODEL_FALLBACK.map { ModelChoice(value: $0, label: $0) } : derived
        let def = defaultModel(configured: configured)
        let rest = base.filter { $0.value != def }
        if let fromBase = base.first(where: { $0.value == def }) {
            return [fromBase] + rest
        }
        // configured/hide model not in the list models — look up cache for label/efforts.
        let entry = entryFor(def)
        let efforts = entry.map { effortIdsFrom($0) } ?? []
        let label: String
        if let dn = entry?.display_name, !dn.isEmpty { label = dn } else { label = def }
        let defChoice = ModelChoice(value: def, label: label, supportedEffortLevels: efforts.isEmpty ? nil : efforts)
        return [defChoice] + rest
    }

    // Effort levels a specific model accepts (supported_reasoning_levels[].effort, cache
    // order). Model absent or listing no efforts → CODEX_EFFORT_FALLBACK. (configSource.ts:106)
    public func effortLevelsFor(_ model: String) -> [String] {
        ensureCacheLoaded()
        if let entry = entryFor(model) {
            let ids = effortIdsFrom(entry)
            if !ids.isEmpty { return ids }
        }
        return CODEX_EFFORT_FALLBACK
    }

    // A model's default effort: default_reasoning_level when it is among the listed levels,
    // else 'medium' if listed, else the first level, else 'medium'. (configSource.ts:118)
    public func defaultEffortFor(_ model: String) -> String {
        let levels = effortLevelsFor(model)
        ensureCacheLoaded()
        let marked = entryFor(model)?.default_reasoning_level
        if let marked, levels.contains(marked) { return marked }
        if levels.contains("medium") { return "medium" }
        if let first = levels.first { return first }
        return "medium"
    }

    // The default model: configured if non-empty → first visibility=list model → first
    // fallback. (configSource.ts:133)
    public func defaultModel(configured: String?) -> String {
        let trimmed = configured?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !trimmed.isEmpty { return trimmed }
        ensureCacheLoaded()
        let derived = listModels()
        if let first = derived.first { return first.value }
        return CODEX_MODEL_FALLBACK[0]
    }

    // Guard for setEffort: true when `value` is any cached model's advertised effort OR a
    // member of CODEX_EFFORT_FALLBACK. (configSource.ts:145)
    public func isKnownEffort(_ value: String) -> Bool {
        ensureCacheLoaded()
        var known = Set(CODEX_EFFORT_FALLBACK)
        if let models = cache?.models {
            for entry in models {
                for id in effortIdsFrom(entry) { known.insert(id) }
            }
        }
        return known.contains(value)
    }

    // MARK: - Internals

    // Models with visibility === 'list' only. Hide entries are lookup-only for `configured`.
    private func listModels() -> [ModelChoice] {
        guard let models = cache?.models else { return [] }
        var choices: [ModelChoice] = []
        for entry in models {
            guard let slug = entry.slug, !slug.isEmpty else { continue }
            guard entry.visibility == "list" else { continue }
            let ids = effortIdsFrom(entry)
            let label = (entry.display_name.flatMap { $0.isEmpty ? nil : $0 }) ?? slug
            choices.append(ModelChoice(value: slug, label: label, supportedEffortLevels: ids.isEmpty ? nil : ids))
        }
        return choices
    }

    // Look up a model entry by exact slug (hide included: a configured binding may reference
    // a now-hidden model and still needs its effort/label).
    private func entryFor(_ model: String) -> CodexModelEntry? {
        guard let models = cache?.models else { return nil }
        for entry in models where entry.slug == model { return entry }
        return nil
    }

    // stat() the cache and re-read only when the mtime changed. An absent file falls back
    // silently; a read/parse failure falls back too (no logger threaded through → no warn).
    private func ensureCacheLoaded() {
        let cachePath = (codexHome as NSString).appendingPathComponent("models_cache.json")
        let mtime: Date
        do {
            mtime = try statMtime(cachePath)
        } catch {
            cache = nil
            cacheMtime = nil
            return
        }
        if cacheMtime == mtime { return }
        cacheMtime = mtime
        do {
            let data = Data(try readFile(cachePath).utf8)
            cache = try JSONDecoder().decode(CodexModelsCache.self, from: data)
        } catch {
            cache = nil
        }
    }
}

// MARK: - CodexPermissionSource (permissionSource.ts:58)

// Short English hints for known sandbox ids (selectable option labels, English only). (permissionSource.ts:38)
private let CODEX_SANDBOX_HINTS: [String: String] = [
    "read-only": "read-only, ask to run",
    "workspace-write": "write in workspace",
    "danger-full-access": "no sandbox (⚠ dangerous)",
]

/// Pick the sandbox block: the possible-values list containing a known sandbox sentinel. (permissionSource.ts:50)
func parseCodexSandboxModes(_ helpText: String) -> [String] {
    guard let block = findPossibleValuesBlock(helpText, where: { $0.contains("workspace-write") || $0.contains("read-only") }),
          !block.isEmpty else { return [] }
    return block
}

/// Codex DYNAMIC sandbox-mode source: discovers `-s`/`--sandbox` values from the installed
/// `codex --help`, cached by CLI identity. Never throws (falls back to CODEX_SANDBOX_FALLBACK).
/// A `struct` — the identity cache lives in the wrapped `CliHelpValueSource` actor.
public struct CodexPermissionSource: Sendable {
    private let source: CliHelpValueSource

    public init(runHelp: RunHelpFn? = nil, resolveIdentity: ResolveIdentityFn? = nil) {
        let defaults = createCliHelpRunner("codex")
        self.source = CliHelpValueSource(
            fallback: CODEX_SANDBOX_FALLBACK,
            parseHelp: parseCodexSandboxModes,
            filter: nil,
            runHelp: runHelp ?? defaults.runHelp,
            resolveIdentity: resolveIdentity ?? defaults.resolveIdentity
        )
    }

    /// Sandbox mode ids from CLI help, or the static fallback. Never throws.
    public func sandboxModes() async -> [String] {
        await source.values()
    }

    /// English {value,label} choices for the wizard/config permission step.
    public func sandboxChoices() async -> [ModelChoice] {
        let modes = await sandboxModes()
        return modes.map { mode in
            if let hint = CODEX_SANDBOX_HINTS[mode] { return ModelChoice(value: mode, label: "\(mode) (\(hint))") }
            return ModelChoice(value: mode, label: mode)
        }
    }

    /// True when `value` is in the (dynamic or fallback) sandbox catalog.
    public func isKnownSandbox(_ value: String) async -> Bool {
        await sandboxModes().contains(value)
    }
}

// MARK: - CodexCatalog (providerCatalog.ts:321 codexCatalog)

/// Wires Codex vocabulary through CodexConfigSource (models_cache.json) + CodexPermissionSource
/// (`codex --help`). For Codex, start-time == runtime effort (providerCatalog.ts:176-178).
public struct CodexCatalog: ProviderCatalog {
    private let perms: CodexPermissionSource

    public init(perms: CodexPermissionSource = CodexPermissionSource()) {
        self.perms = perms
    }

    public func models(configured: String?) async -> [ModelChoice] {
        await CodexConfigSource.shared.models(configured: configured)
    }

    public func permissionChoices() async -> [ModelChoice] {
        await perms.sandboxChoices()
    }

    // Model's advertised levels when non-empty, else CODEX_EFFORT_FALLBACK (always selectable).
    public func effortChoices(modelLevels: [String]?) -> [ModelChoice] {
        choices(narrowStartEffort(base: CODEX_EFFORT_FALLBACK, modelLevels: modelLevels))
    }

    // Codex has no start/runtime distinction — same list as effortChoices.
    public func runtimeEffortChoices(modelLevels: [String]?) -> [ModelChoice] {
        effortChoices(modelLevels: modelLevels)
    }

    public func defaultEffort() async -> String? {
        let model = await CodexConfigSource.shared.defaultModel(configured: nil)
        return await CodexConfigSource.shared.defaultEffortFor(model)
    }
}
