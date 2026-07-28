import Foundation

// Auto-update orchestrator (TS `src/update/autoUpdater.ts`).
// Owns scheduling, check→compare→notify, dismiss, and approve.
// Install+restart are DI ports — production wires `installLatestSelfUpdate` + `performRestart`
// (install.sh + launchctl; no in-process binary mmap replace).

public let updateDefaultIntervalMs = 1 * 60 * 60 * 1000

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
    /// Install done; service relaunch requested (not yet verified running).
    public var restartRequested: String
    /// New process verified up.
    public var restartConfirmed: String
    public var installFailed: String
    public var dismissed: String
    /// Used when the install port is nil (no self-update path wired).
    public var manualOnly: String
    /// Install ok but relaunch could not be started or verified.
    public var restartFailed: String
    /// Approve delegated to a Homebrew tap's detached self-update script (install/restart/result
    /// all happen outside this process).
    public var homebrewInProgress: String

    public init(
        busy: String,
        restartRequested: String,
        restartConfirmed: String,
        installFailed: String,
        dismissed: String,
        manualOnly: String,
        restartFailed: String,
        homebrewInProgress: String
    ) {
        self.busy = busy
        self.restartRequested = restartRequested
        self.restartConfirmed = restartConfirmed
        self.installFailed = installFailed
        self.dismissed = dismissed
        self.manualOnly = manualOnly
        self.restartFailed = restartFailed
        self.homebrewInProgress = homebrewInProgress
    }

    public static let korean = UpdateMessages(
        busy: UpdateLabels.busy,
        restartRequested: UpdateLabels.restartRequested,
        restartConfirmed: UpdateLabels.restartConfirmed,
        installFailed: UpdateLabels.installFailed,
        dismissed: UpdateLabels.dismissed,
        manualOnly: UpdateLabels.manualOnly,
        restartFailed: UpdateLabels.restartFailed,
        homebrewInProgress: UpdateLabels.homebrewInProgress
    )
}

/// Context for the restart port after a successful install.
public struct RestartRequest: Sendable {
    public var applicationId: String
    public var interactionToken: String
    /// Public channel notify (interaction followup).
    public var notify: @Sendable (String) async -> Void

    public init(
        applicationId: String,
        interactionToken: String,
        notify: @escaping @Sendable (String) async -> Void
    ) {
        self.applicationId = applicationId
        self.interactionToken = interactionToken
        self.notify = notify
    }
}

public struct UpdateDecisionCtx: Sendable {
    public var actorId: String
    public var guildId: String
    public var channelId: String
    /// Discord application id — forwarded to a Homebrew self-update script so it can announce
    /// its result via that interaction's followup webhook, without this bot process involved.
    public var applicationId: String
    /// Interaction token for the same followup webhook.
    public var interactionToken: String
    public var ack: @Sendable (String) async -> Void
    public var disableButtons: @Sendable () async -> Void

    public init(
        actorId: String,
        guildId: String,
        channelId: String,
        applicationId: String,
        interactionToken: String,
        ack: @escaping @Sendable (String) async -> Void,
        disableButtons: @escaping @Sendable () async -> Void
    ) {
        self.actorId = actorId
        self.guildId = guildId
        self.channelId = channelId
        self.applicationId = applicationId
        self.interactionToken = interactionToken
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
    /// Returns true when at least one control channel was ready to receive the prompt.
    public var postPrompt: @Sendable (String) async throws -> Bool
    public var announce: @Sendable (String) async -> Void
    /// Optional install port. nil → approve acks `manualOnly` (no restart).
    public var install: (@Sendable () async -> UpdateInstallResult)?
    /// After install succeeds: relaunch service (or spawn successor). Returns whether handoff
    /// was started; final "running" confirm may arrive later via webhook for supervised path.
    public var restart: (@Sendable (RestartRequest) async -> RestartResult)?
    /// Optional Homebrew self-update delegate `(applicationId, interactionToken) -> handled`.
    /// When present and it returns true, `approve` skips the in-process install/restart entirely —
    /// a detached script owns install → verify → rollback and announces the result itself.
    public var homebrewTrigger: (@Sendable (String, String) -> Bool)?
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
        postPrompt: @escaping @Sendable (String) async throws -> Bool,
        announce: @escaping @Sendable (String) async -> Void = { _ in },
        install: (@Sendable () async -> UpdateInstallResult)? = nil,
        restart: (@Sendable (RestartRequest) async -> RestartResult)? = nil,
        homebrewTrigger: (@Sendable (String, String) -> Bool)? = nil,
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
        self.homebrewTrigger = homebrewTrigger
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
    private var pendingControlChannelPrompt = false
    private var activeChecks = 0
    private var checkWaiters: [CheckedContinuation<Void, Never>] = []

    public init(deps: AutoUpdaterDeps) {
        self.deps = deps
    }

    /// Start scheduling. Immediate check when due; then interval loop. Idempotent.
    public func start() async {
        guard loopTask == nil else { return }
        let interval = deps.intervalMs
        // Install the loop before the initial due-check suspends. A concurrent replacement can
        // then cancel it while waiting for that check, rather than leaving a late-created old
        // scheduler running after the successor has taken ownership.
        loopTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let ns = UInt64(max(1, interval)) * 1_000_000
                try? await Task.sleep(nanoseconds: ns)
                if Task.isCancelled { break }
                await self.checkNow()
            }
        }
        // Complete the first due-check before returning so a subsequent GuildCreate can
        // reliably tell whether it needs to retry after creating its control channel.
        let enabled = await deps.enabled()
        if enabled {
            let meta = await deps.readMeta()
            let due = deps.now() - meta.lastCheckAt >= interval
            if due { await self.checkNow() }
        }
    }

    public func stop() {
        loopTask?.cancel()
        loopTask = nil
    }

    /// Stop scheduling and wait for a check that has already crossed an actor suspension point.
    /// A replacement updater must not start its due-check until this returns, otherwise both
    /// instances can post the same `@here` prompt.
    public func stopAndWaitForCurrentCheck() async {
        stop()
        guard activeChecks > 0 else { return }
        await withCheckedContinuation { checkWaiters.append($0) }
    }

    /// One check cycle. Never throws. Re-posts prompt for a newer stable until dismissed.
    @discardableResult
    public func checkNow(post: Bool = true) async -> UpdateCheckResult {
        activeChecks += 1
        defer {
            activeChecks -= 1
            if activeChecks == 0 {
                let waiters = checkWaiters
                checkWaiters.removeAll()
                for waiter in waiters { waiter.resume() }
            }
        }
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
                pendingControlChannelPrompt = !(try await deps.postPrompt(latest))
            } catch {
                deps.onLog("auto-update: failed to post prompt: \(error)")
                pendingControlChannelPrompt = true
            }
        }
        return UpdateCheckResult(kind: .available, currentVersion: current, latestVersion: latest)
    }

    /// Retry exactly once after auto-provisioning made the first control channel available.
    public func checkAfterControlChannelReady() async {
        guard pendingControlChannelPrompt else { return }
        pendingControlChannelPrompt = false
        _ = await checkNow()
    }

    /// [Yes] click. Without install port → manual-only ack (no restart).
    /// With install port: install then announce + restart on success; on failure keep process.
    public func approve(_ version: String, ctx: UpdateDecisionCtx) async {
        if updating {
            await ctx.ack(deps.messages.busy)
            return
        }
        await ctx.disableButtons()

        if let homebrewTrigger = deps.homebrewTrigger,
           homebrewTrigger(ctx.applicationId, ctx.interactionToken)
        {
            await ctx.ack(deps.messages.homebrewInProgress)
            deps.onLog("auto-update: approve \(version) — delegated to Homebrew self-update script")
            return
        }

        updating = true

        guard let install = deps.install else {
            await ctx.ack(deps.messages.manualOnly)
            deps.onLog("auto-update: approve \(version) — no install port (manual path)")
            updating = false
            return
        }

        await ctx.ack("업데이트 설치를 시작합니다…")
        let result = await install()
        if !result.ok {
            deps.onLog("auto-update: install failed code=\(result.code) stderr=\(result.stderr.prefix(200))")
            // Reply on the interaction channel (where the user clicked), not the control channel.
            await ctx.ack(deps.messages.installFailed)
            updating = false
            return
        }
        guard let restart = deps.restart else {
            await ctx.ack(deps.messages.restartFailed)
            deps.onLog("auto-update: install ok for \(version) — restart path unavailable")
            updating = false
            return
        }
        // "재시작 요청" is distinct from final "기동 확인" (supervised path confirms via webhook).
        await ctx.ack(deps.messages.restartRequested)
        let restartResult = await restart(RestartRequest(
            applicationId: ctx.applicationId,
            interactionToken: ctx.interactionToken,
            notify: { text in await ctx.ack(text) }
        ))
        if restartResult == .manualRestartRequired {
            await ctx.ack(deps.messages.restartFailed)
            deps.onLog("auto-update: install ok for \(version) — relaunch failed to start")
        }
        // If restart returns (tests / dry-run / spawn-only), release guard.
        // Production supervised path typically exits the process after spawning the helper.
        updating = false
    }

    /// [No] click: silence this version until a newer one appears.
    public func dismiss(_ version: String, ctx: UpdateDecisionCtx) async {
        await deps.writeMeta(AutoUpdateMetaPatch(dismissedVersion: version))
        await ctx.disableButtons()
        await ctx.ack(deps.messages.dismissed)
    }
}

/// Process-wide updater ownership. The predecessor fully stops its in-flight check before the
/// successor's due-check can run, preventing a READY-time duplicate update prompt.
public actor AutoUpdaterRegistry {
    private var updater: AutoUpdater?

    public init() {}

    public func get() -> AutoUpdater? { updater }

    public func startReplacing(with next: AutoUpdater) async {
        let previous = updater
        await previous?.stopAndWaitForCurrentCheck()
        updater = next
        await next.start()
    }
}
