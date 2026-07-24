import Foundation

/// A pending tool-permission ask surfaced to Discord (dab renders Allow/Deny buttons + matches the
/// reply back via `reqKey`).
public struct PermissionPrompt: Sendable, Equatable {
    public var reqKey: String
    public var toolName: String
    public var detail: String?
    public var approverId: String?

    public init(reqKey: String, toolName: String, detail: String? = nil, approverId: String? = nil) {
        self.reqKey = reqKey
        self.toolName = toolName
        self.detail = detail
        self.approverId = approverId
    }
}

public enum PermissionDecision: String, Sendable, Equatable {
    case allow
    case deny
}

/// Deny-by-default permission gate. A backend `await`s a decision keyed by `reqKey`; the Discord
/// layer `resolve`s it when the owner clicks a button. No sleep-based races: `await` suspends on a
/// continuation and a timeout Task settles it as `.deny` if unanswered.
public actor PermissionGate {
    public static let shared = PermissionGate()

    private struct Pending {
        let continuation: CheckedContinuation<PermissionDecision, Never>
        let approverId: String?
        let timeoutTask: Task<Void, Never>
    }
    private var pending: [String: Pending] = [:]

    public init() {}

    /// Suspend until `resolve` (or the timeout) settles this `reqKey`. Deny-by-default on timeout.
    public func await(prompt: PermissionPrompt, timeoutNs: UInt64) async -> PermissionDecision {
        await withCheckedContinuation { (cont: CheckedContinuation<PermissionDecision, Never>) in
            let key = prompt.reqKey
            let timeoutTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: timeoutNs)
                guard !Task.isCancelled else { return }
                await self?.settle(reqKey: key, decision: .deny)
            }
            pending[key] = Pending(continuation: cont, approverId: prompt.approverId, timeoutTask: timeoutTask)
        }
    }

    /// Resolve a pending ask. Returns whether it was accepted: an unknown `reqKey` is a no-op
    /// (false); when `approverId` was set, a `byUserId` mismatch is ignored (false) so a bystander
    /// cannot answer. First valid resolve wins.
    @discardableResult
    public func resolve(reqKey: String, action: PermissionDecision, byUserId: String? = nil) -> Bool {
        guard let entry = pending[reqKey] else { return false }
        if let approver = entry.approverId, approver != byUserId { return false }
        settleEntry(reqKey: reqKey, entry: entry, decision: action)
        return true
    }

    /// Test hook (internal): number of awaits currently suspended. Lets tests observe registration
    /// without a sleep. Not part of the public API.
    func pendingCount() -> Int { pending.count }

    private func settle(reqKey: String, decision: PermissionDecision) {
        guard let entry = pending[reqKey] else { return }
        settleEntry(reqKey: reqKey, entry: entry, decision: decision)
    }

    private func settleEntry(reqKey: String, entry: Pending, decision: PermissionDecision) {
        pending[reqKey] = nil
        entry.timeoutTask.cancel()
        entry.continuation.resume(returning: decision)
    }
}

// MARK: - Discord component custom_id (≤100 chars)

/// `perm:<reqKey>:<action>` — the button's custom_id, round-tripped by `parseCustomId`.
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
