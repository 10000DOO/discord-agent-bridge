import Foundation

public let protocolVersion = 1

public enum EnvelopeType: String, Codable, Sendable, Equatable {
    case req
    case res
    case event
    case notify
}

public struct SidecarError: Codable, Sendable, Equatable, Error {
    public var code: String
    public var message: String
    public var retryable: Bool

    public init(code: String, message: String, retryable: Bool = false) {
        self.code = code
        self.message = message
        self.retryable = retryable
    }
}

/// NDJSON envelope (CLAUDE_SIDECAR_PROTOCOL.md).
public struct Envelope: Codable, Sendable, Equatable {
    public var v: Int
    public var type: EnvelopeType
    public var id: String?
    public var method: String?
    public var session: String?
    public var params: [String: JSONValue]?
    public var result: JSONValue?
    public var error: SidecarError?
    public var event: AgentEvent?

    public init(
        v: Int = protocolVersion,
        type: EnvelopeType,
        id: String? = nil,
        method: String? = nil,
        session: String? = nil,
        params: [String: JSONValue]? = nil,
        result: JSONValue? = nil,
        error: SidecarError? = nil,
        event: AgentEvent? = nil
    ) {
        self.v = v
        self.type = type
        self.id = id
        self.method = method
        self.session = session
        self.params = params
        self.result = result
        self.error = error
        self.event = event
    }
}

// MARK: - Method param/result shapes

public struct SessionStartParams: Sendable, Equatable {
    public var cwd: String
    public var guildId: String
    public var channelId: String
    public var ownerId: String?
    public var model: String?
    public var effort: String?
    public var permMode: String
    public var config: SessionConfig?
    public var env: [String: String?]?

    public struct SessionConfig: Sendable, Equatable {
        public var allowedTools: [String]?
        public var autoAllowClaudeTools: [String]?
        public var permissionTimeoutSec: Int?

        public init(
            allowedTools: [String]? = nil,
            autoAllowClaudeTools: [String]? = nil,
            permissionTimeoutSec: Int? = nil
        ) {
            self.allowedTools = allowedTools
            self.autoAllowClaudeTools = autoAllowClaudeTools
            self.permissionTimeoutSec = permissionTimeoutSec
        }
    }

    public init(
        cwd: String,
        guildId: String,
        channelId: String,
        ownerId: String? = nil,
        model: String? = nil,
        effort: String? = nil,
        permMode: String,
        config: SessionConfig? = nil,
        env: [String: String?]? = nil
    ) {
        self.cwd = cwd
        self.guildId = guildId
        self.channelId = channelId
        self.ownerId = ownerId
        self.model = model
        self.effort = effort
        self.permMode = permMode
        self.config = config
        self.env = env
    }

    public func asParams() -> [String: JSONValue] {
        var p: [String: JSONValue] = [
            "cwd": .string(cwd),
            "guildId": .string(guildId),
            "channelId": .string(channelId),
            "permMode": .string(permMode),
        ]
        if let ownerId { p["ownerId"] = .string(ownerId) }
        if let model { p["model"] = .string(model) }
        if let effort { p["effort"] = .string(effort) }
        if let config {
            var c: [String: JSONValue] = [:]
            if let allowedTools = config.allowedTools {
                c["allowedTools"] = .array(allowedTools.map { .string($0) })
            }
            if let autoAllow = config.autoAllowClaudeTools {
                c["autoAllowClaudeTools"] = .array(autoAllow.map { .string($0) })
            }
            if let timeout = config.permissionTimeoutSec {
                c["permissionTimeoutSec"] = .number(Double(timeout))
            }
            if !c.isEmpty { p["config"] = .object(c) }
        }
        if let env {
            var e: [String: JSONValue] = [:]
            for (k, v) in env {
                e[k] = v.map { .string($0) } ?? .null
            }
            p["env"] = .object(e)
        }
        return p
    }
}

public struct SessionStartResult: Sendable, Equatable {
    public var session: String
    public var backendSessionId: String?

    public init(session: String, backendSessionId: String?) {
        self.session = session
        self.backendSessionId = backendSessionId
    }

    public init(from result: JSONValue) throws {
        guard let obj = result.objectValue,
              let session = obj["session"]?.stringValue
        else {
            throw SidecarRpcError(code: "invalid_request", message: "session.start result missing session")
        }
        let backend: String? = {
            guard let v = obj["backendSessionId"] else { return nil }
            if case .null = v { return nil }
            return v.stringValue
        }()
        self.session = session
        self.backendSessionId = backend
    }
}

public struct ResumableSession: Sendable, Equatable {
    public var sessionId: String
    public var cwd: String
    public var label: String?
    public var updatedAt: String?

    public init(sessionId: String, cwd: String, label: String? = nil, updatedAt: String? = nil) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.label = label
        self.updatedAt = updatedAt
    }
}

public struct SessionsListResult: Sendable, Equatable {
    public var sessions: [ResumableSession]

    public init(sessions: [ResumableSession]) {
        self.sessions = sessions
    }

    public init(from result: JSONValue) throws {
        guard let obj = result.objectValue,
              let arr = obj["sessions"]?.arrayValue
        else {
            self.sessions = []
            return
        }
        self.sessions = arr.compactMap { item -> ResumableSession? in
            guard let o = item.objectValue,
                  let sessionId = o["sessionId"]?.stringValue,
                  let cwd = o["cwd"]?.stringValue
            else { return nil }
            return ResumableSession(
                sessionId: sessionId,
                cwd: cwd,
                label: o["label"]?.stringValue,
                updatedAt: o["updatedAt"]?.stringValue
            )
        }
    }
}

// MARK: - Parse / serialize

public enum ProtocolParseError: Error, Equatable, CustomStringConvertible {
    case emptyLine
    case invalidJSON
    case notObject
    case unsupportedVersion(String)
    case invalidType(String)

    public var description: String {
        switch self {
        case .emptyLine: return "empty line"
        case .invalidJSON: return "invalid JSON"
        case .notObject: return "envelope must be a JSON object"
        case .unsupportedVersion(let v): return "unsupported protocol version: \(v)"
        case .invalidType(let t): return "invalid envelope type: \(t)"
        }
    }
}

private let envelopeEncoder: JSONEncoder = {
    let e = JSONEncoder()
    e.outputFormatting = []
    return e
}()

private let envelopeDecoder = JSONDecoder()

/// Parse one NDJSON line into an Envelope.
public func parseEnvelope(_ line: String) throws -> Envelope {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw ProtocolParseError.emptyLine }
    guard let data = trimmed.data(using: .utf8) else { throw ProtocolParseError.invalidJSON }
    // Quick version/type checks before full decode for clearer errors
    guard let raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        // Distinguish invalid JSON vs non-object
        if (try? JSONSerialization.jsonObject(with: data)) != nil {
            throw ProtocolParseError.notObject
        }
        throw ProtocolParseError.invalidJSON
    }
    if let v = raw["v"] as? Int, v != protocolVersion {
        throw ProtocolParseError.unsupportedVersion(String(v))
    } else if let v = raw["v"] as? Double, Int(v) != protocolVersion {
        throw ProtocolParseError.unsupportedVersion(String(v))
    } else if raw["v"] == nil {
        throw ProtocolParseError.unsupportedVersion("missing")
    }
    guard let typeStr = raw["type"] as? String,
          EnvelopeType(rawValue: typeStr) != nil
    else {
        throw ProtocolParseError.invalidType(String(describing: raw["type"]))
    }
    do {
        return try envelopeDecoder.decode(Envelope.self, from: data)
    } catch {
        throw ProtocolParseError.invalidJSON
    }
}

/// Serialize an Envelope to a single NDJSON line (no trailing newline).
public func serializeEnvelope(_ env: Envelope) throws -> String {
    let data = try envelopeEncoder.encode(env)
    guard let s = String(data: data, encoding: .utf8) else {
        throw ProtocolParseError.invalidJSON
    }
    return s
}

// MARK: - Builders

public func req(
    id: String,
    method: String,
    params: [String: JSONValue]? = nil,
    session: String? = nil
) -> Envelope {
    Envelope(type: .req, id: id, method: method, session: session, params: params)
}

public func res(
    id: String,
    method: String,
    result: JSONValue,
    session: String? = nil
) -> Envelope {
    Envelope(type: .res, id: id, method: method, session: session, result: result)
}

public func resError(
    id: String,
    method: String,
    error: SidecarError,
    session: String? = nil
) -> Envelope {
    Envelope(type: .res, id: id, method: method, session: session, error: error)
}

public func eventEnvelope(session: String, event: AgentEvent) -> Envelope {
    Envelope(type: .event, session: session, event: event)
}

public func notify(
    method: String,
    params: [String: JSONValue]? = nil,
    session: String? = nil
) -> Envelope {
    Envelope(type: .notify, method: method, session: session, params: params)
}

public func makeError(
    code: String,
    message: String,
    retryable: Bool = false
) -> SidecarError {
    SidecarError(code: code, message: message, retryable: retryable)
}

// MARK: - RPC error

public struct SidecarRpcError: Error, Sendable, Equatable {
    public var code: String
    public var message: String
    public var retryable: Bool

    public init(code: String, message: String, retryable: Bool = false) {
        self.code = code
        self.message = message
        self.retryable = retryable
    }

    public init(_ error: SidecarError) {
        self.code = error.code
        self.message = error.message
        self.retryable = error.retryable
    }
}

extension SidecarRpcError: LocalizedError {
    public var errorDescription: String? { message }
}
