/// Discord message content hard limit + format helpers (TS `src/discord/format.ts`).
///
/// Lengths match JS `String.length` / Discord's limit: **UTF-16 code units**, not
/// Swift `Character` (extended grapheme) count.
public enum DiscordText {
    public static let maxLen = 2000
    /// Discord thread name hard cap (TS `THREAD_NAME_LIMIT`).
    public static let threadNameLimit = 100

    public static func clip(_ s: String, limit: Int = maxLen) -> String {
        if utf16Len(s) <= limit { return s }
        // TS: text.slice(0, max - 1) + '…'  (slice is UTF-16)
        return utf16Slice(s, 0, max(0, limit - 1)) + "…"
    }

    /// TS `truncate` — alias of `clip` (embed previews / thread names).
    public static func truncate(_ text: String, _ max: Int) -> String {
        clip(text, limit: max)
    }

    /// Split text into Discord-message-sized chunks (TS `chunkMessage`).
    /// Prefers newline breaks; when ` ``` ` is present, balances fences across chunk
    /// boundaries (close + reopen). Fence-free long text rejoins content-identical.
    /// Empty input → `[]`; non-empty never yields an empty array.
    public static func chunkMessage(_ text: String, limit: Int = maxLen) -> [String] {
        if text.isEmpty { return [] }
        if utf16Len(text) <= limit { return [text] }
        let fenced = text.contains("```")
        var chunks: [String] = []
        var rest = text
        var carryFence = false
        while !rest.isEmpty {
            let prefix = carryFence ? "```\n" : ""
            // Reserve room for the reopening prefix and a possible closing ``` so a finished
            // chunk (markers included) never exceeds the limit. Fence-free text reserves
            // nothing, so its output is identical to the plain newline split.
            // prefix / "\n```" are BMP-only → Character count == UTF-16 length.
            let budget = limit - utf16Len(prefix) - (fenced ? 4 : 0)
            let raw: String
            if utf16Len(rest) <= budget {
                raw = rest
                rest = ""
            } else {
                // Prefer the last newline within the budget; fall back to a hard cut.
                // `nl > 0` in TS: do not break on a leading newline alone.
                let window = utf16Slice(rest, 0, max(0, budget))
                if let nl = window.lastIndex(of: "\n"), nl > window.startIndex {
                    let cut = utf16Len(String(window[window.startIndex..<nl]))
                    raw = utf16Slice(rest, 0, cut)
                    rest = utf16Slice(rest, cut, utf16Len(rest))
                    if rest.first == "\n" { rest = String(rest.dropFirst()) }
                } else {
                    raw = window
                    rest = utf16Slice(rest, max(0, budget), utf16Len(rest))
                    if rest.first == "\n" { rest = String(rest.dropFirst()) }
                }
            }
            let fenceCount = countTripleBackticks(raw)
            let endsOpen = ((carryFence ? 1 : 0) + fenceCount) % 2 == 1
            chunks.append(prefix + raw + (endsOpen ? "\n```" : ""))
            carryFence = endsOpen
        }
        return chunks
    }

    // MARK: - UTF-16 (JS String.length) helpers

    /// JS `String.length` — UTF-16 code unit count.
    public static func utf16Len(_ s: String) -> Int { s.utf16.count }

    /// JS `s.slice(start, end)` on UTF-16 code units. Clamps; rounds down if `n` lands mid-scalar.
    private static func utf16Slice(_ s: String, _ start: Int, _ end: Int) -> String {
        let len = utf16Len(s)
        let lo = min(max(0, start), len)
        let hi = min(max(lo, end), len)
        if lo == 0 && hi == len { return s }
        if lo == hi { return "" }
        let from = indexByUTF16(s, lo)
        let to = indexByUTF16(s, hi)
        return String(s[from..<to])
    }

    /// String index after `n` UTF-16 code units (clamped). If `n` lands mid-surrogate pair,
    /// steps back one unit so the result is a valid Unicode scalar boundary (JS can emit a
    /// lone surrogate; Discord JSON needs well-formed UTF-8 — only difference vs TS).
    private static func indexByUTF16(_ s: String, _ n: Int) -> String.Index {
        let u = s.utf16
        guard n > 0 else { return s.startIndex }
        guard n < u.count else { return s.endIndex }
        let ui = u.index(u.startIndex, offsetBy: n)
        if let si = String.Index(ui, within: s) { return si }
        if ui > u.startIndex {
            let prev = u.index(before: ui)
            if let si = String.Index(prev, within: s) { return si }
        }
        return s.startIndex
    }

    /// Non-overlapping count of ` ``` ` substrings (TS `raw.match(/```/g)?.length`).
    private static func countTripleBackticks(_ s: String) -> Int {
        var count = 0
        var search = s[s.startIndex...]
        while let range = search.range(of: "```") {
            count += 1
            search = search[range.upperBound...]
        }
        return count
    }
}
