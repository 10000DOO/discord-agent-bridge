import Foundation

/// Splits a matched issue list into Discord select-menu-sized chunks (WO-13b, 9장 Q6). Discord's
/// string select menu caps `options` at 25 — when the matched-issue count exceeds that, callers
/// must post one dropdown per chunk instead of silently truncating (R9 — 사용자가 명시적으로 거부한
/// "25개로 잘라서 나머지를 버리는" 방식 금지, every matched issue must stay selectable somewhere).
public enum RedmineIssueChunker {
    public static let maxOptionsPerMenu = 25

    public static func chunk<T>(_ items: [T], size: Int = maxOptionsPerMenu) -> [[T]] {
        guard !items.isEmpty else { return [] }
        guard size > 0 else { return [items] }
        return stride(from: 0, to: items.count, by: size).map {
            Array(items[$0..<min($0 + size, items.count)])
        }
    }
}
