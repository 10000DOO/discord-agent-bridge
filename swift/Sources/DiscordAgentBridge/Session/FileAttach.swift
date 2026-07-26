import Foundation

// Attach a workspace file to the bound Discord channel (TS `mcpFileTool.attachFileConfined`
// + `SessionWiring.sendFileFor` parity). Pure confinement + inject-send core; Discord I/O is
// injected via `FileAttachHost` so the library stays free of DiscordBM.
//
// Deliberate boundaries (TS mcpFileTool.ts §1–2):
//  1. Transport-agnostic — actual Discord send is an injected callback.
//  2. Path-confined — every requested path is realpath-resolved and must stay inside the
//     session workspace root (fixes A5). Escape is rejected before the callback runs.

/// Model-facing attach outcome (subset of MCP CallToolResult). `isError` means confinement
/// or send failure — never throws for known rejections so reverse-RPC mappers can choose.
public struct AttachFileResult: Sendable, Equatable {
    public var text: String
    public var isError: Bool

    public init(text: String, isError: Bool = false) {
        self.text = text
        self.isError = isError
    }
}

/// Resolve `requestedPath` against the workspace, reject escapes, then forward to `sendFile`.
/// Mirrors TS `attachFileConfined` (mcpFileTool.ts:49-81) 1:1.
public func attachFileConfined(
    workspaceRoot: String,
    sendFile: @Sendable (_ absPath: String, _ filename: String?) async throws -> String,
    requestedPath: String,
    filename: String? = nil
) async -> AttachFileResult {
    let root = realpathOrResolve(workspaceRoot)
    let joined: String
    if (requestedPath as NSString).isAbsolutePath {
        joined = requestedPath
    } else {
        joined = (root as NSString).appendingPathComponent(requestedPath)
    }
    let resolved = realpathOrResolve(joined)
    guard isWithin(root: root, child: resolved) else {
        return AttachFileResult(
            text: "Refused: \"\(requestedPath)\" is outside the session workspace and cannot be attached.",
            isError: true
        )
    }
    do {
        let result = try await sendFile(resolved, filename)
        return AttachFileResult(text: result)
    } catch {
        return AttachFileResult(
            text: "Failed to attach file: \(error.localizedDescription)",
            isError: true
        )
    }
}

/// Pure path-only confinement (no send). Returns resolved absolute path, or nil on escape.
/// Unit-test seam for path validation without a fake Discord sink.
public func resolveConfinedAttachPath(
    workspaceRoot: String,
    requestedPath: String
) -> String? {
    let root = realpathOrResolve(workspaceRoot)
    let joined: String
    if (requestedPath as NSString).isAbsolutePath {
        joined = requestedPath
    } else {
        joined = (root as NSString).appendingPathComponent(requestedPath)
    }
    let resolved = realpathOrResolve(joined)
    guard isWithin(root: root, child: resolved) else { return nil }
    return resolved
}

// MARK: - Process-wide reverse-RPC host

/// Discord-agnostic attach sink keyed by channel (wired once from `dab` at boot).
/// Absent → throw so reverse RPC returns internal (matches unwired sendFileFor throw in TS).
public actor FileAttachHost {
    public static let shared = FileAttachHost()

    public typealias AttachFn = @Sendable (
        _ channelId: String,
        _ path: String,
        _ name: String?
    ) async throws -> String

    private var attachFn: AttachFn?

    public init() {}

    public func setAttachHandler(_ fn: @escaping AttachFn) {
        attachFn = fn
    }

    /// Returns confirmation string for the model, or throws when unwired / send fails.
    public func attach(channelId: String, path: String, name: String?) async throws -> String {
        guard let attachFn else {
            throw FileAttachHostError.notWired
        }
        return try await attachFn(channelId, path, name)
    }
}

public enum FileAttachHostError: Error, Sendable, Equatable {
    case notWired
    case noSession
    case refused(String)
}

extension FileAttachHostError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .notWired:
            return "Channel is not wired; cannot send file."
        case .noSession:
            return "No active session for this channel."
        case .refused(let msg):
            return msg
        }
    }
}
