import Foundation

public struct OrchestrationInstallReport: Sendable, Equatable {
    public var removedPaths: [String]
    public var writtenPaths: [String]
    public var errors: [String]
    /// Path of the `.claude/` backup zip created before this install, or nil when no prior
    /// `.claude/` existed (first run — nothing to back up).
    public var backupPath: String?
    /// Skill ids skipped because a skill of the same name already exists — globally under
    /// `~/.claude/skills/` or in this project's own `.claude/skills/` (R13/D19, WO-8 step 8).
    /// Surfaced here so the ephemeral install response/report can tell the user what was left
    /// alone instead of silently doing nothing for those ids.
    public var skippedSkills: [String]

    public init(
        removedPaths: [String] = [],
        writtenPaths: [String] = [],
        errors: [String] = [],
        backupPath: String? = nil,
        skippedSkills: [String] = []
    ) {
        self.removedPaths = removedPaths
        self.writtenPaths = writtenPaths
        self.errors = errors
        self.backupPath = backupPath
        self.skippedSkills = skippedSkills
    }
}

/// Installs the project-scoped orchestration bundle (`OrchestrationProjectBundle`) into
/// `<project-root>/.claude/` for the `/orchestration` command (design
/// design_orchestration_project_scoped_command.md §4.2/§4.2a). Claude only — the old global
/// 3-backend (Claude/Codex/Grok) installer was removed (§6 decision ①); this type now owns a
/// single entry point, `installProject`.
public enum OrchestrationInstaller {
    /// `<root>/.claude/{CLAUDE.md, roles/*.md, skills/*/SKILL.md, agents/*.md}` only —
    /// Codex/Grok and `settings.json`/LSP patching are not part of this path (§6 decision ①).
    ///
    /// Step 0 backs up any existing `<root>/.claude/` to a zip before touching it; a backup
    /// failure aborts here with no delete/rewrite (§4.2a). CLAUDE.md is fully overwritten;
    /// `roles/{id}.md`, `skills/{id}/`, and `agents/{id}.md` are removed then recreated (same
    /// idempotent pattern the old global installer already used) — except skills whose id is
    /// already installed globally or in this project (R13/D19 below), which are left untouched
    /// and reported in `skippedSkills` instead. Safe to call repeatedly — re-running always backs
    /// up again (new timestamped zip) and rewrites the same content (§5: no separate "already
    /// installed" branch needed for CLAUDE.md/roles/agents).
    public static func installProject(
        root: URL,
        fileManager: FileManager = .default
    ) -> OrchestrationInstallReport {
        var report = OrchestrationInstallReport()
        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDir), isDir.boolValue else {
            report.errors.append("project root does not exist: \(root.path)")
            return report
        }
        let backup = backupExistingClaudeDir(root: root, fileManager: fileManager)
        if let error = backup.error {
            report.errors.append(error)
            return report
        }
        report.backupPath = backup.path

        // R13/D19: collected before the skills loop below removes/recreates anything, so this
        // project's own already-installed skills still count as "already there" (WO-8 step 8 —
        // the backup above is a zip copy, not a delete, so `<root>/.claude/skills/` on disk right
        // now is still the pre-reinstall state).
        let skipSkillIds = existingSkillIds(root: root, homeDir: NSHomeDirectory(), fm: fileManager)

        let claudeRoot = root.appendingPathComponent(".claude", isDirectory: true)
        ensureDir(claudeRoot, fm: fileManager, report: &report)
        writeFile(
            claudeRoot.appendingPathComponent("CLAUDE.md"),
            content: OrchestrationProjectBundle.claudeMdBody,
            fm: fileManager,
            report: &report
        )
        copyGlobalSettingsJSON(into: claudeRoot, fm: fileManager, report: &report)

        let rolesRoot = claudeRoot.appendingPathComponent("roles", isDirectory: true)
        ensureDir(rolesRoot, fm: fileManager, report: &report)
        for role in OrchestrationProjectBundle.roles {
            let path = rolesRoot.appendingPathComponent("\(role.id).md")
            removeIfExists(path, fm: fileManager, report: &report)
            writeFile(path, content: role.markdown, fm: fileManager, report: &report)
        }

        let skillsRoot = claudeRoot.appendingPathComponent("skills", isDirectory: true)
        ensureDir(skillsRoot, fm: fileManager, report: &report)
        for skill in OrchestrationProjectBundle.skills {
            guard !skipSkillIds.contains(skill.id) else {
                report.skippedSkills.append(skill.id)
                continue
            }
            let dir = skillsRoot.appendingPathComponent(skill.id, isDirectory: true)
            removeIfExists(dir, fm: fileManager, report: &report)
            ensureDir(dir, fm: fileManager, report: &report)
            writeFile(dir.appendingPathComponent("SKILL.md"), content: skill.markdown, fm: fileManager, report: &report)
        }

        let agentsRoot = claudeRoot.appendingPathComponent("agents", isDirectory: true)
        ensureDir(agentsRoot, fm: fileManager, report: &report)
        for agent in OrchestrationProjectBundle.subagents {
            let path = agentsRoot.appendingPathComponent("\(agent.id).md")
            removeIfExists(path, fm: fileManager, report: &report)
            writeFile(path, content: agent.markdown, fm: fileManager, report: &report)
        }

        return report
    }

    /// Skill ids that already exist under the global `~/.claude/skills/` or this project's own
    /// `<root>/.claude/skills/` — the R13/D19 "don't clobber what's already there" set (WO-8
    /// step 8). `orchestration` (the Orca skill symlink, a same-name-different-thing) is always
    /// excluded regardless of whether it's actually present, so it can never be treated as "this
    /// bundle's skill is already installed". Read-only — only lists directory entries, never
    /// writes under either root.
    public static func existingSkillIds(root: URL, homeDir: String, fm: FileManager) -> Set<String> {
        let globalSkillsDir = URL(fileURLWithPath: homeDir).appendingPathComponent(".claude/skills", isDirectory: true)
        let projectSkillsDir = root.appendingPathComponent(".claude/skills", isDirectory: true)
        var ids = skillDirEntries(at: globalSkillsDir, fm: fm)
        ids.formUnion(skillDirEntries(at: projectSkillsDir, fm: fm))
        ids.remove("orchestration")
        return ids
    }

    private static func skillDirEntries(at dir: URL, fm: FileManager) -> Set<String> {
        guard let entries = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        return Set(entries)
    }

    /// `<root>/.claude` → `<root>/.claude-backups/orchestration-{stamp}.zip` (§4.2a). No prior
    /// `.claude/` → skip entirely (`path: nil, error: nil`); this is a plain existence check, not
    /// an "already installed" state flag (§5). Shells out to `zip -r -q` synchronously via
    /// `/usr/bin/env` (PATH lookup) rather than adding a new SPM compression dependency — same
    /// non-absolute-path convention as `Update/Installer.swift`'s `runUpdateCommand`, since a
    /// hardcoded `/usr/bin/zip` doesn't exist on Linux/Windows (README: supported platforms).
    private static func backupExistingClaudeDir(
        root: URL,
        fileManager: FileManager
    ) -> (path: String?, error: String?) {
        let claudeDir = root.appendingPathComponent(".claude", isDirectory: true)
        guard fileManager.fileExists(atPath: claudeDir.path) else {
            return (nil, nil)
        }
        let backupsDir = root.appendingPathComponent(".claude-backups", isDirectory: true)
        do {
            try fileManager.createDirectory(at: backupsDir, withIntermediateDirectories: true)
        } catch {
            return (nil, "mkdir \(backupsDir.path): \(error.localizedDescription)")
        }
        let stamp = iso8601Now().replacingOccurrences(of: ":", with: "-") + "-" + UUID().uuidString.prefix(8)
        let zipURL = backupsDir.appendingPathComponent("orchestration-\(stamp).zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.currentDirectoryURL = root
        // Compress ".claude" as a relative path (cwd = project root) so unzip restores it in place.
        process.arguments = ["zip", "-r", "-q", zipURL.path, ".claude"]
        do {
            try process.run()
        } catch {
            return (nil, "zip \(zipURL.path): \(error.localizedDescription)")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            return (nil, "zip exited with status \(process.terminationStatus): \(zipURL.path)")
        }
        return (zipURL.path, nil)
    }

    /// Mirrors global `~/.claude/settings.json` (if any) into `<root>/.claude/settings.json` on
    /// every install (R7) — full overwrite, not a merge, not "first run only". No global file →
    /// silent no-op, not an error (D14): unlike CLAUDE.md/skills/agents this is an external file
    /// the user may never have created. Global is read-only here; only the project-local copy
    /// is written.
    private static func copyGlobalSettingsJSON(
        into claudeRoot: URL,
        fm: FileManager,
        report: inout OrchestrationInstallReport
    ) {
        let globalPath = (NSHomeDirectory() as NSString).appendingPathComponent(".claude/settings.json")
        guard fm.fileExists(atPath: globalPath) else { return }
        guard let content = try? String(contentsOfFile: globalPath, encoding: .utf8) else { return }
        writeFile(claudeRoot.appendingPathComponent("settings.json"), content: content, fm: fm, report: &report)
    }

    // MARK: - IO helpers

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
}
