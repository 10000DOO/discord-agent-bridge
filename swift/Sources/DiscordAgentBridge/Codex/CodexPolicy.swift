import Foundation

/// Map a session permission mode (Claude PermMode OR Codex-native sandbox mode) onto the Codex
/// app-server `thread/start` params. 1:1 port of src/modes/codex/policy.ts:15-46.
public struct CodexThreadPolicy: Sendable, Equatable {
    public var approvalPolicy: String   // "never" | "on-request"
    public var sandbox: String
}

private let codexSandboxModes: Set<String> = ["read-only", "workspace-write", "danger-full-access"]

public func resolveThreadPolicy(permMode: String) -> CodexThreadPolicy {
    // Codex-native sandbox vocabulary (policy.ts:15-27).
    if codexSandboxModes.contains(permMode) {
        switch permMode {
        case "read-only":           return .init(approvalPolicy: "on-request", sandbox: "read-only")
        case "danger-full-access":  return .init(approvalPolicy: "never", sandbox: "danger-full-access")
        case "workspace-write":     return .init(approvalPolicy: "on-request", sandbox: "workspace-write")
        default:                    return .init(approvalPolicy: "on-request", sandbox: permMode)
        }
    }
    // Claude PermMode vocabulary (policy.ts:29-40).
    switch permMode {
    case "acceptEdits":        return .init(approvalPolicy: "never", sandbox: "workspace-write")
    case "bypassPermissions":  return .init(approvalPolicy: "never", sandbox: "danger-full-access")
    case "plan":               return .init(approvalPolicy: "on-request", sandbox: "read-only")
    case "default":            return .init(approvalPolicy: "on-request", sandbox: "workspace-write")
    default:                   return .init(approvalPolicy: "on-request", sandbox: "workspace-write")
    }
}

/// True when the policy auto-approves (no Discord Allow/Deny needed). policy.ts:43-45.
public func isAutoApprovePolicy(_ policy: CodexThreadPolicy) -> Bool {
    policy.approvalPolicy == "never"
}
