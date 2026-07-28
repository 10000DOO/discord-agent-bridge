import Foundation

/// Resolves Redmine status names to numeric status IDs dynamically per instance (WO-4, 3-3 D2).
/// Status IDs vary across Redmine installations, so IDs are never hardcoded — callers pass
/// candidate names (see `newStatusNames`/`inProgressStatusNames`) and get back the IDs that
/// actually exist on this instance right now.
///
/// Matching is case-insensitive and accepts bilingual labels like `신규(New)` / `진행(Doing)`
/// used by some Redmine installs (exact equality alone would miss those).
///
/// Shared by `/redmine-issue-select` and the 5-minute poller — change status policy only here.
public enum RedmineStatusResolver {
    /// 신규 | New
    public static let newStatusNames = ["신규", "New"]
    /// 진행 | Doing
    public static let inProgressStatusNames = ["진행", "Doing"]

    /// Full target list for both slash select and poller: 신규 | New | 진행 | Doing.
    public static var targetStatusNames: [String] {
        newStatusNames + inProgressStatusNames
    }

    /// Resolve status IDs for the shared target list (신규/New/진행/Doing + bilingual forms).
    public static func resolveTargetIds(statuses: [RedmineStatusDTO]) -> Set<Int> {
        resolveIds(statuses: statuses, names: targetStatusNames)
    }

    public static func resolveIds(statuses: [RedmineStatusDTO], names: [String]) -> Set<Int> {
        Set(statuses.filter { status in
            names.contains { name(status.name, matches: $0) }
        }.map(\.id))
    }

    /// - equality: `신규` / `New` / `진행` / `Doing`
    /// - prefix `c(` / `c `: `신규(New)`, `진행(Doing)`
    /// - parenthetical `(c)`: `신규(New)` matched by candidate `New`
    static func name(_ statusName: String, matches candidate: String) -> Bool {
        let n = statusName.lowercased()
        let c = candidate.lowercased()
        return n == c
            || n.hasPrefix(c + "(")
            || n.hasPrefix(c + " ")
            || n.contains("(" + c + ")")
    }
}
