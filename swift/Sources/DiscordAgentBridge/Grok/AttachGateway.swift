import Foundation
import Network

// Loopback HTTP gateway so the Grok "discord" MCP subprocess (`dab attach-mcp`, spawned by
// `grok agent stdio` as ITS OWN child — not ours) can call attach_file / share_document back
// without an in-process callback. Mirrors src/discord/attachGateway.ts 1:1 (GET /health,
// POST /attach, POST /share), but native: Network.framework instead of node:http (no new SPM
// dependency — this package already targets macOS only), and the registry stores only
// {channelId, workspaceRoot} per token rather than sendFile/shareDocument closures, because
// Swift already centralized those as process-wide singletons keyed by channelId
// (FileAttachHost / DocumentShareHost, wired once in DabMain) — TS threads a closure per
// session because it has no such singleton.

/// One MCP-callback registration: which channel this token belongs to, and its workspace root
/// (for `attach_file` path confinement — `share_document` only needs the channelId).
struct GrokAttachRegistration: Sendable {
    let channelId: String
    let workspaceRoot: String
}

private struct GatewayHTTPRequest {
    let method: String
    let path: String
    let body: Data
}

public let GROK_ATTACH_GATEWAY_MAX_BODY_BYTES = 1_048_576

/// Surface `GrokSessionBridge` depends on (test seam) — lets unit tests that never exercise C5's
/// HTTP round trip inject a no-socket fake instead of paying for a real `NWListener` per test.
public protocol GrokAttachGatewayProviding: Sendable {
    var baseURL: String { get async }
    func whenReady() async throws
    func register(token: String, channelId: String, workspaceRoot: String) async
    func unregister(token: String) async
}

public actor GrokAttachGateway: GrokAttachGatewayProviding {
    public static let shared = GrokAttachGateway()

    private let fileAttachHost: FileAttachHost
    private let documentShareHost: DocumentShareHost

    private var registry: [String: GrokAttachRegistration] = [:]
    private var listener: NWListener?
    private var port: UInt16 = 0

    /// Injectable hosts (test seam, mirrors GrokSessionBridge's `gate`/`configStore` pattern) —
    /// defaults to the real process-wide singletons wired in DabMain.
    public init(fileAttachHost: FileAttachHost = .shared, documentShareHost: DocumentShareHost = .shared) {
        self.fileAttachHost = fileAttachHost
        self.documentShareHost = documentShareHost
    }

    /// Empty until `whenReady()` completes (TS baseUrl getter).
    public var baseURL: String { "http://127.0.0.1:\(port)" }

    /// Starts the loopback listener on first call; idempotent. Lazy (unlike TS's eager boot-time
    /// start) so a channel that never runs Grok never opens a port — matches this bridge's own
    /// lazy-spawn convention for the grok child itself (GrokAcpSession "LAZY-INIT" comment).
    public func whenReady() async throws {
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: params)
        listener.newConnectionHandler = { [weak self] connection in
            Task { await self?.accept(connection) }
        }
        // A loopback ephemeral-port bind is normally near-instant. NWListener can sit in
        // .setup/.waiting (retrying — e.g. no local-network permission in a sandboxed host)
        // WITHOUT ever reaching .ready or .failed, which would strand this continuation forever
        // (a bug this actor had: only .ready/.failed resumed it). `resumed` guards against a
        // double-resume race between the state callback and this timeout.
        let resumed = LockedBox(false)
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            @Sendable func finish(_ result: Result<Void, Error>) {
                let firstTime = resumed.withLock { flag -> Bool in
                    guard !flag else { return false }
                    flag = true
                    return true
                }
                guard firstTime else { return }
                switch result {
                case .success: cont.resume()
                case .failure(let err): cont.resume(throwing: err)
                }
            }
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    finish(.success(()))
                case .failed(let err):
                    finish(.failure(err))
                default:
                    break
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
            Task {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                finish(.failure(AcpClientError("GrokAttachGateway: loopback listener did not become ready within 5s.")))
            }
        }
        self.port = listener.port?.rawValue ?? 0
        self.listener = listener
    }

    public func register(token: String, channelId: String, workspaceRoot: String) {
        registry[token] = GrokAttachRegistration(channelId: channelId, workspaceRoot: workspaceRoot)
    }

    public func unregister(token: String) {
        registry[token] = nil
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) async {
        connection.start(queue: .global(qos: .userInitiated))
        guard let request = await Self.readRequest(connection) else {
            connection.cancel()
            return
        }
        let (status, json) = await route(request)
        await Self.respond(connection, status: status, json: json)
        connection.cancel()
    }

    // One request per connection (our own `dab attach-mcp` client never pipelines) — read until
    // the header terminator, then Content-Length more bytes. No chunked-encoding support: the
    // only client is code we also write, and it always sends a fixed-length JSON body.
    private static func readRequest(_ connection: NWConnection) async -> GatewayHTTPRequest? {
        let headerEnd = Data("\r\n\r\n".utf8)
        var buffer = Data()
        var headerRange: Range<Data.Index>?

        while headerRange == nil {
            guard let chunk = await receiveChunk(connection), !chunk.isEmpty else { return nil }
            buffer.append(chunk)
            headerRange = buffer.range(of: headerEnd)
            if buffer.count > 65_536 { return nil }  // guard: no headers this large on a loopback tool call
        }
        guard let headerRange, let headerText = String(data: buffer[..<headerRange.lowerBound], encoding: .utf8) else {
            return nil
        }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(separator: " ")
        guard requestParts.count >= 2 else { return nil }
        let method = String(requestParts[0])
        let path = String(requestParts[1])

        var contentLength = 0
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[line.startIndex..<colon].trimmingCharacters(in: .whitespaces).lowercased()
            if name == "content-length" {
                let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                contentLength = Int(value) ?? 0
            }
        }
        guard contentLength >= 0, contentLength <= GROK_ATTACH_GATEWAY_MAX_BODY_BYTES else { return nil }

        var body = buffer[headerRange.upperBound...]
        guard body.count <= GROK_ATTACH_GATEWAY_MAX_BODY_BYTES else { return nil }
        while body.count < contentLength {
            guard let chunk = await receiveChunk(connection), !chunk.isEmpty else { break }
            body.append(chunk)
            guard body.count <= GROK_ATTACH_GATEWAY_MAX_BODY_BYTES else { return nil }
        }
        return GatewayHTTPRequest(method: method, path: path, body: Data(body.prefix(contentLength)))
    }

    private static func receiveChunk(_ connection: NWConnection) async -> Data? {
        await withCheckedContinuation { (cont: CheckedContinuation<Data?, Never>) in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    cont.resume(returning: data)
                } else if isComplete || error != nil {
                    cont.resume(returning: nil)
                } else {
                    cont.resume(returning: Data())
                }
            }
        }
    }

    private static func respond(_ connection: NWConnection, status: Int, json: JSONValue) async {
        let bodyData = (try? JSONEncoder().encode(json)) ?? Data("{}".utf8)
        var head = "HTTP/1.1 \(status) \(httpStatusText(status))\r\n"
        head += "Content-Type: application/json; charset=utf-8\r\n"
        head += "Content-Length: \(bodyData.count)\r\n"
        head += "Connection: close\r\n\r\n"
        var full = Data(head.utf8)
        full.append(bodyData)
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            connection.send(content: full, completion: .contentProcessed { _ in cont.resume() })
        }
    }

    // MARK: - Routing (mirrors attachGateway.ts handleRequest)

    private func route(_ request: GatewayHTTPRequest) async -> (Int, JSONValue) {
        if request.method == "GET", request.path == "/" || request.path == "/health" {
            return (200, .object(["ok": .bool(true)]))
        }
        let isShare = request.method == "POST" && request.path == "/share"
        guard request.method == "POST", request.path == "/attach" || isShare else {
            return (404, .object(["ok": .bool(false), "text": .string("Not found")]))
        }
        guard
            let decoded = try? JSONDecoder().decode(JSONValue.self, from: request.body),
            case .object(let body) = decoded
        else {
            return (400, .object(["ok": .bool(false), "text": .string("Invalid JSON body")]))
        }
        let token = body["token"]?.stringValue ?? ""
        let requestedPath = body["path"]?.stringValue ?? ""
        guard !token.isEmpty, !requestedPath.isEmpty else {
            return (400, .object(["ok": .bool(false), "text": .string("token and path are required")]))
        }
        guard let reg = registry[token] else {
            return (401, .object(["ok": .bool(false), "text": .string("Unknown or expired attach token")]))
        }

        if isShare {
            // DocumentShareHost.share MAY rethrow for an uncoded failure (TS mcpFileTool.ts
            // shareDocumentResult:140-156 catches this exact case around its `shareDocument` call).
            do {
                let result = try await documentShareHost.share(channelId: reg.channelId, path: requestedPath)
                let (text, isError) = shareResultText(result, requestedPath: requestedPath)
                return (isError ? 400 : 200, .object(["ok": .bool(!isError), "text": .string(text)]))
            } catch {
                return (400, .object(["ok": .bool(false), "text": .string("Could not share \(requestedPath): unexpected error")]))
            }
        }

        let filename = body["filename"]?.stringValue
        let host = fileAttachHost
        let channelId = reg.channelId
        let result = await attachFileConfined(
            workspaceRoot: reg.workspaceRoot,
            sendFile: { abs, name in try await host.attach(channelId: channelId, path: abs, name: name) },
            requestedPath: requestedPath,
            filename: filename
        )
        return (result.isError ? 400 : 200, .object(["ok": .bool(!result.isError), "text": .string(result.text)]))
    }
}

private func httpStatusText(_ status: Int) -> String {
    switch status {
    case 200: return "OK"
    case 400: return "Bad Request"
    case 401: return "Unauthorized"
    case 404: return "Not Found"
    default: return "Internal Server Error"
    }
}

/// Neutral English, model-facing confirmation/rejection text for a `share_document` result
/// (TS mcpFileTool.ts:140-176 `shareDocumentResult`/`shareErrorText` 1:1). NOT the i18n
/// `doc.error.*` catalog used by the `/doc` slash command — that one is Discord-facing.
func shareResultText(_ result: ShareResult, requestedPath: String) -> (text: String, isError: Bool) {
    if result.ok {
        let threadName = result.threadName ?? result.path ?? requestedPath
        return ("Shared \"\(result.path ?? requestedPath)\" to thread \(threadName)", false)
    }
    let prefix = "Could not share \(requestedPath): "
    switch result.code {
    case .notMarkdown: return (prefix + "not a markdown file", true)
    case .notFound: return (prefix + "file not found", true)
    case .tooLarge: return (prefix + "too large (\(result.max ?? "limit exceeded"))", true)
    case .escape: return (prefix + "outside the workspace", true)
    case .notFile: return (prefix + "not a file", true)
    case .none: return (prefix + "no active session for this channel", true)
    }
}
