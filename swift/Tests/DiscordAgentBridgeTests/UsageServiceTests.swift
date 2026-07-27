import Testing
import Foundation
@testable import DiscordAgentBridge

// MARK: - Mock HTTP

private final class MockUsageHTTP: UsageHTTPPerforming, @unchecked Sendable {
    struct Response {
        var status: Int
        var body: Data
    }

    private struct State {
        var queue: [(String, Response)] = []
        var requests: [URLRequest] = []
    }

    private let box = LockedBox(State())

    var requests: [URLRequest] { box.withLock { $0.requests } }

    func enqueue(urlContains: String, status: Int, json: Any) {
        let data = try! JSONSerialization.data(withJSONObject: json)
        box.withLock { $0.queue.append((urlContains, Response(status: status, body: data))) }
    }

    func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let item: Response = try box.withLock { state in
            state.requests.append(request)
            let url = request.url?.absoluteString ?? ""
            let idx = state.queue.firstIndex { url.contains($0.0) } ?? (state.queue.isEmpty ? nil : 0)
            guard let idx else { throw URLError(.badURL) }
            return state.queue.remove(at: idx).1
        }
        let http = HTTPURLResponse(
            url: request.url!,
            statusCode: item.status,
            httpVersion: nil,
            headerFields: nil
        )!
        return (item.body, http)
    }
}

private let accessToken = String(repeating: "A", count: 24)
private let refreshToken = String(repeating: "R", count: 24)
private let newAccessToken = String(repeating: "B", count: 24)

/// Mutable clock box so `@Sendable` nowMs closures can advance time in tests.
private final class ClockBox: @unchecked Sendable {
    var ms: Double
    init(_ ms: Double) { self.ms = ms }
}

private func usageBody(_ overrides: [String: Any] = [:]) -> [String: Any] {
    var body: [String: Any] = [
        "five_hour": ["utilization": 42, "resets_at": "2026-07-01T12:00:00Z"],
        "seven_day": ["utilization": 10, "resets_at": "2026-07-07T00:00:00Z"],
        "seven_day_opus": ["utilization": 55, "resets_at": NSNull()],
        "seven_day_sonnet": ["utilization": NSNull(), "resets_at": NSNull()],
    ]
    for (k, v) in overrides { body[k] = v }
    return body
}

private func writeCreds(path: String, expiresAt: Double) {
    let obj: [String: Any] = [
        "claudeAiOauth": [
            "accessToken": accessToken,
            "refreshToken": refreshToken,
            "expiresAt": expiresAt,
        ],
    ]
    let data = try! JSONSerialization.data(withJSONObject: obj)
    try! data.write(to: URL(fileURLWithPath: path))
}

@Suite("ClaudeUsageService")
struct ClaudeUsageServiceTests {
    @Test func parsesMockedUsageResponse() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dab-usage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let credsPath = dir.appendingPathComponent(".credentials.json").path
        let clock: Double = 1_000_000
        writeCreds(path: credsPath, expiresAt: clock + 3_600_000)

        let http = MockUsageHTTP()
        http.enqueue(urlContains: "oauth/usage", status: 200, json: usageBody())
        let svc = ClaudeUsageService(
            cacheSec: 15,
            http: http,
            credentialsPath: credsPath,
            readKeychain: { nil },
            nowMs: { clock },
            log: { _ in }
        )

        let result = await svc.getUsage()
        guard case .snapshot(let snap) = result else {
            Issue.record("expected snapshot")
            return
        }
        #expect(snap.fiveHour == UsageLimit(utilization: 42, resetsAt: "2026-07-01T12:00:00Z"))
        #expect(snap.sevenDay == UsageLimit(utilization: 10, resetsAt: "2026-07-07T00:00:00Z"))
        #expect(snap.sevenDayOpus == UsageLimit(utilization: 55))
        #expect(snap.sevenDaySonnet == nil)
        #expect(snap.fetchedAt == clock)
        #expect(http.requests.count == 1)
        #expect(http.requests[0].url?.absoluteString.contains("oauth/usage") == true)
    }

    @Test func sendsAuthAndBetaHeaders() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dab-usage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let credsPath = dir.appendingPathComponent(".credentials.json").path
        let clock: Double = 1_000_000
        writeCreds(path: credsPath, expiresAt: clock + 3_600_000)

        let http = MockUsageHTTP()
        http.enqueue(urlContains: "oauth/usage", status: 200, json: usageBody())
        let svc = ClaudeUsageService(
            userAgentVersion: "1.2.3",
            http: http,
            credentialsPath: credsPath,
            readKeychain: { nil },
            nowMs: { clock },
            log: { _ in }
        )
        _ = await svc.getUsage()
        let headers = http.requests[0].allHTTPHeaderFields ?? [:]
        #expect(headers["User-Agent"] == "claude-code/1.2.3")
        #expect(headers["anthropic-beta"] == "oauth-2025-04-20")
        #expect(headers["Authorization"] == "Bearer \(accessToken)")
    }

    @Test func servesCacheWithinTTL() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dab-usage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let credsPath = dir.appendingPathComponent(".credentials.json").path
        let clock = ClockBox(1_000_000)
        writeCreds(path: credsPath, expiresAt: clock.ms + 3_600_000)

        let http = MockUsageHTTP()
        http.enqueue(urlContains: "oauth/usage", status: 200, json: usageBody())
        http.enqueue(urlContains: "oauth/usage", status: 200, json: usageBody(["five_hour": ["utilization": 99]]))
        let svc = ClaudeUsageService(
            cacheSec: 180,
            http: http,
            credentialsPath: credsPath,
            readKeychain: { nil },
            nowMs: { clock.ms },
            log: { _ in }
        )
        _ = await svc.getUsage()
        clock.ms += 179_000
        let second = await svc.getUsage()
        #expect(http.requests.count == 1)
        if case .snapshot(let s) = second {
            #expect(s.fiveHour?.utilization == 42)
        } else {
            Issue.record("expected cache hit")
        }
        clock.ms += 2_000
        _ = await svc.getUsage()
        #expect(http.requests.count == 2)
    }

    @Test func noCredentialsUnavailable() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dab-usage-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let credsPath = dir.appendingPathComponent("missing.json").path
        let http = MockUsageHTTP()
        let svc = ClaudeUsageService(
            http: http,
            credentialsPath: credsPath,
            readKeychain: { nil },
            nowMs: { 1_000_000 },
            log: { _ in }
        )
        #expect(await svc.isAvailable() == false)
        let result = await svc.getUsage()
        #expect(result == .unavailable(UsageUnavailable(reason: .noCredentials)))
        #expect(http.requests.isEmpty)
    }

    @Test func refreshesExpiredToken() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dab-usage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let credsPath = dir.appendingPathComponent(".credentials.json").path
        let clock: Double = 1_000_000
        writeCreds(path: credsPath, expiresAt: clock - 1_000)

        let http = MockUsageHTTP()
        http.enqueue(urlContains: "oauth/token", status: 200, json: [
            "access_token": newAccessToken,
            "refresh_token": refreshToken,
            "expires_in": 3600,
        ])
        http.enqueue(urlContains: "oauth/usage", status: 200, json: usageBody())
        let svc = ClaudeUsageService(
            http: http,
            credentialsPath: credsPath,
            readKeychain: { nil },
            nowMs: { clock },
            log: { _ in }
        )
        let result = await svc.getUsage()
        #expect(result.isSnapshot)
        #expect(http.requests.count == 2)
        #expect(http.requests[0].url?.absoluteString.contains("oauth/token") == true)
        #expect(http.requests[1].allHTTPHeaderFields?["Authorization"] == "Bearer \(newAccessToken)")

        let persisted = try JSONSerialization.jsonObject(
            with: Data(contentsOf: URL(fileURLWithPath: credsPath))
        ) as! [String: Any]
        let oauth = persisted["claudeAiOauth"] as! [String: Any]
        #expect(oauth["accessToken"] as? String == newAccessToken)
    }

    @Test func keychainFallbackWhenFileAbsent() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dab-usage-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let credsPath = dir.appendingPathComponent("missing.json").path
        let clock: Double = 1_000_000
        let blob = """
        {"claudeAiOauth":{"accessToken":"\(accessToken)","refreshToken":"\(refreshToken)","expiresAt":\(clock + 3_600_000)}}
        """
        let http = MockUsageHTTP()
        http.enqueue(urlContains: "oauth/usage", status: 200, json: usageBody())
        let svc = ClaudeUsageService(
            http: http,
            credentialsPath: credsPath,
            readKeychain: { blob },
            nowMs: { clock },
            log: { _ in }
        )
        #expect(await svc.isAvailable() == true)
        let result = await svc.getUsage()
        #expect(result.isSnapshot)
    }

    @Test func codexUsageUnavailableHelper() {
        let r = codexUsageUnavailable()
        #expect(r == .unavailable(UsageUnavailable(reason: .codexUnsupported)))
    }

    @Test func neverThrowsOn429UsesCache() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dab-usage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let credsPath = dir.appendingPathComponent(".credentials.json").path
        let clock = ClockBox(1_000_000)
        writeCreds(path: credsPath, expiresAt: clock.ms + 3_600_000)

        let http = MockUsageHTTP()
        http.enqueue(urlContains: "oauth/usage", status: 200, json: usageBody())
        http.enqueue(urlContains: "oauth/usage", status: 429, json: [:])
        let svc = ClaudeUsageService(
            cacheSec: 180,
            http: http,
            credentialsPath: credsPath,
            readKeychain: { nil },
            nowMs: { clock.ms },
            log: { _ in }
        )
        _ = await svc.getUsage()
        clock.ms += 181_000
        let second = await svc.getUsage()
        if case .snapshot(let s) = second {
            #expect(s.fiveHour?.utilization == 42)
        } else {
            Issue.record("expected last-good cache on 429")
        }
    }

    // M3: parsing/schema failures must log a warning instead of silently swallowing (TS
    // `usageService.ts:302,307`), even though the public contract still never throws.

    @Test func logsWarningOnInvalidJSONCredentials() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dab-usage-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let credsPath = dir.appendingPathComponent(".credentials.json").path
        try! "not valid json {{{".write(toFile: credsPath, atomically: true, encoding: .utf8)

        let logBox = LockedBox<[String]>([])
        let svc = ClaudeUsageService(
            http: MockUsageHTTP(),
            credentialsPath: credsPath,
            readKeychain: { nil },
            nowMs: { 1_000_000 },
            log: { msg in logBox.withLock { $0.append(msg) } }
        )
        #expect(await svc.getUsage() == .unavailable(UsageUnavailable(reason: .noCredentials)))
        let lines = logBox.withLock { $0 }
        #expect(lines.contains { $0.contains("not valid JSON") })
    }

    @Test func logsWarningOnUnexpectedCredentialsShape() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dab-usage-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let credsPath = dir.appendingPathComponent(".credentials.json").path
        // Valid JSON, but missing the required accessToken/refreshToken fields.
        try! #"{"claudeAiOauth":{"expiresAt":1}}"#.write(toFile: credsPath, atomically: true, encoding: .utf8)

        let logBox = LockedBox<[String]>([])
        let svc = ClaudeUsageService(
            http: MockUsageHTTP(),
            credentialsPath: credsPath,
            readKeychain: { nil },
            nowMs: { 1_000_000 },
            log: { msg in logBox.withLock { $0.append(msg) } }
        )
        #expect(await svc.getUsage() == .unavailable(UsageUnavailable(reason: .noCredentials)))
        let lines = logBox.withLock { $0 }
        #expect(lines.contains { $0.contains("unexpected shape") })
    }
}

// MARK: - GrokUsageService

private let grokAccessToken = String(repeating: "G", count: 24)

private func writeGrokAuth(path: String, key: String = grokAccessToken) {
    let obj: [String: Any] = ["account1": ["key": key]]
    let data = try! JSONSerialization.data(withJSONObject: obj)
    try! data.write(to: URL(fileURLWithPath: path))
}

@Test func grokAuthUsesFirstValidAccountInFileOrder() {
    let data = Data("{\"disabled\":{\"key\":\"\"},\"chosen\":{\"key\":\"FIRST\"},\"later\":{\"key\":\"SECOND\"}}".utf8)
    #expect(firstGrokAccessToken(in: data) == "FIRST")
}

private func billingBody(_ overrides: [String: Any] = [:]) -> [String: Any] {
    var config: [String: Any] = [
        "currentPeriod": [
            "type": "USAGE_PERIOD_TYPE_WEEKLY",
            "start": "2026-07-14T00:00:00Z",
            "end": "2026-07-21T00:00:00Z",
        ],
        "creditUsagePercent": 6.0,
        "productUsage": [
            ["product": "GrokBuild", "usagePercent": 3.0],
            ["product": "GrokChat", "usagePercent": 3.0],
        ],
        "billingPeriodEnd": "2026-08-01T00:00:00Z",
    ]
    for (k, v) in overrides { config[k] = v }
    return ["config": config]
}

@Suite("GrokUsageService")
struct GrokUsageServiceTests {
    @Test func mapsCreditUsagePercentToSevenDay() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dab-grok-usage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let authPath = dir.appendingPathComponent("auth.json").path
        writeGrokAuth(path: authPath)
        let clock: Double = 1_000_000

        let http = MockUsageHTTP()
        http.enqueue(urlContains: "billing", status: 200, json: billingBody())
        let svc = GrokUsageService(
            cacheSec: 15,
            http: http,
            authPath: authPath,
            nowMs: { clock },
            log: { _ in }
        )

        let result = await svc.getUsage()
        guard case .snapshot(let snap) = result else {
            Issue.record("expected snapshot")
            return
        }
        // Prefer total creditUsagePercent (6) over productUsage GrokBuild (3).
        #expect(snap.sevenDay == UsageLimit(utilization: 6.0, resetsAt: "2026-07-21T00:00:00Z"))
        #expect(snap.fiveHour == nil)
        #expect(snap.sevenDayOpus == nil)
        #expect(snap.sevenDaySonnet == nil)
        #expect(snap.fetchedAt == clock)
        #expect(http.requests.count == 1)
        let headers = http.requests[0].allHTTPHeaderFields ?? [:]
        #expect(headers["Authorization"] == "Bearer \(grokAccessToken)")
        #expect(headers["Accept"] == "application/json")
        #expect(headers["x-grok-client-mode"] == "cli")
        #expect(http.requests[0].url?.absoluteString.contains("billing?format=credits") == true)
    }

    @Test func fallsBackToGrokBuildProductUsage() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dab-grok-usage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let authPath = dir.appendingPathComponent("auth.json").path
        writeGrokAuth(path: authPath)

        let http = MockUsageHTTP()
        http.enqueue(urlContains: "billing", status: 200, json: billingBody([
            "productUsage": [["product": "GrokBuild", "usagePercent": 12.5]],
            "creditUsagePercent": NSNull(),
        ]))
        let svc = GrokUsageService(
            http: http,
            authPath: authPath,
            nowMs: { 1_000_000 },
            log: { _ in }
        )
        let result = await svc.getUsage()
        if case .snapshot(let snap) = result {
            #expect(snap.sevenDay?.utilization == 12.5)
        } else {
            Issue.record("expected snapshot from GrokBuild fallback")
        }
    }

    @Test func fallsBackToBillingPeriodEnd() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dab-grok-usage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let authPath = dir.appendingPathComponent("auth.json").path
        writeGrokAuth(path: authPath)

        let http = MockUsageHTTP()
        http.enqueue(urlContains: "billing", status: 200, json: billingBody([
            "currentPeriod": [
                "type": "USAGE_PERIOD_TYPE_WEEKLY",
                "start": "2026-07-14T00:00:00Z",
            ],
            "billingPeriodEnd": "2026-08-01T00:00:00Z",
        ]))
        let svc = GrokUsageService(
            http: http,
            authPath: authPath,
            nowMs: { 1_000_000 },
            log: { _ in }
        )
        let result = await svc.getUsage()
        if case .snapshot(let snap) = result {
            #expect(snap.sevenDay?.resetsAt == "2026-08-01T00:00:00Z")
        } else {
            Issue.record("expected billingPeriodEnd fallback")
        }
    }

    @Test func missingAuthUnavailable() async {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dab-grok-usage-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let authPath = dir.appendingPathComponent("missing.json").path
        let http = MockUsageHTTP()
        let svc = GrokUsageService(
            http: http,
            authPath: authPath,
            nowMs: { 1_000_000 },
            log: { _ in }
        )
        #expect(await svc.isAvailable() == false)
        #expect(await svc.getUsage() == .unavailable(UsageUnavailable(reason: .noCredentials)))
        #expect(http.requests.isEmpty)
    }

    @Test func emptyKeyUnavailable() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dab-grok-usage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let authPath = dir.appendingPathComponent("auth.json").path
        writeGrokAuth(path: authPath, key: "")

        let svc = GrokUsageService(
            http: MockUsageHTTP(),
            authPath: authPath,
            nowMs: { 1_000_000 },
            log: { _ in }
        )
        #expect(await svc.isAvailable() == false)
        #expect(await svc.getUsage() == .unavailable(UsageUnavailable(reason: .noCredentials)))
    }

    @Test func servesCacheWithinTTL() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dab-grok-usage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let authPath = dir.appendingPathComponent("auth.json").path
        writeGrokAuth(path: authPath)
        let clock = ClockBox(1_000_000)

        let http = MockUsageHTTP()
        http.enqueue(urlContains: "billing", status: 200, json: billingBody(["creditUsagePercent": 1.0]))
        http.enqueue(urlContains: "billing", status: 200, json: billingBody(["creditUsagePercent": 9.0]))
        let svc = GrokUsageService(
            cacheSec: 15,
            http: http,
            authPath: authPath,
            nowMs: { clock.ms },
            log: { _ in }
        )
        let first = await svc.getUsage()
        if case .snapshot(let s) = first { #expect(s.sevenDay?.utilization == 1.0) }
        else { Issue.record("first fetch failed") }
        #expect(http.requests.count == 1)

        clock.ms += 5_000
        let second = await svc.getUsage()
        if case .snapshot(let s) = second { #expect(s.sevenDay?.utilization == 1.0) }
        #expect(http.requests.count == 1)

        clock.ms += 11_000
        let third = await svc.getUsage()
        if case .snapshot(let s) = third { #expect(s.sevenDay?.utilization == 9.0) }
        #expect(http.requests.count == 2)
    }

    @Test func nonOKReturnsLastCache() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dab-grok-usage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let authPath = dir.appendingPathComponent("auth.json").path
        writeGrokAuth(path: authPath)
        let clock = ClockBox(1_000_000)

        let http = MockUsageHTTP()
        http.enqueue(urlContains: "billing", status: 200, json: billingBody())
        http.enqueue(urlContains: "billing", status: 500, json: ["error": "boom"])
        let svc = GrokUsageService(
            cacheSec: 0,
            http: http,
            authPath: authPath,
            nowMs: { clock.ms },
            log: { _ in }
        )
        let first = await svc.getUsage()
        clock.ms += 1
        let second = await svc.getUsage()
        #expect(first == second)
        if case .snapshot(let s) = second {
            #expect(s.sevenDay?.utilization == 6.0)
        } else {
            Issue.record("expected last-good cache")
        }
    }

    @Test func status401SoftFailsWithoutCache() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dab-grok-usage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let authPath = dir.appendingPathComponent("auth.json").path
        writeGrokAuth(path: authPath)

        let logBox = LockedBox<[String]>([])
        let http = MockUsageHTTP()
        http.enqueue(urlContains: "billing", status: 401, json: ["error": "unauthorized"])
        let svc = GrokUsageService(
            http: http,
            authPath: authPath,
            nowMs: { 1_000_000 },
            log: { msg in logBox.withLock { $0.append(msg) } }
        )
        #expect(await svc.getUsage() == .unavailable(UsageUnavailable(reason: .noCredentials)))
        let lines = logBox.withLock { $0 }
        #expect(lines.contains { $0.contains("401") })
        #expect(!lines.joined(separator: "\n").contains(grokAccessToken))
    }

    @Test func missingPercentUnavailable() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dab-grok-usage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let authPath = dir.appendingPathComponent("auth.json").path
        writeGrokAuth(path: authPath)

        let http = MockUsageHTTP()
        http.enqueue(urlContains: "billing", status: 200, json: [
            "config": [
                "productUsage": [["product": "GrokChat", "usagePercent": NSNull()]],
                "creditUsagePercent": NSNull(),
            ],
        ] as [String: Any])
        let svc = GrokUsageService(
            http: http,
            authPath: authPath,
            nowMs: { 1_000_000 },
            log: { _ in }
        )
        #expect(await svc.getUsage() == .unavailable(UsageUnavailable(reason: .noCredentials)))
    }
}

// MARK: - CodexUsageService (G-P1-09)

/// Build a rateLimits payload like app-server `account/rateLimits/read`.
private func codexRateLimitsBody(
    primaryUsed: Double = 42,
    primaryMins: Double = 10080,
    primaryResets: Double? = 1_800_000_000,
    secondaryUsed: Double? = 10,
    secondaryMins: Double? = 300,
    secondaryResets: Double? = 1_700_000_000,
    wrapInRateLimits: Bool = true
) -> JSONValue {
    var snap: [String: JSONValue] = [
        "primary": .object([
            "usedPercent": .number(primaryUsed),
            "windowDurationMins": .number(primaryMins),
        ].merging(primaryResets.map { ["resetsAt": .number($0)] } ?? [:]) { _, n in n }),
    ]
    if let secondaryUsed {
        var sec: [String: JSONValue] = [
            "usedPercent": .number(secondaryUsed),
        ]
        if let secondaryMins { sec["windowDurationMins"] = .number(secondaryMins) }
        if let secondaryResets { sec["resetsAt"] = .number(secondaryResets) }
        snap["secondary"] = .object(sec)
    }
    if wrapInRateLimits {
        return .object(["rateLimits": .object(snap)])
    }
    return .object(snap)
}

@Suite("CodexUsageService")
struct CodexUsageServiceTests {
    @Test func mapsPrimaryWeeklyAndSecondaryFiveHour() async {
        let clock: Double = 1_000_000
        let raw = codexRateLimitsBody(
            primaryUsed: 55,
            primaryMins: 10080,
            primaryResets: 1_800_000_000,
            secondaryUsed: 12,
            secondaryMins: 300,
            secondaryResets: 1_700_000_000
        )
        let svc = CodexUsageService(
            cacheSec: 15,
            requestRateLimits: { raw },
            nowMs: { clock },
            log: { _ in }
        )
        let result = await svc.getUsage()
        guard case .snapshot(let snap) = result else {
            Issue.record("expected snapshot")
            return
        }
        #expect(snap.sevenDay?.utilization == 55)
        #expect(snap.fiveHour?.utilization == 12)
        #expect(snap.sevenDay?.resetsAt == ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_800_000_000)))
        #expect(snap.fiveHour?.resetsAt == ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_700_000_000)))
        #expect(snap.fetchedAt == clock)
        #expect(await svc.isAvailable() == true)
    }

    @Test func acceptsUnwrappedSnapshotShape() async {
        let raw = codexRateLimitsBody(
            primaryUsed: 7,
            primaryMins: 10080,
            primaryResets: nil,
            secondaryUsed: nil,
            wrapInRateLimits: false
        )
        let svc = CodexUsageService(
            requestRateLimits: { raw },
            nowMs: { 2_000_000 },
            log: { _ in }
        )
        let result = await svc.getUsage()
        if case .snapshot(let snap) = result {
            #expect(snap.sevenDay?.utilization == 7)
            #expect(snap.fiveHour == nil)
            #expect(snap.sevenDay?.resetsAt == nil)
        } else {
            Issue.record("expected snapshot from unwrapped payload")
        }
    }

    @Test func shortWindowAloneBecomesFiveHour() async {
        let raw = codexRateLimitsBody(
            primaryUsed: 33,
            primaryMins: 300,
            primaryResets: nil,
            secondaryUsed: nil
        )
        let svc = CodexUsageService(
            requestRateLimits: { raw },
            nowMs: { 1 },
            log: { _ in }
        )
        let result = await svc.getUsage()
        if case .snapshot(let snap) = result {
            #expect(snap.fiveHour?.utilization == 33)
            #expect(snap.sevenDay == nil)
        } else {
            Issue.record("expected fiveHour-only snapshot")
        }
    }

    @Test func emptyOrBadShapeUnavailable() async {
        let svc = CodexUsageService(
            requestRateLimits: { .object([:]) },
            nowMs: { 1 },
            log: { _ in }
        )
        #expect(await svc.getUsage() == .unavailable(UsageUnavailable(reason: .noCredentials)))
    }

    @Test func fetchErrorSoftFailsToNoCredentials() async {
        struct Boom: Error {}
        let logBox = LockedBox<[String]>([])
        let svc = CodexUsageService(
            requestRateLimits: { throw Boom() },
            nowMs: { 1 },
            log: { msg in logBox.withLock { $0.append(msg) } }
        )
        #expect(await svc.getUsage() == .unavailable(UsageUnavailable(reason: .noCredentials)))
        let lines = logBox.withLock { $0 }
        #expect(lines.contains { $0.contains("rateLimits") })
    }

    @Test func servesCacheWithinTTL() async {
        let clock = ClockBox(1_000_000)
        let callCount = LockedBox(0)
        let svc = CodexUsageService(
            cacheSec: 15,
            requestRateLimits: {
                let n = callCount.withLock { c -> Int in
                    c += 1
                    return c
                }
                return codexRateLimitsBody(primaryUsed: Double(n * 10), secondaryUsed: nil)
            },
            nowMs: { clock.ms },
            log: { _ in }
        )
        let first = await svc.getUsage()
        if case .snapshot(let s) = first { #expect(s.sevenDay?.utilization == 10) }
        else { Issue.record("first fetch failed") }

        clock.ms += 5_000
        let second = await svc.getUsage()
        if case .snapshot(let s) = second { #expect(s.sevenDay?.utilization == 10) }
        #expect(callCount.withLock { $0 } == 1)

        clock.ms += 11_000
        let third = await svc.getUsage()
        if case .snapshot(let s) = third { #expect(s.sevenDay?.utilization == 20) }
        #expect(callCount.withLock { $0 } == 2)
    }

    @Test func returnsLastCacheOnSubsequentFailure() async {
        let clock = ClockBox(1_000_000)
        let callCount = LockedBox(0)
        struct Boom: Error {}
        let svc = CodexUsageService(
            cacheSec: 0,
            requestRateLimits: {
                let n = callCount.withLock { c -> Int in
                    c += 1
                    return c
                }
                if n == 1 {
                    return codexRateLimitsBody(primaryUsed: 9, secondaryUsed: nil)
                }
                throw Boom()
            },
            nowMs: { clock.ms },
            log: { _ in }
        )
        let first = await svc.getUsage()
        clock.ms += 1
        let second = await svc.getUsage()
        #expect(first == second)
        if case .snapshot(let s) = second {
            #expect(s.sevenDay?.utilization == 9)
        } else {
            Issue.record("expected last-good cache")
        }
    }

    // C1 (usage part): `.shared` starts on nil/nil defaults; `configure` is the only way
    // to move a live singleton off them (WO-7 wires real config values in). Verifies the
    // call actually rewires the request path — not merely accepted and ignored — by
    // pointing at a codexCommand that cannot exist and observing the resulting failure.
    @Test func configureRewiresCodexHomeAndCommand() async {
        let logBox = LockedBox<[String]>([])
        let svc = CodexUsageService(
            cacheSec: 0,
            nowMs: { 1 },
            log: { msg in logBox.withLock { $0.append(msg) } }
        )
        let bogusCommand = "/definitely/not/a/real/codex-\(UUID().uuidString)"
        await svc.configure(codexHome: "/tmp/dab-codex-usage-test", codexCommand: bogusCommand)
        let result = await svc.getUsage()
        #expect(result == .unavailable(UsageUnavailable(reason: .noCredentials)))
        let lines = logBox.withLock { $0 }
        #expect(lines.contains { $0.contains("rateLimits") })
    }

    @Test func pureMapperHelpers() {
        let nested = codexRateLimitsBody(primaryUsed: 1, primaryMins: 10080, secondaryUsed: 2, secondaryMins: 60)
        let snap = codexRateLimitsToSnapshot(nested, fetchedAt: 99)
        #expect(snap?.sevenDay?.utilization == 1)
        #expect(snap?.fiveHour?.utilization == 2)
        #expect(snap?.fetchedAt == 99)

        #expect(codexRateLimitsToSnapshot(.null, fetchedAt: 0) == nil)
        #expect(codexRateLimitsToSnapshot(.object(["primary": .string("x")]), fetchedAt: 0) == nil)
    }
}
