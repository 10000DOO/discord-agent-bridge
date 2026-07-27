import Foundation

// Long-lived JSON-RPC client over one `codex app-server` child (stdio NDJSON).
// Wire (codex app-server, measured in TS): newline-delimited JSON; responses/notifications may
// OMIT `"jsonrpc":"2.0"`. Server→client requests (approval) carry method+id and must be answered.
// Mirrors src/modes/codex/appServerClient.ts (scaffold: request/notify/approval auto-accept).

// MARK: - Types

public enum AppServerApprovalDecision: String, Sendable, Equatable {
    case accept
    case decline
    case acceptForSession
}

public struct AppServerApprovalRequest: Sendable, Equatable {
    public var requestId: JSONValue
    public var method: String
    public var params: JSONValue?

    public init(requestId: JSONValue, method: String, params: JSONValue? = nil) {
        self.requestId = requestId
        self.method = method
        self.params = params
    }
}

public typealias AppServerNotificationHandler = @Sendable (String, JSONValue?) -> Void
public typealias AppServerApprovalHandler = @Sendable (AppServerApprovalRequest) async -> AppServerApprovalDecision

public struct AppServerError: Error, Sendable, Equatable, LocalizedError {
    public var message: String

    public init(_ message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

// MARK: - Dynamic tool call (attach_file / share_document, `item/tool/call` — C3)

/// Server→client dynamic tool call params. Mirrors TS `DynamicToolCallParams`
/// (appServerClient.ts:40-47).
public struct AppServerDynamicToolCallParams: Sendable, Equatable {
    public var tool: String
    public var arguments: JSONValue?
    public var callId: String
    public var threadId: String
    public var turnId: String
    public var namespace: String?

    public init(
        tool: String, arguments: JSONValue?, callId: String, threadId: String, turnId: String,
        namespace: String? = nil
    ) {
        self.tool = tool
        self.arguments = arguments
        self.callId = callId
        self.threadId = threadId
        self.turnId = turnId
        self.namespace = namespace
    }
}

/// Mirrors TS `DynamicToolCallResult` (appServerClient.ts:49-52).
public struct AppServerDynamicToolCallResult: Sendable, Equatable {
    public enum ContentItem: Sendable, Equatable {
        case inputText(String)
        case inputImage(String)
    }

    public var success: Bool
    public var contentItems: [ContentItem]

    public init(success: Bool, contentItems: [ContentItem]) {
        self.success = success
        self.contentItems = contentItems
    }
}

public typealias AppServerDynamicToolCallHandler =
    @Sendable (AppServerDynamicToolCallParams) async -> AppServerDynamicToolCallResult

// MARK: - Client

/**
 Low-level NDJSON JSON-RPC client for `codex app-server`.
 One client maps to one child process (or injected transport for tests).
 */
public final class CodexAppServerClient: @unchecked Sendable {
    private let transport: SidecarTransport
    private let requestTimeoutNs: UInt64
    private let ownsTransport: Bool
    private let approvalHandler: AppServerApprovalHandler?

    private struct PendingRpc {
        let method: String
        let continuation: CheckedContinuation<JSONValue, Error>
        let timeoutTask: Task<Void, Never>
    }

    private struct State {
        var nextId: Int = 1
        var pending: [Int: PendingRpc] = [:]
        var notificationHandlers: [UUID: AppServerNotificationHandler] = [:]
        var dynamicToolHandler: AppServerDynamicToolCallHandler?
        var closed = false
        var started = false
        var initializeResult: JSONValue?
    }

    private let state = LockedBox(State())
    private var readTask: Task<Void, Never>?

    /// Inject transport (unit tests / custom pipes). Reading starts immediately.
    public init(
        transport: SidecarTransport,
        requestTimeoutMs: Int = 60_000,
        ownsTransport: Bool = false,
        onApproval: AppServerApprovalHandler? = nil
    ) {
        self.transport = transport
        self.requestTimeoutNs = UInt64(requestTimeoutMs) * 1_000_000
        self.ownsTransport = ownsTransport
        self.approvalHandler = onApproval
        startReading()
    }

    /// Spawn `codex app-server` via Foundation.Process.
    public convenience init(
        spawn: SidecarSpawn? = nil,
        codexHome: String? = nil,
        codexCommand: String? = nil,
        requestTimeoutMs: Int = 60_000,
        environment: [String: String]? = nil,
        onApproval: AppServerApprovalHandler? = nil
    ) throws {
        let resolved = spawn ?? resolveCodexSpawn(codexCommand: codexCommand)
        var envExtra: [String: String] = environment ?? [:]
        if let codexHome {
            envExtra["CODEX_HOME"] = codexHome
        }
        let transport = try ProcessSidecarTransport(
            spawn: resolved,
            environment: envExtra.isEmpty ? nil : envExtra
        )
        self.init(
            transport: transport,
            requestTimeoutMs: requestTimeoutMs,
            ownsTransport: true,
            onApproval: onApproval
        )
    }

    public var initializeResult: JSONValue? {
        state.withLock { $0.initializeResult }
    }

    public var isClosed: Bool {
        state.withLock { $0.closed }
    }

    // Multicast notification subscription. Returns unsubscribe.
    @discardableResult
    public func onNotification(_ handler: @escaping AppServerNotificationHandler) -> () -> Void {
        let id = UUID()
        state.withLock { $0.notificationHandlers[id] = handler }
        return { [weak self] in
            self?.state.withLock { $0.notificationHandlers[id] = nil }
        }
    }

    /// Registers the single `item/tool/call` handler (mirrors TS `onDynamicToolCall` option).
    /// Set post-construction — same reason as `onNotification`: the handler needs `self`/the
    /// owning channel id, unavailable inside CodexSessionBridge's static `makeClient` default.
    public func setDynamicToolCallHandler(_ handler: @escaping AppServerDynamicToolCallHandler) {
        state.withLock { $0.dynamicToolHandler = handler }
    }

    public func initialize(clientInfo: (name: String, version: String)? = nil) async throws -> JSONValue {
        let name = clientInfo?.name ?? "discord-agent-bridge"
        let version = clientInfo?.version ?? "0.0.0"
        let params: JSONValue = .object([
            "clientInfo": .object([
                "name": .string(name),
                "version": .string(version),
            ]),
            "capabilities": .object([
                "experimentalApi": .bool(true),
            ]),
        ])
        let result = try await request(method: "initialize", params: params)
        state.withLock { $0.initializeResult = result }
        return result
    }

    /// Returns thread id from `result.thread.id` (or fallbacks).
    public func threadStart(params: JSONValue) async throws -> String {
        let result = try await request(method: "thread/start", params: params)
        guard let id = extractThreadId(result) else {
            throw AppServerError("codex app-server: thread/start returned no thread.id.")
        }
        return id
    }

    public func threadResume(params: JSONValue) async throws -> JSONValue {
        try await request(method: "thread/resume", params: params)
    }

    /// Returns turn id from `result.turn.id` (or fallbacks).
    public func turnStart(params: JSONValue) async throws -> String {
        let result = try await request(method: "turn/start", params: params)
        guard let id = extractTurnId(result) else {
            throw AppServerError("codex app-server: turn/start returned no turn.id.")
        }
        return id
    }

    public func turnInterrupt(params: JSONValue) async throws -> JSONValue {
        try await request(method: "turn/interrupt", params: params)
    }

    /// Low-level JSON-RPC request/response. Response may omit jsonrpc.
    public func request(method: String, params: JSONValue? = nil) async throws -> JSONValue {
        let closed = state.withLock { $0.closed }
        if closed { throw AppServerError("Codex app-server client is closed.") }

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
                        throwing: AppServerError(
                            "codex app-server: \(method) timed out after \(Int((self?.requestTimeoutNs ?? 0) / 1_000_000))ms."
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
        failAll(AppServerError("Codex app-server client was closed."))
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
                // Stream itself threw (TS `onChildError` — spawn-level failure, e.g. ENOENT).
                self.failAll(AppServerError(classifyStreamFailure(error)))
                return
            }
            // Stream ended cleanly, i.e. the child exited (TS `onChildClose`/`buildExitError`).
            self.failAll(AppServerError(buildExitError(stderrBuffer: self.transport.stderrBuffer)))
        }
    }

    private func writeObject(_ obj: [String: JSONValue]) async throws {
        let data = try JSONEncoder().encode(JSONValue.object(obj))
        guard let line = String(data: data, encoding: .utf8) else {
            throw AppServerError("codex app-server: failed to encode JSON")
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
            // non-JSON stdout (noise) — skip
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
        let idValue = rawId // number or string (server requests may use either)
        let method = msg["method"]?.stringValue
        let hasResult = msg["result"] != nil
        let hasError = msg["error"] != nil

        // (1) Response: id + result/error, no method.
        if let idNum, method == nil, hasResult || hasError {
            handleResponse(id: idNum, msg: msg)
            return
        }
        // (2) Server→client request: id + method (approvals).
        if let idValue, let method {
            Task { await handleServerRequest(id: idValue, method: method, msg: msg) }
            return
        }
        // (3) Notification: method, no id.
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
            pending.continuation.resume(throwing: AppServerError(formatRpcError(err)))
        } else {
            pending.continuation.resume(returning: msg["result"] ?? .null)
        }
    }

    private func handleServerRequest(id: JSONValue, method: String, msg: [String: JSONValue]) async {
        if isApprovalMethod(method) {
            let decision = await resolveApproval(
                AppServerApprovalRequest(requestId: id, method: method, params: msg["params"])
            )
            let closed = state.withLock { $0.closed }
            if closed { return }
            try? await writeObject([
                "id": id,
                "result": .object(["decision": .string(decision.rawValue)]),
            ])
            return
        }
        if method == "item/tool/call" {
            let result = await resolveDynamicToolCall(msg["params"])
            let closed = state.withLock { $0.closed }
            if closed { return }
            try? await writeObject(["id": id, "result": encodeDynamicToolCallResult(result)])
            return
        }
        // Scaffold: unknown methods → method not found
        let closed = state.withLock { $0.closed }
        if closed { return }
        try? await writeObject([
            "id": id,
            "error": .object([
                "code": .number(-32601),
                "message": .string("Method not found: \(method)"),
            ]),
        ])
    }

    private func resolveApproval(_ req: AppServerApprovalRequest) async -> AppServerApprovalDecision {
        guard let approvalHandler else { return .accept }
        return await approvalHandler(req)
    }

    private func resolveDynamicToolCall(_ params: JSONValue?) async -> AppServerDynamicToolCallResult {
        guard let parsed = parseDynamicToolCallParams(params) else {
            return AppServerDynamicToolCallResult(
                success: false,
                contentItems: [.inputText("Invalid item/tool/call params.")]
            )
        }
        guard let handler = state.withLock({ $0.dynamicToolHandler }) else {
            return AppServerDynamicToolCallResult(
                success: false,
                contentItems: [.inputText("No handler for dynamic tool \"\(parsed.tool)\".")]
            )
        }
        return await handler(parsed)
    }

    private func dispatchNotification(method: String, params: JSONValue?) {
        let handlers = state.withLock { Array($0.notificationHandlers.values) }
        for h in handlers {
            h(method, params)
        }
    }

    private func failAll(_ err: AppServerError) {
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

func isApprovalMethod(_ method: String) -> Bool {
    method.contains("requestApproval") || method.hasSuffix("Approval") || method.range(
        of: "Approval$",
        options: .regularExpression
    ) != nil
}

func extractThreadId(_ result: JSONValue) -> String? {
    guard case .object(let obj) = result else { return nil }
    if let threadVal = obj["thread"], case .object(let thread) = threadVal,
       let id = thread["id"]?.stringValue, !id.isEmpty
    {
        return id
    }
    if let id = obj["threadId"]?.stringValue, !id.isEmpty { return id }
    if let id = obj["id"]?.stringValue, !id.isEmpty { return id }
    return nil
}

func extractTurnId(_ result: JSONValue) -> String? {
    guard case .object(let obj) = result else { return nil }
    if let turnVal = obj["turn"], case .object(let turn) = turnVal,
       let id = turn["id"]?.stringValue, !id.isEmpty
    {
        return id
    }
    if let id = obj["turnId"]?.stringValue, !id.isEmpty { return id }
    if let id = obj["id"]?.stringValue, !id.isEmpty { return id }
    return nil
}

/// Mirrors TS `parseDynamicToolCallParams` (appServerClient.ts:442-458) — tool/callId/threadId/
/// turnId must all be non-empty strings, else the whole request is invalid.
func parseDynamicToolCallParams(_ params: JSONValue?) -> AppServerDynamicToolCallParams? {
    guard case .object(let obj)? = params else { return nil }
    guard let tool = obj["tool"]?.stringValue, !tool.isEmpty,
          let callId = obj["callId"]?.stringValue, !callId.isEmpty,
          let threadId = obj["threadId"]?.stringValue, !threadId.isEmpty,
          let turnId = obj["turnId"]?.stringValue, !turnId.isEmpty
    else { return nil }
    return AppServerDynamicToolCallParams(
        tool: tool,
        arguments: obj["arguments"],
        callId: callId,
        threadId: threadId,
        turnId: turnId,
        namespace: obj["namespace"]?.stringValue
    )
}

func encodeDynamicToolCallResult(_ result: AppServerDynamicToolCallResult) -> JSONValue {
    let items: [JSONValue] = result.contentItems.map { item in
        switch item {
        case .inputText(let text):
            return .object(["type": .string("inputText"), "text": .string(text)])
        case .inputImage(let url):
            return .object(["type": .string("inputImage"), "imageUrl": .string(url)])
        }
    }
    return .object(["success": .bool(result.success), "contentItems": .array(items)])
}

func formatRpcError(_ error: JSONValue) -> String {
    if case .object(let obj) = error {
        let code: String
        if let n = obj["code"]?.numberValue {
            code = String(Int(n))
        } else {
            code = "unknown"
        }
        let message = obj["message"]?.stringValue ?? "unknown error"
        return "codex app-server error \(code): \(message)"
    }
    return "codex app-server error: \(String(describing: error))"
}

// MARK: - Process failure classification (H24)

/// User-facing KO hint when the `codex` CLI binary itself can't be found (TS
/// `NOT_INSTALLED_MESSAGE`, appServerClient.ts:110).
let codexNotInstalledMessage = "`codex` CLI를 찾을 수 없습니다. 설치 여부와 PATH를 확인하세요."
/// User-facing KO hint when codex app-server reports it isn't logged in (TS `LOGIN_MESSAGE`,
/// appServerClient.ts:112).
let codexLoginMessage = "Codex에 로그인되어 있지 않습니다. 터미널에서 `codex login`을 실행한 뒤 다시 시도하세요."

private let codexAuthFailureRegex = try? NSRegularExpression(
    pattern: #"\bnot authenticated\b|please log in|codex login|\bunauthorized\b|\bauthenticat"#,
    options: .caseInsensitive
)

/// Classify spawn-error text or accumulated stderr into an actionable hint, else nil (TS
/// `classifyFailure`, appServerClient.ts:487-490).
func classifyFailure(_ text: String, code: String? = nil) -> String? {
    if code == "ENOENT" || text.range(of: #"\bENOENT\b"#, options: .regularExpression) != nil {
        return codexNotInstalledMessage
    }
    if let re = codexAuthFailureRegex {
        let range = NSRange(text.startIndex..., in: text)
        if re.firstMatch(in: text, options: [], range: range) != nil {
            return codexLoginMessage
        }
    }
    return nil
}

/// Classify a thrown transport-stream error (TS `onChildError`, appServerClient.ts:403-408 —
/// a spawn-level failure such as ENOENT). Swift has no direct analogue of Node's `err.code`
/// errno string; approximate it from the NSError domain/code, the same technique already used
/// by Grok's `AcpClient.classifySpawnFailure`.
func classifyStreamFailure(_ error: Error) -> String {
    let ns = error as NSError
    let posixEnoent = ns.domain == NSPOSIXErrorDomain && ns.code == 2
    let cocoaNoSuchFile = ns.domain == NSCocoaErrorDomain && ns.code == NSFileNoSuchFileError
    let code: String? = (posixEnoent || cocoaNoSuchFile) ? "ENOENT" : nil
    let text = error.localizedDescription
    return classifyFailure(text, code: code) ?? redactSecrets(text)
}

/// Build the message for a clean stream EOF, i.e. the child exited (TS `buildExitError`,
/// appServerClient.ts:416-423). `SidecarTransport` does not expose the child's exit code/signal
/// (unlike Node's `close` event), so the `(code N)`/`(signal S)` suffix TS includes is omitted
/// here — a gap in the current transport surface, not a behavior choice.
func buildExitError(stderrBuffer: String) -> String {
    if let actionable = classifyFailure(stderrBuffer) {
        return actionable
    }
    let tail = redactSecrets(stderrTail(stderrBuffer))
    let suffix = tail.isEmpty ? "" : " \(tail)"
    return "codex app-server exited unexpectedly.\(suffix)"
}
