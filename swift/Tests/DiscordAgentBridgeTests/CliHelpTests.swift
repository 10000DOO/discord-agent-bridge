import Testing
import Foundation
@testable import DiscordAgentBridge

@Suite("CLI possible-values parser")
struct PossibleValuesParserTests {
    // Mirrors src/core/cliPossibleValues.ts behaviour.

    @Test func singleBlockSplitsTrimsAndDropsEmpty() {
        #expect(parsePossibleValues("--sandbox <MODE> [possible values: read-only, workspace-write, danger-full-access]")
            == ["read-only", "workspace-write", "danger-full-access"])
    }

    @Test func labelIsCaseInsensitive() {
        #expect(parsePossibleValues("[POSSIBLE VALUES: a, b]") == ["a", "b"])
        #expect(parsePossibleValues("[Possible Values: a]") == ["a"])
    }

    @Test func trimsInnerWhitespaceAndDropsEmptyTokens() {
        #expect(parsePossibleValues("[possible values:   low ,  high , ,  ]") == ["low", "high"])
    }

    @Test func noMatchOrEmptyInputYieldsEmpty() {
        #expect(parsePossibleValues("no brackets here").isEmpty)
        #expect(parsePossibleValues("").isEmpty)
    }

    @Test func malformedUnterminatedBlockYieldsEmpty() {
        #expect(parsePossibleValues("[possible values: a, b").isEmpty)
    }

    @Test func parsePossibleValuesReturnsFirstBlockOnly() {
        let text = "[possible values: a, b]\n[possible values: c, d]"
        #expect(parsePossibleValues(text) == ["a", "b"])
    }

    @Test func allBlocksReturnedInDocumentOrder() {
        let text = "x [possible values: a, b] y [POSSIBLE VALUES: c] z"
        #expect(parseAllPossibleValueBlocks(text) == [["a", "b"], ["c"]])
    }

    @Test func allBlocksEmptyWhenNone() {
        #expect(parseAllPossibleValueBlocks("nope").isEmpty)
        #expect(parseAllPossibleValueBlocks("").isEmpty)
    }

    @Test func findBlockByPredicate() {
        let text = "--perm [possible values: default, plan] --sandbox [possible values: read-only, workspace-write]"
        #expect(findPossibleValuesBlock(text) { $0.contains("workspace-write") } == ["read-only", "workspace-write"])
        #expect(findPossibleValuesBlock(text) { $0.contains("plan") } == ["default", "plan"])
    }

    @Test func findBlockNilWhenNoPredicateMatch() {
        #expect(findPossibleValuesBlock("[possible values: a, b]") { $0.contains("zzz") } == nil)
        #expect(findPossibleValuesBlock("no blocks") { _ in true } == nil)
    }
}

@Suite("CliHelpValueSource")
struct CliHelpValueSourceTests {
    // Fake runHelp/resolveIdentity injection — no real process spawn.

    private func makeSource(identity: String, help: String, helpCalls: LockedBox<Int>? = nil, fallback: [String], parseHelp: @escaping @Sendable (String) -> [String] = parsePossibleValues, filter: (@Sendable ([String]) -> [String])? = nil) -> CliHelpValueSource {
        let runHelp: RunHelpFn = { helpCalls?.withLock { $0 += 1 }; return help }
        let resolveIdentity: ResolveIdentityFn = { identity }
        return CliHelpValueSource(fallback: fallback, parseHelp: parseHelp, filter: filter, runHelp: runHelp, resolveIdentity: resolveIdentity)
    }

    @Test func missingIdentityReturnsFallbackWithoutRunningHelp() async {
        let calls = LockedBox(0)
        let s = makeSource(identity: CLI_MISSING_IDENTITY, help: "[possible values: a]", helpCalls: calls, fallback: ["x", "y"])
        #expect(await s.values() == ["x", "y"])
        #expect(calls.withLock { $0 } == 0)
    }

    @Test func parsedValuesWhenHelpNonEmpty() async {
        let s = makeSource(identity: "codex@1", help: "[possible values: read-only, workspace-write]", fallback: ["fb"])
        #expect(await s.values() == ["read-only", "workspace-write"])
    }

    @Test func fallbackWhenParseEmpty() async {
        let s = makeSource(identity: "codex@1", help: "no possible values here", fallback: ["fb1", "fb2"])
        #expect(await s.values() == ["fb1", "fb2"])
    }

    @Test func cacheHitAvoidsSecondHelpRun() async {
        let calls = LockedBox(0)
        let s = makeSource(identity: "grok@2", help: "[possible values: default, plan]", helpCalls: calls, fallback: ["fb"])
        _ = await s.values()
        _ = await s.values()
        #expect(calls.withLock { $0 } == 1)
    }

    @Test func identityChangeTriggersReprobe() async {
        let identity = LockedBox("cli@1")
        let calls = LockedBox(0)
        let runHelp: RunHelpFn = { calls.withLock { $0 += 1 }; return "[possible values: a]" }
        let resolveIdentity: ResolveIdentityFn = { identity.withLock { $0 } }
        let s = CliHelpValueSource(fallback: ["fb"], parseHelp: parsePossibleValues, filter: nil, runHelp: runHelp, resolveIdentity: resolveIdentity)
        _ = await s.values()
        identity.withLock { $0 = "cli@2" }
        _ = await s.values()
        #expect(calls.withLock { $0 } == 2)
    }

    @Test func filterAppliedToParsedAndFallbackPaths() async {
        let dropDrop: @Sendable ([String]) -> [String] = { $0.filter { $0 != "drop" } }
        let parsed = makeSource(identity: "x@1", help: "[possible values: keep, drop]", fallback: ["fb"], filter: dropDrop)
        #expect(await parsed.values() == ["keep"])
        // Missing identity → fallback path is filtered too.
        let fb = makeSource(identity: CLI_MISSING_IDENTITY, help: "", fallback: ["keep", "drop"], filter: dropDrop)
        #expect(await fb.values() == ["keep"])
    }
}
