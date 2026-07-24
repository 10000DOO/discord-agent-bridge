/// Discord message content hard limit.
enum DiscordText {
    static let maxLen = 2000

    static func clip(_ s: String, limit: Int = maxLen) -> String {
        if s.count <= limit { return s }
        let idx = s.index(s.startIndex, offsetBy: max(0, limit - 1))
        return String(s[..<idx]) + "…"
    }
}
