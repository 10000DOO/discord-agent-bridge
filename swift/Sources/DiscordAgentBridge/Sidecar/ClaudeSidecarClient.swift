import Foundation

private let log = Logger(name: "claude-sidecar")

/// Per-session host handlers for sidecar → host reverse RPC and events.
public struct SidecarSessionHandlers: Sendable {
    public var onEvent: @Sendable (AgentEvent) -> Void
    public var onBackendId: (@Sendable (String) -> Void)?
    /// host.file.attach — confirmation string for the model.
    public var onFileAttach: (@Sendable (_ path: String, _ name: String?) async throws -> String)?
    /// host.file.share — ShareResult for the model-facing mapper.
    public var onFileShare: (@Sendable (_ path: String) async throws -> ShareResult)?
    /// host.orchestration.order — lead → module (WO-5, design_orchestration_module_agents.md).
    /// Unlike onFileAttach/onFileShare this never throws: every `OrchestrationDecision` —
    /// including refusals like `.busy`/`.outsideWorkspace` — is a normal outcome (R7), not a
    /// transport-level error, so the model-facing sentence + ok flag come back as a plain value.
    public var onOrchestrationOrder: (@Sendable (_ module: String, _ path: String, _ text: String) async -> (text: String, isError: Bool))?
    /// host.orchestration.report — module → lead. No target-channel argument (R4 enforced by omission).
    public var onOrchestrationReport: (@Sendable (_ text: String) async -> (text: String, isError: Bool))?

    public init(
        onEvent: @escaping @Sendable (AgentEvent) -> Void,
        onBackendId: (@Sendable (String) -> Void)? = nil,
        onFileAttach: (@Sendable (_ path: String, _ name: String?) async throws -> String)? = nil,
        onFileShare: (@Sendable (_ path: String) async throws -> ShareResult)? = nil,
        onOrchestrationOrder: (@Sendable (_ module: String, _ path: String, _ text: String) async -> (text: String, isError: Bool))? = nil,
        onOrchestrationReport: (@Sendable (_ text: String) async -> (text: String, isError: Bool))? = nil
    ) {
        self.onEvent = onEvent
        self.onBackendId = onBackendId
        self.onFileAttach = onFileAttach
        self.onFileShare = onFileShare
        self.onOrchestrationOrder = onOrchestrationOrder
        self.onOrchestrationReport = onOrchestrationReport
    }
}

/**
 Low-level NDJSON client: request/response + event/notify multiplexing.
 One client maps to one sidecar process (multi-session capable).
 Mirrors TS `ClaudeSidecarClient` (src/modes/claude/sidecarClient.ts).
 */
public final class ClaudeSidecarClient: @unchecked Sendable {
    private let transport: SidecarTransport
    private let requestTimeoutNs: UInt64
    private let ownsTransport: Bool

    private struct PendingRpc {
        let method: String
        let continuation: CheckedContinuation<JSONValue, Error>
        let timeoutTask: Task<Void, Never>
    }

    private struct State {
        var pending: [String: PendingRpc] = [:]
        var sessionHandlers: [String: SidecarSessionHandlers] = [:]
        // A `session.backend_id` notify can arrive before the caller registers handlers (the start
        // response resumes the caller, but the read loop processes the very next line — the notify —
        // before the caller runs registerSessionHandlers). Buffer it here and replay at registration.
        var pendingBackendIds: [String: String] = [:]
        var eventContinuations: [String: [UUID: AsyncStream<AgentEvent>.Continuation]] = [:]
        var ready = false
        var readyWaiters: [CheckedContinuation<Void, Never>] = []
        var closed = false
        var closeError: SidecarRpcError?
        var closeHandlers: [UUID: @Sendable (SidecarRpcError) -> Void] = [:]
        var started = false
        var reqSeq: Int = 0
    }

    private let state = LockedBox(State())
    private var readTask: Task<Void, Never>?

    public init(
        transport: SidecarTransport,
        requestTimeoutMs: Int = 60_000,
        ownsTransport: Bool = false
    ) {
        self.transport = transport
        self.requestTimeoutNs = UInt64(requestTimeoutMs) * 1_000_000
        self.ownsTransport = ownsTransport
    }

    /// Spawn sidecar via Foundation.Process (default command resolution).
    public convenience init(
        spawn: SidecarSpawn? = nil,
        repoRoot: URL? = nil,
        requestTimeoutMs: Int = 60_000,
        environment: [String: String]? = nil
    ) throws {
        let resolved = spawn ?? resolveClaudeSidecarSpawn(repoRoot: repoRoot)
        let transport = try ProcessSidecarTransport(spawn: resolved, environment: environment)
        self.init(transport: transport, requestTimeoutMs: requestTimeoutMs, ownsTransport: true)
    }

    public var isClosed: Bool {
        state.withLock { $0.closed }
    }

    /// Bounded stderr capture forwarded from the transport (empty for in-memory test transports).
    public var stderrBuffer: String {
        transport.stderrBuffer
    }

    private func nextId() -> String {
        let seq = state.withLock { s -> Int in
            s.reqSeq += 1
            return s.reqSeq
        }
        return "h-\(seq)-\(String(Int(Date().timeIntervalSince1970 * 1000), radix: 36))"
    }

    /// Begin reading sidecar stdout. Resolves when `sidecar.ready` is seen (or already).
    public func connect() async throws {
        guard !isClosed else {
            throw SidecarRpcError(code: "internal", message: "sidecar transport closed unexpectedly", retryable: true)
        }
        let alreadyStarted = state.withLock { s -> Bool in
            if s.started { return true }
            s.started = true
            return false
        }
        if alreadyStarted {
            await waitReady()
            guard !isClosed else {
                throw SidecarRpcError(code: "internal", message: "sidecar transport closed unexpectedly", retryable: true)
            }
            return
        }

        readTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await line in self.transport.lines {
                    self.onLine(line)
                }
            } catch {
                await self.handleTransportClosure()
                return
            }
            await self.handleTransportClosure()
        }

        await waitReady()
        guard !isClosed else {
            throw SidecarRpcError(code: "internal", message: "sidecar transport closed unexpectedly", retryable: true)
        }
    }

    private func waitReady() async {
        let isReady = state.withLock { $0.ready }
        if isReady { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            let resumeNow = state.withLock { s -> Bool in
                if s.ready { return true }
                s.readyWaiters.append(cont)
                return false
            }
            if resumeNow { cont.resume() }
        }
    }

    private func markReady() {
        let waiters = state.withLock { s -> [CheckedContinuation<Void, Never>] in
            s.ready = true
            let w = s.readyWaiters
            s.readyWaiters = []
            return w
        }
        for w in waiters { w.resume() }
    }

    private func onLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let env: Envelope
        do {
            env = try parseEnvelope(trimmed)
        } catch {
            // H1: a silently dropped line here could be a lost `.result` (see
            // DabSessionBridge.onEvent .turnComplete) — log enough to confirm/rule that out.
            log.warn("[DAB-DIAG-ENVELOPE-DECODE] failed to decode sidecar line error=\(error) line=\(trimmed.prefix(200))")
            return
        }

        if env.type == .notify, env.method == "sidecar.ready" {
            markReady()
            return
        }

        if env.type == .notify, env.method == "session.backend_id" {
            if let session = env.session,
               let backend = env.params?["backendSessionId"]?.stringValue
            {
                let handler = state.withLock { s -> SidecarSessionHandlers? in
                    if let h = s.sessionHandlers[session] { return h }
                    s.pendingBackendIds[session] = backend   // no handler yet → buffer, replay at register
                    return nil
                }
                handler?.onBackendId?(backend)
            }
            return
        }

        if env.type == .event, let session = env.session, let event = env.event {
            let (handler, conts) = state.withLock { s -> (SidecarSessionHandlers?, [AsyncStream<AgentEvent>.Continuation]) in
                let h = s.sessionHandlers[session]
                let c = s.eventContinuations[session]?.values.map { $0 } ?? []
                return (h, c)
            }
            handler?.onEvent(event)
            for c in conts {
                c.yield(event)
            }
            return
        }

        if env.type == .req {
            Task { await handleReverseRpc(env) }
            return
        }

        if env.type == .res, let id = env.id {
            let p = state.withLock { $0.pending.removeValue(forKey: id) }
            guard let p else { return }
            p.timeoutTask.cancel()
            if let err = env.error {
                p.continuation.resume(throwing: SidecarRpcError(err))
            } else {
                p.continuation.resume(returning: env.result ?? .null)
            }
        }
    }

    private func handleReverseRpc(_ env: Envelope) async {
        guard let id = env.id, let method = env.method else { return }
        let session = env.session
        let handlers: SidecarSessionHandlers? = session.flatMap { sid in
            state.withLock { $0.sessionHandlers[sid] }
        }
        let params = env.params ?? [:]

        do {
            if method == "host.file.attach" {
                guard let onFileAttach = handlers?.onFileAttach else {
                    try await write(resError(
                        id: id,
                        method: method,
                        error: makeError(code: "unsupported", message: "host.file.attach not wired for session"),
                        session: session
                    ))
                    return
                }
                guard let path = params["path"]?.stringValue, !path.isEmpty else {
                    try await write(resError(
                        id: id,
                        method: method,
                        error: makeError(code: "invalid_request", message: "params.path required"),
                        session: session
                    ))
                    return
                }
                let name = params["name"]?.stringValue
                let message = try await onFileAttach(path, name)
                try await write(res(
                    id: id,
                    method: method,
                    result: .object(["ok": .bool(true), "message": .string(message)]),
                    session: session
                ))
                return
            }

            if method == "host.file.share" {
                guard let onFileShare = handlers?.onFileShare else {
                    try await write(resError(
                        id: id,
                        method: method,
                        error: makeError(code: "unsupported", message: "host.file.share not wired for session"),
                        session: session
                    ))
                    return
                }
                guard let path = params["path"]?.stringValue, !path.isEmpty else {
                    try await write(resError(
                        id: id,
                        method: method,
                        error: makeError(code: "invalid_request", message: "params.path required"),
                        session: session
                    ))
                    return
                }
                let shareResult = try await onFileShare(path)
                try await write(res(id: id, method: method, result: shareResult.asJSONValue(), session: session))
                return
            }

            if method == "host.orchestration.order" {
                guard let onOrchestrationOrder = handlers?.onOrchestrationOrder else {
                    try await write(resError(
                        id: id,
                        method: method,
                        error: makeError(code: "unsupported", message: "host.orchestration.order not wired for session"),
                        session: session
                    ))
                    return
                }
                guard let module = params["module"]?.stringValue, !module.isEmpty else {
                    try await write(resError(
                        id: id, method: method,
                        error: makeError(code: "invalid_request", message: "params.module required"),
                        session: session
                    ))
                    return
                }
                guard let path = params["path"]?.stringValue, !path.isEmpty else {
                    try await write(resError(
                        id: id, method: method,
                        error: makeError(code: "invalid_request", message: "params.path required"),
                        session: session
                    ))
                    return
                }
                guard let orderText = params["text"]?.stringValue, !orderText.isEmpty else {
                    try await write(resError(
                        id: id, method: method,
                        error: makeError(code: "invalid_request", message: "params.text required"),
                        session: session
                    ))
                    return
                }
                let outcome = await onOrchestrationOrder(module, path, orderText)
                try await write(res(
                    id: id, method: method,
                    result: .object(["ok": .bool(!outcome.isError), "message": .string(outcome.text)]),
                    session: session
                ))
                return
            }

            if method == "host.orchestration.report" {
                guard let onOrchestrationReport = handlers?.onOrchestrationReport else {
                    try await write(resError(
                        id: id,
                        method: method,
                        error: makeError(code: "unsupported", message: "host.orchestration.report not wired for session"),
                        session: session
                    ))
                    return
                }
                guard let reportText = params["text"]?.stringValue, !reportText.isEmpty else {
                    try await write(resError(
                        id: id, method: method,
                        error: makeError(code: "invalid_request", message: "params.text required"),
                        session: session
                    ))
                    return
                }
                let outcome = await onOrchestrationReport(reportText)
                try await write(res(
                    id: id, method: method,
                    result: .object(["ok": .bool(!outcome.isError), "message": .string(outcome.text)]),
                    session: session
                ))
                return
            }

            try await write(resError(
                id: id,
                method: method,
                error: makeError(code: "unsupported", message: "\(method) not implemented on host"),
                session: session
            ))
        } catch {
            // Best-effort error res so the sidecar does not hang on the reverse RPC.
            try? await write(resError(
                id: id,
                method: method,
                error: makeError(code: "internal", message: "\(error)"),
                session: session
            ))
        }
    }

    private func write(_ env: Envelope) async throws {
        let line = try serializeEnvelope(env)
        try await transport.writeLine(line + "\n")
    }

    public func request(
        method: String,
        params: [String: JSONValue]? = nil,
        session: String? = nil
    ) async throws -> JSONValue {
        guard !isClosed else {
            throw SidecarRpcError(code: "internal", message: "sidecar transport closed unexpectedly", retryable: true)
        }
        try await connect()
        guard !isClosed else {
            throw SidecarRpcError(code: "internal", message: "sidecar transport closed unexpectedly", retryable: true)
        }
        let id = nextId()
        return try await withCheckedThrowingContinuation { cont in
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: self?.requestTimeoutNs ?? 60_000_000_000)
                guard !Task.isCancelled else { return }
                let removed = self?.state.withLock { $0.pending.removeValue(forKey: id) }
                if let removed {
                    removed.continuation.resume(
                        throwing: SidecarRpcError(
                            code: "internal",
                            message: "RPC timeout: \(method)",
                            retryable: true
                        )
                    )
                }
            }
            state.withLock {
                $0.pending[id] = PendingRpc(method: method, continuation: cont, timeoutTask: timeoutTask)
            }
            Task {
                do {
                    try await self.write(req(id: id, method: method, params: params, session: session))
                } catch {
                    let removed = self.state.withLock { $0.pending.removeValue(forKey: id) }
                    removed?.timeoutTask.cancel()
                    removed?.continuation.resume(throwing: error)
                }
            }
        }
    }

    public func registerSessionHandlers(handle: String, handlers: SidecarSessionHandlers) {
        let buffered = state.withLock { s -> String? in
            s.sessionHandlers[handle] = handlers
            return s.pendingBackendIds.removeValue(forKey: handle)
        }
        // A backend id that raced ahead of this registration was buffered — deliver it now.
        if let buffered { handlers.onBackendId?(buffered) }
    }

    public func unregisterSessionHandlers(handle: String) {
        let conts = state.withLock { s -> [AsyncStream<AgentEvent>.Continuation] in
            s.sessionHandlers.removeValue(forKey: handle)
            let c = s.eventContinuations.removeValue(forKey: handle)?.values.map { $0 } ?? []
            return c
        }
        for c in conts { c.finish() }
    }

    /// Async stream of events for a session (in addition to registered handlers).
    public func events(for session: String) -> AsyncStream<AgentEvent> {
        let id = UUID()
        return AsyncStream { cont in
            state.withLock {
                $0.eventContinuations[session, default: [:]][id] = cont
            }
            cont.onTermination = { [weak self] _ in
                guard let self else { return }
                self.state.withLock { s in
                    s.eventContinuations[session]?[id] = nil
                    if s.eventContinuations[session]?.isEmpty == true {
                        s.eventContinuations.removeValue(forKey: session)
                    }
                }
            }
        }
    }

    public func sessionStart(_ params: SessionStartParams) async throws -> SessionStartResult {
        let result = try await request(method: "session.start", params: params.asParams())
        return try SessionStartResult(from: result)
    }

    public func sessionResume(
        _ params: SessionStartParams,
        backendSessionId: String
    ) async throws -> SessionStartResult {
        var p = params.asParams()
        p["backendSessionId"] = .string(backendSessionId)
        let result = try await request(method: "session.resume", params: p)
        return try SessionStartResult(from: result)
    }

    public func sessionSend(session: String, text: String, files: [[String: String]]? = nil) async throws {
        var params: [String: JSONValue] = [
            "session": .string(session),
            "text": .string(text),
        ]
        if let files {
            params["files"] = .array(files.map { f in
                var o: [String: JSONValue] = ["path": .string(f["path"] ?? "")]
                if let mime = f["mime"] { o["mime"] = .string(mime) }
                return .object(o)
            })
        }
        _ = try await request(method: "session.send", params: params, session: session)
    }

    public func sessionStop(session: String) async throws {
        _ = try await request(
            method: "session.stop",
            params: ["session": .string(session)],
            session: session
        )
    }

    /// Tool permission decision (CLAUDE_SIDECAR_PROTOCOL.md §3.4). `requestId` = `permission_request.id`.
    public func sessionPermission(session: String, requestId: String, behavior: String, message: String? = nil) async throws {
        var params: [String: JSONValue] = [
            "session": .string(session),
            "requestId": .string(requestId),
            "behavior": .string(behavior),
        ]
        if let message { params["message"] = .string(message) }
        _ = try await request(method: "session.permission", params: params, session: session)
    }

    public func sessionInterrupt(session: String) async throws {
        _ = try await request(
            method: "session.interrupt",
            params: ["session": .string(session)],
            session: session
        )
    }

    /// Live model switch (CLAUDE_SIDECAR_PROTOCOL.md §3.6). Takes effect on the next turn
    /// without restarting the session. Sidecar may return `unsupported`.
    public func sessionSetModel(session: String, model: String? = nil) async throws {
        var params: [String: JSONValue] = ["session": .string(session)]
        if let model { params["model"] = .string(model) }
        _ = try await request(method: "session.setModel", params: params, session: session)
    }

    /// Runtime slash-command catalog for one live session (WO-2b, docs/cli-slash-command-parity.md §6).
    /// The sidecar never answers this with an `error` — an absent or unknown handle is
    /// `{"commands":[]}` — so a throw out of here means transport, not "this session has no commands".
    public func claudeSlashCommands(session: String) async throws -> [SlashCatalogEntry] {
        let result = try await request(
            method: "claude.slashCommands",
            params: ["session": .string(session)],
            session: session
        )
        return claudeSlashCatalog(result)
    }

    /// Live effort switch (CLAUDE_SIDECAR_PROTOCOL.md §3.6). Sidecar may return `unsupported`.
    public func sessionSetEffort(session: String, effort: String? = nil) async throws {
        var params: [String: JSONValue] = ["session": .string(session)]
        if let effort { params["effort"] = .string(effort) }
        _ = try await request(method: "session.setEffort", params: params, session: session)
    }

    public func sessionsList(cwd: String, limit: Int? = nil) async throws -> SessionsListResult {
        var params: [String: JSONValue] = ["cwd": .string(cwd)]
        if let limit { params["limit"] = .number(Double(limit)) }
        let result = try await request(method: "sessions.list", params: params)
        return try SessionsListResult(from: result)
    }

    /// Claude model/permission/effort catalog snapshot (CLAUDE_SIDECAR_PROTOCOL.md §3.9).
    /// No params, not session-scoped. The sidecar handler never throws for a probe failure
    /// (alias fallback is internal); RPC transport/spawn failures surface as thrown errors
    /// for the caller (DabSessionBridge) to map to a degraded fallback.
    public func claudeCatalog() async throws -> ClaudeCatalogResult {
        let result = try await request(method: "claude.catalog")
        return try ClaudeCatalogResult(from: result)
    }

    /// Register a one-shot transport-close observer. A handler added after closure is invoked
    /// immediately so a bridge cannot retain a dead client because it raced the EOF.
    public func addCloseHandler(_ handler: @escaping @Sendable (SidecarRpcError) -> Void) {
        let error = state.withLock { s -> SidecarRpcError? in
            if let closeError = s.closeError { return closeError }
            s.closeHandlers[UUID()] = handler
            return nil
        }
        if let error { handler(error) }
    }

    private func failAll(_ err: SidecarRpcError, closing: Bool = false) {
        let (all, waiters, handlers) = state.withLock {
            s -> ([PendingRpc], [CheckedContinuation<Void, Never>], [@Sendable (SidecarRpcError) -> Void]) in
            let pending = Array(s.pending.values)
            s.pending = [:]
            let w = s.readyWaiters
            s.readyWaiters = []
            if !s.ready {
                s.ready = true
            }
            let handlers: [@Sendable (SidecarRpcError) -> Void]
            if closing, !s.closed {
                s.closed = true
                s.closeError = err
                handlers = Array(s.closeHandlers.values)
                s.closeHandlers = [:]
            } else {
                handlers = []
            }
            return (pending, w, handlers)
        }
        for w in waiters { w.resume() }
        for p in all {
            p.timeoutTask.cancel()
            p.continuation.resume(throwing: err)
        }
        for handler in handlers { handler(err) }
    }

    private func handleTransportClosure() async {
        failAll(
            SidecarRpcError(code: "internal", message: "sidecar transport closed unexpectedly", retryable: true),
            closing: true
        )
        await transport.close()
    }

    public func close() async {
        guard !isClosed else { return }
        failAll(SidecarRpcError(code: "internal", message: "client closed"), closing: true)
        readTask?.cancel()
        await transport.close()
        _ = ownsTransport
    }
}
