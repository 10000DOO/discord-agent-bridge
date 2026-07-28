import Foundation

/// Shared issue filter for the 5-minute poller and `/redmine-issue-select` (WO-5, 3-3 D5).
/// Status matching always applies; the "since" (last-checked) time condition is optional —
/// `nil` means no time condition at all (the dropdown path, R9), not "everything after epoch 0".
///
/// Assignee filtering (`assigned_to_id=me`) is intentionally NOT redone here — Redmine already
/// resolves that server-side from the API key (3-3 D3), so re-filtering it here would duplicate
/// logic that belongs to `RedmineClient`'s query.
public enum RedmineIssueFilter {
    public static func match(
        issues: [RedmineIssueDTO],
        resolvedStatusIds: Set<Int>,
        since: Int?
    ) -> [RedmineIssueDTO] {
        issues.filter { issue in
            guard resolvedStatusIds.contains(issue.statusId) else { return false }
            guard let since else { return true }
            guard let createdAt = parseEpochMs(issue.createdOn) else { return false }
            return createdAt > since
        }
    }

    private static func parseEpochMs(_ iso8601: String) -> Int? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = formatter.date(from: iso8601)
        if date == nil {
            formatter.formatOptions = [.withInternetDateTime]
            date = formatter.date(from: iso8601)
        }
        guard let date else { return nil }
        return Int(date.timeIntervalSince1970 * 1000)
    }
}
