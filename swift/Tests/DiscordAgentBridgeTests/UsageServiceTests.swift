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
}
