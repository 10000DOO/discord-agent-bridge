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
        var lines: [String] = [I18n.t("orchestration.install.title"), ""]
        if !removedPaths.isEmpty {
            lines.append(I18n.t("orchestration.install.removedHeading", ["count": "\(removedPaths.count)"]))
            for p in removedPaths.sorted() {
                lines.append("- `\(p)`")
            }
            lines.append("")
        }
        if !writtenPaths.isEmpty {
            lines.append(I18n.t("orchestration.install.writtenHeading", ["count": "\(writtenPaths.count)"]))
            for p in writtenPaths.sorted() {
                lines.append("- `\(p)`")
            }
            lines.append("")
        }
        if !errors.isEmpty {
            lines.append(I18n.t("orchestration.install.errorHeading"))
            for e in errors {
                lines.append("- \(e)")
            }
            lines.append("")
        }
        if writtenPaths.isEmpty, removedPaths.isEmpty, errors.isEmpty {
            lines.append(I18n.t("orchestration.install.noChanges"))
        }
        lines.append(I18n.t("orchestration.install.reinstallNote"))
        lines.append(I18n.t("orchestration.install.claudePaths"))
        lines.append(I18n.t("orchestration.install.codexPaths"))
        lines.append(I18n.t("orchestration.install.grokPaths"))
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

    // MARK: - LSP plugin/config surgical patch (DAB R1)

    /// Force `pluginKeys` on in a `~/.claude/settings.json`-shaped JSON blob, touching nothing
    /// else (D1: no full JSONSerialization re-encode — that would reorder/reformat unrelated keys).
    /// Returns the file untouched (`changed == false`) when every key is already `true`.
    /// On unparseable existing JSON, returns `existing` verbatim plus a diagnostic `error` (P4
    /// fail-safe: never attempt a surgical patch against content we couldn't understand).
    public static func ensureLSPPlugins(
        existing: String?,
        pluginKeys: [String] = OrchestrationBundle.claudeLSPPluginKeys
    ) -> (text: String, changed: Bool, error: String?) {
        guard let existing, !existing.isEmpty else {
            var lines = ["{", "  \"enabledPlugins\": {"]
            for (i, key) in pluginKeys.enumerated() {
                lines.append("    \"\(key)\": true" + (i == pluginKeys.count - 1 ? "" : ","))
            }
            lines.append("  }")
            lines.append("}")
            return (lines.joined(separator: "\n") + "\n", true, nil)
        }
        guard let root = try? JSONSerialization.jsonObject(with: Data(existing.utf8)) as? [String: Any] else {
            return (existing, false, "settings.json parse failed — skipped LSP plugin patch")
        }
        let enabledPlugins = root["enabledPlugins"] as? [String: Any]
        let missing = pluginKeys.filter { (enabledPlugins?[$0] as? Bool) != true }
        guard !missing.isEmpty else {
            return (existing, false, nil)
        }
        return (patchEnabledPlugins(in: existing, missingKeys: missing), true, nil)
    }

    /// `"enabledPlugins"` object: flat boolean map (D2) — its closing brace is the first `}`
    /// after its opening `{`, no nested-brace matching needed. If the key itself is absent,
    /// insert a whole new top-level block before the document's root closing brace.
    private static func patchEnabledPlugins(in text: String, missingKeys: [String]) -> String {
        guard
            let keyRange = text.range(of: "\"enabledPlugins\""),
            let openRange = text.range(of: "{", range: keyRange.upperBound..<text.endIndex),
            let closeRange = text.range(of: "}", range: openRange.upperBound..<text.endIndex)
        else {
            let indent = sampleIndent(in: text) ?? "  "
            var lines = ["\(indent)\"enabledPlugins\": {"]
            for (i, key) in missingKeys.enumerated() {
                lines.append("\(indent)  \"\(key)\": true" + (i == missingKeys.count - 1 ? "" : ","))
            }
            lines.append("\(indent)}")
            return insertBeforeRootClosingBrace(in: text, blockLines: lines)
        }

        var body = String(text[openRange.upperBound..<closeRange.lowerBound])
        var toAppend: [String] = []
        for key in missingKeys {
            let pattern = "\"\(NSRegularExpression.escapedPattern(for: key))\"\\s*:\\s*false"
            if let hit = body.range(of: pattern, options: .regularExpression) {
                body.replaceSubrange(hit, with: "\"\(key)\": true")
            } else {
                toAppend.append(key)
            }
        }
        if !toAppend.isEmpty {
            let indent = sampleIndent(in: body) ?? "    "
            body = appendLines(toAppend.map { "\(indent)\"\($0)\": true" }, to: body)
        }
        return String(text[text.startIndex..<openRange.upperBound]) + body + String(text[closeRange.lowerBound...])
    }

    /// Leading whitespace of the first line whose trimmed content starts with a JSON string key
    /// (`"..."`), scanning top-to-bottom. Over a full document this is always a top-level key's
    /// indent (a nested key's line can't appear before its parent key's line); over an object-body
    /// substring it's a sibling key's indent. `nil` if no such line exists (empty object/file).
    private static func sampleIndent(in text: String) -> String? {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let firstNonSpace = line.firstIndex(where: { $0 != " " && $0 != "\t" }) else { continue }
            guard line[firstNonSpace] == "\"" else { continue }
            return String(line[line.startIndex..<firstNonSpace])
        }
        return nil
    }

    /// Append `lines` just before the end of `body` (an object's inner text, braces excluded),
    /// adding a trailing comma to existing content if needed, and commas between the new `lines`
    /// themselves when there's more than one.
    private static func appendLines(_ lines: [String], to body: String) -> String {
        var trimmed = body
        while let last = trimmed.last, last == " " || last == "\n" || last == "\t" {
            trimmed.removeLast()
        }
        let joinedNew = lines.joined(separator: ",\n")
        if trimmed.isEmpty {
            return "\n" + joinedNew + "\n"
        }
        let comma = trimmed.hasSuffix(",") ? "" : ","
        return trimmed + comma + "\n" + joinedNew + "\n"
    }

    /// Insert `blockLines` right before a JSON document's root closing brace (the last `}` in
    /// the trimmed text, D2 — valid for any single-root JSON document), adding a trailing comma
    /// to whatever precedes it if needed.
    private static func insertBeforeRootClosingBrace(in text: String, blockLines: [String]) -> String {
        guard let lastBrace = text.range(of: "}", options: .backwards) else {
            return text
        }
        var trimmedBefore = String(text[text.startIndex..<lastBrace.lowerBound])
        while let last = trimmedBefore.last, last == " " || last == "\n" || last == "\t" {
            trimmedBefore.removeLast()
        }
        let comma = (trimmedBefore.isEmpty || trimmedBefore.hasSuffix("{") || trimmedBefore.hasSuffix(",")) ? "" : ","
        return trimmedBefore + comma + "\n" + blockLines.joined(separator: "\n") + "\n" + String(text[lastBrace.lowerBound...])
    }

    // MARK: - Grok LSP config surgical patch (DAB R1, Grok)

    /// Force `[features] lsp_tools = true` on in a `~/.grok/config.toml`-shaped TOML blob.
    /// TOML has no braces, so section boundaries are found by line scanning (D10) rather than
    /// the brace-matching used for JSON — simpler, not shared with the Claude/JSON helpers above.
    public static func ensureGrokLSPFeatureFlag(existing: String?) -> (text: String, changed: Bool) {
        guard let existing, !existing.isEmpty else {
            return ("[features]\nlsp_tools = true\n", true)
        }
        var lines = existing.components(separatedBy: "\n")
        guard let sectionStart = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "[features]" }) else {
            var text = existing
            if !text.hasSuffix("\n") { text += "\n" }
            text += "\n[features]\nlsp_tools = true\n"
            return (text, true)
        }
        var sectionEnd = lines.count
        for i in (sectionStart + 1)..<lines.count where lines[i].hasPrefix("[") {
            sectionEnd = i
            break
        }
        for i in (sectionStart + 1)..<sectionEnd {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            let parts = trimmed.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.first == "lsp_tools" else { continue }
            if parts.count == 2, parts[1] == "true" {
                return (existing, false)
            }
            lines[i] = "lsp_tools = true"
            return (lines.joined(separator: "\n"), true)
        }
        lines.insert("lsp_tools = true", at: sectionStart + 1)
        return (lines.joined(separator: "\n"), true)
    }

    /// Add missing `entries` as top-level keys in a `~/.grok/lsp.json`-shaped JSON blob. Only
    /// checks whether each entry's **key** already exists (3-8 point 2) — existing values are
    /// never inspected or touched, so a user's own customized language entry is preserved as-is.
    public static func ensureGrokLSPServers(
        existing: String?,
        entries: [OrchestrationBundle.GrokLSPServerEntry] = OrchestrationBundle.grokLSPServerEntries
    ) -> (text: String, changed: Bool, error: String?) {
        var base = "{}\n"
        if let existing, !existing.isEmpty {
            base = existing
        }
        guard let root = try? JSONSerialization.jsonObject(with: Data(base.utf8)) as? [String: Any] else {
            return (base, false, "lsp.json parse failed — skipped server entry patch")
        }
        let missing = entries.filter { root[$0.key] == nil }
        guard !missing.isEmpty else {
            return (base, false, nil)
        }
        let indent = sampleIndent(in: base) ?? "  "
        var blockLines: [String] = []
        for (i, entry) in missing.enumerated() {
            var entryLines = entry.jsonLiteral.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            entryLines[0] = "\(indent)\"\(entry.key)\": \(entryLines[0])"
            for j in 1..<entryLines.count {
                entryLines[j] = "\(indent)\(entryLines[j])"
            }
            if i < missing.count - 1 {
                entryLines[entryLines.count - 1] += ","
            }
            blockLines.append(contentsOf: entryLines)
        }
        return (insertBeforeRootClosingBrace(in: base, blockLines: blockLines), true, nil)
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
        ensureLSPPluginsEnabled(root.appendingPathComponent("settings.json"), fm: fm, report: &report)
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

    /// Force `claudeLSPPluginKeys` on in `settings.json`; leaves the file untouched when already
    /// satisfied (`changed == false`), never rewrites unrelated keys.
    private static func ensureLSPPluginsEnabled(_ url: URL, fm: FileManager, report: inout OrchestrationInstallReport) {
        let existing = try? String(contentsOf: url, encoding: .utf8)
        let result = ensureLSPPlugins(existing: existing)
        if let error = result.error {
            report.errors.append("\(url.path): \(error)")
        }
        guard result.changed else { return }
        writeFile(url, content: result.text, fm: fm, report: &report)
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
        ensureGrokLSPEnabled(root, fm: fm, report: &report)
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

    /// Force Grok's `[features] lsp_tools = true` (config.toml) + swift/objective-c server
    /// entries (lsp.json). Only rewrites a file when its patch actually changed something
    /// (D9/D11 — no PATH binary check, config only; both files independently idempotent).
    private static func ensureGrokLSPEnabled(_ root: URL, fm: FileManager, report: inout OrchestrationInstallReport) {
        let configURL = root.appendingPathComponent("config.toml")
        let existingConfig = try? String(contentsOf: configURL, encoding: .utf8)
        let configResult = ensureGrokLSPFeatureFlag(existing: existingConfig)
        if configResult.changed {
            writeFile(configURL, content: configResult.text, fm: fm, report: &report)
        }

        let lspURL = root.appendingPathComponent("lsp.json")
        let existingLSP = try? String(contentsOf: lspURL, encoding: .utf8)
        let lspResult = ensureGrokLSPServers(existing: existingLSP)
        if let error = lspResult.error {
            report.errors.append("\(lspURL.path): \(error)")
        }
        if lspResult.changed {
            writeFile(lspURL, content: lspResult.text, fm: fm, report: &report)
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
