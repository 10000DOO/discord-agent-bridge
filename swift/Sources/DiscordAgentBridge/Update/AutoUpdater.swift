import Foundation

// Auto-update orchestrator (TS `src/update/autoUpdater.ts`).
// Owns scheduling, check→compare→notify, dismiss, and approve.
// Install+restart are DI ports — Swift shippable slice wires a no-op self-replace
// (ponytail: binary self-replace/service restart not shipped; approve → manual path ack).

public let updateDefaultIntervalMs = 24 * 60 * 60 * 1000

public struct AutoUpdateMeta: Codable, Sendable, Equatable {
    public var lastCheckAt: Int
    public var dismissedVersion: String?

    public init(lastCheckAt: Int = 0, dismissedVersion: String? = nil) {
        self.lastCheckAt = lastCheckAt
        self.dismissedVersion = dismissedVersion
    }

    public static let empty = AutoUpdateMeta()
}

/// Partial patch for meta (nil fields = leave unchanged).
public struct AutoUpdateMetaPatch: Sendable, Equatable {
    public var lastCheckAt: Int?
    public var dismissedVersion: String?

    public init(lastCheckAt: Int? = nil, dismissedVersion: String? = nil) {
        self.lastCheckAt = lastCheckAt
        self.dismissedVersion = dismissedVersion
    }
}

public struct UpdateMessages: Sendable, Equatable {
    public var busy: String
    public var manualOnly: String
    public var dismissed: String

    public init(busy: String, manualOnly: String, dismissed: String) {
        self.busy = busy
        self.manualOnly = manualOnly
        self.dismissed = dismissed
    }

    public static let korean = UpdateMessages(
        busy: UpdateLabels.busy,
        manualOnly: UpdateLabels.manualOnly,
        dismissed: UpdateLabels.dismissed
    )
}

public struct UpdateDecisionCtx: Sendable {
    public var actorId: String
    public var guildId: String
    public var channelId: String
    public var ack: @Sendable (String) async -> Void
    public var disableButtons: @Sendable () async -> Void

    public init(
        actorId: String,
        guildId: String,
        channelId: String,
        ack: @escaping @Sendable (String) async -> Void,
        disableButtons: @escaping @Sendable () async -> Void
    ) {
        self.actorId = actorId
        self.guildId = guildId
        self.channelId = channelId
        self.ack = ack
        self.disableButtons = disableButtons
    }
}

public struct UpdateInstallResult: Sendable, Equatable {
    public var ok: Bool
    public var code: Int
    public var stderr: String

    public init(ok: Bool, code: Int = 0, stderr: String = "") {
        self.ok = ok
        self.code = code
        self.stderr = stderr
    }
}

public struct AutoUpdaterDeps: Sendable {
    public var currentVersion: String
    public var enabled: @Sendable () async -> Bool
    public var intervalMs: Int
    public var now: @Sendable () -> Int
    public var fetchLatest: @Sendable () async -> String?
    public var readMeta: @Sendable () async -> AutoUpdateMeta
    public var writeMeta: @Sendable (AutoUpdateMetaPatch) async -> Void
    public var postPrompt: @Sendable (String) async throws -> Void
    public var announce: @Sendable (String) async -> Void
    /// Optional install port. Swift default: not implemented → approve uses manualOnly.
    public var install: (@Sendable () async -> UpdateInstallResult)?
    public var restart: (@Sendable () -> Void)?
    public var messages: UpdateMessages
    public var onLog: @Sendable (String) -> Void

    public init(
        currentVersion: String,
        enabled: @escaping @Sendable () async -> Bool,
        intervalMs: Int = updateDefaultIntervalMs,
        now: @escaping @Sendable () -> Int = { Int(Date().timeIntervalSince1970 * 1000) },
        fetchLatest: @escaping @Sendable () async -> String?,
        readMeta: @escaping @Sendable () async -> AutoUpdateMeta,
        writeMeta: @escaping @Sendable (AutoUpdateMetaPatch) async -> Void,
        postPrompt: @escaping @Sendable (String) async throws -> Void,
        announce: @escaping @Sendable (String) async -> Void = { _ in },
        install: (@Sendable () async -> UpdateInstallResult)? = nil,
        restart: (@Sendable () -> Void)? = nil,
        messages: UpdateMessages = .korean,
        onLog: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.currentVersion = currentVersion
        self.enabled = enabled
        self.intervalMs = intervalMs
        self.now = now
        self.fetchLatest = fetchLatest
        self.readMeta = readMeta
        self.writeMeta = writeMeta
        self.postPrompt = postPrompt
        self.announce = announce
        self.install = install
        self.restart = restart
        self.messages = messages
        self.onLog = onLog
    }
}

/// Result of one check cycle (for `/update` and tests).
public struct UpdateCheckResult: Sendable, Equatable {
    public enum Kind: String, Sendable, Equatable {
        case disabled
        case fetchFailed
        case upToDate
        case dismissed
        case available
    }

    public var kind: Kind
    public var currentVersion: String
    public var latestVersion: String?

    public init(kind: Kind, currentVersion: String, latestVersion: String? = nil) {
        self.kind = kind
        self.currentVersion = currentVersion
        self.latestVersion = latestVersion
    }
}

public actor AutoUpdater {
    private let deps: AutoUpdaterDeps
    private var loopTask: Task<Void, Never>?
    private var updating = false

    public init(deps: AutoUpdaterDeps) {
        self.deps = deps
    }

    /// Start scheduling. Immediate check when due; then interval loop. Idempotent.
    public func start() {
        guard loopTask == nil else { return }
        let interval = deps.intervalMs
        loopTask = Task { [weak self] in
            guard let self else { return }
            // Immediate due-check.
            let enabled = await self.deps.enabled()
            if enabled {
                let meta = await self.deps.readMeta()
                let due = self.deps.now() - meta.lastCheckAt >= interval
                if due { await self.checkNow() }
            }
            while !Task.isCancelled {
                let ns = UInt64(max(1, interval)) * 1_000_000
                try? await Task.sleep(nanoseconds: ns)
                if Task.isCancelled { break }
                await self.checkNow()
            }
        }
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    /// One check cycle. Never throws. Re-posts prompt for a newer stable until dismissed.
    @discardableResult
    public func checkNow(post: Bool = true) async -> UpdateCheckResult {
        let current = deps.currentVersion
        guard await deps.enabled() else {
            return UpdateCheckResult(kind: .disabled, currentVersion: current)
        }
        let latest = await deps.fetchLatest()
        await deps.writeMeta(AutoUpdateMetaPatch(lastCheckAt: deps.now()))
        guard let latest else {
            deps.onLog("auto-update: registry fetch failed/null")
            return UpdateCheckResult(kind: .fetchFailed, currentVersion: current)
        }
        guard isNewerStable(current: current, latest: latest) else {
            return UpdateCheckResult(kind: .upToDate, currentVersion: current, latestVersion: latest)
        }
        let meta = await deps.readMeta()
        if latest == meta.dismissedVersion {
            return UpdateCheckResult(kind: .dismissed, currentVersion: current, latestVersion: latest)
        }
        if post {
            do {
                try await deps.postPrompt(latest)
            } catch {
                deps.onLog("auto-update: failed to post prompt: \(error)")
            }
        }
        return UpdateCheckResult(kind: .available, currentVersion: current, latestVersion: latest)
    }

    /// [Yes] click. Without install port → manual-only ack (no restart).
    /// With install port (future): install then restart on success.
    public func approve(_ version: String, ctx: UpdateDecisionCtx) async {
        if updating {
            await ctx.ack(deps.messages.busy)
            return
        }
        updating = true
        await ctx.disableButtons()

        guard let install = deps.install else {
            // ponytail: no self-replace for Swift dab binary — ceiling is notify+dismiss+manual path;
            // upgrade when shipping install.sh/service restart wiring.
            await ctx.ack(deps.messages.manualOnly)
            deps.onLog("auto-update: approve \(version) — self-replace skipped (manual path)")
            updating = false
            return
        }

        let result = await install()
        if !result.ok {
            deps.onLog("auto-update: install failed code=\(result.code)")
            await deps.announce(deps.messages.manualOnly)
            updating = false
            return
        }
        await deps.announce(deps.messages.manualOnly)
        deps.restart?()
        // If restart returns (tests), release guard.
        updating = false
    }

    /// [No] click: silence this version until a newer one appears.
    public func dismiss(_ version: String, ctx: UpdateDecisionCtx) async {
        await deps.writeMeta(AutoUpdateMetaPatch(dismissedVersion: version))
        await ctx.disableButtons()
        await ctx.ack(deps.messages.dismissed)
    }
}
