import Foundation

/// F2: persisting a session must NEVER kill a turn. Build the record, upsert, and swallow+log any
/// write failure. Shared by the three bridges' turn-time capture (F7).
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
    backendSessionId: String?
) async {
    let record = PersistedSession(
        backend: backend,
        backendSessionId: backendSessionId,
        cwd: cwd,
        guildId: guildId,
        ownerId: ownerId,
        model: model,
        effort: effort,
        permMode: permMode,
        updatedAt: iso8601Now()
    )
    do {
        try await store.upsert(channelId: channelId, record)
    } catch {
        print("dab: session persist failed (channel=\(channelId)): \(error)")
    }
}

func iso8601Now() -> String { ISO8601DateFormatter().string(from: Date()) }

/// Shown once when a stored session cannot be resumed (expired/gone) and we start fresh (F5).
let sessionFallbackNotice = "⚠️ 이전 세션 복구 실패 — 새 세션으로 시작합니다."
