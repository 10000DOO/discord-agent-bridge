import DiscordAgentBridge
import Foundation

// MARK: - /command autocomplete source (WO-6, docs/cli-slash-command-parity.md §3-5-4 · C1 · C17)

/// "Ask this channel's backend which slash commands its live session advertises."
typealias SlashCatalogFetch = @Sendable (_ channelId: String) async -> [SlashCatalogEntry]

/// The ONE place a backend id maps to the bridge that answers for it — mirrors
/// `providerCatalog(for:)`. The three bridge calls arrive as injected closures, the same shape
/// `SessionLifecycle.swift:54-64` uses for stop/interrupt/setModel, so tests substitute fakes and
/// nobody branches on a backend name string.
///
/// `.custom` runs on the Claude sidecar, so it shares Claude's bridge — the same grouping
/// `providerCatalog(for:)` makes.
func slashCatalogFetcher(
    for backend: Backend,
    claude: @escaping SlashCatalogFetch = { await DabSessionBridge.shared.slashCatalog(channelId: $0) },
    codex: @escaping SlashCatalogFetch = { await CodexSessionBridge.shared.slashCatalog(channelId: $0) },
    // No `await` on grok alone: it serves a list the client already holds, so its accessor is not
    // async (C19 in the parity doc's concern ledger). The closure type stays async for all three.
    grok: @escaping SlashCatalogFetch = { GrokSessionBridge.shared.slashCatalog(channelId: $0) }
) -> SlashCatalogFetch {
    switch backend {
    case .claude, .custom: return claude
    case .codex: return codex
    case .grok: return grok
    }
}

/// 60s per-channel command cache — the sibling of `AutocompleteModelsCache` (DabMain.swift:3588).
///
/// C17: `slashCatalog` really leaves the process for Claude (sidecar, 120s request timeout) and
/// Codex (`skills/list` RPC), but Discord autocomplete has ~3s and no defer. So this lookup is
/// **synchronous by construction** — it cannot await a fetch even by mistake. A miss answers with
/// whatever it can serve right now and starts a background fill, so the next keystroke is served
/// from cache. Grok answers instantly, which is exactly why a grok channel never exposes this
/// bug: verify on claude/codex.
///
/// Staleness policy (two different rules, deliberately):
///   • same backend, TTL expired → serve the last good list while refreshing behind it, so a
///     channel that has talked before never goes blank again.
///   • backend CHANGED (`/mode backend …`) → the old list is DROPPED, never served. Showing
///     codex skills in a grok channel is worse than showing nothing: the user can pick one and it
///     actually runs.
///
/// ponytail: entries are keyed by channel with no cap and, because of the stale-serve rule above,
/// they are never evicted — a channel's last good list lives for the life of the process. Fine at
/// this repo's channel count; add an LRU cap if channel count ever grows by orders of magnitude.
enum AutocompleteSlashCatalogCache {
    private struct Entry {
        var backend: Backend
        var commands: [SlashCatalogEntry]
        var fetchedAt: Date
    }

    private struct State {
        var entries: [String: Entry] = [:]
        /// Channels already being filled — a typing burst must not stack one fetch per keystroke.
        var filling: Set<String> = []
    }

    private static let box = LockedBox(State())
    static let ttl: TimeInterval = 60

    /// Commands servable for this channel right now (possibly stale, possibly empty), starting a
    /// background refresh when one is due. NEVER blocks on the backend.
    static func commands(
        channelId: String,
        backend: Backend,
        now: Date = Date(),
        fetch: @escaping SlashCatalogFetch
    ) -> [SlashCatalogEntry] {
        // The claim is taken HERE, under the same lock as the read — not inside the spawned task.
        // A typing burst outruns the scheduler, so a claim made after the hop would let every
        // keystroke queue a task that probes in turn as each release lands.
        let (serve, claimed): ([SlashCatalogEntry], Bool) = box.withLock { s in
            guard let hit = s.entries[channelId], hit.backend == backend else {
                // Unknown channel, or one that switched backends: serve nothing, refill.
                return ([], s.filling.insert(channelId).inserted)
            }
            if now.timeIntervalSince(hit.fetchedAt) < ttl { return (hit.commands, false) }
            return (hit.commands, s.filling.insert(channelId).inserted)
        }
        if claimed {
            Task { await probe(channelId: channelId, backend: backend, fetch: fetch) }
        }
        return serve
    }

    /// Warm-up entry point (`warmSlashCatalog`): probe the backend NOW rather than on the first
    /// keystroke. Never call it from autocomplete — it awaits the backend (C17).
    ///
    /// Returns whether a list actually landed. Loses to whatever probe is already in flight for the
    /// channel, so a boot sweep racing a typing burst still costs one round trip.
    @discardableResult
    static func fill(channelId: String, backend: Backend, fetch: SlashCatalogFetch) async -> Bool {
        guard box.withLock({ $0.filling.insert(channelId).inserted }) else { return false }
        return await probe(channelId: channelId, backend: backend, fetch: fetch)
    }

    /// One round trip, for a caller that already holds the channel's claim. Releases it either way.
    @discardableResult
    private static func probe(channelId: String, backend: Backend, fetch: SlashCatalogFetch) async -> Bool {
        let fetched = await fetch(channelId)
        box.withLock { s in
            // Empty means "nobody to ask yet" — sessions spawn lazily on the first turn.
            // Storing that would blank the channel for a full TTL after it finally starts
            // talking, and would also throw away a good list across a session restart.
            if !fetched.isEmpty {
                s.entries[channelId] = Entry(backend: backend, commands: fetched, fetchedAt: Date())
            }
            s.filling.remove(channelId)
        }
        return !fetched.isEmpty
    }
}

/// Pre-fill the `/command` picker for a channel, so its FIRST open shows real commands instead of
/// the "still loading" stand-in (WO-9).
///
/// All three backends can only list their commands from a LIVE session, so this opens one the same
/// way `/agent resume` does — no user turn, no visible side effect. Everything here is
/// best-effort and silent: a channel with no store row, a backend that will not start, a failed
/// RPC — all just leave the cache as it was, because a missing list is a stale picker, not an error.
///
/// Slow by nature (a cold Claude sidecar takes seconds), so every caller runs it detached: each one
/// owes Discord a reply first.
@discardableResult
func warmSlashCatalog(
    channelId: String,
    backend: Backend,
    ensureLive: @Sendable (String) async -> Bool = { await SessionLifecycle.shared.softEnsureLive(channelId: $0) },
    fetch: SlashCatalogFetch? = nil
) async -> Bool {
    guard await ensureLive(channelId) else { return false }
    return await AutocompleteSlashCatalogCache.fill(
        channelId: channelId,
        backend: backend,
        fetch: fetch ?? slashCatalogFetcher(for: backend)
    )
}

/// Cached commands for the channel's bound backend. Synchronous on purpose (C17).
func autocompleteSlashCommands(channelId: String, backend: Backend) -> [SlashCatalogEntry] {
    AutocompleteSlashCatalogCache.commands(
        channelId: channelId,
        backend: backend,
        fetch: slashCatalogFetcher(for: backend)
    )
}

/// Sentinel `value` handed back when the channel has no command list yet (C1) — a blank picker
/// reads as a broken command, so one entry stands in and says what is going on.
///
/// WO-9: `warmSlashCatalog` fills the cache at every point a session comes up, so by the time a
/// picker opens this is normally already gone. What is left is genuinely "not loaded yet" — the
/// warm-up is still in flight, or it could not open a session at all — which is why the text says
/// exactly that instead of telling a busy channel to start talking.
///
/// This is NOT a backend command. WO-7's submit handler must test for it **before** looking the
/// value up as a command name, and answer with guidance instead of opening the modal. The `dab:`
/// prefix cannot collide: backends report either bare names (`context`) or `plugin:command`
/// namespaces, never a `dab:` one.
let slashCatalogNoSessionValue = "dab:no-session"

/// `/command` autocomplete suggestions for this channel: the backend's own commands, filtered by
/// what the user typed. When the backend has advertised nothing at all, one guidance entry stands
/// in for the empty list (C1). A non-empty list that simply does not match the query stays empty —
/// that is ordinary "no match", not a missing session.
func slashCatalogSuggestions(channelId: String, backend: Backend, query: String) -> [AutocompleteChoice] {
    let commands = autocompleteSlashCommands(channelId: channelId, backend: backend)
    guard !commands.isEmpty else {
        return [AutocompleteChoice(name: I18n.t("run.noSession"), value: slashCatalogNoSessionValue)]
    }
    return filterSlashCatalogChoices(commands, query: query)
}
