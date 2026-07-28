import Foundation
import Testing
@testable import DiscordAgentBridge

@Suite("OrchestrationInstaller")
struct OrchestrationInstallerTests {
    private func tempHomes() throws -> (OrchestrationHomes, URL) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dab-orch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let homes = OrchestrationHomes(
            claude: root.appendingPathComponent("claude", isDirectory: true),
            codex: root.appendingPathComponent("codex", isDirectory: true),
            grok: root.appendingPathComponent("grok", isDirectory: true)
        )
        return (homes, root)
    }

    @Test func replaceMarkedBlock_removesThenAppendsAtEnd() {
        let body1 = "v1-rule"
        let first = OrchestrationInstaller.replaceMarkedBlock(existing: nil, body: body1)
        #expect(first.removedExistingBlock == false)
        #expect(first.text.contains(body1))

        let body2 = "v2-rule"
        // Marker in the middle of file: remove it, keep prefix/suffix, append new block at end.
        let middle = "prefix\n\n" + first.text + "\nsuffix keep\n"
        let second = OrchestrationInstaller.replaceMarkedBlock(existing: middle, body: body2)
        #expect(second.removedExistingBlock == true)
        #expect(second.text.contains("prefix"))
        #expect(second.text.contains("suffix keep"))
        #expect(second.text.contains(body2))
        #expect(!second.text.contains(body1))
        #expect(second.text.components(separatedBy: OrchestrationBundle.markerBegin).count == 2)
        // New block is at the end (after suffix).
        let suffixIdx = second.text.range(of: "suffix keep")!
        let beginIdx = second.text.range(of: OrchestrationBundle.markerBegin)!
        #expect(suffixIdx.lowerBound < beginIdx.lowerBound)
    }

    @Test func install_writesClaudeCodexGrokLayouts() throws {
        let (homes, root) = try tempHomes()
        defer { try? FileManager.default.removeItem(at: root) }

        // Grok home must be created even when missing.
        #expect(!FileManager.default.fileExists(atPath: homes.grok.path))

        let report = OrchestrationInstaller.install(homes: homes)
        #expect(report.errors.isEmpty, "errors: \(report.errors)")
        #expect(!report.writtenPaths.isEmpty)

        // Claude
        let claudeMd = try String(contentsOf: homes.claude.appendingPathComponent("CLAUDE.md"), encoding: .utf8)
        #expect(claudeMd.contains("영향도 분석"))
        #expect(claudeMd.contains(OrchestrationBundle.markerBegin))
        for id in ["issue-orchestration", "issue-analysis", "issue-artifacts", "issue-implementation"] {
            let skill = homes.claude.appendingPathComponent("skills/\(id)/SKILL.md")
            #expect(FileManager.default.fileExists(atPath: skill.path))
        }
        for id in ["issue-analyzer", "impact-analyzer", "module-implementer", "common-handoff", "design-critic"] {
            let agent = homes.claude.appendingPathComponent("agents/\(id).md")
            #expect(FileManager.default.fileExists(atPath: agent.path))
        }

        // Codex
        let agentsMd = try String(contentsOf: homes.codex.appendingPathComponent("AGENTS.md"), encoding: .utf8)
        #expect(agentsMd.contains("이슈 오케스트레이션"))
        let codexToml = try String(
            contentsOf: homes.codex.appendingPathComponent("agents/impact-analyzer.toml"),
            encoding: .utf8
        )
        #expect(codexToml.contains("name = \"impact-analyzer\""))
        #expect(codexToml.contains("developer_instructions"))
        #expect(FileManager.default.fileExists(
            atPath: homes.codex.appendingPathComponent("skills/issue-orchestration/SKILL.md").path
        ))

        // Grok (folder created)
        #expect(FileManager.default.fileExists(atPath: homes.grok.path))
        let grokAgents = try String(contentsOf: homes.grok.appendingPathComponent("AGENTS.md"), encoding: .utf8)
        #expect(grokAgents.contains("dab-orchestration BEGIN"))
        let grokAgent = try String(
            contentsOf: homes.grok.appendingPathComponent("agents/module-implementer.md"),
            encoding: .utf8
        )
        #expect(grokAgent.contains("name: module-implementer"))
        #expect(grokAgent.contains("permission_mode: default"))
        #expect(grokAgent.contains("prompt_mode: full"))
        #expect(grokAgent.contains("agents_md: true"))
        let grokReadOnly = try String(
            contentsOf: homes.grok.appendingPathComponent("agents/impact-analyzer.md"),
            encoding: .utf8
        )
        #expect(grokReadOnly.contains("permission_mode: plan"))
        #expect(FileManager.default.fileExists(
            atPath: homes.grok.appendingPathComponent("skills/issue-analysis/SKILL.md").path
        ))

        // Format samples vs existing tooling conventions
        let claudeAgent = try String(
            contentsOf: homes.claude.appendingPathComponent("agents/issue-analyzer.md"),
            encoding: .utf8
        )
        #expect(claudeAgent.hasPrefix("---\n"))
        #expect(claudeAgent.contains("description: \""))
        #expect(!claudeAgent.contains("permission_mode:")) // Claude agents do not use Grok fields
    }

    @Test func codexAndGrokFormatHelpers_matchExistingShapes() {
        let toml = OrchestrationInstaller.codexAgentTOML(
            id: "sample",
            description: "desc",
            instructions: "# body\n- rule"
        )
        #expect(toml.contains("name = \"sample\""))
        #expect(toml.contains("description = \"desc\""))
        #expect(toml.contains("developer_instructions = '''"))
        #expect(toml.contains("# body"))

        let grok = OrchestrationInstaller.grokAgentMarkdown(
            id: "sample",
            description: "desc",
            permissionMode: "plan",
            body: "# body"
        )
        #expect(grok.contains("permission_mode: plan"))
        #expect(grok.contains("model: inherit"))
    }

    @Test func install_removesThenRecreatesSkillsAndAgents() throws {
        let (homes, root) = try tempHomes()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = OrchestrationInstaller.install(homes: homes)
        #expect(first.removedPaths.isEmpty)

        // Stale file inside skill dir should disappear after reinstall (dir deleted then recreated).
        let skillDir = homes.claude.appendingPathComponent("skills/issue-orchestration", isDirectory: true)
        let stale = skillDir.appendingPathComponent("STALE.txt")
        try "old".write(to: stale, atomically: true, encoding: .utf8)
        #expect(FileManager.default.fileExists(atPath: stale.path))

        let second = OrchestrationInstaller.install(homes: homes)
        #expect(second.removedPaths.contains { $0.contains("issue-orchestration") })
        #expect(second.removedPaths.contains { $0.contains("CLAUDE.md") && $0.contains("block") })
        #expect(!FileManager.default.fileExists(atPath: stale.path))
        #expect(FileManager.default.fileExists(
            atPath: skillDir.appendingPathComponent("SKILL.md").path
        ))

        let text = try String(contentsOf: homes.claude.appendingPathComponent("CLAUDE.md"), encoding: .utf8)
        #expect(text.components(separatedBy: OrchestrationBundle.markerBegin).count == 2)
    }

    @Test func orchestrationSlashCommand_isRegistered() {
        #expect(allSlashCommandSpecs().contains { $0.name == "orchestration" })
    }
}
