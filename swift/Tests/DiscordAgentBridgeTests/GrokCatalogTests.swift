import Testing
import Foundation
@testable import DiscordAgentBridge

// Fixture models_cache.json: grok stores models as an id→entry OBJECT (unlike codex's array).
// Two visible with efforts + one hidden + one effort-less + one empty-info (skipped).
private let fixtureCache = """
{
  "models": {
    "grok-4.5": { "info": { "id": "grok-4.5", "name": "Grok 4.5", "context_window": 256000,
      "reasoning_efforts": [ {"id":"low"}, {"id":"high","default":true} ] } },
    "grok-composer-2.5-fast": { "info": { "id": "grok-composer-2.5-fast", "reasoning_effort": "medium",
      "reasoning_efforts": [ {"id":"low"}, {"value":"medium"}, {"id":"high"} ] } },
    "grok-hidden": { "info": { "id": "grok-hidden", "hidden": true,
      "reasoning_efforts": [ {"id":"secret"} ] } },
    "grok-noeffort": { "info": { "id": "grok-noeffort", "name": "No Effort Grok" } },
    "grok-empty": { "info": { } }
  }
}
"""

// config.toml: the [models] default is table-scoped — defaults under [other]/[server] and the
// inline comments after the table header and the value must all be handled.
private let fixtureConfig = """
[other]
default = "ignored-other"

[models]  # user models table
default = "grok-composer-2.5-fast"  # the chosen default

[server]
default = "ignored-server"
"""

private func makeGrokSource(
    cacheJson: String? = fixtureCache,
    configToml: String? = fixtureConfig,
    cacheMtime: LockedBox<Date> = LockedBox(Date(timeIntervalSince1970: 1)),
    configMtime: LockedBox<Date> = LockedBox(Date(timeIntervalSince1970: 1)),
    cacheReads: LockedBox<Int>? = nil,
    configReads: LockedBox<Int>? = nil
) -> GrokConfigSource {
    let home = "/fake"
    let cachePath = (home as NSString).appendingPathComponent("models_cache.json")
    let configPath = (home as NSString).appendingPathComponent("config.toml")
    let readFile: @Sendable (String) throws -> String = { path in
        if path == cachePath {
            guard let cacheJson else { throw CocoaError(.fileReadNoSuchFile) }
            cacheReads?.withLock { $0 += 1 }
            return cacheJson
        }
        if path == configPath {
            guard let configToml else { throw CocoaError(.fileReadNoSuchFile) }
            configReads?.withLock { $0 += 1 }
            return configToml
        }
        throw CocoaError(.fileReadNoSuchFile)
    }
    let statMtime: @Sendable (String) throws -> Date = { path in
        if path == cachePath {
            guard cacheJson != nil else { throw CocoaError(.fileReadNoSuchFile) }
            return cacheMtime.withLock { $0 }
        }
        if path == configPath {
            guard configToml != nil else { throw CocoaError(.fileReadNoSuchFile) }
            return configMtime.withLock { $0 }
        }
        throw CocoaError(.fileReadNoSuchFile)
    }
    return GrokConfigSource(readFile: readFile, statMtime: statMtime, grokHome: home)
}

@Suite("GrokConfigSource — models_cache.json parsing")
struct GrokConfigSourceModelsTests {
    @Test func modelsExcludeHiddenAndLeadWithConfigDefault() async {
        let s = makeGrokSource()
        #expect(await s.models() == [
            ModelChoice(value: "grok-composer-2.5-fast", label: "grok-composer-2.5-fast", supportedEffortLevels: ["low", "medium", "high"]),
            ModelChoice(value: "grok-4.5", label: "Grok 4.5", supportedEffortLevels: ["low", "high"]),
            ModelChoice(value: "grok-noeffort", label: "No Effort Grok"),
        ])
    }

    @Test func modelsLeadWithConfigDefaultEvenWhenCacheAbsent() async {
        // Cache absent → static base; the config default (not even in the static list) still leads.
        let s = makeGrokSource(cacheJson: nil, configToml: "[models]\ndefault = \"grok-custom-9\"")
        #expect(await s.models() == [
            ModelChoice(value: "grok-custom-9", label: "grok-custom-9"),
            ModelChoice(value: "grok-4.5", label: "grok-4.5"),
            ModelChoice(value: "grok-composer-2.5-fast", label: "grok-composer-2.5-fast"),
        ])
    }

    @Test func missingFileFallsBackToStaticModels() async {
        let s = makeGrokSource(cacheJson: nil, configToml: nil)
        #expect(await s.models().map(\.value) == GROK_STATIC_MODELS)
    }

    @Test func brokenJsonFallsBackToStaticModels() async {
        let s = makeGrokSource(cacheJson: "not json {", configToml: nil)
        #expect(await s.models().map(\.value) == GROK_STATIC_MODELS)
    }

    @Test func defaultModelPrefersConfigThenFirstCacheThenStatic() async {
        #expect(await makeGrokSource().defaultModel() == "grok-composer-2.5-fast")            // config default wins
        #expect(await makeGrokSource(configToml: nil).defaultModel() == "grok-4.5")           // first cache model
        #expect(await makeGrokSource(cacheJson: nil, configToml: nil).defaultModel() == GROK_STATIC_MODELS[0])
    }

    @Test func isKnownModelReflectsOfferedList() async {
        let s = makeGrokSource()
        #expect(await s.isKnownModel("grok-4.5"))
        #expect(await s.isKnownModel("grok-composer-2.5-fast"))
        #expect(await s.isKnownModel("grok-hidden") == false)   // hidden never offered
        #expect(await s.isKnownModel("nope") == false)
    }

    @Test func contextWindowFromCacheOrNil() async {
        let s = makeGrokSource()
        #expect(await s.contextWindow("grok-4.5") == 256000)
        #expect(await s.contextWindow("grok-noeffort") == nil)
        #expect(await s.contextWindow("missing") == nil)
    }
}

@Suite("GrokConfigSource — received-only effort")
struct GrokConfigSourceEffortTests {
    @Test func effortLevelsAreReceivedOnlyNeverBorrowed() async {
        let s = makeGrokSource()
        #expect(await s.effortLevelsFor("grok-4.5") == ["low", "high"])
        #expect(await s.effortLevelsFor("grok-composer-2.5-fast") == ["low", "medium", "high"]) // {value:"medium"} → id
        #expect(await s.effortLevelsFor("grok-noeffort") == [])   // advertises none → [] (no borrow)
        #expect(await s.effortLevelsFor("does-not-exist") == [])
    }

    @Test func defaultEffortMarkedThenReasoningEffortThenEmpty() async {
        let s = makeGrokSource()
        #expect(await s.defaultEffortFor("grok-4.5") == "high")                 // reasoning_efforts default:true
        #expect(await s.defaultEffortFor("grok-composer-2.5-fast") == "medium") // reasoning_effort, in listed ids
        #expect(await s.defaultEffortFor("grok-noeffort") == "")                // no advertised effort
        #expect(await s.defaultEffortFor("missing") == "")
    }

    @Test func isKnownEffortUnionsCanonicalAndCache() async {
        let s = makeGrokSource()
        #expect(await s.isKnownEffort("max"))       // canonical only
        #expect(await s.isKnownEffort("high"))      // canonical + cache
        #expect(await s.isKnownEffort("secret"))    // only in the hidden model's cache
        #expect(await s.isKnownEffort("bogus") == false)
    }

    @Test func isKnownEffortWithoutCacheIsCanonicalOnly() async {
        let s = makeGrokSource(cacheJson: nil)
        #expect(await s.isKnownEffort("medium"))
        #expect(await s.isKnownEffort("secret") == false)
    }
}

@Suite("GrokConfigSource — two independently mtime-gated caches")
struct GrokConfigSourceCacheTests {
    @Test func cachesReReadOnlyWhenTheirOwnFileChanges() async {
        let cacheReads = LockedBox(0)
        let configReads = LockedBox(0)
        let cacheMtime = LockedBox(Date(timeIntervalSince1970: 1))
        let configMtime = LockedBox(Date(timeIntervalSince1970: 1))
        let s = makeGrokSource(cacheMtime: cacheMtime, configMtime: configMtime, cacheReads: cacheReads, configReads: configReads)

        _ = await s.models()   // reads both once
        #expect(cacheReads.withLock { $0 } == 1)
        #expect(configReads.withLock { $0 } == 1)

        _ = await s.models()   // unchanged → no re-read of either
        #expect(cacheReads.withLock { $0 } == 1)
        #expect(configReads.withLock { $0 } == 1)

        configMtime.withLock { $0 = Date(timeIntervalSince1970: 2) }
        _ = await s.models()   // only config.toml re-read
        #expect(cacheReads.withLock { $0 } == 1)
        #expect(configReads.withLock { $0 } == 2)

        cacheMtime.withLock { $0 = Date(timeIntervalSince1970: 2) }
        _ = await s.models()   // only models_cache re-read
        #expect(cacheReads.withLock { $0 } == 2)
        #expect(configReads.withLock { $0 } == 2)
    }
}

@Suite("parseModelsDefault — [models] table-scoped line scan")
struct ParseModelsDefaultTests {
    @Test func scopedToModelsTable() {
        let toml = "[other]\ndefault = \"ignored\"\n\n[models]\ndefault = \"grok-4.5\""
        #expect(parseModelsDefault(toml) == "grok-4.5")
    }

    @Test func ignoresDefaultUnderOtherTables() {
        #expect(parseModelsDefault("[server]\ndefault = \"nope\"") == nil)
    }

    @Test func handlesInlineCommentsOnHeaderAndValue() {
        let toml = "[models]  # my models table\ndefault = \"grok-x\"  # chosen"
        #expect(parseModelsDefault(toml) == "grok-x")
    }

    @Test func acceptsSingleQuotesAndWhitespace() {
        #expect(parseModelsDefault("[models]\n  default   =   'grok-y'  ") == "grok-y")
    }

    @Test func nilWhenNoModelsTableOrNoDefaultKey() {
        #expect(parseModelsDefault("just text\nno tables") == nil)
        #expect(parseModelsDefault("[models]\nother = \"x\"") == nil)
    }

    @Test func emptyValueIsNil() {
        #expect(parseModelsDefault("[models]\ndefault = \"\"") == nil)
    }
}

@Suite("orderedModelKeys — document-order recovery")
struct OrderedModelKeysTests {
    @Test func preservesTopLevelKeyOrderIgnoringNested() {
        // Nested objects/arrays and value strings must not leak into the key list.
        let json = "{\"models\":{\"z\":{\"info\":{\"id\":\"z\",\"name\":\"nested-key-not-a-model\"}},\"a\":{\"efforts\":[{\"id\":\"low\"}]},\"m\":{}}}"
        #expect(orderedModelKeys(json) == ["z", "a", "m"])
    }

    @Test func emptyWhenNoModelsObject() {
        #expect(orderedModelKeys("{\"other\":{\"x\":1}}").isEmpty)
        #expect(orderedModelKeys("not json").isEmpty)
    }
}

@Suite("parseGrokPermissionModes")
struct ParseGrokPermissionModesTests {
    @Test func picksBypassBlockAmongDecoys() {
        let help = "--sandbox [possible values: read-only, workspace-write] --permission-mode [possible values: default, bypassPermissions, plan]"
        #expect(parseGrokPermissionModes(help) == ["default", "bypassPermissions", "plan"])
    }

    @Test func emptyWhenNoBypassSentinelBlock() {
        #expect(parseGrokPermissionModes("[possible values: read-only, workspace-write]").isEmpty)
        #expect(parseGrokPermissionModes("no blocks at all").isEmpty)
    }
}

@Suite("GrokPermissionSource — dynamic permission modes")
struct GrokPermissionSourceTests {
    private func make(identity: String, help: String) -> GrokPermissionSource {
        GrokPermissionSource(runHelp: { help }, resolveIdentity: { identity })
    }

    @Test func permissionChoicesParseAndLabelKnownIds() async {
        let s = make(identity: "grok@1", help: "--permission-mode <M> [possible values: default, acceptEdits, bypassPermissions, plan]")
        #expect(await s.permissionChoices() == [
            ModelChoice(value: "default", label: "default (prompts are cancelled — tools are skipped)"),
            ModelChoice(value: "acceptEdits", label: "acceptEdits (accepted by CLI; non-always-approve path)"),
            ModelChoice(value: "bypassPermissions", label: "bypassPermissions (auto-approve all tools)"),
            ModelChoice(value: "plan", label: "plan (accepted by CLI; non-always-approve path)"),
        ])
    }

    @Test func filterDropsIdsOutsideSchema() async {
        let s = make(identity: "grok@1", help: "[possible values: default, bypassPermissions, weird-mode]")
        #expect(await s.permissionModes() == ["default", "bypassPermissions"])
    }

    @Test func missingIdentityFallsBackToFullList() async {
        let s = make(identity: CLI_MISSING_IDENTITY, help: "[possible values: default, bypassPermissions]")
        #expect(await s.permissionModes() == GROK_PERMISSION_FALLBACK)
    }

    @Test func noBypassSentinelBlockFallsBack() async {
        // A block without the bypassPermissions sentinel → parse yields [] → fallback.
        let s = make(identity: "grok@1", help: "[possible values: read-only, workspace-write]")
        #expect(await s.permissionModes() == GROK_PERMISSION_FALLBACK)
    }

    @Test func isKnownPermissionReflectsList() async {
        let s = make(identity: "grok@1", help: "[possible values: default, bypassPermissions, plan]")
        #expect(await s.isKnownPermission("plan"))
        #expect(await s.isKnownPermission("acceptEdits") == false)
    }
}

@Suite("GrokCatalog — received-only effort choices")
struct GrokCatalogEffortTests {
    @Test func effortChoicesAreModelLevelsVerbatim() {
        let cat = GrokCatalog()
        #expect(cat.effortChoices(modelLevels: ["low", "high"]) == choices(["low", "high"]))
    }

    @Test func effortChoicesEmptyWhenNoModelLevels() {
        let cat = GrokCatalog()
        #expect(cat.effortChoices(modelLevels: nil) == [])
        #expect(cat.effortChoices(modelLevels: []) == [])
    }

    @Test func runtimeEffortEqualsStartEffort() {
        let cat = GrokCatalog()
        #expect(cat.runtimeEffortChoices(modelLevels: ["medium"]) == cat.effortChoices(modelLevels: ["medium"]))
        #expect(cat.runtimeEffortChoices(modelLevels: nil) == cat.effortChoices(modelLevels: nil))
    }
}
