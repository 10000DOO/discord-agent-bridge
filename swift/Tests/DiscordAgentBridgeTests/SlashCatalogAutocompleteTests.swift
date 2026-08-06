import Foundation
import Testing
@testable import DiscordAgentBridge
@testable import dab

private func sampleCommands(_ names: [String]) -> [SlashCatalogEntry] {
    names.map { SlashCatalogEntry(name: $0, description: "does \($0)") }
}

/// Poll until a background fill lands (bounded), returning what the cache then serves.
private func waitForFill(
    channelId: String,
    backend: Backend,
    fetch: @escaping SlashCatalogFetch
) async -> [SlashCatalogEntry] {
    for _ in 0..<200 {
        let served = AutocompleteSlashCatalogCache.commands(channelId: channelId, backend: backend, fetch: fetch)
        if !served.isEmpty { return served }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return []
}

/// WO-6: `/command` autocomplete source — the TTL cache, the backend→bridge map, and the C1
/// guidance entry. Channel ids are unique per test, so the process-wide cache needs no reset and
/// the suite stays parallel-safe. No test asserts a command COUNT (C12: lists are cwd-dependent).
@Suite("WO-6 /command autocomplete source")
struct SlashCatalogAutocompleteTests {
    // MARK: - C17 (the reason this WO exists)

    /// A cache miss must answer NOW. Claude's sidecar request timeout is 120s and Discord gives
    /// autocomplete ~3s with no defer, so this path may never wait on the backend.
    @Test func cacheMissReturnsImmediatelyWithoutWaitingForTheBackend() {
        let slowFetch: SlashCatalogFetch = { _ in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            return sampleCommands(["too-late"])
        }
        let started = Date()
        let served = AutocompleteSlashCatalogCache.commands(channelId: "c-slow", backend: .claude, fetch: slowFetch)
        #expect(served.isEmpty)
        #expect(Date().timeIntervalSince(started) < 0.5)
    }

    /// A typing burst must not stack one backend probe per keystroke.
    @Test func repeatedMissesDoNotStackFetches() async {
        let calls = LockedBox(0)
        let slowFetch: SlashCatalogFetch = { _ in
            calls.withLock { $0 += 1 }
            try? await Task.sleep(nanoseconds: 500_000_000)
            return sampleCommands(["context"])
        }
        _ = AutocompleteSlashCatalogCache.commands(channelId: "c-burst", backend: .claude, fetch: slowFetch)
        while calls.withLock({ $0 }) < 1 { try? await Task.sleep(nanoseconds: 5_000_000) }
        // The first probe is still parked; further keystrokes must not launch a second one.
        for _ in 0..<5 {
            _ = AutocompleteSlashCatalogCache.commands(channelId: "c-burst", backend: .claude, fetch: slowFetch)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(calls.withLock { $0 } == 1)
    }

    // MARK: - Cache hit / miss

    @Test func cacheHitDoesNotCallTheBackendAgain() async {
        let calls = LockedBox(0)
        let fetch: SlashCatalogFetch = { _ in
            calls.withLock { $0 += 1 }
            return sampleCommands(["context", "review"])
        }
        #expect(AutocompleteSlashCatalogCache.commands(channelId: "c-hit", backend: .codex, fetch: fetch).isEmpty)
        #expect(await waitForFill(channelId: "c-hit", backend: .codex, fetch: fetch).map(\.name) == ["context", "review"])
        _ = AutocompleteSlashCatalogCache.commands(channelId: "c-hit", backend: .codex, fetch: fetch)
        _ = AutocompleteSlashCatalogCache.commands(channelId: "c-hit", backend: .codex, fetch: fetch)
        #expect(calls.withLock { $0 } == 1)
    }

    /// Lazy spawn: "no session yet" is an empty answer, and freezing it for a full TTL would keep
    /// the channel blank for a minute after it finally starts talking.
    @Test func emptyResultIsNotCached() async {
        let calls = LockedBox(0)
        let fetch: SlashCatalogFetch = { _ in
            calls.withLock { $0 += 1 }
            return []
        }
        _ = AutocompleteSlashCatalogCache.commands(channelId: "c-empty", backend: .claude, fetch: fetch)
        while calls.withLock({ $0 }) < 1 { try? await Task.sleep(nanoseconds: 10_000_000) }
        _ = AutocompleteSlashCatalogCache.commands(channelId: "c-empty", backend: .claude, fetch: fetch)
        while calls.withLock({ $0 }) < 2 { try? await Task.sleep(nanoseconds: 10_000_000) }
        #expect(calls.withLock { $0 } >= 2)
    }

    // MARK: - Staleness policy (the two halves must not be confused)

    /// Same backend, TTL expired: keep serving the last good list while refreshing behind it, so a
    /// channel that has talked before never goes blank again.
    @Test func expiredEntryIsServedStaleWhileRefreshing() async {
        let first = sampleCommands(["old-one"])
        let second = sampleCommands(["new-one"])
        let phase = LockedBox(0)
        let fetch: SlashCatalogFetch = { _ in
            let n = phase.withLock { v -> Int in
                v += 1
                return v
            }
            return n == 1 ? first : second
        }
        _ = AutocompleteSlashCatalogCache.commands(channelId: "c-stale", backend: .grok, fetch: fetch)
        #expect(await waitForFill(channelId: "c-stale", backend: .grok, fetch: fetch).map(\.name) == ["old-one"])

        let expired = Date().addingTimeInterval(AutocompleteSlashCatalogCache.ttl + 10)
        let servedWhileRefreshing = AutocompleteSlashCatalogCache.commands(
            channelId: "c-stale", backend: .grok, now: expired, fetch: fetch
        )
        #expect(servedWhileRefreshing.map(\.name) == ["old-one"])

        for _ in 0..<200 {
            let now = AutocompleteSlashCatalogCache.commands(channelId: "c-stale", backend: .grok, fetch: fetch)
            if now.map(\.name) == ["new-one"] { break }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let refreshed = AutocompleteSlashCatalogCache.commands(channelId: "c-stale", backend: .grok, fetch: fetch)
        #expect(refreshed.map(\.name) == ["new-one"])
    }

    /// The most valuable regression guard here: after `/mode backend …` the previous backend's
    /// commands must NEVER leak. A codex skill offered in a grok channel would actually be run.
    @Test func switchingBackendNeverServesThePreviousBackendsList() async {
        let codexFetch: SlashCatalogFetch = { _ in sampleCommands(["codex-only-skill"]) }
        let grokFetch: SlashCatalogFetch = { _ in sampleCommands(["grok-only-command"]) }

        _ = AutocompleteSlashCatalogCache.commands(channelId: "c-switch", backend: .codex, fetch: codexFetch)
        let asCodex = await waitForFill(channelId: "c-switch", backend: .codex, fetch: codexFetch)
        #expect(asCodex.map(\.name) == ["codex-only-skill"])

        // Same channel, new backend, entry still well inside its TTL: stale-serve must NOT apply.
        let afterSwitch = AutocompleteSlashCatalogCache.commands(channelId: "c-switch", backend: .grok, fetch: grokFetch)
        #expect(afterSwitch.isEmpty)

        let refilled = await waitForFill(channelId: "c-switch", backend: .grok, fetch: grokFetch)
        #expect(refilled.map(\.name) == ["grok-only-command"])
        #expect(!refilled.contains { $0.name == "codex-only-skill" })
    }

    @Test func eachChannelSeesItsOwnBackendList() async {
        let claudeFetch: SlashCatalogFetch = { _ in sampleCommands(["compact", "context"]) }
        let grokFetch: SlashCatalogFetch = { _ in sampleCommands(["session-info"]) }
        _ = AutocompleteSlashCatalogCache.commands(channelId: "c-multi-claude", backend: .claude, fetch: claudeFetch)
        _ = AutocompleteSlashCatalogCache.commands(channelId: "c-multi-grok", backend: .grok, fetch: grokFetch)
        #expect(await waitForFill(channelId: "c-multi-claude", backend: .claude, fetch: claudeFetch).map(\.name) == ["compact", "context"])
        #expect(await waitForFill(channelId: "c-multi-grok", backend: .grok, fetch: grokFetch).map(\.name) == ["session-info"])
    }

    // MARK: - Backend → bridge map

    /// The one thing only the injected factory can prove: `.custom` rides Claude's bridge, exactly
    /// as `providerCatalog(for:)` groups them. An unbound channel falls back to `.claude` in
    /// `handleAutocomplete`, so this is also that fallback's destination.
    @Test func customBackendUsesTheClaudeBridge() async {
        let claude: SlashCatalogFetch = { _ in sampleCommands(["from-claude"]) }
        let codex: SlashCatalogFetch = { _ in sampleCommands(["from-codex"]) }
        let grok: SlashCatalogFetch = { _ in sampleCommands(["from-grok"]) }
        for backend in [Backend.claude, .custom] {
            let fetch = slashCatalogFetcher(for: backend, claude: claude, codex: codex, grok: grok)
            #expect(await fetch("c").map(\.name) == ["from-claude"])
        }
        let codexFetch = slashCatalogFetcher(for: .codex, claude: claude, codex: codex, grok: grok)
        let grokFetch = slashCatalogFetcher(for: .grok, claude: claude, codex: codex, grok: grok)
        #expect(await codexFetch("c").map(\.name) == ["from-codex"])
        #expect(await grokFetch("c").map(\.name) == ["from-grok"])
    }

    // MARK: - Discord surface

    @Test func filteringAndTheTwentyFiveCapSurviveTheWiring() async {
        let many = sampleCommands((0..<40).map { "cmd-\($0)" })
        let fetch: SlashCatalogFetch = { _ in many }
        _ = AutocompleteSlashCatalogCache.commands(channelId: "c-cap", backend: .grok, fetch: fetch)
        let filled = await waitForFill(channelId: "c-cap", backend: .grok, fetch: fetch)
        #expect(filterSlashCatalogChoices(filled, query: "").count == discordAutocompleteChoiceLimit)
        #expect(filterSlashCatalogChoices(filled, query: "cmd-7").map(\.value) == ["cmd-7"])
    }

    // MARK: - C1 guidance entry

    /// A bound-but-silent channel shows one guidance entry instead of a blank picker. Its value is
    /// the sentinel WO-7 must recognise BEFORE treating the value as a command name.
    @Test func noCommandsYieldsTheGuidanceSentinel() {
        let suggestions = slashCatalogSuggestions(channelId: "c-guidance", backend: .claude, query: "")
        #expect(suggestions.map(\.value) == [slashCatalogNoSessionValue])
        #expect(!(suggestions.first?.name.isEmpty ?? true))
        #expect((suggestions.first?.name.count ?? 0) <= 100)
        // Cannot collide with a backend command name.
        #expect(slashCatalogNoSessionValue.hasPrefix("dab:"))
    }

    /// A real list that simply does not match what was typed is ordinary "no match" — not a
    /// missing session, so the guidance entry must stay out of the way.
    @Test func nonMatchingQueryDoesNotShowTheGuidanceSentinel() async {
        let fetch: SlashCatalogFetch = { _ in sampleCommands(["context", "review"]) }
        _ = AutocompleteSlashCatalogCache.commands(channelId: "c-nomatch", backend: .grok, fetch: fetch)
        _ = await waitForFill(channelId: "c-nomatch", backend: .grok, fetch: fetch)
        #expect(slashCatalogSuggestions(channelId: "c-nomatch", backend: .grok, query: "zzzz").isEmpty)
        #expect(slashCatalogSuggestions(channelId: "c-nomatch", backend: .grok, query: "rev").map(\.value) == ["review"])
    }

    /// C15 house rule: Korean user-facing strings stay at or under 32 scalars.
    @Test func koreanGuidanceStringStaysUnderTheThirtyTwoScalarRule() {
        #expect(I18n.t("run.noSession", locale: .ko).count <= 32)
        #expect(I18n.t("run.noSession", locale: .en) != "run.noSession")
    }

    /// WO-9: the old wording told the user to "start the conversation first", which is a lie in the
    /// channel this was reported from — it was mid-conversation, the cache was simply cold. The
    /// stand-in may only claim what it actually knows: the list is not here YET.
    @Test func guidanceDoesNotClaimTheChannelHasNeverTalked() {
        #expect(!I18n.t("run.noSession", locale: .ko).contains("대화"))
        #expect(!I18n.t("run.noSession", locale: .en).lowercased().contains("conversation"))
    }

    // MARK: - WO-9 warm-up

    /// The whole point: after a warm-up the FIRST picker open serves the real list, with no
    /// intervening keystroke to prime the cache.
    @Test func warmingMakesTheVeryFirstLookupServeRealCommands() async {
        let fetch: SlashCatalogFetch = { _ in sampleCommands(["context", "review"]) }
        #expect(await warmSlashCatalog(channelId: "c-warm", backend: .claude, ensureLive: { _ in true }, fetch: fetch))
        #expect(slashCatalogSuggestions(channelId: "c-warm", backend: .claude, query: "").map(\.value) == ["context", "review"])
    }

    /// C17 stands: the lookup path is still synchronous and still refuses to wait, warm or not.
    @Test func warmingDoesNotBlockTheLookupPath() async {
        let slowFetch: SlashCatalogFetch = { _ in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            return sampleCommands(["too-late"])
        }
        let warming = Task { await warmSlashCatalog(channelId: "c-warm-slow", backend: .codex, ensureLive: { _ in true }, fetch: slowFetch) }
        let started = Date()
        let served = AutocompleteSlashCatalogCache.commands(channelId: "c-warm-slow", backend: .codex, fetch: slowFetch)
        #expect(served.isEmpty)
        #expect(Date().timeIntervalSince(started) < 0.5)
        warming.cancel()
    }

    /// `/mode backend …`: the old list is dropped on sight (C26) and the warm-up puts the NEW
    /// backend's list in its place, so the first picker after a switch is not empty-handed either.
    @Test func warmingAfterABackendSwitchInstallsTheNewBackendsList() async {
        let codexFetch: SlashCatalogFetch = { _ in sampleCommands(["codex-only-skill"]) }
        let grokFetch: SlashCatalogFetch = { _ in sampleCommands(["grok-only-command"]) }
        #expect(await warmSlashCatalog(channelId: "c-warm-switch", backend: .codex, ensureLive: { _ in true }, fetch: codexFetch))
        #expect(await warmSlashCatalog(channelId: "c-warm-switch", backend: .grok, ensureLive: { _ in true }, fetch: grokFetch))
        let served = slashCatalogSuggestions(channelId: "c-warm-switch", backend: .grok, query: "")
        #expect(served.map(\.value) == ["grok-only-command"])
        #expect(!served.contains { $0.value == "codex-only-skill" })
    }

    /// No session, and none that can be opened: the warm-up reports failure and changes nothing.
    /// It must never throw or block a user flow — the picker just keeps its stand-in.
    @Test func warmingIsSilentWhenNoSessionCanBeOpened() async {
        let probed = LockedBox(false)
        let fetch: SlashCatalogFetch = { _ in
            probed.withLock { $0 = true }
            return sampleCommands(["never-asked"])
        }
        #expect(await warmSlashCatalog(channelId: "c-warm-dead", backend: .grok, ensureLive: { _ in false }, fetch: fetch) == false)
        #expect(probed.withLock { $0 } == false)
        #expect(slashCatalogSuggestions(channelId: "c-warm-dead", backend: .grok, query: "").map(\.value) == [slashCatalogNoSessionValue])
    }

    /// A live session that advertises nothing is not a list — caching it would blank the channel
    /// for a full TTL after it finally has one (C22).
    @Test func warmingDoesNotCacheAnEmptyList() async {
        #expect(await warmSlashCatalog(channelId: "c-warm-empty", backend: .claude, ensureLive: { _ in true }, fetch: { _ in [] }) == false)
        #expect(slashCatalogSuggestions(channelId: "c-warm-empty", backend: .claude, query: "").map(\.value) == [slashCatalogNoSessionValue])
    }

    /// Two warm-ups racing (boot sweep vs. a wizard that just finished), or a warm-up racing a
    /// typing burst, must collapse into one backend probe.
    @Test func concurrentWarmingProbesTheBackendOnce() async {
        let calls = LockedBox(0)
        let fetch: SlashCatalogFetch = { _ in
            calls.withLock { $0 += 1 }
            try? await Task.sleep(nanoseconds: 200_000_000)
            return sampleCommands(["context"])
        }
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<5 {
                group.addTask { await warmSlashCatalog(channelId: "c-warm-race", backend: .codex, ensureLive: { _ in true }, fetch: fetch) }
            }
            for await _ in group {}
        }
        #expect(calls.withLock { $0 } == 1)
    }
}
