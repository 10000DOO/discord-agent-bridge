import DiscordAgentBridge
import DiscordBM
import Foundation

private let log = Logger(name: "discord-pacer")

/// Discord enforces ~50 HTTP requests/second per bot, and DiscordBM mirrors that number locally so
/// it can refuse a request instead of earning a real 429 (real 429s count toward Discord's
/// invalid-request budget, which ends in a Cloudflare IP ban — `HTTPRateLimiter.swift:109-118`
/// guards against exactly that). The catch: that local refusal throws `DiscordHTTPError.rateLimited`
/// *before* any retry policy is consulted (`DefaultDiscordClient.checkRateLimitsAllowRequest`,
/// `case .false`), so whatever the caller was sending is simply lost.
///
/// That bit us on 2026-08-10 09:19:41 — a finished Grok turn's answer hit the ceiling and
/// `deliverAnswer` dropped it (`~/.dab/logs/agent.err.log`: 16 × "Hit HTTP Global rate-limit" in
/// one second, then `turn-delivery: deliverAnswer failed … rateLimited`). The burst was ordinary:
/// a turn end fires ~10 writes back to back (answer chunks, cost footer, rate-limit line, mention,
/// usage panel, status notification, reaction swap, control-message finalize) while every other
/// live channel keeps its 5s stream heartbeat going.
///
/// `DiscordPacer` hands out send slots `interval` apart so the burst is spread under the ceiling
/// instead of crashing into it. Slot assignment is synchronous inside the actor, so callers keep
/// their arrival order; only the waiting is concurrent.
///
/// Deliberate ceiling: one global queue, no per-channel fairness. The budget being paced *is*
/// global, and at 20/s a full turn-end burst drains in ~0.5s, so a channel can at worst wait out
/// the other channels ahead of it. Per-channel fairness only becomes worth its complexity if
/// sustained load ever pushes that wait past a few seconds.
actor DiscordPacer {
    static let shared = DiscordPacer()

    /// 20/s against a ceiling DiscordBM effectively enforces at ~25/s (see `bootRateLimitTuning`).
    static let defaultInterval: Duration = .milliseconds(50)

    private let interval: Duration
    private var nextSlot: ContinuousClock.Instant?

    init(interval: Duration = DiscordPacer.defaultInterval) {
        self.interval = interval
    }

    /// Claim this caller's slot and wait for it. Returns once the request may go out.
    func acquire() async {
        let wait = reserve(now: ContinuousClock.now)
        if wait > .zero {
            try? await Task.sleep(for: wait, clock: .continuous)
        }
    }

    /// Slot assignment, split out so it is testable without waiting: advances the queue by one
    /// `interval` and reports how long this caller must hold. An idle stretch collapses the queue
    /// back to `now`, so a quiet bot never pays for slots nobody used.
    func reserve(now: ContinuousClock.Instant) -> Duration {
        let slot = max(now, nextSlot ?? now)
        nextSlot = slot.advanced(by: interval)
        return now.duration(to: slot)
    }
}

/// Every DiscordBM convenience call (`createMessage`, `updateMessage`, reactions, file uploads, …)
/// funnels into these three protocol requirements, so pacing here covers all of them without
/// touching a single call site. Wired once in `DabMain` — `bot.client` must not be used directly
/// after that point.
struct PacedDiscordClient: DiscordClient {
    let inner: any DiscordClient

    var appId: ApplicationSnowflake? { inner.appId }

    /// Interaction responses/followups are the endpoints Discord itself exempts from the global
    /// limit (`APIEndpoint.countsAgainstGlobalRateLimit` → false), and they are exactly the ones
    /// with the ~3s ack deadline. Pacing them would risk trading a lost answer for an expired
    /// interaction token, so they skip the queue — they cost nothing against the budget anyway.
    private func pace(_ request: DiscordHTTPRequest) async {
        guard request.endpoint.countsAgainstGlobalRateLimit else { return }
        await DiscordPacer.shared.acquire()
    }

    func send(request: DiscordHTTPRequest) async throws -> DiscordHTTPResponse {
        await pace(request)
        return try await inner.send(request: request)
    }

    func send<E: Sendable & Encodable & ValidatablePayload>(request: DiscordHTTPRequest, payload: E) async throws -> DiscordHTTPResponse {
        await pace(request)
        return try await inner.send(request: request, payload: payload)
    }

    func sendMultipart<E: Sendable & MultipartEncodable & ValidatablePayload>(request: DiscordHTTPRequest, payload: E) async throws -> DiscordHTTPResponse {
        await pace(request)
        return try await inner.sendMultipart(request: request, payload: payload)
    }
}

/// DiscordBM counts one request twice against its global-per-second budget: `shouldRequest(to:)`
/// increments in `globalRateLimitAllows()` and then again in `addGlobalRateLimitRecord()` once the
/// endpoint's bucket is known (`HTTPRateLimiter.swift:139,179`). The configured 50 therefore
/// behaves as ~25/s. Raising it to 100 restores the intended 50 — this is bug compensation, not a
/// limit increase, and must go back to 50 if DiscordBM fixes the double count. `DiscordPacer` is
/// what actually keeps us under the real ceiling; this only widens the safety margin.
func bootRateLimitTuning() {
    DiscordGlobalConfiguration.globalRateLimit = 100
    log.info("rate limits: pacer \(DiscordPacer.defaultInterval) per request, globalRateLimit=100 (DiscordBM double-count compensation)")
}
