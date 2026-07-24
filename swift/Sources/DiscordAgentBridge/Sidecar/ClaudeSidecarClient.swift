import Foundation

/// Per-session host handlers for sidecar → host reverse RPC and events.
public struct SidecarSessionHandlers: Sendable {
    public var onEvent: @Sendable (AgentEvent) -> Void
    public var onBackendId: (@Sendable (String) -> Void)?

    public init(
        onEvent: @escaping @Sendable (AgentEvent) -> Void,
        onBackendId: (@Sendable (String) -> Void)? = nil
    ) {
        self.onEvent = onEvent
        self.onBackendId = onBackendId
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
        var eventContinuations: [String: [UUID: AsyncStream<AgentEvent>.Continuation]] = [:]
        var ready = false
        var readyWaiters: [CheckedContinuation<Void, Never>] = []
        var closed = false
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

    private func nextId() -> String {
        let seq = state.withLock { s -> Int in
            s.reqSeq += 1
            return s.reqSeq
        }
        return "h-\(seq)-\(String(Int(Date().timeIntervalSince1970 * 1000), radix: 36))"
    }

    /// Begin reading sidecar stdout. Resolves when `sidecar.ready` is seen (or already).
    public func connect() async throws {
        let alreadyStarted = state.withLock { s -> Bool in
            if s.started { return true }
            s.started = true
            return false
        }
        if alreadyStarted {
            await waitReady()
            return
        }

        readTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await line in self.transport.lines {
                    self.onLine(line)
                }
            } catch {
                self.failAll(SidecarRpcError(code: "internal", message: "sidecar stdout closed: \(error)"))
                return
            }
            self.failAll(SidecarRpcError(code: "internal", message: "sidecar stdout closed"))
        }

        await waitReady()
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
                let handler = state.withLock { $0.sessionHandlers[session] }
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
        let error = makeError(code: "unsupported", message: "\(method) not implemented on host")
        do {
            try await write(resError(id: id, method: method, error: error, session: session))
        } catch {
            // ignore write failures on reverse path
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
        try await connect()
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
        state.withLock { $0.sessionHandlers[handle] = handlers }
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

    public func sessionsList(cwd: String, limit: Int? = nil) async throws -> SessionsListResult {
        var params: [String: JSONValue] = ["cwd": .string(cwd)]
        if let limit { params["limit"] = .number(Double(limit)) }
        let result = try await request(method: "sessions.list", params: params)
        return try SessionsListResult(from: result)
    }

    private func failAll(_ err: SidecarRpcError) {
        let (all, waiters) = state.withLock { s -> ([PendingRpc], [CheckedContinuation<Void, Never>]) in
            let pending = Array(s.pending.values)
            s.pending = [:]
            let w = s.readyWaiters
            s.readyWaiters = []
            if !s.ready {
                s.ready = true
            }
            return (pending, w)
        }
        for w in waiters { w.resume() }
        for p in all {
            p.timeoutTask.cancel()
            p.continuation.resume(throwing: err)
        }
    }

    public func close() async {
        let already = state.withLock { s -> Bool in
            if s.closed { return true }
            s.closed = true
            return false
        }
        if already { return }
        failAll(SidecarRpcError(code: "internal", message: "client closed"))
        readTask?.cancel()
        await transport.close()
        _ = ownsTransport
    }
}
