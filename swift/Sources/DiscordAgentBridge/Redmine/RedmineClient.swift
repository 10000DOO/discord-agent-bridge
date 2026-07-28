import Foundation

/// Redmine REST API client (WO-3) — issues + statuses only. No retry/cache (caller's job,
/// e.g. `RedminePoller`). Auth via `X-Redmine-API-Key` header, never a URL query param
/// (avoids leaking the key into logs/proxies).

public struct RedmineIssueDTO: Sendable, Equatable {
    public var id: Int
    public var subject: String
    public var description: String
    public var projectName: String
    public var projectId: Int
    public var statusId: Int
    public var fixedVersionName: String?
    /// Raw `created_on` as returned by Redmine (ISO8601); parsing is the caller's job (WO-5).
    public var createdOn: String
    public var url: String

    public init(
        id: Int,
        subject: String,
        description: String,
        projectName: String,
        projectId: Int,
        statusId: Int,
        fixedVersionName: String? = nil,
        createdOn: String,
        url: String
    ) {
        self.id = id
        self.subject = subject
        self.description = description
        self.projectName = projectName
        self.projectId = projectId
        self.statusId = statusId
        self.fixedVersionName = fixedVersionName
        self.createdOn = createdOn
        self.url = url
    }
}

public struct RedmineStatusDTO: Sendable, Equatable {
    public var id: Int
    public var name: String

    public init(id: Int, name: String) {
        self.id = id
        self.name = name
    }
}

public enum RedmineClientError: Error, CustomStringConvertible, Equatable {
    case invalidURL
    case httpError(status: Int)
    case invalidResponse

    public var description: String {
        switch self {
        case .invalidURL:
            return "Redmine request URL is invalid"
        case .httpError(let status):
            return "Redmine API returned HTTP \(status)"
        case .invalidResponse:
            return "Redmine API response was not valid JSON in the expected shape"
        }
    }
}

public struct RedmineClient: Sendable {
    private let http: any UsageHTTPPerforming

    public init(http: any UsageHTTPPerforming = URLSessionUsageHTTP()) {
        self.http = http
    }

    public func fetchIssues(
        baseURL: String,
        apiKey: String,
        projectId: String?
    ) async throws -> [RedmineIssueDTO] {
        var urlString = "\(baseURL)/issues.json?assigned_to_id=me&status_id=open&limit=100"
        if let projectId {
            urlString += "&project_id=\(projectId)"
        }
        let (data, response) = try await perform(urlString: urlString, apiKey: apiKey)
        guard (200..<300).contains(response.statusCode) else {
            throw RedmineClientError.httpError(status: response.statusCode)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawIssues = obj["issues"] as? [[String: Any]]
        else {
            throw RedmineClientError.invalidResponse
        }
        return try rawIssues.map { try issueDTO(from: $0, baseURL: baseURL) }
    }

    public func fetchStatuses(baseURL: String, apiKey: String) async throws -> [RedmineStatusDTO] {
        let urlString = "\(baseURL)/issue_statuses.json"
        let (data, response) = try await perform(urlString: urlString, apiKey: apiKey)
        guard (200..<300).contains(response.statusCode) else {
            throw RedmineClientError.httpError(status: response.statusCode)
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawStatuses = obj["issue_statuses"] as? [[String: Any]]
        else {
            throw RedmineClientError.invalidResponse
        }
        return try rawStatuses.map { try statusDTO(from: $0) }
    }

    private func perform(urlString: String, apiKey: String) async throws -> (Data, HTTPURLResponse) {
        guard let url = URL(string: urlString) else {
            throw RedmineClientError.invalidURL
        }
        var request = URLRequest(url: url)
        request.setValue(apiKey, forHTTPHeaderField: "X-Redmine-API-Key")
        return try await http.perform(request)
    }

    private func issueDTO(from raw: [String: Any], baseURL: String) throws -> RedmineIssueDTO {
        guard let id = raw["id"] as? Int,
              let subject = raw["subject"] as? String,
              let description = raw["description"] as? String,
              let status = raw["status"] as? [String: Any],
              let statusId = status["id"] as? Int,
              let project = raw["project"] as? [String: Any],
              let projectId = project["id"] as? Int,
              let projectName = project["name"] as? String,
              let createdOn = raw["created_on"] as? String
        else {
            throw RedmineClientError.invalidResponse
        }
        let fixedVersionName = (raw["fixed_version"] as? [String: Any])?["name"] as? String
        return RedmineIssueDTO(
            id: id,
            subject: subject,
            description: description,
            projectName: projectName,
            projectId: projectId,
            statusId: statusId,
            fixedVersionName: fixedVersionName,
            createdOn: createdOn,
            url: "\(baseURL)/issues/\(id)"
        )
    }

    private func statusDTO(from raw: [String: Any]) throws -> RedmineStatusDTO {
        guard let id = raw["id"] as? Int, let name = raw["name"] as? String else {
            throw RedmineClientError.invalidResponse
        }
        return RedmineStatusDTO(id: id, name: name)
    }
}
