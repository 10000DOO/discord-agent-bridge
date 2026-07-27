import Foundation

private let log = Logger(name: "session-persist")

/// F2: persisting a session must NEVER kill a turn. Build the record, upsert, and swallow+log any
/// write failure. Shared by the three bridges' turn-time capture (F7).
///
/// G-P0-05 / TS sessionOrchestrator: projectAuth (and permissionProfile/archived) are
/// binding-resident — REPLACE must not drop them when a row already exists.
func persistSession(
    store: SessionStore,
    backend: Backend,
    channelId: String,
    guildId: String,
    ownerId: String?,
    cwd: String,
    model: String?,
    effort: String?,
    permMode: String?,
    backendSessionId: String?,
    lifecycleGeneration: String? = nil
) async {
    let existing = await store.binding(channelId: channelId)
    // A backend-id callback can arrive after the channel was reconfigured, closed, or
    // archived. It belongs to the old live client and must not resurrect/overwrite the
    // current binding (including its workspace).
    if let existing, (
        existing.backend != backend
            || existing.archived
            || existing.lifecycleGeneration != lifecycleGeneration
    ) {
        return
    }
    // A removed binding is a terminal lifecycle state. Only a genuinely unbound first-start
    // callback (which has no captured generation yet) may create a new record.
    if existing == nil, lifecycleGeneration != nil { return }
    let record = PersistedSession(
        // Once a binding exists and its generation matches, this callback is allowed to
        // publish only the backend session id. The live bridge captured its startup values;
        // model/effort/permission and guild/owner can have changed in the meantime.
        backend: existing?.backend ?? backend,
        backendSessionId: backendSessionId,
        // The binding's workspace is authoritative for this channel. Bridge callbacks often
        // only know the process fallback cwd, so never replace a wizard-selected cwd with it.
        cwd: existing?.cwd ?? cwd,
        guildId: existing?.guildId ?? guildId,
        ownerId: existing?.ownerId ?? ownerId,
        model: existing?.model ?? model,
        effort: existing?.effort ?? effort,
        permMode: existing?.permMode ?? permMode,
        permissionProfile: existing?.permissionProfile,
        projectAuth: existing?.projectAuth,
        lifecycleGeneration: existing?.lifecycleGeneration ?? UUID().uuidString,
        createdAt: existing?.createdAt,
        updatedAt: iso8601Now(),
        archived: existing?.archived ?? false
    )
    do {
        try await store.upsert(channelId: channelId, record)
    } catch {
        log.warn("session persist failed (channel=\(channelId)): \(error)")
    }
}

func iso8601Now() -> String { ISO8601DateFormatter().string(from: Date()) }

/// Shown once when a stored session cannot be resumed (expired/gone) and we start fresh (F5).
let sessionFallbackNotice = "⚠️ 이전 세션 복구 실패 — 새 세션으로 시작합니다."
