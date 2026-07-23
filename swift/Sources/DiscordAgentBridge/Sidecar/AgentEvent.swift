import Foundation

/// Agent stream events — kind names fixed by CLAUDE_SIDECAR_PROTOCOL.md / contracts.ts.
public enum AgentEvent: Codable, Sendable, Equatable {
    case text(text: String, delta: Bool)
    case thinking(text: String, delta: Bool)
    case toolUse(id: String, name: String, input: JSONValue, parentToolUseId: String?)
    case toolResult(id: String, ok: Bool, content: String, parentToolUseId: String?)
    case permissionRequest(id: String, toolName: String, input: JSONValue)
    case progress(label: String, detail: String?)
    case result(
        text: String?,
        costUsd: Double?,
        tokensIn: Int?,
        tokensOut: Int?,
        durationMs: Int?
    )
    case contextUsage(
        totalTokens: Int,
        maxTokens: Int,
        percentage: Double,
        model: String?,
        modelDisplayName: String?,
        clearableTokens: Int?,
        memoryFileCount: Int?,
        mcpServerCount: Int?
    )
    case subagentResult(
        taskId: String,
        status: SubagentStatus,
        summary: String,
        toolUseId: String?,
        durationMs: Int?,
        toolUses: Int?
    )
    case error(message: String, retryable: Bool)
    case rateLimit(resetAt: String?, rateLimitType: String?, utilization: Double?)

    public enum SubagentStatus: String, Codable, Sendable, Equatable {
        case completed
        case failed
        case stopped
    }

    public var kind: String {
        switch self {
        case .text: return "text"
        case .thinking: return "thinking"
        case .toolUse: return "tool_use"
        case .toolResult: return "tool_result"
        case .permissionRequest: return "permission_request"
        case .progress: return "progress"
        case .result: return "result"
        case .contextUsage: return "context_usage"
        case .subagentResult: return "subagent_result"
        case .error: return "error"
        case .rateLimit: return "rate_limit"
        }
    }

    private enum CodingKeys: String, CodingKey {
        case kind, text, delta, id, name, input, parentToolUseId
        case ok, content, toolName, label, detail
        case costUsd, tokensIn, tokensOut, durationMs
        case totalTokens, maxTokens, percentage, model, modelDisplayName
        case clearableTokens, memoryFileCount, mcpServerCount
        case taskId, status, summary, toolUseId, toolUses
        case message, retryable, resetAt, rateLimitType, utilization
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try c.decode(String.self, forKey: .kind)
        switch kind {
        case "text":
            self = .text(
                text: try c.decode(String.self, forKey: .text),
                delta: try c.decode(Bool.self, forKey: .delta)
            )
        case "thinking":
            self = .thinking(
                text: try c.decode(String.self, forKey: .text),
                delta: try c.decode(Bool.self, forKey: .delta)
            )
        case "tool_use":
            self = .toolUse(
                id: try c.decode(String.self, forKey: .id),
                name: try c.decode(String.self, forKey: .name),
                input: try c.decodeIfPresent(JSONValue.self, forKey: .input) ?? .null,
                parentToolUseId: try c.decodeIfPresent(String.self, forKey: .parentToolUseId)
            )
        case "tool_result":
            self = .toolResult(
                id: try c.decode(String.self, forKey: .id),
                ok: try c.decode(Bool.self, forKey: .ok),
                content: try c.decode(String.self, forKey: .content),
                parentToolUseId: try c.decodeIfPresent(String.self, forKey: .parentToolUseId)
            )
        case "permission_request":
            self = .permissionRequest(
                id: try c.decode(String.self, forKey: .id),
                toolName: try c.decode(String.self, forKey: .toolName),
                input: try c.decodeIfPresent(JSONValue.self, forKey: .input) ?? .null
            )
        case "progress":
            self = .progress(
                label: try c.decode(String.self, forKey: .label),
                detail: try c.decodeIfPresent(String.self, forKey: .detail)
            )
        case "result":
            self = .result(
                text: try c.decodeIfPresent(String.self, forKey: .text),
                costUsd: try c.decodeIfPresent(Double.self, forKey: .costUsd),
                tokensIn: try c.decodeIfPresent(Int.self, forKey: .tokensIn),
                tokensOut: try c.decodeIfPresent(Int.self, forKey: .tokensOut),
                durationMs: try c.decodeIfPresent(Int.self, forKey: .durationMs)
            )
        case "context_usage":
            self = .contextUsage(
                totalTokens: try c.decode(Int.self, forKey: .totalTokens),
                maxTokens: try c.decode(Int.self, forKey: .maxTokens),
                percentage: try c.decode(Double.self, forKey: .percentage),
                model: try c.decodeIfPresent(String.self, forKey: .model),
                modelDisplayName: try c.decodeIfPresent(String.self, forKey: .modelDisplayName),
                clearableTokens: try c.decodeIfPresent(Int.self, forKey: .clearableTokens),
                memoryFileCount: try c.decodeIfPresent(Int.self, forKey: .memoryFileCount),
                mcpServerCount: try c.decodeIfPresent(Int.self, forKey: .mcpServerCount)
            )
        case "subagent_result":
            self = .subagentResult(
                taskId: try c.decode(String.self, forKey: .taskId),
                status: try c.decode(SubagentStatus.self, forKey: .status),
                summary: try c.decode(String.self, forKey: .summary),
                toolUseId: try c.decodeIfPresent(String.self, forKey: .toolUseId),
                durationMs: try c.decodeIfPresent(Int.self, forKey: .durationMs),
                toolUses: try c.decodeIfPresent(Int.self, forKey: .toolUses)
            )
        case "error":
            self = .error(
                message: try c.decode(String.self, forKey: .message),
                retryable: try c.decode(Bool.self, forKey: .retryable)
            )
        case "rate_limit":
            self = .rateLimit(
                resetAt: try c.decodeIfPresent(String.self, forKey: .resetAt),
                rateLimitType: try c.decodeIfPresent(String.self, forKey: .rateLimitType),
                utilization: try c.decodeIfPresent(Double.self, forKey: .utilization)
            )
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: c,
                debugDescription: "unknown AgentEvent kind: \(kind)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        switch self {
        case .text(let text, let delta):
            try c.encode(text, forKey: .text)
            try c.encode(delta, forKey: .delta)
        case .thinking(let text, let delta):
            try c.encode(text, forKey: .text)
            try c.encode(delta, forKey: .delta)
        case .toolUse(let id, let name, let input, let parent):
            try c.encode(id, forKey: .id)
            try c.encode(name, forKey: .name)
            try c.encode(input, forKey: .input)
            try c.encodeIfPresent(parent, forKey: .parentToolUseId)
        case .toolResult(let id, let ok, let content, let parent):
            try c.encode(id, forKey: .id)
            try c.encode(ok, forKey: .ok)
            try c.encode(content, forKey: .content)
            try c.encodeIfPresent(parent, forKey: .parentToolUseId)
        case .permissionRequest(let id, let toolName, let input):
            try c.encode(id, forKey: .id)
            try c.encode(toolName, forKey: .toolName)
            try c.encode(input, forKey: .input)
        case .progress(let label, let detail):
            try c.encode(label, forKey: .label)
            try c.encodeIfPresent(detail, forKey: .detail)
        case .result(let text, let costUsd, let tokensIn, let tokensOut, let durationMs):
            try c.encodeIfPresent(text, forKey: .text)
            try c.encodeIfPresent(costUsd, forKey: .costUsd)
            try c.encodeIfPresent(tokensIn, forKey: .tokensIn)
            try c.encodeIfPresent(tokensOut, forKey: .tokensOut)
            try c.encodeIfPresent(durationMs, forKey: .durationMs)
        case .contextUsage(
            let total, let max, let pct, let model, let display,
            let clearable, let memCount, let mcpCount
        ):
            try c.encode(total, forKey: .totalTokens)
            try c.encode(max, forKey: .maxTokens)
            try c.encode(pct, forKey: .percentage)
            try c.encodeIfPresent(model, forKey: .model)
            try c.encodeIfPresent(display, forKey: .modelDisplayName)
            try c.encodeIfPresent(clearable, forKey: .clearableTokens)
            try c.encodeIfPresent(memCount, forKey: .memoryFileCount)
            try c.encodeIfPresent(mcpCount, forKey: .mcpServerCount)
        case .subagentResult(let taskId, let status, let summary, let toolUseId, let durationMs, let toolUses):
            try c.encode(taskId, forKey: .taskId)
            try c.encode(status, forKey: .status)
            try c.encode(summary, forKey: .summary)
            try c.encodeIfPresent(toolUseId, forKey: .toolUseId)
            try c.encodeIfPresent(durationMs, forKey: .durationMs)
            try c.encodeIfPresent(toolUses, forKey: .toolUses)
        case .error(let message, let retryable):
            try c.encode(message, forKey: .message)
            try c.encode(retryable, forKey: .retryable)
        case .rateLimit(let resetAt, let rateLimitType, let utilization):
            try c.encodeIfPresent(resetAt, forKey: .resetAt)
            try c.encodeIfPresent(rateLimitType, forKey: .rateLimitType)
            try c.encodeIfPresent(utilization, forKey: .utilization)
        }
    }
}
