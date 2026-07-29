import Foundation

// Long-lived JSON-RPC 2.0 client over one `grok agent stdio` child (NDJSON).
// Mirrors src/modes/grok/agent/acpClient.ts (request/notify/permission + initialize/session/prompt).
//
// Control requests use `requestTimeoutMs` (default 60s). `session/prompt` has no client-side
// sleep timeout — the bridge owns the turn budget (DAB_TURN_TIMEOUT_SEC). On child death,
// stderr is classified into login/install hints (classifyAcpFailure) else a redacted tail.
//
// ponytail: no AsyncIterator prompt stream — updates go through onNotification while sessionPrompt
// awaits the session/prompt RESPONSE (bridge folds text synchronously before return).

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

/// Optional session/new `_meta` (TS AcpSessionMeta / 15-agent-mode.md).
public struct AcpSessionMeta: Sendable, Equatable {
    public var rules: String?
    public var systemPromptOverride: String?
    /// Wire: string profile name or object (JSONValue covers both).
    public var agentProfile: JSONValue?

    public init(rules: String? = nil, systemPromptOverride: String? = nil, agentProfile: JSONValue? = nil) {
        self.rules = rules
        self.systemPromptOverride = systemPromptOverride
        self.agentProfile = agentProfile
    }

    public func asJSON() -> JSONValue {
        var o: [String: JSONValue] = [:]
        if let rules { o["rules"] = .string(rules) }
        if let systemPromptOverride { o["systemPromptOverride"] = .string(systemPromptOverride) }
        if let agentProfile { o["agentProfile"] = agentProfile }
        return .object(o)
    }
}

/// MCP env entry — Grok wire format is `[{name,value}]`, not a string map (-32602 if map).
public struct AcpMcpEnvVar: Sendable, Equatable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }

    public func asJSON() -> JSONValue {
        .object(["name": .string(name), "value": .string(value)])
    }
}

/// MCP server entry for session/new and session/load (TS AcpMcpServerConfig).
public struct AcpMcpServerConfig: Sendable, Equatable {
    public var name: String
    public var command: String
    public var args: [String]?
    public var env: [AcpMcpEnvVar]?

    public init(name: String, command: String, args: [String]? = nil, env: [AcpMcpEnvVar]? = nil) {
        self.name = name
        self.command = command
        self.args = args
        self.env = env
    }

    public func asJSON() -> JSONValue {
        var o: [String: JSONValue] = [
            "name": .string(name),
            "command": .string(command),
        ]
        if let args {
            o["args"] = .array(args.map { .string($0) })
        }
        if let env {
            o["env"] = .array(env.map { $0.asJSON() })
        }
        return .object(o)
    }
}

/// Multimodal prompt blocks for session/prompt (text + image base64).
public enum AcpPromptBlock: Sendable, Equatable {
    case text(String)
    case image(data: String, mimeType: String)

    public func asJSON() -> JSONValue {
        switch self {
        case .text(let text):
            return .object([
                "type": .string("text"),
                "text": .string(text),
            ])
        case .image(let data, let mimeType):
            return .object([
                "type": .string("image"),
                "data": .string(data),
                "mimeType": .string(mimeType),
            ])
        }
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
    private let mcpServers: [AcpMcpServerConfig]

    private struct PendingRpc {
        let method: String
        let continuation: CheckedContinuation<JSONValue, Error>
        /// nil when the request has no sleep timeout (session/prompt).
        let timeoutTask: Task<Void, Never>?
    }

    private struct State {
        var nextId: Int = 1
        var pending: [Int: PendingRpc] = [:]
        var notificationHandlers: [UUID: AcpNotificationHandler] = [:]
        var closed = false
        var started = false
        var initializeResult: JSONValue?
        var sessionId: String?
        var promptInFlight = false
        var lastPromptResult: JSONValue?
    }

    private let state = LockedBox(State())
    private var readTask: Task<Void, Never>?

    /// Inject transport (unit tests / custom pipes). Reading starts immediately.
    public init(
        transport: SidecarTransport,
        requestTimeoutMs: Int = 60_000,
        ownsTransport: Bool = false,
        mcpServers: [AcpMcpServerConfig] = [],
        onPermission: AcpPermissionHandler? = nil
    ) {
        self.transport = transport
        self.requestTimeoutNs = UInt64(requestTimeoutMs) * 1_000_000
        self.ownsTransport = ownsTransport
        self.mcpServers = mcpServers
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
        mcpServers: [AcpMcpServerConfig] = [],
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
        let transport: ProcessSidecarTransport
        do {
            transport = try ProcessSidecarTransport(
                spawn: resolved,
                environment: environment
            )
        } catch {
            throw AcpClientError(classifySpawnFailure(error))
        }
        self.init(
            transport: transport,
            requestTimeoutMs: requestTimeoutMs,
            ownsTransport: true,
            mcpServers: mcpServers,
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

    /// stopReason/usage from the most recent completed prompt turn (nil until one completes).
    public var lastPromptResult: JSONValue? {
        state.withLock { $0.lastPromptResult }
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
    /// `_meta` attached only when provided; `mcpServers` from client construction (empty default).
    public func sessionNew(cwd: String, meta: AcpSessionMeta? = nil) async throws -> String {
        var paramsObj: [String: JSONValue] = [
            "cwd": .string(cwd),
            "mcpServers": .array(mcpServers.map { $0.asJSON() }),
        ]
        if let meta {
            paramsObj["_meta"] = meta.asJSON()
        }
        let result = try await request(method: "session/new", params: .object(paramsObj))
        guard let sid = extractAcpSessionId(result) else {
            throw AcpClientError("grok agent stdio: session/new returned no sessionId.")
        }
        state.withLock { $0.sessionId = sid }
        return sid
    }

    /// Resume an existing session (session/load). Forwards the same mcpServers as session/new.
    public func sessionLoad(sessionId: String, cwd: String) async throws {
        let params: JSONValue = .object([
            "sessionId": .string(sessionId),
            "cwd": .string(cwd),
            "mcpServers": .array(mcpServers.map { $0.asJSON() }),
        ])
        _ = try await request(method: "session/load", params: params)
        state.withLock { $0.sessionId = sessionId }
    }

    /// Run one prompt turn (plain text). session/update chunks stream to `onNotification`
    /// meanwhile; this BLOCKS until the `session/prompt` RESPONSE — the turn terminator
    /// (acpClient.ts). Returns the prompt result (stopReason/usage); throws on prompt error or
    /// child exit. Requires a prior sessionNew/sessionLoad.
    ///
    /// No client-side sleep timeout (TS: prompt is not in the control pending-timeout map).
    /// `GrokSessionBridge` owns the turn budget via `DAB_TURN_TIMEOUT_SEC`.
    public func sessionPrompt(prompt: String) async throws -> JSONValue {
        try await sessionPrompt(blocks: [.text(prompt)])
    }

    /// Multimodal prompt turn (text + image blocks). Empty `blocks` → single space text block
    /// (TS acpClient.prompt empty-array fallback). One prompt in flight at a time.
    public func sessionPrompt(blocks: [AcpPromptBlock]) async throws -> JSONValue {
        let sid = state.withLock { $0.sessionId }
        guard let sid else {
            throw AcpClientError("grok agent stdio: no session — call sessionNew or sessionLoad first.")
        }
        let claimed = state.withLock { s -> Bool in
            if s.promptInFlight { return false }
            s.promptInFlight = true
            s.lastPromptResult = nil
            return true
        }
        guard claimed else {
            throw AcpClientError("A grok prompt is already in flight.")
        }
        defer { state.withLock { $0.promptInFlight = false } }

        let normalized: [AcpPromptBlock] = blocks.isEmpty ? [.text(" ")] : blocks
        let params: JSONValue = .object([
            "sessionId": .string(sid),
            "prompt": .array(normalized.map { $0.asJSON() }),
        ])
        // nil timeout: ends only on response or child death (TS acpClient.prompt).
        let result = try await request(method: "session/prompt", params: params, timeoutMs: nil)
        state.withLock { $0.lastPromptResult = result }
        return result
    }

    /// Low-level control request (initialize / session/*). Uses `requestTimeoutMs`.
    public func request(method: String, params: JSONValue? = nil) async throws -> JSONValue {
        try await request(
            method: method,
            params: params,
            timeoutMs: Int(requestTimeoutNs / 1_000_000)
        )
    }

    /// JSON-RPC request. `timeoutMs == nil` → no sleep timeout (session/prompt).
    public func request(method: String, params: JSONValue?, timeoutMs: Int?) async throws -> JSONValue {
        let closed = state.withLock { $0.closed }
        if closed { throw AcpClientError("Grok ACP client is closed.") }

        let id = state.withLock { s -> Int in
            let n = s.nextId
            s.nextId += 1
            return n
        }

        return try await withCheckedThrowingContinuation { cont in
            let timeoutTask: Task<Void, Never>?
            if let timeoutMs, timeoutMs > 0 {
                let timeoutNs = UInt64(timeoutMs) * 1_000_000
                timeoutTask = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: timeoutNs)
                    guard !Task.isCancelled else { return }
                    let removed = self?.state.withLock { $0.pending.removeValue(forKey: id) }
                    if let removed {
                        removed.continuation.resume(
                            throwing: AcpClientError(
                                "grok agent stdio: \(method) timed out after \(timeoutMs)ms."
                            )
                        )
                    }
                }
            } else {
                timeoutTask = nil
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
                    removed?.timeoutTask?.cancel()
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
                self.failAll(self.buildExitError(underlying: error))
                return
            }
            self.failAll(self.buildExitError(underlying: nil))
        }
    }

    /// Actionable stderr classification, else generic closed + redacted tail (TS buildExitError).
    private func buildExitError(underlying: Error?) -> AcpClientError {
        let stderr = transport.stderrBuffer
        if let underlying {
            let text = String(describing: underlying)
            if let classified = classifyAcpFailure(text) {
                return AcpClientError(classified)
            }
        }
        if let classified = classifyAcpFailure(stderr) {
            return AcpClientError(classified)
        }
        let tail = redactSecrets(stderrTail(stderr))
        let suffix = tail.isEmpty ? "" : " \(tail)"
        if let underlying {
            return AcpClientError("grok agent stdio stdout closed: \(underlying).\(suffix)")
        }
        return AcpClientError("grok agent stdio stdout closed.\(suffix)")
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
            guard case .number(let value) = rawId,
                  value.isFinite,
                  value > 0,
                  let id = Int(exactly: value)
            else { return nil }
            return id
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
        pending.timeoutTask?.cancel()
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
            s.promptInFlight = false
            return pending
        }
        for p in all {
            p.timeoutTask?.cancel()
            p.continuation.resume(throwing: err)
        }
    }
}

// MARK: - Pure helpers

/// User-facing hints for a dead/missing child (TS acpClient ACP_*_MESSAGE). Computed (not `let`)
/// so each read reflects the request-local locale (I18n.getLocale()), same reasoning as
/// AppServerClient.swift's codexNotInstalledMessage/codexLoginMessage (§8-2 `let` constant issue).
public var ACP_LOGIN_MESSAGE: String { I18n.t("grok.notLoggedIn") }
public var ACP_NOT_INSTALLED_MESSAGE: String { I18n.t("grok.notInstalled") }

private let acpAuthFailureRegex: NSRegularExpression? = try? NSRegularExpression(
    pattern: #"\bnot authenticated\b|please log in|grok login|\bunauthorized\b|\bauthenticat"#,
    options: .caseInsensitive
)

/// Classify spawn/exit text into a login or install hint, or nil when generic (TS classifyAcpFailure).
public func classifyAcpFailure(_ text: String, code: String? = nil) -> String? {
    if code == "ENOENT" || text.range(of: #"\bENOENT\b"#, options: .regularExpression) != nil {
        return ACP_NOT_INSTALLED_MESSAGE
    }
    if let re = acpAuthFailureRegex {
        let range = NSRange(text.startIndex..., in: text)
        if re.firstMatch(in: text, options: [], range: range) != nil {
            return ACP_LOGIN_MESSAGE
        }
    }
    return nil
}

/// Last `maxChars` of stderr (ellipsis prefix when truncated). TS stderrTail.
public func stderrTail(_ stderr: String, maxChars: Int = 500) -> String {
    let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.count <= maxChars { return trimmed }
    return "…" + String(trimmed.suffix(maxChars))
}

/// Map a Process launch failure to a user-facing message (ENOENT → not installed).
func classifySpawnFailure(_ error: Error) -> String {
    let ns = error as NSError
    // POSIX ENOENT = 2; Cocoa no-such-file also means missing binary.
    let posixEnoent = ns.domain == NSPOSIXErrorDomain && ns.code == 2
    let cocoaNoSuchFile = ns.domain == NSCocoaErrorDomain && ns.code == NSFileNoSuchFileError
    let code: String? = (posixEnoent || cocoaNoSuchFile) ? "ENOENT" : nil
    let text = error.localizedDescription
    if let classified = classifyAcpFailure(text, code: code) {
        return classified
    }
    if posixEnoent || cocoaNoSuchFile || text.localizedCaseInsensitiveContains("no such file") {
        return ACP_NOT_INSTALLED_MESSAGE
    }
    return text
}

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

/// H3: same `redactSecrets` scrub as `buildExitError` — an RPC error's `message` can carry a
/// backend-echoed secret (token/key in a shell error, auth header, …), so it must not reach the
/// user unmasked (TS `formatRpcError` always applies `redactString`).
func formatAcpRpcError(_ error: JSONValue) -> String {
    if case .object(let obj) = error {
        let code: String
        if let n = obj["code"]?.numberValue {
            code = String(Int(n))
        } else {
            code = "unknown"
        }
        let message = obj["message"]?.stringValue ?? "unknown error"
        return redactSecrets("grok agent stdio error \(code): \(message)")
    }
    return redactSecrets("grok agent stdio error: \(String(describing: error))")
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
