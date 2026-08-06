import Foundation

// `/diff` — uncommitted changes in the session folder (docs/task-panel-and-diff-view.md WO-6).
// Pure parse/format only: running git and talking to Discord both live in dab.
//
// Two git outputs are merged because neither alone is enough: `status --porcelain` knows about
// untracked and deleted files, `diff --numstat` knows the line counts.

/// Discord caps a string select at 25 options.
public let diffSelectPageSize = 25

public enum GitChangeKind: String, Sendable, Equatable {
    case modified = "M"
    case added = "A"
    case deleted = "D"
    case renamed = "R"
    case untracked = "?"

    /// Untracked files have no counterpart in the index, so their body comes from a no-index diff.
    public var isUntracked: Bool { self == .untracked }
}

public struct GitChangedFile: Sendable, Equatable {
    public var path: String
    public var kind: GitChangeKind
    public var added: Int
    public var removed: Int

    public init(path: String, kind: GitChangeKind, added: Int = 0, removed: Int = 0) {
        self.path = path
        self.kind = kind
        self.added = added
        self.removed = removed
    }
}

/// Parse `git status --porcelain` (v1). Handles the two-letter status field, renames
/// (`R  old -> new`), untracked (`??`), and quoted paths with spaces.
public func parseGitStatusPorcelain(_ output: String) -> [GitChangedFile] {
    output.split(separator: "\n", omittingEmptySubsequences: true).compactMap { rawLine in
        let line = String(rawLine)
        guard line.count > 3 else { return nil }
        let statusField = String(line.prefix(2))
        var path = String(line.dropFirst(3))
        // Rename/copy reports both sides; the new path is the one that exists now.
        if let arrow = path.range(of: " -> ") {
            path = String(path[arrow.upperBound...])
        }
        path = unquoteGitPath(path)
        guard !path.isEmpty else { return nil }
        let kind: GitChangeKind
        if statusField == "??" {
            kind = .untracked
        } else {
            // Prefer the worktree column, falling back to the index column: a file staged as added
            // and then edited shows "AM", and "added" is the useful label.
            let worktree = statusField.dropFirst().first.map(String.init) ?? " "
            let index = statusField.first.map(String.init) ?? " "
            kind = GitChangeKind(rawValue: worktree == " " ? index : worktree)
                ?? GitChangeKind(rawValue: index)
                ?? .modified
        }
        return GitChangedFile(path: path, kind: kind)
    }
}

/// Parse `git diff --numstat`. Binary files report `-` for both counts and land as 0/0.
public func parseGitNumstat(_ output: String) -> [String: (added: Int, removed: Int)] {
    var result: [String: (added: Int, removed: Int)] = [:]
    for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
        let fields = rawLine.split(separator: "\t", omittingEmptySubsequences: false)
        guard fields.count >= 3 else { continue }
        var path = resolveNumstatRenamePath(String(fields[2]))
        path = unquoteGitPath(path)
        guard !path.isEmpty else { continue }
        let added = Int(fields[0]) ?? 0
        let removed = Int(fields[1]) ?? 0
        let previous = result[path] ?? (0, 0)
        result[path] = (previous.added + added, previous.removed + removed)
    }
    return result
}

/// Fold line counts into the status list. Status decides which files exist; numstat only enriches.
public func mergeChangedFiles(
    status: [GitChangedFile],
    numstat: [String: (added: Int, removed: Int)]
) -> [GitChangedFile] {
    status.map { file in
        guard let counts = numstat[file.path] else { return file }
        var merged = file
        merged.added = counts.added
        merged.removed = counts.removed
        return merged
    }
}

/// numstat reports a rename as `old => new`, or with the common part factored out as
/// `prefix{old => new}suffix`. Both must resolve to the path that exists now, or the file's line
/// counts never match the status entry and a renamed file shows as +0 −0.
func resolveNumstatRenamePath(_ raw: String) -> String {
    guard raw.contains(" => ") else { return raw }
    if let open = raw.firstIndex(of: "{"), let close = raw.firstIndex(of: "}"), open < close {
        let prefix = raw[raw.startIndex..<open]
        let inner = raw[raw.index(after: open)..<close]
        let suffix = raw[raw.index(after: close)...]
        let renamed = inner.components(separatedBy: " => ").last ?? String(inner)
        return prefix + renamed + suffix
    }
    return raw.components(separatedBy: " => ").last ?? raw
}

/// `"a b"` / `"a\"b"` → unquoted. git quotes paths containing spaces or specials in porcelain v1.
func unquoteGitPath(_ path: String) -> String {
    let trimmed = path.trimmingCharacters(in: .whitespaces)
    guard trimmed.count >= 2, trimmed.hasPrefix("\""), trimmed.hasSuffix("\"") else { return trimmed }
    return String(trimmed.dropFirst().dropLast())
        .replacingOccurrences(of: "\\\"", with: "\"")
        .replacingOccurrences(of: "\\\\", with: "\\")
}

// MARK: - Presentation

public struct DiffSummarySpec: Sendable, Equatable {
    public var title: String
    public var description: String
    public var footer: String

    public init(title: String, description: String, footer: String) {
        self.title = title
        self.description = description
        self.footer = footer
    }
}

/// Thread name for a `/diff` run (mirrors DocumentShare's `📄 <basename>` shape).
public func diffThreadName(fileCount: Int) -> String {
    DiscordText.truncate(I18n.t("diff.thread.name", ["n": "\(fileCount)"]), DiscordText.threadNameLimit)
}

/// Summary card: one line per file with its kind and line counts, aligned by padding the path.
public func formatDiffSummary(files: [GitChangedFile], repoName: String, branch: String?) -> DiffSummarySpec {
    let totalAdded = files.reduce(0) { $0 + $1.added }
    let totalRemoved = files.reduce(0) { $0 + $1.removed }
    let width = files.map(\.path.count).max() ?? 0
    let lines = files.map { file in
        let padded = file.path.padding(toLength: max(file.path.count, min(width, 48)), withPad: " ", startingAt: 0)
        return "\(file.kind.rawValue)  \(padded)  +\(file.added)  -\(file.removed)"
    }
    var footerParts = [repoName]
    if let branch, !branch.isEmpty { footerParts.append(branch) }
    footerParts.append(I18n.t("diff.footer.uncommitted"))
    return DiffSummarySpec(
        title: I18n.t("diff.summary.title", [
            "n": "\(files.count)",
            "added": "\(totalAdded)",
            "removed": "\(totalRemoved)",
        ]),
        description: DiscordText.truncate("```\n" + lines.joined(separator: "\n") + "\n```", streamEmbedDescLimit),
        footer: footerParts.joined(separator: " · ")
    )
}

/// Split the file list into select-menu pages of 25. Nothing is dropped — a longer list costs extra
/// messages, the same trade the Redmine issue picker makes.
public func diffFileSelectPages(files: [GitChangedFile], pageSize: Int = diffSelectPageSize) -> [[GitChangedFile]] {
    guard pageSize > 0, !files.isEmpty else { return [] }
    return stride(from: 0, to: files.count, by: pageSize).map {
        Array(files[$0..<min($0 + pageSize, files.count)])
    }
}

/// One file's diff, work-log shaped (`⎿ path · +n -m`) with the body in a ```diff``` fence.
/// Not clipped — `DiscordText.chunkMessage` splits an over-long body across messages (R7).
public func formatFileDiffBody(file: GitChangedFile, diff: String) -> String {
    let head = "⎿ \(file.path) · +\(file.added) -\(file.removed)"
    let trimmed = diff.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
        return "\(head)\n\(I18n.t("diff.file.empty"))"
    }
    // A diff body can itself contain a fence (a markdown file's own code block) — neutralize it so
    // it cannot terminate ours early.
    let safe = trimmed.replacingOccurrences(of: "```", with: "'''")
    return "\(head)\n```diff\n\(safe)\n```"
}
