import Foundation

/// `channelId` → Redmine issue id for a "신규 세션" wizard opened from the Redmine session-pick
/// dropdown, kept only until the wizard's completion block picks it back up (redmine-issue-session-start.md
/// WO-3). Mirrors `PresetDraftRegistry` (`Session/ChannelWizard.swift:912-932`) but stays volatile —
/// no `SessionStore` disk persistence, since this state only matters while the wizard is in flight
/// (3-3 D9 already accepts the `channelId`-only key's cross-request collision risk, so there is no
/// reason to survive a restart either).
public actor PendingRedmineStartRegistry {
    public static let shared = PendingRedmineStartRegistry()

    private var pending: [String: Int] = [:]

    public init() {}

    public func put(_ issueId: Int, channelId: String) {
        pending[channelId] = issueId
    }

    public func get(channelId: String) -> Int? {
        pending[channelId]
    }

    public func remove(channelId: String) {
        pending.removeValue(forKey: channelId)
    }
}
