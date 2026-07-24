import Foundation

// Grok's DYNAMIC model / effort / permission catalog. 1:1 port of
// `src/modes/grok/{configSource,permissionSource,catalog}.ts`. Instead of hardcoding the
// vocabulary, models and per-model effort come from grok's local
// `${GROK_HOME}/models_cache.json` + the `[models] default` key of `config.toml`, and the
// permission modes come from the installed `grok --help` — so an account/CLI change surfaces
// without a bridge restart. Every read is fail-safe: a missing/unreadable/malformed source
// falls back to static constants and NEVER throws. Must NOT change GrokSpawn/GrokSessionBridge
// (the runtime permission mapping is a separate concern) and must NOT add a TOML dependency
// (config.toml is line-scanned).

// MARK: - grokHome resolution (grok/configSource.ts:66)

/// Resolve grok's home: `GROK_HOME` when set/non-empty, else `<home>/.grok`.
public func resolveGrokHome() -> String {
    if let env = ProcessInfo.processInfo.environment["GROK_HOME"], !env.isEmpty { return env }
    return (NSHomeDirectory() as NSString).appendingPathComponent(".grok")
}

// MARK: - Static fallbacks / canonical enum (grok/configSource.ts:22·28)

/// Static model fallback: the cache may be incomplete (e.g. unauthenticated machine caches only
/// grok-4.5 while the config default is grok-composer-2.5-fast) — both stay selectable.
let GROK_STATIC_MODELS = ["grok-4.5", "grok-composer-2.5-fast"]

/// Grok's documented canonical reasoning-effort enum. Used ONLY by `isKnownEffort` to accept a
/// manually-typed /effort value; NEVER for display (effort is RECEIVED-ONLY — a model's own
/// advertised reasoning_efforts, never fabricated from this set).
let GROK_CANONICAL_EFFORT = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]

// MARK: - models_cache.json subset (all optional so a partial/older cache degrades gracefully;
// a broken JSON fails the whole decode → static fallback, never throws).

private struct GrokReasoningEffort: Decodable {
    var id: String?
    var value: String?
    var `default`: Bool?
}

private struct GrokModelInfo: Decodable {
    var id: String?
    var name: String?
    var context_window: Int?
    var hidden: Bool?
    var reasoning_effort: String? // the model's default effort as a bare string
    var reasoning_efforts: [GrokReasoningEffort]?
}

private struct GrokModelEntry: Decodable {
    var info: GrokModelInfo?
}

/// models_cache.json = a `{ id: entry }` object. Foundation's JSONDecoder maps this to an
/// UNORDERED dictionary (allKeys is hash-seed randomized per process), but TS iterates
/// `Object.values` in insertion order and grok writes models in /v1/models order — the wizard
/// must show that order. So the entries are re-ordered by the document key order recovered from
/// the raw text (see `orderedModelKeys`); the dict decode stays for the (reliable) values.
private struct GrokModelsCache: Decodable {
    var models: [String: GrokModelEntry]?
}

/// Immediate child keys of the top-level `"models"` object, in document order. Foundation gives
/// no ordered JSON decode, so this brace/string-aware scan recovers the order grok wrote (TS
/// `Object.values` parity). A key with an escape sequence in it (never true of a model id) may
/// not round-trip exactly — such a key simply falls to the sorted-append tail in `orderEntries`.
func orderedModelKeys(_ raw: String) -> [String] {
    let re = #/"models"\s*:\s*\{/#
    guard let m = raw.firstMatch(of: re) else { return [] }
    var keys: [String] = []
    var depth = 1              // start just inside the models '{'
    var inString = false
    var escaped = false
    var buf = ""
    var pendingKey: String?
    var idx = m.range.upperBound   // char right after the models '{'
    while idx < raw.endIndex {
        let c = raw[idx]
        if inString {
            if escaped {
                escaped = false
                buf.append(c)
            } else if c == "\\" {
                escaped = true
            } else if c == "\"" {
                inString = false
                if depth == 1 { pendingKey = buf } // a completed string at the models level
            } else {
                buf.append(c)
            }
        } else {
            switch c {
            case "\"": inString = true; buf = ""
            case "{", "[": depth += 1
            case "}", "]": depth -= 1
            case ":": if depth == 1, let k = pendingKey { keys.append(k); pendingKey = nil } // string was a key
            case ",": if depth == 1 { pendingKey = nil }                                     // string was a value
            default: break
            }
            if depth == 0 { break } // closed the models object
        }
        idx = raw.index(after: idx)
    }
    return keys
}

/// Ordered entries: document key order first, then any key the scan missed appended sorted (so
/// no model is ever dropped and the result is deterministic even if the scan degrades).
private func orderEntries(_ raw: String, _ models: [String: GrokModelEntry]) -> [GrokModelEntry] {
    var seen = Set<String>()
    var result: [GrokModelEntry] = []
    for key in orderedModelKeys(raw) {
        guard let entry = models[key], seen.insert(key).inserted else { continue }
        result.append(entry)
    }
    for key in models.keys.sorted() where !seen.contains(key) {
        result.append(models[key]!)
    }
    return result
}

/// Effort ids for a model, in the cache's order (prefer `id`, fall back to `value`). (configSource.ts:267)
private func effortIdsFrom(_ info: GrokModelInfo) -> [String] {
    guard let efforts = info.reasoning_efforts else { return [] }
    var ids: [String] = []
    for effort in efforts {
        if let id = effortId(effort) { ids.append(id) }
    }
    return ids
}

private func effortId(_ effort: GrokReasoningEffort?) -> String? {
    guard let effort else { return nil }
    if let id = effort.id, !id.isEmpty { return id }
    if let value = effort.value, !value.isEmpty { return value }
    return nil
}

// MARK: - config.toml `[models] default` line-scan (grok/configSource.ts:289)

/// Parse ONLY `[models] default = "..."` from config.toml. No TOML dependency (forbidden), so
/// scan lines to find the `[models]` table, then a single regex on its `default` assignment —
/// scoped to the table so a `default =` under another table is never misread. Anything
/// unexpected → nil (the caller falls back). Never throws.
func parseModelsDefault(_ raw: String) -> String? {
    var inModels = false
    for rawLine in raw.split(separator: "\n", omittingEmptySubsequences: false) {
        let trimmed = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("[") {
            let header = stripInlineComment(trimmed) // strip a comment after the table header
            inModels = header == "[models]"          // entering/leaving a table; only [models] counts
            continue
        }
        if !inModels { continue }
        if let value = matchDefaultAssignment(trimmed) { return value }
    }
    return nil
}

private func stripInlineComment(_ line: String) -> String {
    guard let hash = line.firstIndex(of: "#") else { return line }
    return String(line[..<hash]).trimmingCharacters(in: .whitespaces)
}

private func matchDefaultAssignment(_ line: String) -> String? {
    let re = #/^default\s*=\s*["']([^"']*)["']/#
    guard let match = line.firstMatch(of: re) else { return nil }
    let value = String(match.output.1)
    return value.isEmpty ? nil : value
}

// MARK: - GrokConfigSource (grok/configSource.ts:71)

/// Serves grok's model/effort catalog from `${GROK_HOME}/models_cache.json` + the `[models]
/// default` of `config.toml`. TWO independently mtime-gated caches re-read only when a file
/// actually changed; every parse is fail-safe. An `actor` so both caches are thread-safe under
/// Swift concurrency. Injectable readFile/statMtime/grokHome for tests (defaults hit the real fs).
public actor GrokConfigSource {
    public static let shared = GrokConfigSource()

    private let readFile: @Sendable (String) throws -> String
    private let statMtime: @Sendable (String) throws -> Date
    private let grokHome: String

    // Parsed models_cache.json entries in document order (nil → static fallback) + the mtime
    // they were read at.
    private var cacheEntries: [GrokModelEntry]?
    private var cacheMtime: Date?

    // The `[models] default` parsed from config.toml, cached the same mtime-gated way.
    private var configDefault: String?
    private var configMtime: Date?

    public init(
        readFile: @escaping @Sendable (String) throws -> String = { try String(contentsOfFile: $0, encoding: .utf8) },
        statMtime: @escaping @Sendable (String) throws -> Date = { path in
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            guard let date = attrs[.modificationDate] as? Date else { throw CocoaError(.fileReadUnknown) }
            return date
        },
        grokHome: String = resolveGrokHome()
    ) {
        self.readFile = readFile
        self.statMtime = statMtime
        self.grokHome = grokHome
    }

    // Visible models (hidden:true excluded), each carrying its own effort levels. Empty/absent
    // cache → static list. The default (config.toml → cache first → static first) always leads,
    // and stays selectable even when the cache omits it. (configSource.ts:97)
    public func models() -> [ModelChoice] {
        ensureCacheLoaded()
        let derived = derivedModels()
        let base = derived.isEmpty ? GROK_STATIC_MODELS.map { ModelChoice(value: $0, label: $0) } : derived
        let def = defaultModel()
        let rest = base.filter { $0.value != def }
        let defChoice = base.first(where: { $0.value == def }) ?? ModelChoice(value: def, label: def)
        return [defChoice] + rest
    }

    // Effort levels a specific model accepts (its reasoning_efforts[] ids, cache order). A model
    // absent, or listing no efforts → [] (RECEIVED-ONLY: never fabricated). (configSource.ts:112)
    public func effortLevelsFor(_ model: String) -> [String] {
        ensureCacheLoaded()
        if let info = infoFor(model) {
            let ids = effortIdsFrom(info)
            if !ids.isEmpty { return ids }
        }
        return []
    }

    // A model's default effort: the reasoning_efforts[] entry flagged default:true, else the
    // per-model reasoning_effort string only when it is among the listed ids. No advertised
    // effort → "" (RECEIVED-ONLY: never fabricated; grok's own default then applies). (configSource.ts:125)
    public func defaultEffortFor(_ model: String) -> String {
        ensureCacheLoaded()
        if let info = infoFor(model) {
            let marked = (info.reasoning_efforts ?? []).first(where: { $0.`default` == true })
            if let id = effortId(marked), !id.isEmpty { return id }
            let ids = effortIdsFrom(info)
            if let re = info.reasoning_effort, ids.contains(re) { return re }
        }
        return ""
    }

    // The user's default model: config.toml [models] default → first cache model → first static
    // model. The config default may be absent from the cache yet still wins. (configSource.ts:143)
    public func defaultModel() -> String {
        ensureConfigLoaded()
        if let cd = configDefault, !cd.isEmpty { return cd }
        ensureCacheLoaded()
        let derived = derivedModels()
        if let first = derived.first { return first.value }
        return GROK_STATIC_MODELS[0]
    }

    // A model's context window (models_cache), for the usage panel (W11-g). Absent → nil. (configSource.ts:154)
    public func contextWindow(_ model: String) -> Int? {
        ensureCacheLoaded()
        return infoFor(model)?.context_window
    }

    // Guard for the runner's `-m`: true when `value` is one of the models we would offer, so a
    // leaked non-grok model id is dropped. (configSource.ts:162)
    public func isKnownModel(_ value: String) -> Bool {
        models().contains { $0.value == value }
    }

    // Guard for setEffort: true when `value` is any cached model's advertised effort OR a member
    // of grok's canonical enum. The canonical set is used ONLY here — never to fabricate display
    // options. (configSource.ts:169)
    public func isKnownEffort(_ value: String) -> Bool {
        ensureCacheLoaded()
        var known = Set(GROK_CANONICAL_EFFORT)
        if let entries = cacheEntries {
            for entry in entries {
                if let info = entry.info {
                    for id in effortIdsFrom(info) { known.insert(id) }
                }
            }
        }
        return known.contains(value)
    }

    // MARK: - Internals

    // Visible models (hidden excluded, valid non-empty id), in cache order. (configSource.ts:183)
    private func derivedModels() -> [ModelChoice] {
        guard let entries = cacheEntries else { return [] }
        var choices: [ModelChoice] = []
        for entry in entries {
            guard let info = entry.info, let id = info.id, !id.isEmpty else { continue }
            if info.hidden == true { continue } // hidden models never surface
            let ids = effortIdsFrom(info)
            let label = (info.name.flatMap { $0.isEmpty ? nil : $0 }) ?? id
            choices.append(ModelChoice(value: id, label: label, supportedEffortLevels: ids.isEmpty ? nil : ids))
        }
        return choices
    }

    // Look up a model's info by exact id (hidden included: a persisted binding may reference a
    // now-hidden model and still needs its effort/context_window). (configSource.ts:203)
    private func infoFor(_ model: String) -> GrokModelInfo? {
        guard let entries = cacheEntries else { return nil }
        for entry in entries where entry.info?.id == model { return entry.info }
        return nil
    }

    // stat() the cache and re-read only when the mtime changed. Absent file falls back silently;
    // a read/parse failure falls back too (no logger threaded through → no warn). (configSource.ts:214)
    private func ensureCacheLoaded() {
        let cachePath = (grokHome as NSString).appendingPathComponent("models_cache.json")
        let mtime: Date
        do {
            mtime = try statMtime(cachePath)
        } catch {
            cacheEntries = nil
            cacheMtime = nil
            return
        }
        if cacheMtime == mtime { return }
        cacheMtime = mtime
        do {
            let raw = try readFile(cachePath)
            let decoded = try JSONDecoder().decode(GrokModelsCache.self, from: Data(raw.utf8))
            cacheEntries = orderEntries(raw, decoded.models ?? [:])
        } catch {
            cacheEntries = nil
        }
    }

    // Same mtime-gated, fail-safe read for the one config.toml key we need. (configSource.ts:240)
    private func ensureConfigLoaded() {
        let configPath = (grokHome as NSString).appendingPathComponent("config.toml")
        let mtime: Date
        do {
            mtime = try statMtime(configPath)
        } catch {
            configDefault = nil
            configMtime = nil
            return
        }
        if configMtime == mtime { return }
        configMtime = mtime
        do {
            configDefault = parseModelsDefault(try readFile(configPath))
        } catch {
            configDefault = nil
        }
    }
}

// MARK: - GrokPermissionSource (grok/permissionSource.ts:79)

/// Full CLI default list (matches current `grok --help`), used when the probe fails.
let GROK_PERMISSION_FALLBACK = ["default", "acceptEdits", "auto", "dontAsk", "bypassPermissions", "plan"]

/// Values we will offer/persist: intersection with the Claude PermMode set (state schema). (permissionSource.ts:44)
private let GROK_VALID_PERM_MODES: Set<String> = ["default", "acceptEdits", "bypassPermissions", "plan", "dontAsk", "auto"]

/// Honest English labels for known ids. Others note they are accepted by the CLI but ride the
/// non-always-approve (Discord/ACP) path. (permissionSource.ts:55)
private let GROK_PERMISSION_LABELS: [String: String] = [
    "bypassPermissions": "bypassPermissions (auto-approve all tools)",
    "default": "default (prompts are cancelled — tools are skipped)",
    "acceptEdits": "acceptEdits (accepted by CLI; non-always-approve path)",
    "auto": "auto (accepted by CLI; non-always-approve path)",
    "dontAsk": "dontAsk (accepted by CLI; non-always-approve path)",
    "plan": "plan (accepted by CLI; non-always-approve path)",
]

/// Pick the permission-mode block (contains the bypassPermissions sentinel). (permissionSource.ts:70)
func parseGrokPermissionModes(_ helpText: String) -> [String] {
    guard let block = findPossibleValuesBlock(helpText, where: { $0.contains("bypassPermissions") }),
          !block.isEmpty else { return [] }
    return block
}

/// Keep only ids in the persisted PermMode schema. (permissionSource.ts:75)
func filterValidGrokPermModes(_ modes: [String]) -> [String] {
    modes.filter { GROK_VALID_PERM_MODES.contains($0) }
}

/// Grok DYNAMIC permission-mode source: discovers `--permission-mode` values from the installed
/// `grok --help`, cached by CLI identity. Never throws (falls back to GROK_PERMISSION_FALLBACK).
/// A `struct` — the identity cache lives in the wrapped `CliHelpValueSource` actor.
public struct GrokPermissionSource: Sendable {
    private let source: CliHelpValueSource

    public init(runHelp: RunHelpFn? = nil, resolveIdentity: ResolveIdentityFn? = nil) {
        let defaults = createCliHelpRunner("grok")
        self.source = CliHelpValueSource(
            fallback: GROK_PERMISSION_FALLBACK,
            parseHelp: parseGrokPermissionModes,
            filter: filterValidGrokPermModes,
            runHelp: runHelp ?? defaults.runHelp,
            resolveIdentity: resolveIdentity ?? defaults.resolveIdentity
        )
    }

    /// Permission-mode ids from CLI help (schema-filtered), or the static fallback. Never throws.
    public func permissionModes() async -> [String] {
        await source.values()
    }

    /// English {value,label} choices for the wizard/config permission step.
    public func permissionChoices() async -> [ModelChoice] {
        let modes = await permissionModes()
        return modes.map { ModelChoice(value: $0, label: GROK_PERMISSION_LABELS[$0] ?? $0) }
    }

    /// True when `value` is in the (dynamic or fallback) permission catalog.
    public func isKnownPermission(_ value: String) async -> Bool {
        await permissionModes().contains(value)
    }
}

// MARK: - GrokCatalog (grok/catalog.ts:40 createGrokCatalog)

/// Wires grok vocabulary through GrokConfigSource (models_cache.json / config.toml) +
/// GrokPermissionSource (`grok --help`). Effort is RECEIVED-ONLY: only the chosen model's
/// advertised levels, no borrow from another model. (grok/catalog.ts:48)
public struct GrokCatalog: ProviderCatalog {
    private let perms: GrokPermissionSource

    public init(perms: GrokPermissionSource = GrokPermissionSource()) {
        self.perms = perms
    }

    // `configured` is ignored — grok's default source is config.toml [models] default.
    public func models(configured: String?) async -> [ModelChoice] {
        await GrokConfigSource.shared.models()
    }

    public func permissionChoices() async -> [ModelChoice] {
        await perms.permissionChoices()
    }

    // Received-only: empty modelLevels → [] so the wizard skips the effort step and grok's own
    // per-model default applies. No borrow from the default model.
    public func effortChoices(modelLevels: [String]?) -> [ModelChoice] {
        choices(modelLevels ?? [])
    }

    // Runtime /effort uses the same received-only list.
    public func runtimeEffortChoices(modelLevels: [String]?) -> [ModelChoice] {
        effortChoices(modelLevels: modelLevels)
    }

    // Default model's default effort — may be "" (received-only; grok's own default applies).
    public func defaultEffort() async -> String? {
        let model = await GrokConfigSource.shared.defaultModel()
        return await GrokConfigSource.shared.defaultEffortFor(model)
    }
}
