import Foundation

// C14: finite-retry engine for a Discord send-like call. Mirrors TS `wiring.ts`'s
// attachWithRetry budget/backoff (5 attempts, 300/600/1200/2400ms exponential backoff,
// stopping early on a confirmed-permanent failure) — but TS applies that at a separate
// "attach" (channel resolve) stage that Swift has no equivalent of, so the same
// gone-vs-transient split is applied at the point of sending instead (see C14/H26 in
// swift-port-parity-gaps.md). Kept DiscordBM-free so it's testable from
// DiscordAgentBridgeTests; the `dab` target supplies the actual `createMessage` call and
// its Unknown-Channel (10003) classification.

/// Outcome of ONE send attempt, as classified by the caller. Carries the successful value
/// (e.g. the Discord response) so `sendWithRetry` never needs a mutable capture across the
/// `@Sendable` attempt closure.
public enum SendAttemptResult<Success: Sendable>: Sendable {
    case success(Success)
    /// The target is confirmed permanently gone (Discord 10003) — stop retrying now.
    case gone
    /// Any other failure (network hiccup, rate limit, 5xx, decode error, ...) — retry.
    case transientFailure
}

/// Outcome of the whole retry run.
public enum SendRetryOutcome<Success: Sendable>: Sendable {
    case sent(Success)
    case gone
    case unavailable
}

extension SendRetryOutcome: Equatable where Success: Equatable {}

/// TS `MAX_ATTACH_ATTEMPTS` / `ATTACH_RETRY_DELAYS_MS` (wiring.ts).
public let sendRetryMaxAttempts = 5
public let sendRetryDelaysMs: [Int] = [300, 600, 1200, 2400]

/// Retries `attempt` up to `maxAttempts` times with exponential backoff between attempts,
/// stopping immediately (no further delay) on `.success`/`.gone`. `sleep` is injectable so
/// tests never wait on the real backoff (mirrors TS `SessionWiringDeps.sleep`).
public func sendWithRetry<Success: Sendable>(
    maxAttempts: Int = sendRetryMaxAttempts,
    delaysMs: [Int] = sendRetryDelaysMs,
    sleep: @Sendable (UInt64) async -> Void = { ns in try? await Task.sleep(nanoseconds: ns) },
    attempt: @Sendable () async -> SendAttemptResult<Success>
) async -> SendRetryOutcome<Success> {
    for i in 0..<maxAttempts {
        switch await attempt() {
        case .success(let value): return .sent(value)
        case .gone: return .gone
        case .transientFailure: break
        }
        if i < delaysMs.count {
            await sleep(UInt64(delaysMs[i]) * 1_000_000)
        }
    }
    return .unavailable
}
