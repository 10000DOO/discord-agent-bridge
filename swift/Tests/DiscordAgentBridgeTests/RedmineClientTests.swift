import Testing
import Foundation
@testable import DiscordAgentBridge

// MARK: - Mock HTTP (mirrors UsageServiceTests.swift's MockUsageHTTP)

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

private func issueJSON(
    id: Int = 1,
    subject: String = "Something broke",
    description: String = "Steps to reproduce...",
    projectId: Int = 10,
    projectName: String = "Sample Project",
    statusId: Int = 1,
    fixedVersionName: String? = "v1.0",
    createdOn: String = "2026-07-28T00:00:00Z"
) -> [String: Any] {
    var fixedVersion: Any = NSNull()
    if let fixedVersionName {
        fixedVersion = ["id": 5, "name": fixedVersionName]
    }
    return [
        "id": id,
        "subject": subject,
        "description": description,
        "project": ["id": projectId, "name": projectName],
        "status": ["id": statusId, "name": "New"],
        "fixed_version": fixedVersion,
        "created_on": createdOn,
    ]
}

@Suite("RedmineClient")
struct RedmineClientTests {
    @Test func fetchIssuesMapsToDTOs() async throws {
        let http = MockUsageHTTP()
        http.enqueue(urlContains: "issues.json", status: 200, json: ["issues": [issueJSON()]])
        let client = RedmineClient(http: http)

        let issues = try await client.fetchIssues(
            baseURL: "https://redmine.example.com",
            apiKey: "test-key",
            projectId: nil
        )

        #expect(issues.count == 1)
        let issue = issues[0]
        #expect(issue.id == 1)
        #expect(issue.subject == "Something broke")
        #expect(issue.description == "Steps to reproduce...")
        #expect(issue.projectId == 10)
        #expect(issue.projectName == "Sample Project")
        #expect(issue.statusId == 1)
        #expect(issue.fixedVersionName == "v1.0")
        #expect(issue.createdOn == "2026-07-28T00:00:00Z")
        #expect(issue.url == "https://redmine.example.com/issues/1")
    }

    @Test func fetchIssuesTreatsMissingFixedVersionAsNil() async throws {
        let http = MockUsageHTTP()
        http.enqueue(urlContains: "issues.json", status: 200, json: ["issues": [issueJSON(fixedVersionName: nil)]])
        let client = RedmineClient(http: http)

        let issues = try await client.fetchIssues(
            baseURL: "https://redmine.example.com",
            apiKey: "test-key",
            projectId: nil
        )

        #expect(issues[0].fixedVersionName == nil)
    }

    @Test func fetchIssuesOmitsProjectIdQueryWhenNil() async throws {
        let http = MockUsageHTTP()
        http.enqueue(urlContains: "issues.json", status: 200, json: ["issues": []])
        let client = RedmineClient(http: http)

        _ = try await client.fetchIssues(baseURL: "https://redmine.example.com", apiKey: "test-key", projectId: nil)

        let url = http.requests[0].url?.absoluteString ?? ""
        #expect(!url.contains("project_id"))
    }

    @Test func fetchIssuesIncludesProjectIdQueryWhenPresent() async throws {
        let http = MockUsageHTTP()
        http.enqueue(urlContains: "issues.json", status: 200, json: ["issues": []])
        let client = RedmineClient(http: http)

        _ = try await client.fetchIssues(baseURL: "https://redmine.example.com", apiKey: "test-key", projectId: "42")

        let url = http.requests[0].url?.absoluteString ?? ""
        #expect(url.contains("project_id=42"))
    }

    @Test func fetchIssuesSendsApiKeyHeaderNotQuery() async throws {
        let http = MockUsageHTTP()
        http.enqueue(urlContains: "issues.json", status: 200, json: ["issues": []])
        let client = RedmineClient(http: http)

        _ = try await client.fetchIssues(baseURL: "https://redmine.example.com", apiKey: "secret-key", projectId: nil)

        let request = http.requests[0]
        #expect(request.allHTTPHeaderFields?["X-Redmine-API-Key"] == "secret-key")
        #expect(request.url?.absoluteString.contains("secret-key") == false)
    }

    @Test func fetchIssuesThrowsOnHttpError() async throws {
        let http = MockUsageHTTP()
        http.enqueue(urlContains: "issues.json", status: 500, json: [:])
        let client = RedmineClient(http: http)

        await #expect(throws: RedmineClientError.self) {
            _ = try await client.fetchIssues(baseURL: "https://redmine.example.com", apiKey: "test-key", projectId: nil)
        }
    }

    @Test func fetchStatusesMapsToDTOs() async throws {
        let http = MockUsageHTTP()
        http.enqueue(
            urlContains: "issue_statuses.json",
            status: 200,
            json: ["issue_statuses": [["id": 1, "name": "New"], ["id": 2, "name": "In Progress"]]]
        )
        let client = RedmineClient(http: http)

        let statuses = try await client.fetchStatuses(baseURL: "https://redmine.example.com", apiKey: "test-key")

        #expect(statuses == [RedmineStatusDTO(id: 1, name: "New"), RedmineStatusDTO(id: 2, name: "In Progress")])
    }

    @Test func fetchStatusesSendsApiKeyHeader() async throws {
        let http = MockUsageHTTP()
        http.enqueue(urlContains: "issue_statuses.json", status: 200, json: ["issue_statuses": []])
        let client = RedmineClient(http: http)

        _ = try await client.fetchStatuses(baseURL: "https://redmine.example.com", apiKey: "secret-key")

        #expect(http.requests[0].allHTTPHeaderFields?["X-Redmine-API-Key"] == "secret-key")
    }
}
