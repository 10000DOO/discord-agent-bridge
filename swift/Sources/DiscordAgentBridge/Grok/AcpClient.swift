import Foundation

// Long-lived JSON-RPC 2.0 client over one `grok agent stdio` child (NDJSON).
// Mirrors src/modes/grok/agent/acpClient.ts (scaffold: request/notify/permission + initialize/session).
// TODO(TS parity): prompt() as async stream of session/update chunks; activePrompt id not in pending map;
// MCP servers on session/new; stderr-classified exit errors; model guard via isGrokModel.

// MARK: - Types

public enum AcpPermissionDecision: String, Sendable, Equatable {
    case allow
    case deny
}

public struct AcpPermissionOption: Sendable, Equatable {
    public var optionId: String
    public var name: String?
    public var kind: String?

    public init(optionId: String, name: String? = nil, kind: String? = nil) {
        self.optionId = optionId
        self.name = name
        self.kind = kind
    }
}

public struct AcpPermissionRequest: Sendable, Equatable {
    public var requestId: JSONValue
    public var sessionId: String?
    public var toolName: String?
    public var toolCall: JSONValue?
    public var input: JSONValue?
    public var options: [AcpPermissionOption]

    public init(
        requestId: JSONValue,
        sessionId: String? = nil,
        toolName: String? = nil,
        toolCall: JSONValue? = nil,
        input: JSONValue? = nil,
        options: [AcpPermissionOption] = []
    ) {
        self.requestId = requestId
        self.sessionId = sessionId
        self.toolName = toolName
        self.toolCall = toolCall
        self.input = input
        self.options = options
    }
}

public typealias AcpNotificationHandler = @Sendable (String, JSONValue?) -> Void
public typealias AcpPermissionHandler = @Sendable (AcpPermissionRequest) async -> AcpPermissionDecision

public struct AcpClientError: Error, Sendable, Equatable, LocalizedError {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

// MARK: - Client

/**
 Low-level NDJSON JSON-RPC client for `grok agent stdio`.
 One client maps to one child process (or injected transport for tests).
 */
public final class GrokAcpClient: @unchecked Sendable {
    private let transport: SidecarTransport
    private let requestTimeoutNs: UInt64
    private let ownsTransport: Bool
    private let permissionHandler: AcpPermissionHandler?

    private struct PendingRpc {
        let method: String
        let continuation: CheckedContinuation<JSONValue, Error>
        let timeoutTask: Task<Void, Never>
    }

    private struct State {
        var nextId: Int = 1
        var pending: [Int: PendingRpc] = [:]
        var notificationHandlers: [UUID: AcpNotificationHandler] = [:]
        var closed = false
        var started = false
        var initializeResult: JSONValue?
        var sessionId: String?
    }

    private let state = LockedBox(State())
    private var readTask: Task<Void, Never>?

    /// Inject transport (unit tests / custom pipes). Reading starts immediately.
    public init(
        transport: SidecarTransport,
        requestTimeoutMs: Int = 60_000,
        ownsTransport: Bool = false,
        onPermission: AcpPermissionHandler? = nil
    ) {
        self.transport = transport
        self.requestTimeoutNs = UInt64(requestTimeoutMs) * 1_000_000
        self.ownsTransport = ownsTransport
        self.permissionHandler = onPermission
        startReading()
    }

    /// Spawn `grok agent stdio` via Foundation.Process.
    public convenience init(
        spawn: SidecarSpawn? = nil,
        grokCommand: String? = nil,
        model: String? = nil,
        effort: String? = nil,
        bypassPermissions: Bool = false,
        requestTimeoutMs: Int = 60_000,
        environment: [String: String]? = nil,
        onPermission: AcpPermissionHandler? = nil
    ) throws {
        let resolved =
            spawn
            ?? resolveGrokSpawn(
                grokCommand: grokCommand,
                model: model,
                effort: effort,
                bypassPermissions: bypassPermissions
            )
        let transport = try ProcessSidecarTransport(
            spawn: resolved,
            environment: environment
        )
        self.init(
            transport: transport,
            requestTimeoutMs: requestTimeoutMs,
            ownsTransport: true,
            onPermission: onPermission
        )
    }

    public var initializeResult: JSONValue? {
        state.withLock { $0.initializeResult }
    }

    public var sessionId: String? {
        state.withLock { $0.sessionId }
    }

    public var isClosed: Bool {
        state.withLock { $0.closed }
    }

    // Multicast notification subscription. Returns unsubscribe.
    @discardableResult
    public func onNotification(_ handler: @escaping AcpNotificationHandler) -> () -> Void {
        let id = UUID()
        state.withLock { $0.notificationHandlers[id] = handler }
        return { [weak self] in
            self?.state.withLock { $0.notificationHandlers[id] = nil }
        }
    }

    /// Handshake with minimal client capabilities (TS Q5: no fs/terminal delegation).
    public func initialize() async throws -> JSONValue {
        let params: JSONValue = .object([
            "protocolVersion": .number(1),
            "clientCapabilities": .object([
                "fs": .object([
                    "readTextFile": .bool(false),
                    "writeTextFile": .bool(false),
                ]),
                "terminal": .bool(false),
            ]),
        ])
        let result = try await request(method: "initialize", params: params)
        state.withLock { $0.initializeResult = result }
        return result
    }

    /// Create a fresh session; returns backend sessionId.
    /// TODO(TS): attach `_meta` (rules/systemPromptOverride/agentProfile) and mcpServers.
    public func sessionNew(cwd: String, meta: JSONValue? = nil) async throws -> String {
        var paramsObj: [String: JSONValue] = [
            "cwd": .string(cwd),
            "mcpServers": .array([]),
        ]
        if let meta {
            paramsObj["_meta"] = meta
        }
        let result = try await request(method: "session/new", params: .object(paramsObj))
        guard let sid = extractAcpSessionId(result) else {
            throw AcpClientError("grok agent stdio: session/new returned no sessionId.")
        }
        state.withLock { $0.sessionId = sid }
        return sid
    }

    /// Resume an existing session (session/load).
    public func sessionLoad(sessionId: String, cwd: String) async throws {
        let params: JSONValue = .object([
            "sessionId": .string(sessionId),
            "cwd": .string(cwd),
            "mcpServers": .array([]),
        ])
        _ = try await request(method: "session/load", params: params)
        state.withLock { $0.sessionId = sessionId }
    }

    /// Run one prompt turn. session/update text chunks stream to `onNotification` subscribers
    /// meanwhile; this BLOCKS until the `session/prompt` RESPONSE — the turn terminator
    /// (acpClient.ts:341-342, 470-475). Returns the prompt result (stopReason/usage); throws on
    /// prompt error or child exit (in-flight reject). Requires a prior sessionNew/sessionLoad.
    ///
    /// ponytail: the prompt turn shares the control-request timeout (requestTimeoutMs). The c3
    /// bridge owns the turn timeout by creating the client with requestTimeoutMs = the turn budget
    /// (like CodexSessionBridge). TS separates control/prompt timeouts (acpClient.ts:162) — split
    /// here only if fast-failing control requests becomes necessary.
    public func sessionPrompt(prompt: String) async throws -> JSONValue {
        let sid = state.withLock { $0.sessionId }
        guard let sid else {
            throw AcpClientError("grok agent stdio: no session — call sessionNew or sessionLoad first.")
        }
        let params: JSONValue = .object([
            "sessionId": .string(sid),
            "prompt": .array([.object([
                "type": .string("text"),
                "text": .string(prompt),
            ])]),
        ])
        return try await request(method: "session/prompt", params: params)
    }

    /// Low-level control request (initialize / session/*). Not used for streaming prompt turns.
    /// TODO(TS): session/prompt uses activePrompt stream; response terminates updates, not pending map.
    public func request(method: String, params: JSONValue? = nil) async throws -> JSONValue {
        let closed = state.withLock { $0.closed }
        if closed { throw AcpClientError("Grok ACP client is closed.") }

        let id = state.withLock { s -> Int in
            let n = s.nextId
            s.nextId += 1
            return n
        }

        return try await withCheckedThrowingContinuation { cont in
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: self?.requestTimeoutNs ?? 60_000_000_000)
                guard !Task.isCancelled else { return }
                let removed = self?.state.withLock { $0.pending.removeValue(forKey: id) }
                if let removed {
                    removed.continuation.resume(
                        throwing: AcpClientError(
                            "grok agent stdio: \(method) timed out after \(Int((self?.requestTimeoutNs ?? 0) / 1_000_000))ms."
                        )
                    )
                }
            }
            state.withLock {
                $0.pending[id] = PendingRpc(method: method, continuation: cont, timeoutTask: timeoutTask)
            }
            Task {
                do {
                    var msg: [String: JSONValue] = [
                        "jsonrpc": .string("2.0"),
                        "id": .number(Double(id)),
                        "method": .string(method),
                    ]
                    if let params {
                        msg["params"] = params
                    }
                    try await self.writeObject(msg)
                } catch {
                    let removed = self.state.withLock { $0.pending.removeValue(forKey: id) }
                    removed?.timeoutTask.cancel()
                    removed?.continuation.resume(throwing: error)
                }
            }
        }
    }

    public func close() async {
        let already = state.withLock { s -> Bool in
            if s.closed { return true }
            s.closed = true
            return false
        }
        if already { return }
        failAll(AcpClientError("Grok ACP client was closed."))
        readTask?.cancel()
        await transport.close()
        _ = ownsTransport
    }

    // MARK: - Internals

    private func startReading() {
        let already = state.withLock { s -> Bool in
            if s.started { return true }
            s.started = true
            return false
        }
        if already { return }

        readTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await line in self.transport.lines {
                    self.onLine(line)
                }
            } catch {
                self.failAll(AcpClientError("grok agent stdio stdout closed: \(error)"))
                return
            }
            self.failAll(AcpClientError("grok agent stdio stdout closed"))
        }
    }

    private func writeObject(_ obj: [String: JSONValue]) async throws {
        let data = try JSONEncoder().encode(JSONValue.object(obj))
        guard let line = String(data: data, encoding: .utf8) else {
            throw AcpClientError("grok agent stdio: failed to encode JSON")
        }
        try await transport.writeLine(line + "\n")
    }

    private func onLine(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let data = Data(trimmed.utf8)
        let value: JSONValue
        do {
            value = try JSONDecoder().decode(JSONValue.self, from: data)
        } catch {
            // non-JSON stdout (noise) — skip (TS: debug log)
            return
        }
        guard case .object(let msg) = value else { return }

        let rawId = msg["id"]
        let idNum: Int? = {
            guard let rawId else { return nil }
            if case .number(let n) = rawId { return Int(n) }
            return nil
        }()
        let idValue = rawId
        let method = msg["method"]?.stringValue
        let hasResult = msg["result"] != nil
        let hasError = msg["error"] != nil

        // (1) Response: id + result/error, no method.
        if let idNum, method == nil, hasResult || hasError {
            handleResponse(id: idNum, msg: msg)
            return
        }
        // (2) Server→client request: id + method (permission asks).
        if let idValue, let method {
            Task { await handleServerRequest(id: idValue, method: method, msg: msg) }
            return
        }
        // (3) Notification: method, no id (session/update, x.ai/*).
        if rawId == nil, let method {
            dispatchNotification(method: method, params: msg["params"])
            return
        }
    }

    private func handleResponse(id: Int, msg: [String: JSONValue]) {
        let pending = state.withLock { $0.pending.removeValue(forKey: id) }
        guard let pending else { return }
        pending.timeoutTask.cancel()
        if let err = msg["error"] {
            pending.continuation.resume(throwing: AcpClientError(formatAcpRpcError(err)))
        } else {
            pending.continuation.resume(returning: msg["result"] ?? .null)
        }
    }

    private func handleServerRequest(id: JSONValue, method: String, msg: [String: JSONValue]) async {
        if isAcpPermissionMethod(method) {
            let req = parseAcpPermissionRequest(requestId: id, params: msg["params"])
            let decision = await resolvePermission(req)
            let closed = state.withLock { $0.closed }
            if closed { return }
            try? await writeObject([
                "jsonrpc": .string("2.0"),
                "id": id,
                "result": buildAcpPermissionResult(decision: decision, options: req.options),
            ])
            return
        }
        // Q5: we do not delegate fs/terminal — method-not-found so agent is not left waiting.
        let closed = state.withLock { $0.closed }
        if closed { return }
        try? await writeObject([
            "jsonrpc": .string("2.0"),
            "id": id,
            "error": .object([
                "code": .number(-32601),
                "message": .string("Method not found: \(method)"),
            ]),
        ])
    }

    private func resolvePermission(_ req: AcpPermissionRequest) async -> AcpPermissionDecision {
        // Without a handler: safe default cancel/deny so the agent never hangs (TS).
        guard let permissionHandler else { return .deny }
        return await permissionHandler(req)
    }

    private func dispatchNotification(method: String, params: JSONValue?) {
        let handlers = state.withLock { Array($0.notificationHandlers.values) }
        for h in handlers {
            h(method, params)
        }
    }

    private func failAll(_ err: AcpClientError) {
        let all = state.withLock { s -> [PendingRpc] in
            let pending = Array(s.pending.values)
            s.pending = [:]
            s.closed = true
            return pending
        }
        for p in all {
            p.timeoutTask.cancel()
            p.continuation.resume(throwing: err)
        }
    }
}

// MARK: - Pure helpers

/// Q4: confirmed live method `session/request_permission`.
func isAcpPermissionMethod(_ method: String) -> Bool {
    method == "session/request_permission"
}

func extractAcpSessionId(_ result: JSONValue) -> String? {
    guard case .object(let obj) = result else { return nil }
    if let id = obj["sessionId"]?.stringValue, !id.isEmpty { return id }
    if let id = obj["session_id"]?.stringValue, !id.isEmpty { return id }
    return nil
}

func formatAcpRpcError(_ error: JSONValue) -> String {
    if case .object(let obj) = error {
        let code: String
        if let n = obj["code"]?.numberValue {
            code = String(Int(n))
        } else {
            code = "unknown"
        }
        let message = obj["message"]?.stringValue ?? "unknown error"
        return "grok agent stdio error \(code): \(message)"
    }
    return "grok agent stdio error: \(String(describing: error))"
}

func parseAcpPermissionRequest(requestId: JSONValue, params: JSONValue?) -> AcpPermissionRequest {
    guard case .object(let p) = params else {
        return AcpPermissionRequest(requestId: requestId)
    }
    let sessionId = p["sessionId"]?.stringValue
    let toolCall = p["toolCall"]
    var toolName: String?
    var input: JSONValue?
    if case .object(let tc) = toolCall {
        if let title = tc["title"]?.stringValue, !title.isEmpty {
            toolName = title
        } else if let name = tc["name"]?.stringValue, !name.isEmpty {
            toolName = name
        } else if let kind = tc["kind"]?.stringValue, !kind.isEmpty {
            toolName = kind
        }
        input = tc["rawInput"]
    }
    var options: [AcpPermissionOption] = []
    if case .array(let rawOpts) = p["options"] {
        for item in rawOpts {
            guard case .object(let o) = item,
                  let optionId = o["optionId"]?.stringValue
            else { continue }
            options.append(
                AcpPermissionOption(
                    optionId: optionId,
                    name: o["name"]?.stringValue,
                    kind: o["kind"]?.stringValue
                )
            )
        }
    }
    return AcpPermissionRequest(
        requestId: requestId,
        sessionId: sessionId,
        toolName: toolName,
        toolCall: toolCall,
        input: input,
        options: options
    )
}

/// Q4: map decision → ACP outcome (allow → allow-kind option; deny → reject-kind or cancelled).
func buildAcpPermissionResult(
    decision: AcpPermissionDecision,
    options: [AcpPermissionOption]
) -> JSONValue {
    switch decision {
    case .allow:
        let option =
            options.first(where: { ($0.kind ?? "").hasPrefix("allow") })
            ?? options.first
        return .object([
            "outcome": .object([
                "outcome": .string("selected"),
                "optionId": .string(option?.optionId ?? "allow"),
            ]),
        ])
    case .deny:
        if let reject = options.first(where: { ($0.kind ?? "").hasPrefix("reject") }) {
            return .object([
                "outcome": .object([
                    "outcome": .string("selected"),
                    "optionId": .string(reject.optionId),
                ]),
            ])
        }
        return .object([
            "outcome": .object([
                "outcome": .string("cancelled"),
            ]),
        ])
    }
}
