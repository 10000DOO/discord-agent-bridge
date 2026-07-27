import Foundation

private let log = Logger(name: "codex")

/// `attach_file` dynamic tool spec registered on `thread/start` (TS appSession.ts
/// ATTACH_FILE_DYNAMIC_TOOL, :62-75).
private let codexAttachFileDynamicTool: JSONValue = .object([
    "type": .string("function"),
    "name": .string("attach_file"),
    "description": .string(
        "Send a file from the workspace to the Discord channel for this session. Path must be inside the workspace. Create the file first if needed."
    ),
    "inputSchema": .object([
        "type": .string("object"),
        "properties": .object([
            "path": .object([
                "type": .string("string"),
                "description": .string("Workspace-relative or absolute path inside workspace"),
            ]),
            "filename": .object([
                "type": .string("string"),
                "description": .string("Optional display name"),
            ]),
        ]),
        "required": .array([.string("path")]),
    ]),
])

/// `share_document` dynamic tool spec, PATH-ONLY (D2) — TS appSession.ts
/// SHARE_DOCUMENT_DYNAMIC_TOOL, :80-91.
private let codexShareDocumentDynamicTool: JSONValue = .object([
    "type": .string("function"),
    "name": .string("share_document"),
    "description": .string("Post a markdown document from the workspace into a Discord thread."),
    "inputSchema": .object([
        "type": .string("object"),
        "properties": .object([
            "path": .object([
                "type": .string("string"),
                "description": .string("Workspace-relative or absolute path inside workspace"),
            ]),
        ]),
        "required": .array([.string("path")]),
    ]),
])

/// Sibling of `DabSessionBridge` for the minimal `!codex` path (W10-c1). Same shape:
/// per-channel session, per-channel turn serialization, blocking runTurn that accumulates
/// text until the turn completes (or a timeout fallback), via a continuation.
///
/// Unlike Claude (one shared sidecar, many sessions), Codex uses **one `codex app-server`
/// child per channel** — matching TS `CodexAppSession` (one client per session,
/// src/modes/codex/appSession.ts:317) — so a client's notifications belong to that channel's
/// single thread and need no threadId routing.
public actor CodexSessionBridge {
    public static let shared = CodexSessionBridge()

    /// Client factory (test seam). The per-channel approval handler is passed at construction (the
    /// client stores it immutably), so the factory takes it. `nil` (production default) spawns via
    /// `codexHome`/`codexCliCommand`/PATH augmentation below (see `ensureChannel`); tests always
    /// inject a fake. `@testable` in tests.
    private let makeClient: (@Sendable (_ onApproval: AppServerApprovalHandler?) throws -> CodexAppServerClient)?
    /// Test seam: override the turn timeout (default nil → codexTimeoutMs/DAB_TURN_TIMEOUT_SEC env, floor 5s).
    private let turnTimeoutOverrideNs: UInt64?
    /// C1: configured Codex CLI location (TS appSession.ts:299-312 `resolveCodexHome` +
    /// `config.codexCliCommand`). `nil` → `CodexAppServerClient`'s own defaults (`~/.codex`,
    /// `"codex"`). `var` (not `let`) because `.shared` is a fixed `static let` — `configure`
    /// below (WO-14) is the only way to move it off these `init` defaults after construction,
    /// mirroring `CodexUsageService.configure`. The resolved config values are wired in at the
    /// call site (DabMain, WO-14).
    private var codexHome: String?
    private var codexCliCommand: String?
    /// C2: `config.codexTimeoutMs` (ms) — highest priority in `turnTimeoutNs` below.
    private let codexTimeoutMs: Int?
    /// Permission gate (default shared; tests inject a fresh gate for isolation).
    private let gate: PermissionGate
    /// Session persistence (default shared; tests inject a temp-file store).
    private let store: SessionStore
    /// H8/M2: global config (profiles) for permissionMode re-resolution at session start.
    private let configStore: ConfigStore
    /// C3: attach_file / share_document sinks (default shared; tests inject fresh instances
    /// so they never touch the process-wide singleton, mirroring GrokAttachGateway's own DI).
    private let fileAttachHost: FileAttachHost
    private let documentShareHost: DocumentShareHost

    init(
        makeClient: (@Sendable (_ onApproval: AppServerApprovalHandler?) throws -> CodexAppServerClient)? = nil,
        turnTimeoutOverrideNs: UInt64? = nil,
        codexHome: String? = nil,
        codexCliCommand: String? = nil,
        codexTimeoutMs: Int? = nil,
        gate: PermissionGate = .shared,
        store: SessionStore = .shared,
        configStore: ConfigStore = .shared,
        fileAttachHost: FileAttachHost = .shared,
        documentShareHost: DocumentShareHost = .shared
    ) {
        self.makeClient = makeClient
        self.turnTimeoutOverrideNs = turnTimeoutOverrideNs
        self.codexHome = codexHome
        self.codexCliCommand = codexCliCommand
        self.codexTimeoutMs = codexTimeoutMs
        self.gate = gate
        self.store = store
        self.configStore = configStore
        self.fileAttachHost = fileAttachHost
        self.documentShareHost = documentShareHost
    }

    /// Reconfigure `.shared`'s codexHome/codexCliCommand at bot boot (WO-14 wires the real
    /// config values into this call — `.shared` is a fixed `static let`, so this is the
    /// only way to move it off the `nil, nil` defaults after construction). Mirrors
    /// `CodexUsageService.configure`.
    public func configure(codexHome: String?, codexCliCommand: String?) {
        self.codexHome = codexHome
        self.codexCliCommand = codexCliCommand
    }

    /// One-shot resume-failure notice to prepend to the next reply (F5).
    private var fallbackNotice: [String: String] = [:]

    private struct Channel {
        let client: CodexAppServerClient
        let threadId: String
    }

    /// channelId (snowflake string) → codex client + thread
    private var channels: [String: Channel] = [:]
    /// channelId → in-flight turn accumulator
    private var turns: [String: TurnBox] = [:]
    /// channelId → turn id from the latest `turn/start` (needed for `turn/interrupt`; W14).
    private var activeTurnIds: [String: String] = [:]
    /// channelId → generation bumped on interrupt/stop so a late `turn/start` result cannot
    /// re-stamp a zombie activeTurnId (W14 RV).
    private var turnGens: [String: UInt64] = [:]
    /// channelId → epoch bumped on `stop` so ensureChannel that races mid-await closes the orphan.
    private var stopEpoch: [String: UInt64] = [:]
    /// Serialize turns per channel (avoid concurrent turn/start on the same thread).
    private var channelGates: [String: Task<TurnResult, Error>] = [:]
    /// Per-channel count of `runTurn` callers (in-flight + waiting). G-P2-04 stats.
    private var turnDepth: [String: Int] = [:]
    /// childThreadId → spawn tool_use id (TS CodexAppSession.parentByThread). Session-scoped
    /// so collab child-thread tools keep routing after spawn across the client lifetime.
    private var parentByThread: [String: [String: String]] = [:]
    /// Per-channel FIFO chain so delta → completed notifications cannot reorder across the
    /// sync-handler → actor hop (`Task { await onNotification }`). Under parallel load a
    /// bare Task hop can finish the turn before appendText, yielding "(empty result)".
    private let notifyChains = LockedBox<[String: Task<Void, Never>]>([:])

    private struct TurnBox {
        var text = ""
        var usage: TurnUsage?
        /// C2: latest `thread/tokenUsage/updated` snapshot (kept, not emitted mid-turn).
        var contextUsage: ContextUsageInfo?
        /// Explicit turn model only; nil means Codex selected its CLI default.
        var contextModel: String?
        /// Turn-local tools/subagent HUD + ToolActivityHost feed (W16-g residual).
        var stats = TurnToolStatsAggregator()
        /// Mint ids for codex items that lack `id` / `itemId`.
        var toolIdSeq = 0
        var done = false
        var continuation: CheckedContinuation<TurnResult, Error>?
        var timeoutTask: Task<Void, Never>?
    }

    private func makeTurnResult(box: TurnBox, text: String) -> TurnResult {
        TurnResult(
            text: text,
            usage: box.usage,
            contextUsage: box.contextUsage,
            tools: box.stats.toolsSnapshot(),
            agents: box.stats.agentsSnapshot()
        )
    }

    // env rules copied from DabSessionBridge (B/"sibling bridge": no forced sharing).
    private var cwd: String {
        let env = ProcessInfo.processInfo.environment
        if let v = env["DAB_CWD"], !v.isEmpty { return v }
        return NSHomeDirectory()
    }

    private var turnTimeoutNs: UInt64 {
        if let turnTimeoutOverrideNs { return turnTimeoutOverrideNs }
        // C2: config.codexTimeoutMs (ms) wins over the env-var/default fallback (TS
        // appSession.ts:60,156 — `ctx.config.codexTimeoutMs ?? DEFAULT_CODEX_TIMEOUT_MS`).
        if let codexTimeoutMs, codexTimeoutMs > 0 { return UInt64(codexTimeoutMs) * 1_000_000 }
        let sec = Int(ProcessInfo.processInfo.environment["DAB_TURN_TIMEOUT_SEC"] ?? "") ?? 1_800
        return UInt64(max(5, sec)) * 1_000_000_000
    }

    /// Send user text for a Discord channel; wait for accumulated text + completion (or timeout).
    /// Turns on the same channel are serialized. Token usage from `turn/completed` is returned
    /// when present (W11-g slice1).
    /// `files`: images go out as `localImage` input items (Codex reads the path itself), everything
    /// else as a text hint (`buildCodexTurnItems`, TS `appSession.ts:486-498` parity).
    public func runTurn(channelId: String, ownerId: String? = nil, guildId: String = "", text: String, config: SessionConfig? = nil, files: [TurnFile] = []) async throws -> TurnResult {
        // Read + install the gate with NO await between them, so a reentering job cannot install a
        // rival task against the same session (buffer/session cross-talk). The previous turn is
        // awaited INSIDE the task — that is where serialization happens.
        let prev = channelGates[channelId]
        turnDepth[channelId, default: 0] += 1
        let task = Task { () -> TurnResult in
            if let prev { _ = try? await prev.value }
            return try await self.executeTurn(channelId: channelId, ownerId: ownerId, guildId: guildId, text: text, config: config, files: files)
        }
        channelGates[channelId] = task
        defer {
            turnDepth[channelId, default: 1] -= 1
            if turnDepth[channelId] == 0 { turnDepth[channelId] = nil }
            if channelGates[channelId] == task { channelGates[channelId] = nil }
        }
        var result = try await task.value
        if let notice = fallbackNotice.removeValue(forKey: channelId) {
            result.text = notice + "\n\n" + result.text
        }
        return result
    }

    /// G-P2-04: any turn in-flight or waiting on this channel's gate chain.
    public func isTurnRunning(channelId: String) -> Bool {
        (turnDepth[channelId] ?? 0) > 0
    }

    /// G-P2-04: turns waiting behind the running one (TS `queueDepth`).
    public func turnQueueDepth(channelId: String) -> Int {
        max(0, (turnDepth[channelId] ?? 0) - 1)
    }

    private func executeTurn(channelId: String, ownerId: String?, guildId: String, text: String, config: SessionConfig?, files: [TurnFile]) async throws -> TurnResult {
        let channel = try await ensureChannel(channelId: channelId, config: config, ownerId: ownerId, guildId: guildId)
        // Multimodal: images → `localImage` input items; everything else → text hint.
        let inputItems = buildCodexTurnItems(text: text, files: files)
        let timeoutNs = turnTimeoutNs
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<TurnResult, Error>) in
            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: timeoutNs)
                guard !Task.isCancelled else { return }
                self.finishTurn(channelId: channelId, error: nil, timeoutFallback: true)
            }
            turns[channelId] = TurnBox(
                text: "",
                usage: nil,
                contextModel: config?.model,
                done: false,
                continuation: cont,
                timeoutTask: timeoutTask
            )

            // W11-b1: model/effort from the bound session config. permMode → approvalPolicy/sandbox
            // stays hardcoded (danger) until the permission UI lands (W11-c).
            var input: [String: JSONValue] = [
                "threadId": .string(channel.threadId),
                "input": .array(inputItems),
            ]
            if let effort = config?.effort, !effort.isEmpty { input["effort"] = .string(effort) }
            if let model = config?.model, !model.isEmpty { input["model"] = .string(model) }

            // Generation tokens this turnStart; interrupt/stop bump so a late result cannot zombie-stamp.
            let gen = (turnGens[channelId] ?? 0) + 1
            turnGens[channelId] = gen
            let threadId = channel.threadId
            let client = channel.client
            Task {
                do {
                    let turnId = try await client.turnStart(params: .object(input))
                    await self.noteTurnStarted(
                        channelId: channelId,
                        gen: gen,
                        turnId: turnId,
                        threadId: threadId,
                        client: client
                    )
                } catch {
                    await self.noteTurnStartFailed(channelId: channelId, gen: gen, error: error)
                }
            }
        }
    }

    /// Apply a turn/start id only if this generation is still current and the turn is live;
    /// otherwise best-effort `turn/interrupt` so a late id after interrupt does not leave a zombie.
    private func noteTurnStarted(
        channelId: String,
        gen: UInt64,
        turnId: String,
        threadId: String,
        client: CodexAppServerClient
    ) async {
        guard turnGens[channelId] == gen else {
            _ = try? await client.turnInterrupt(params: .object([
                "threadId": .string(threadId),
                "turnId": .string(turnId),
            ]))
            return
        }
        guard let box = turns[channelId], !box.done else {
            _ = try? await client.turnInterrupt(params: .object([
                "threadId": .string(threadId),
                "turnId": .string(turnId),
            ]))
            return
        }
        activeTurnIds[channelId] = turnId
    }

    private func noteTurnStartFailed(channelId: String, gen: UInt64, error: Error) {
        guard turnGens[channelId] == gen else { return }
        finishTurn(channelId: channelId, error: error)
    }

    private func ensureChannel(channelId: String, config: SessionConfig?, ownerId: String?, guildId: String) async throws -> Channel {
        // Reuse a live client; a closed one (crashed/EOF) is dropped and respawned
        // (mirrors TS appSession.ts:296 `if (this.client && !this.client.isClosed) return`).
        if let existing = channels[channelId] {
            if !existing.client.isClosed {
                return existing
            }
            await existing.client.close()
            channels[channelId] = nil
        }
        let epoch = stopEpoch[channelId] ?? 0
        let persisted = await store.binding(channelId: channelId)

        // H8: re-resolve permissionMode from the CURRENT config.profiles on every session start
        // instead of trusting a possibly-stale persisted value (mirrors DabSessionBridge's
        // allowedTools re-resolution, same-shaped ConfigResolver + SessionStoreBindingSource
        // lookup). M2: a bound profile that no longer exists in config blocks the session instead
        // of silently falling back (TS permissionResolver.ts:66-70 throws `Unknown permission
        // profile`). M7: "default" (approval required) when nothing is bound at all — was
        // "bypassPermissions" (danger), TS parity sessionOrchestrator.ts:817.
        var effectivePermMode = config?.permMode ?? "default"
        if let globalConfig = try? await configStore.load() {
            let resolvedConfig = try? await ConfigResolver(
                configStore: configStore,
                bindingSource: SessionStoreBindingSource(store: store)
            ).resolve(guildId: guildId, channelId: channelId)
            if let profileName = resolvedConfig?.permissionProfile {
                guard let profile = globalConfig.profiles[profileName] else {
                    throw AppServerError("Unknown permission profile '\(profileName)'.")
                }
                effectivePermMode = profile.permissionMode
            }
        }

        // W11-c: permMode → approvalPolicy/sandbox (resolveThreadPolicy). A non-auto policy routes
        // Codex approval requests through the Discord permission gate; an auto policy needs no
        // handler (nil).
        let policy = resolveThreadPolicy(permMode: effectivePermMode)
        let gate = self.gate
        let onApproval: AppServerApprovalHandler?
        if isAutoApprovePolicy(policy) {
            onApproval = nil   // auto-approve: no Discord prompt needed
        } else {
            // H25: Codex approval is decided solely by this session's approvalPolicy/sandbox above —
            // it must not consult the Claude-only autoAllowClaudeTools list (TS parity).
            onApproval = { req in
                let toolName = codexApprovalToolName(req)
                let decision = await gate.await(
                    prompt: PermissionPrompt(
                        reqKey: UUID().uuidString,
                        channelId: channelId,
                        toolName: toolName,
                        approverId: ownerId
                    )
                )
                return decision.isAllowing ? .accept : .decline   // always|allow → accept; deny-by-default
            }
        }
        // C1/M6: production default (no injected test factory) spawns codex directly with the
        // configured home/command + a PATH-augmented environment; tests always inject `makeClient`.
        let client: CodexAppServerClient
        if let makeClient {
            client = try makeClient(onApproval)
        } else {
            let spawn = resolveCodexSpawn(codexCommand: codexCliCommand)
            log.info("spawning codex app-server: \(spawn.command) \(spawn.args.joined(separator: " "))")
            client = try CodexAppServerClient(
                spawn: spawn,
                codexHome: codexHome,
                requestTimeoutMs: 120_000,
                environment: codexChildEnvironment(),
                onApproval: onApproval
            )
        }

        var startParams: [String: JSONValue] = [
            "cwd": .string(cwd),
            "approvalPolicy": .string(policy.approvalPolicy),
            "sandbox": .string(policy.sandbox),
        ]
        if let model = config?.model, !model.isEmpty { startParams["model"] = .string(model) }
        // C3: attach_file / share_document — FileAttachHost/DocumentShareHost sinks are wired
        // process-wide at boot (DabMain), so always register (TS registers unconditionally too:
        // wiring.ts always supplies sendFileFor/shareDocumentFor to the Codex mode factory deps).
        // No-op on thread/resume (ignored there, same as TS — the handler lives on the client).
        startParams["dynamicTools"] = .array([codexAttachFileDynamicTool, codexShareDocumentDynamicTool])

        let threadId: String
        var startedFresh = persisted?.backendSessionId == nil
        do {
            _ = try await client.initialize()
            // W11-f2: resume the stored thread if any; on failure start a fresh one (F5).
            if let resumeId = persisted?.backendSessionId {
                do {
                    _ = try await client.threadResume(params: .object(["threadId": .string(resumeId)]))
                    threadId = resumeId
                    log.info("thread/resume channel=\(channelId) thread=\(resumeId)")
                } catch {
                    fallbackNotice[channelId] = sessionFallbackNotice
                    threadId = try await client.threadStart(params: .object(startParams))
                    startedFresh = true
                    log.warn("resume failed (\(error)) → thread/start channel=\(channelId)")
                }
            } else {
                threadId = try await client.threadStart(params: .object(startParams))
            }
        } catch {
            // Init failed: close the spawned child so it does not leak as an orphan.
            await client.close()
            throw error
        }

        // stop raced mid-ensure → close orphan, do not publish.
        if (stopEpoch[channelId] ?? 0) != epoch {
            await client.close()
            throw AppServerError("session stopped")
        }

        // C3: item/tool/call → attach_file / share_document (TS appSession.ts handleDynamicToolCall).
        // No approval gate — dynamic tools bypass the permission flow entirely, same as TS.
        client.setDynamicToolCallHandler { [weak self] params in
            guard let self else {
                return AppServerDynamicToolCallResult(success: false, contentItems: [.inputText("session closed")])
            }
            return await self.handleDynamicToolCall(channelId: channelId, params: params)
        }
        // Extend the chain *synchronously* in the read-loop callback so arrival order is kept
        // even when work hops onto this actor.
        client.onNotification { [weak self] method, params in
            guard let self else { return }
            self.notifyChains.withLock { chains in
                let prev = chains[channelId]
                let next = Task {
                    _ = await prev?.value
                    await self.onNotification(channelId: channelId, method: method, params: params)
                }
                chains[channelId] = next
            }
        }
        let channel = Channel(client: client, threadId: threadId)
        channels[channelId] = channel
        // F7: capture the thread id (= backend session) + live context.
        await persistSession(store: store, backend: .codex, channelId: channelId, guildId: guildId, ownerId: ownerId, cwd: cwd, model: config?.model, effort: config?.effort, permMode: config?.permMode, backendSessionId: threadId, lifecycleGeneration: persisted?.lifecycleGeneration, contextGenerationStartedAt: startedFresh ? iso8601Now() : nil)
        // stop during persist → drop the just-published channel.
        if (stopEpoch[channelId] ?? 0) != epoch {
            channels[channelId] = nil
            await client.close()
            throw AppServerError("session stopped")
        }
        log.info("thread channel=\(channelId) thread=\(threadId)")
        return channel
    }

    private func onNotification(channelId: String, method: String, params: JSONValue?) {
        guard var box = turns[channelId], !box.done else { return }

        // C2: thread/tokenUsage/updated → keep the latest context_usage snapshot; makeTurnResult
        // surfaces it once via TurnResult.contextUsage at turn end (TS appSession.ts:211-219,
        // not emitted mid-turn since this notification fires many times per turn).
        if let ctx = codexContextUsage(method: method, params: params, model: box.contextModel) {
            box.contextUsage = ctx
            turns[channelId] = box
        }

        // G-P1-02: item/started + turn/started → stream embed progress (TS transcriptFeed).
        // C1: item/reasoning/delta(+aliases) → thinking (TS eventMapper.ts:171-184).
        let progressEvs = codexProgressEvents(method: method, params: params)
        if !progressEvs.isEmpty {
            let ch = channelId
            for ev in progressEvs {
                switch ev {
                case .progress(let label, let detail):
                    Task {
                        await StreamStatusHost.shared.noteProgress(
                            channelId: ch, label: label, detail: detail
                        )
                    }
                case .thinking(let text, _):
                    Task { await StreamStatusHost.shared.noteThinking(channelId: ch, delta: text) }
                default:
                    break
                }
            }
        }

        // W16-g residual: tool_use / tool_result mid-turn → stats + Discord work threads.
        // parentByThread mutates on collab spawnAgent (TS MapContext.onSpawnThread).
        var parentMap = parentByThread[channelId] ?? [:]
        let toolEvs = codexToolEvents(
            method: method,
            params: params,
            mintId: &box.toolIdSeq,
            parentByThread: &parentMap
        )
        parentByThread[channelId] = parentMap
        if !toolEvs.isEmpty {
            for ev in toolEvs {
                box.stats.note(ev)
                let ch = channelId
                Task { await ToolActivityHost.shared.handle(channelId: ch, event: ev) }
                if case .toolUse = ev {
                    Task { await StreamStatusHost.shared.noteToolUse(channelId: ch) }
                }
            }
            turns[channelId] = box
        }

        switch codexTurnStep(method: method, params: params) {
        case .appendText(let delta):
            box.text += delta
            turns[channelId] = box
            // W11-g residual: live stream text (same path as Claude).
            let ch = channelId
            Task { await StreamStatusHost.shared.noteText(channelId: ch, delta: delta) }
        case .fullText(let text):
            // Only when no deltas streamed (avoids duplicating the streamed message).
            if box.text.isEmpty {
                box.text = text
                turns[channelId] = box
            }
        case .finished(let usage):
            // H2: a `turn/completed` carrying a turnId that doesn't match the currently active
            // turn is stale (already-interrupted/finished turn) and must not complete this one
            // (TS appSession.ts:220 `if (!mapped.turnId || mapped.turnId === turnId) settle()`).
            guard codexNotificationMatchesActiveTurn(params: params, activeTurnId: activeTurnIds[channelId]) else { break }
            if let usage { box.usage = usage }
            turns[channelId] = box
            let text = box.text.isEmpty ? "(empty result)" : box.text
            finishTurnUnlocked(channelId: channelId, result: makeTurnResult(box: box, text: text))
        case .failed(let message):
            guard codexNotificationMatchesActiveTurn(params: params, activeTurnId: activeTurnIds[channelId]) else { break }
            finishTurnUnlocked(channelId: channelId, result: nil, error: AppServerError(message))
        case .ignore:
            break
        }
    }

    // MARK: - Dynamic tool calls (C3: attach_file / share_document)

    /// TS `handleDynamicToolCall` (appSession.ts:369-414). No approval gate — dynamic tools bypass
    /// the permission flow entirely, same as TS (`item/tool/call` is routed separately from
    /// `requestApproval` methods in `AppServerClient.handleServerRequest`).
    private func handleDynamicToolCall(
        channelId: String,
        params: AppServerDynamicToolCallParams
    ) async -> AppServerDynamicToolCallResult {
        let args = params.arguments?.objectValue ?? [:]
        let requestedPath = args["path"]?.stringValue ?? ""

        if params.tool == "share_document" {
            return await handleShareDocumentCall(channelId: channelId, callId: params.callId, requestedPath: requestedPath)
        }

        let filename = args["filename"]?.stringValue
        var input: [String: JSONValue] = ["path": .string(requestedPath)]
        if let filename { input["filename"] = .string(filename) }
        let toolName = params.tool.isEmpty ? "attach_file" : params.tool
        noteToolEvent(channelId: channelId, .toolUse(id: params.callId, name: toolName, input: .object(input), parentToolUseId: nil))

        guard params.tool == "attach_file" else {
            let text = "Unknown dynamic tool: \(params.tool)"
            noteToolEvent(channelId: channelId, .toolResult(id: params.callId, ok: false, content: text, parentToolUseId: nil))
            return AppServerDynamicToolCallResult(success: false, contentItems: [.inputText(text)])
        }
        guard !requestedPath.isEmpty else {
            let text = "attach_file requires a path."
            noteToolEvent(channelId: channelId, .toolResult(id: params.callId, ok: false, content: text, parentToolUseId: nil))
            return AppServerDynamicToolCallResult(success: false, contentItems: [.inputText(text)])
        }

        let host = fileAttachHost
        let result = await attachFileConfined(
            workspaceRoot: cwd,
            sendFile: { abs, name in try await host.attach(channelId: channelId, path: abs, name: name) },
            requestedPath: requestedPath,
            filename: filename
        )
        noteToolEvent(
            channelId: channelId,
            .toolResult(id: params.callId, ok: !result.isError, content: result.text, parentToolUseId: nil)
        )
        return AppServerDynamicToolCallResult(success: !result.isError, contentItems: [.inputText(result.text)])
    }

    /// Path-only share (D2): result is a short confirmation, never the document body. Reuses
    /// `shareResultText` (Grok/AttachGateway.swift, C5) for the rejection-code → English text
    /// mapping instead of re-porting TS `shareErrorText` a third time.
    private func handleShareDocumentCall(
        channelId: String,
        callId: String,
        requestedPath: String
    ) async -> AppServerDynamicToolCallResult {
        noteToolEvent(
            channelId: channelId,
            .toolUse(id: callId, name: "share_document", input: .object(["path": .string(requestedPath)]), parentToolUseId: nil)
        )
        guard !requestedPath.isEmpty else {
            let text = "share_document requires a path."
            noteToolEvent(channelId: channelId, .toolResult(id: callId, ok: false, content: text, parentToolUseId: nil))
            return AppServerDynamicToolCallResult(success: false, contentItems: [.inputText(text)])
        }

        let text: String
        let isError: Bool
        do {
            let result = try await documentShareHost.share(channelId: channelId, path: requestedPath)
            (text, isError) = shareResultText(result, requestedPath: requestedPath)
        } catch {
            text = "Could not share \(requestedPath): unexpected error"
            isError = true
        }
        noteToolEvent(channelId: channelId, .toolResult(id: callId, ok: !isError, content: text, parentToolUseId: nil))
        return AppServerDynamicToolCallResult(success: !isError, contentItems: [.inputText(text)])
    }

    /// Feed a synthetic tool_use/tool_result event into this turn's stats + Discord side-effects
    /// (ToolActivityHost work thread, StreamStatusHost tool count) — the same three effects as the
    /// tool loop in `onNotification` (W16-g), reused here for dynamic tool calls so attach_file /
    /// share_document show up in Discord the same way any other Codex tool call does (TS `ctx.emit`).
    private func noteToolEvent(channelId: String, _ ev: AgentEvent) {
        guard var box = turns[channelId], !box.done else { return }
        box.stats.note(ev)
        turns[channelId] = box
        let ch = channelId
        Task { await ToolActivityHost.shared.handle(channelId: ch, event: ev) }
        if case .toolUse = ev {
            Task { await StreamStatusHost.shared.noteToolUse(channelId: ch) }
        }
    }

    private func finishTurn(channelId: String, error: Error?, timeoutFallback: Bool = false) {
        guard let box = turns[channelId], !box.done else { return }
        if let error {
            finishTurnUnlocked(channelId: channelId, result: nil, error: error)
            return
        }
        if timeoutFallback {
            if box.text.isEmpty {
                finishTurnUnlocked(
                    channelId: channelId,
                    result: nil,
                    error: AppServerError("codex turn timeout (no text)")
                )
            } else {
                finishTurnUnlocked(
                    channelId: channelId,
                    result: makeTurnResult(box: box, text: box.text + "\n…(timeout)")
                )
            }
        }
    }

    private func finishTurnUnlocked(channelId: String, result: TurnResult?, error: Error? = nil) {
        guard var box = turns[channelId], !box.done else { return }
        box.done = true
        box.timeoutTask?.cancel()
        let cont = box.continuation
        box.continuation = nil
        box.timeoutTask = nil
        turns[channelId] = box
        activeTurnIds[channelId] = nil
        // W16-g: turn boundary for tool threads.
        Task { await ToolActivityHost.shared.resetTurn(channelId: channelId) }
        if let error {
            cont?.resume(throwing: error)
        } else {
            cont?.resume(returning: result ?? makeTurnResult(box: box, text: box.text))
        }
    }

    // MARK: - Lifecycle (W14)

    /// Kill the channel's codex app-server child and drop maps (TS CodexSession.stop / dropClient).
    /// Does NOT touch SessionRegistry / SessionStore.
    public func stop(channelId: String) async {
        stopEpoch[channelId, default: 0] += 1
        turnGens[channelId, default: 0] += 1
        channelGates[channelId]?.cancel()
        channelGates[channelId] = nil
        turnDepth[channelId] = nil
        if let box = turns[channelId], !box.done {
            finishTurnUnlocked(
                channelId: channelId,
                result: nil,
                error: AppServerError("session stopped")
            )
        }
        turns[channelId] = nil
        activeTurnIds[channelId] = nil
        parentByThread[channelId] = nil
        await ToolActivityHost.shared.dispose(channelId: channelId)
        await StreamStatusHost.shared.dispose(channelId: channelId)
        await UsageActivityHost.shared.dispose(channelId: channelId)
        await IdleWatchdog.shared.stop(channelId: channelId)
        guard let ch = channels.removeValue(forKey: channelId) else { return }
        await ch.client.close()
    }

    /// Cancel the in-flight turn via `turn/interrupt` without closing the client/thread
    /// (TS CodexSession.interrupt). Returns `true` when a live channel session existed.
    /// Bumps turn generation so a late turn/start result cannot re-stamp activeTurnId.
    public func interrupt(channelId: String) async -> Bool {
        guard let ch = channels[channelId] else { return false }
        turnGens[channelId, default: 0] += 1
        if let turnId = activeTurnIds[channelId] {
            _ = try? await ch.client.turnInterrupt(params: .object([
                "threadId": .string(ch.threadId),
                "turnId": .string(turnId),
            ]))
        }
        if let box = turns[channelId], !box.done {
            let partial = box.text.isEmpty ? "(interrupted)" : box.text
            finishTurnUnlocked(channelId: channelId, result: makeTurnResult(box: box, text: partial))
        } else {
            activeTurnIds[channelId] = nil
        }
        return true
    }

    /// Live `/effort` switch for an open Codex channel (TS `CodexAppSession.setEffort`,
    /// appSession.ts:278-284). Unlike Claude, codex app-server has no mid-thread effort-set RPC —
    /// TS itself only validates the level and stores it for the NEXT `turn/start`; Swift already
    /// threads `config.effort` into `executeTurn` on every call (the binding layer persists the
    /// patch before invoking this), so this function's job mirrors TS exactly: report whether the
    /// channel is live and the value is a known Codex effort. Codex has no live `setModel`
    /// counterpart (TS `sessionOrchestrator.ts:389` — only Claude sessions expose `setModel`; a
    /// Codex session object never does, so `/model` reports "unsupported" there), so no such
    /// function is added here.
    /// Returns `false` when the channel has no live thread or the level is unrecognized (an empty
    /// string always passes — clears the override, mirrors TS's `level.length > 0` guard).
    @discardableResult
    public func setEffort(channelId: String, effort: String) async -> Bool {
        guard channels[channelId] != nil else { return false }
        let trimmed = effort.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        return await CodexConfigSource.shared.isKnownEffort(trimmed)
    }

    /// Test/inspection: whether this channel still holds a live codex client.
    public func isLive(channelId: String) -> Bool {
        channels[channelId] != nil
    }

    /// G-P1-05: open/resume the Codex thread without a user turn. No-op when already live.
    @discardableResult
    public func softEnsure(
        channelId: String,
        guildId: String,
        ownerId: String?,
        config: SessionConfig?
    ) async -> Bool {
        if isLive(channelId: channelId) { return true }
        do {
            _ = try await ensureChannel(
                channelId: channelId,
                config: config,
                ownerId: ownerId,
                guildId: guildId
            )
            return true
        } catch {
            log.warn("softEnsure failed channel=\(channelId) error=\(error)")
            return false
        }
    }

    /// Test/inspection: turn id from the latest `turn/start` (nil when idle).
    public func activeTurnId(channelId: String) -> String? {
        activeTurnIds[channelId]
    }

    /// Test/inspection: current turn generation (bumped on interrupt/stop).
    public func turnGeneration(channelId: String) -> UInt64 {
        turnGens[channelId] ?? 0
    }
}

/// Multimodal turn input: text + `localImage` paths (Codex `UserInput.localImage` reads the file
/// itself — no base64 needed). Mirrors TS `buildCodexTurnInput` (`appSession.ts:486-498`).
func buildCodexTurnItems(text: String, files: [TurnFile]) -> [JSONValue] {
    let classified = classifyTurnFiles(files)
    let images = classified.filter { $0.isImage }
    let nonImages = classified.filter { !$0.isImage }
    let hinted = appendAttachedFileHints(text: text, files: nonImages.map { TurnFile(path: $0.path, mime: $0.mime) })
    var items: [JSONValue] = []
    if !hinted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        items.append(.object(["type": .string("text"), "text": .string(hinted)]))
    }
    for img in images {
        items.append(.object(["type": .string("localImage"), "path": .string(img.path)]))
    }
    if items.isEmpty { items.append(.object(["type": .string("text"), "text": .string(" ")])) }
    return items
}

/// Short tool label for a Codex approval prompt (mirrors TS deriveApprovalToolName, appSession.ts).
private func codexApprovalToolName(_ req: AppServerApprovalRequest) -> String {
    if case .object(let p)? = req.params {
        if p["command"] != nil { return "shell" }
        if let tool = p["tool"]?.stringValue { return tool }
        if let name = p["name"]?.stringValue { return name }
    }
    if req.method.contains("commandExecution") { return "shell" }
    if req.method.contains("fileChange") { return "apply_patch" }
    return "tool"
}
