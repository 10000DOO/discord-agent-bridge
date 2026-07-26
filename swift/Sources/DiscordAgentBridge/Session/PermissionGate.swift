import Foundation

/// A pending tool-permission ask surfaced to Discord (dab renders Allow / Always-Allow / Deny
/// buttons + matches the reply back via `reqKey`).
public struct PermissionPrompt: Sendable, Equatable {
    public var reqKey: String
    public var channelId: String
    public var toolName: String
    public var detail: String?
    public var approverId: String?

    public init(reqKey: String, channelId: String, toolName: String, detail: String? = nil, approverId: String? = nil) {
        self.reqKey = reqKey
        self.channelId = channelId
        self.toolName = toolName
        self.detail = detail
        self.approverId = approverId
    }
}

/// Discord-agnostic sink: the dab layer posts Allow / Always-Allow / Deny buttons for a prompt.
/// Lives on the gate so the library never imports DiscordBM.
public typealias PermissionPresenter = @Sendable (PermissionPrompt) async -> Void

/// Pure embed shape for the permission prompt + its post-decision re-render (TS embed literal in
/// `permissionButtons.ts:97-104,153-166`). dab converts this to a `DiscordBM.Embed` (same
/// library-Spec-struct → dab-converter pattern as `UpdateEmbedSpec`/`discordEmbed(from:)`).
public struct PermissionEmbedSpec: Sendable, Equatable {
    public var title: String
    public var description: String
    public var color: Int
    public init(title: String, description: String, color: Int) {
        self.title = title
        self.description = description
        self.color = color
    }
}

/// Button / resolve action. `always` allows the tool **and** signals the host to persist the tool
/// into the global auto-allow set (TS `perm:<reqId>:always` + `addAutoAllowClaudeTool`).
public enum PermissionDecision: String, Sendable, Equatable {
    case allow
    case always
    case deny

    /// Backend sessionPermission / approval behavior (`always` → allow for the current ask).
    public var backendBehavior: String { self == .deny ? "deny" : "allow" }

    /// Whether the tool may proceed (allow and always both grant).
    public var isAllowing: Bool { self != .deny }

    public var isAlways: Bool { self == .always }
}

/// Deny-by-default permission gate. A backend `await`s a decision keyed by `reqKey`; the Discord
/// layer `resolve`s it when the owner clicks a button. No sleep-based races: `await` suspends on a
/// continuation until `resolve` is called — no timeout (TS parity: an unanswered ask waits forever).
public actor PermissionGate {
    public static let shared = PermissionGate()

    private struct Pending {
        let continuation: CheckedContinuation<PermissionDecision, Never>
        let approverId: String?
        let toolName: String
    }
    private var pending: [String: Pending] = [:]
    private var presenter: PermissionPresenter?

    public init() {}

    /// Wire the button presenter once at startup (dab). Absent → prompts still register and just
    /// never resolve (no UI = no approval, no auto-deny either).
    public func setPresenter(_ presenter: @escaping PermissionPresenter) {
        self.presenter = presenter
    }

    /// The tool name of a still-pending request, or nil once resolved.
    /// Lets the host peek the tool for always-allow persistence **before** `resolve` removes the entry.
    public func peekToolName(_ reqKey: String) -> String? {
        pending[reqKey]?.toolName
    }

    /// Suspend until `resolve` settles this `reqKey`. No timeout — waits forever if unanswered.
    /// Registers BEFORE presenting so a fast button click can never race ahead of registration.
    public func await(prompt: PermissionPrompt) async -> PermissionDecision {
        let presenter = self.presenter
        return await withCheckedContinuation { (cont: CheckedContinuation<PermissionDecision, Never>) in
            pending[prompt.reqKey] = Pending(
                continuation: cont,
                approverId: prompt.approverId,
                toolName: prompt.toolName
            )
            if let presenter { Task { await presenter(prompt) } }
        }
    }

    /// Resolve a pending ask. Returns whether it was accepted: an unknown `reqKey` is a no-op
    /// (false); when `approverId` was set, a `byUserId` mismatch is ignored (false) so a bystander
    /// cannot answer. First valid resolve wins.
    ///
    /// `always` is accepted like `allow` for the waiting backend (via `backendBehavior`); the host
    /// persists the tool name (peeked before this call) into `autoAllowClaudeTools`.
    @discardableResult
    public func resolve(reqKey: String, action: PermissionDecision, byUserId: String? = nil) -> Bool {
        guard let entry = pending[reqKey] else { return false }
        // deny-by-default: only the named approver may decide. An ask with no approver (approverId
        // == nil) cannot be resolved by any click — it stays pending forever.
        guard let approver = entry.approverId, approver == byUserId else { return false }
        pending[reqKey] = nil
        entry.continuation.resume(returning: action)
        return true
    }

    /// Test hook (internal): number of awaits currently suspended. Lets tests observe registration
    /// without a sleep. Not part of the public API.
    func pendingCount() -> Int { pending.count }
}

// MARK: - Discord component custom_id (≤100 chars)

/// `perm:<reqKey>:<action>` — the button's custom_id, round-tripped by `parseCustomId`.
/// action ∈ allow | always | deny (TS permissionButtons).
public func buildCustomId(reqKey: String, action: PermissionDecision) -> String {
    "perm:\(reqKey):\(action.rawValue)"
}

/// Parse a `perm:<reqKey>:<action>` custom_id. Exactly 3 tokens with a known action, else nil.
public func parseCustomId(_ customId: String) -> (reqKey: String, action: PermissionDecision)? {
    let parts = customId.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 3, parts[0] == "perm",
          !parts[1].isEmpty, let action = PermissionDecision(rawValue: parts[2])
    else { return nil }
    return (parts[1], action)
}

// MARK: - Auto-allow lookup (host-side)

/// True when `toolName` is in the global `autoAllowClaudeTools` set. Missing/corrupt config → false
/// (fail-closed: still prompt). Used by bridges to skip the button when the tool is always-allowed.
public func isAutoAllowedClaudeTool(_ toolName: String, store: ConfigStore = .shared) async -> Bool {
    do {
        let cfg = try await store.load()
        return cfg.autoAllowClaudeTools.contains(toolName)
    } catch {
        return false
    }
}
