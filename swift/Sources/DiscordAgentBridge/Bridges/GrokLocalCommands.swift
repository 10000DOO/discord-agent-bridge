import Foundation

// MARK: - Grok's terminal-only command screens

/// Grok handles the commands it advertises itself, and most of them answer over ACP in full
/// (`/session-info` returns session id, cwd, model and context as ordinary text). `/context` is the
/// exception: its screen is drawn by the TUI and NOTHING comes back over ACP, so the turn used to
/// land in Discord as the empty-answer stand-in `(no text)`.
///
/// The facts that screen shows are the same ones the usage panel already computes for every grok
/// turn, so it is rebuilt here rather than left blank. Laid out like the terminal's own screen, in a
/// code fence, matching the Claude sidecar's rebuilt screens (`localCommands.ts`).
///
/// Returns nil for anything else — an ordinary turn that simply produced no text must keep its
/// existing stand-in, not get a context screen it never asked for.
public func grokLocalCommandScreen(prompt: String, model: String, totalTokens: Int?, maxTokens: Int?) -> String? {
    // `/command` submits "/name\n<prompt>" (slashRunPromptText), so only the first line names it.
    let first = prompt.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? prompt
    guard first.trimmingCharacters(in: .whitespaces) == "/context" else { return nil }
    var rows = ["  Model      \(model)"]
    if let totalTokens, let maxTokens, maxTokens > 0 {
        let pct = Int((Double(totalTokens) / Double(maxTokens) * 100).rounded())
        rows.append("  Context    \(grokTokenCount(totalTokens)) / \(grokTokenCount(maxTokens)) (\(pct)%)")
    }
    return (["```", "Context Usage", ""] + rows + ["```"]).joined(separator: "\n")
}

/// 9411 → '9.4k', 500000 → '500k'. Same formatting as the Claude screens.
private func grokTokenCount(_ n: Int) -> String {
    guard n >= 1000 else { return String(n) }
    let k = (Double(n) / 1000 * 10).rounded() / 10
    return k == k.rounded() ? "\(Int(k))k" : "\(k)k"
}
