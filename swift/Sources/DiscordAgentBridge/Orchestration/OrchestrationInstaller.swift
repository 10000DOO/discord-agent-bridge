import Foundation

/// Home roots for global agent tooling. Injectable for tests.
public struct OrchestrationHomes: Sendable, Equatable {
    public var claude: URL
    public var codex: URL
    public var grok: URL

    public init(claude: URL, codex: URL, grok: URL) {
        self.claude = claude
        self.codex = codex
        self.grok = grok
    }

    /// Default: `~/.claude`, `~/.codex`, `~/.grok` (creates nothing until install).
    public static func standard(fileManager: FileManager = .default) -> OrchestrationHomes {
        let home = fileManager.homeDirectoryForCurrentUser
        return OrchestrationHomes(
            claude: home.appendingPathComponent(".claude", isDirectory: true),
            codex: home.appendingPathComponent(".codex", isDirectory: true),
            grok: home.appendingPathComponent(".grok", isDirectory: true)
        )
    }
}

public struct OrchestrationInstallReport: Sendable, Equatable {
    public var removedPaths: [String]
    public var writtenPaths: [String]
    public var errors: [String]

    public init(removedPaths: [String] = [], writtenPaths: [String] = [], errors: [String] = []) {
        self.removedPaths = removedPaths
        self.writtenPaths = writtenPaths
        self.errors = errors
    }

    public var summaryMarkdown: String {
        var lines: [String] = ["**오케스트레이션 설치 결과**", ""]
        if !removedPaths.isEmpty {
            lines.append("### 삭제 후 재작성 (\(removedPaths.count))")
            for p in removedPaths.sorted() {
                lines.append("- `\(p)`")
            }
            lines.append("")
        }
        if !writtenPaths.isEmpty {
            lines.append("### 기록 (\(writtenPaths.count))")
            for p in writtenPaths.sorted() {
                lines.append("- `\(p)`")
            }
            lines.append("")
        }
        if !errors.isEmpty {
            lines.append("### 오류")
            for e in errors {
                lines.append("- \(e)")
            }
            lines.append("")
        }
        if writtenPaths.isEmpty, removedPaths.isEmpty, errors.isEmpty {
            lines.append("_변경 없음_")
        }
        lines.append("재설치 시: 마커 블록·해당 스킬/서브 디렉터리·파일을 지운 뒤 다시 씁니다.")
        lines.append("Claude: `CLAUDE.md` + `skills/` + `agents/`")
        lines.append("Codex: `AGENTS.md` + `skills/` + `agents/*.toml`")
        lines.append("Grok: `AGENTS.md` + `skills/` + `agents/` (홈 없으면 생성)")
        return lines.joined(separator: "\n")
    }
}

/// Installs global orchestration rules, skills, and subagents for Claude / Codex / Grok.
/// Re-run policy: if our block/skill/agent already exists, **delete then recreate**.
public enum OrchestrationInstaller {
    /// Remove marked block if present, then append a fresh block at the end (preserves all other content).
    public static func replaceMarkedBlock(
        existing: String?,
        body: String,
        begin: String = OrchestrationBundle.markerBegin,
        end: String = OrchestrationBundle.markerEnd
    ) -> (text: String, removedExistingBlock: Bool) {
        let block = "\(begin)\n\n\(body.trimmingCharacters(in: .whitespacesAndNewlines))\n\n\(end)\n"
        guard let existing, !existing.isEmpty else {
            return (block, false)
        }
        var base = existing
        var removed = false
        if let range = markedRange(in: base, begin: begin, end: end) {
            base.removeSubrange(range)
            removed = true
        }
        // Collapse leftover blank runs after removal, then append block at end.
        base = collapseTrailingWhitespace(base)
        if base.isEmpty {
            return (block, removed)
        }
        return (base + "\n\n" + block, removed)
    }

    /// Legacy name — same as `replaceMarkedBlock` text only.
    public static func upsertMarkedBlock(
        existing: String?,
        body: String,
        begin: String = OrchestrationBundle.markerBegin,
        end: String = OrchestrationBundle.markerEnd
    ) -> String {
        replaceMarkedBlock(existing: existing, body: body, begin: begin, end: end).text
    }

    public static func markedRange(in text: String, begin: String, end: String) -> Range<String.Index>? {
        guard let b = text.range(of: begin), let e = text.range(of: end, range: b.upperBound..<text.endIndex) else {
            return nil
        }
        // Expand to include a single trailing newline after END if present.
        var upper = e.upperBound
        if upper < text.endIndex, text[upper] == "\n" {
            upper = text.index(after: upper)
        }
        // Expand to include one leading newline before BEGIN if present (avoid double blank later).
        var lower = b.lowerBound
        if lower > text.startIndex {
            let prev = text.index(before: lower)
            if text[prev] == "\n" {
                lower = prev
            }
        }
        return lower..<upper
    }

    public static func install(
        homes: OrchestrationHomes,
        fileManager: FileManager = .default
    ) -> OrchestrationInstallReport {
        var report = OrchestrationInstallReport()
        installClaude(homes.claude, fm: fileManager, report: &report)
        installCodex(homes.codex, fm: fileManager, report: &report)
        installGrok(homes.grok, fm: fileManager, report: &report)
        return report
    }

    // MARK: - Claude

    private static func installClaude(_ root: URL, fm: FileManager, report: inout OrchestrationInstallReport) {
        ensureDir(root, fm: fm, report: &report)
        writeRulesFile(root.appendingPathComponent("CLAUDE.md"), fm: fm, report: &report)
        let skillsRoot = root.appendingPathComponent("skills", isDirectory: true)
        let agentsRoot = root.appendingPathComponent("agents", isDirectory: true)
        ensureDir(skillsRoot, fm: fm, report: &report)
        ensureDir(agentsRoot, fm: fm, report: &report)
        for skill in OrchestrationBundle.skills {
            let dir = skillsRoot.appendingPathComponent(skill.id, isDirectory: true)
            removeIfExists(dir, fm: fm, report: &report)
            ensureDir(dir, fm: fm, report: &report)
            writeFile(dir.appendingPathComponent("SKILL.md"), content: skill.skillMarkdown, fm: fm, report: &report)
        }
        for agent in OrchestrationBundle.subagents {
            let path = agentsRoot.appendingPathComponent("\(agent.id).md")
            removeIfExists(path, fm: fm, report: &report)
            writeFile(path, content: agent.claudeMarkdownBody, fm: fm, report: &report)
        }
    }

    // MARK: - Codex

    private static func installCodex(_ root: URL, fm: FileManager, report: inout OrchestrationInstallReport) {
        ensureDir(root, fm: fm, report: &report)
        writeRulesFile(root.appendingPathComponent("AGENTS.md"), fm: fm, report: &report)
        let skillsRoot = root.appendingPathComponent("skills", isDirectory: true)
        let agentsRoot = root.appendingPathComponent("agents", isDirectory: true)
        ensureDir(skillsRoot, fm: fm, report: &report)
        ensureDir(agentsRoot, fm: fm, report: &report)
        for skill in OrchestrationBundle.skills {
            let dir = skillsRoot.appendingPathComponent(skill.id, isDirectory: true)
            removeIfExists(dir, fm: fm, report: &report)
            ensureDir(dir, fm: fm, report: &report)
            writeFile(dir.appendingPathComponent("SKILL.md"), content: skill.skillMarkdown, fm: fm, report: &report)
        }
        for agent in OrchestrationBundle.subagents {
            let path = agentsRoot.appendingPathComponent("\(agent.id).toml")
            removeIfExists(path, fm: fm, report: &report)
            let toml = codexAgentTOML(id: agent.id, description: agent.codexDescription, instructions: agent.codexInstructions)
            writeFile(path, content: toml, fm: fm, report: &report)
        }
    }

    /// Codex agent file: name + description + developer_instructions (triple-single-quoted).
    public static func codexAgentTOML(id: String, description: String, instructions: String) -> String {
        let desc = description.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let body = instructions.replacingOccurrences(of: "'''", with: "\"\"\"")
        return """
        name = "\(id)"
        description = "\(desc)"
        developer_instructions = '''
        \(body)
        '''
        """
    }

    // MARK: - Grok

    private static func installGrok(_ root: URL, fm: FileManager, report: inout OrchestrationInstallReport) {
        ensureDir(root, fm: fm, report: &report)
        writeRulesFile(root.appendingPathComponent("AGENTS.md"), fm: fm, report: &report)
        let skillsRoot = root.appendingPathComponent("skills", isDirectory: true)
        let agentsRoot = root.appendingPathComponent("agents", isDirectory: true)
        ensureDir(skillsRoot, fm: fm, report: &report)
        ensureDir(agentsRoot, fm: fm, report: &report)
        for skill in OrchestrationBundle.skills {
            let dir = skillsRoot.appendingPathComponent(skill.id, isDirectory: true)
            removeIfExists(dir, fm: fm, report: &report)
            ensureDir(dir, fm: fm, report: &report)
            writeFile(dir.appendingPathComponent("SKILL.md"), content: skill.skillMarkdown, fm: fm, report: &report)
        }
        for agent in OrchestrationBundle.subagents {
            let path = agentsRoot.appendingPathComponent("\(agent.id).md")
            removeIfExists(path, fm: fm, report: &report)
            let body = grokAgentMarkdown(
                id: agent.id,
                description: agent.codexDescription,
                permissionMode: agent.grokPermissionMode,
                body: agent.codexInstructions
            )
            writeFile(path, content: body, fm: fm, report: &report)
        }
    }

    /// Grok agent frontmatter mirrors existing `~/.grok/agents/{architect,developer,reviewer}.md`.
    public static func grokAgentMarkdown(
        id: String,
        description: String,
        permissionMode: String,
        body: String
    ) -> String {
        let descEscaped = description.replacingOccurrences(of: "\"", with: "\\\"")
        return """
        ---
        name: \(id)
        description: "\(descEscaped)"
        prompt_mode: full
        model: inherit
        permission_mode: \(permissionMode)
        agents_md: true
        ---

        \(body.trimmingCharacters(in: .whitespacesAndNewlines))
        """
    }

    // MARK: - IO helpers

    /// CLAUDE.md / AGENTS.md: 기존 마커 있으면 제거한 뒤 맨 아래에 새 블록 추가.
    private static func writeRulesFile(_ url: URL, fm: FileManager, report: inout OrchestrationInstallReport) {
        let existing = try? String(contentsOf: url, encoding: .utf8)
        let result = replaceMarkedBlock(existing: existing, body: OrchestrationBundle.alwaysRulesMarkdown)
        if result.removedExistingBlock {
            report.removedPaths.append("\(url.path) [dab-orchestration block]")
        }
        writeFile(url, content: result.text, fm: fm, report: &report)
    }

    private static func removeIfExists(_ url: URL, fm: FileManager, report: inout OrchestrationInstallReport) {
        guard fm.fileExists(atPath: url.path) else { return }
        do {
            try fm.removeItem(at: url)
            report.removedPaths.append(url.path)
        } catch {
            report.errors.append("remove \(url.path): \(error.localizedDescription)")
        }
    }

    private static func ensureDir(_ url: URL, fm: FileManager, report: inout OrchestrationInstallReport) {
        do {
            try fm.createDirectory(at: url, withIntermediateDirectories: true)
        } catch {
            report.errors.append("mkdir \(url.path): \(error.localizedDescription)")
        }
    }

    private static func writeFile(_ url: URL, content: String, fm: FileManager, report: inout OrchestrationInstallReport) {
        do {
            let parent = url.deletingLastPathComponent()
            try fm.createDirectory(at: parent, withIntermediateDirectories: true)
            try Data(content.utf8).write(to: url, options: .atomic)
            report.writtenPaths.append(url.path)
        } catch {
            report.errors.append("write \(url.path): \(error.localizedDescription)")
        }
    }

    private static func collapseTrailingWhitespace(_ s: String) -> String {
        var t = s
        while t.hasSuffix("\n") || t.hasSuffix(" ") || t.hasSuffix("\t") {
            t.removeLast()
        }
        return t
    }
}
