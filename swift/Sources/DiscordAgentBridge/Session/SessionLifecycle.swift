import Foundation

/// Thin orchestration over the three bridges + SessionRegistry + SessionStore for stop /
/// interrupt / stopAll (W14). Mirrors `sessionOrchestrator.ts` stop/interrupt/stopAll without
/// pulling Discord into the library. Bridges only drop live backend state; this type owns the
/// registry/store unbind for hard-stop paths.
///
/// Injectable bridge callbacks keep unit tests off the shared singletons when needed; production
/// uses the default shared-bridge closures.
public struct SessionLifecycle: Sendable {
    public typealias ChannelOp = @Sendable (String) async -> Void
    public typealias InterruptOp = @Sendable (String) async -> Bool

    private let registry: SessionRegistry
    private let store: SessionStore
    private let audit: AuditLog
    private let stopClaude: ChannelOp
    private let stopCodex: ChannelOp
    private let stopGrok: ChannelOp
    private let interruptClaude: InterruptOp
    private let interruptCodex: InterruptOp
    private let interruptGrok: InterruptOp

    public init(
        registry: SessionRegistry = .shared,
        store: SessionStore = .shared,
        audit: AuditLog = .shared,
        stopClaude: @escaping ChannelOp = { await DabSessionBridge.shared.stop(channelId: $0) },
        stopCodex: @escaping ChannelOp = { await CodexSessionBridge.shared.stop(channelId: $0) },
        stopGrok: @escaping ChannelOp = { await GrokSessionBridge.shared.stop(channelId: $0) },
        interruptClaude: @escaping InterruptOp = { await DabSessionBridge.shared.interrupt(channelId: $0) },
        interruptCodex: @escaping InterruptOp = { await CodexSessionBridge.shared.interrupt(channelId: $0) },
        interruptGrok: @escaping InterruptOp = { await GrokSessionBridge.shared.interrupt(channelId: $0) }
    ) {
        self.registry = registry
        self.store = store
        self.audit = audit
        self.stopClaude = stopClaude
        self.stopCodex = stopCodex
        self.stopGrok = stopGrok
        self.interruptClaude = interruptClaude
        self.interruptCodex = interruptCodex
        self.interruptGrok = interruptGrok
    }

    /// Process-wide default used by `dab` (same pattern as bridges/registry).
    public static let shared = SessionLifecycle()

    // MARK: - stop / interrupt / stopAll

    /// Hard-stop one channel: stop **every** backend bridge for this channelId (prefix/rebind can
    /// leave a non-bound backend live), then unbind registry + remove store. Idempotent when
    /// nothing is bound and all bridges are idle.
    @discardableResult
    public func stopChannel(
        channelId: String,
        actorId: String,
        guildId: String,
        roleTier: String = "execute"
    ) async -> Bool {
        // Always all three — binding/store may name the wrong backend or be empty while a
        // prefix-spawned process is still live (RV: process leak).
        await stopClaude(channelId)
        await stopCodex(channelId)
        await stopGrok(channelId)

        let backend = await resolveBackend(channelId: channelId)
        let hadReg = await registry.binding(channelId: channelId) != nil
        let hadStore = await store.binding(channelId: channelId) != nil
        let hadBinding = hadReg || hadStore
        await registry.unbind(channelId: channelId)
        try? await store.remove(channelId: channelId)
        if hadBinding {
            await audit.record(AuditEntry(
                actorId: actorId,
                roleTier: roleTier,
                guildId: guildId,
                channelId: channelId,
                action: "stop",
                mode: backend?.rawValue,
                status: "ok"
            ))
        }
        return hadBinding
    }

    /// Cancel in-flight turns on **every** backend for this channel; keep registry/store.
    /// Returns whether any live backend reported a session (TS `orchestrator.interrupt`).
    public func interruptChannel(
        channelId: String,
        actorId: String,
        guildId: String,
        roleTier: String = "execute"
    ) async -> Bool {
        // Any-backend: prefix/rebind can leave a non-bound bridge as the live one.
        let claude = await interruptClaude(channelId)
        let codex = await interruptCodex(channelId)
        let grok = await interruptGrok(channelId)
        let ok = claude || codex || grok
        if ok {
            let mode: String?
            if claude { mode = Backend.claude.rawValue }
            else if codex { mode = Backend.codex.rawValue }
            else if grok { mode = Backend.grok.rawValue }
            else { mode = await resolveBackend(channelId: channelId)?.rawValue }
            await audit.record(AuditEntry(
                actorId: actorId,
                roleTier: roleTier,
                guildId: guildId,
                channelId: channelId,
                action: "interrupt",
                mode: mode,
                status: "ok"
            ))
        }
        return ok
    }

    /// Stop every bound channel (registry ∪ **active** store). Archived store rows are skipped
    /// (TS resumeAll / list consumers filter `archived`; stop itself hard-removes). Each stop is
    /// isolated so one failure does not abort the rest. Per-channel audit guildId prefers the
    /// store binding when present.
    public func stopAll(actorId: String, guildId: String, roleTier: String = "admin") async -> Int {
        var ids = Set(await registry.list().keys)
        let storeActive = await store.active()
        for key in storeActive.keys { ids.insert(key) }
        // guildId for audit: prefer any store row (incl. if only registry-bound).
        let storeAll = await store.all()
        for channelId in ids {
            let g = storeAll[channelId]?.guildId ?? guildId
            await stopChannel(channelId: channelId, actorId: actorId, guildId: g, roleTier: roleTier)
        }
        return ids.count
    }

    // MARK: - private

    private func resolveBackend(channelId: String) async -> Backend? {
        if let b = await registry.binding(channelId: channelId)?.backend { return b }
        return await store.binding(channelId: channelId)?.backend
    }
}
