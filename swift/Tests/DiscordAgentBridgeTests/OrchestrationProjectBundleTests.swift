import Foundation
import Testing
@testable import DiscordAgentBridge

/// design_orchestration_module_agents.md WO-8 completion checks: the bundle's static content
/// (not the installer's file-system wiring, which `OrchestrationInstallerTests` covers) matches
/// the role-fixed reshaping §3-7 mandates, and stays byte-for-byte in sync with its hand-ported
/// source set under `docs/sample/`.
@Suite("OrchestrationProjectBundle")
struct OrchestrationProjectBundleTests {
    /// discord-agent-bridge repo root — 4 levels up from this test file
    /// (swift/Tests/DiscordAgentBridgeTests/<this file>.swift).
    private func repositoryRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url
    }

    private var sampleRoot: URL {
        repositoryRoot().appendingPathComponent("docs/sample", isDirectory: true)
    }

    // MARK: - WO-8 completion condition ① — roles exist

    @Test func rolesIncludeOrchestratorAndModuleAgent() {
        let ids = Set(OrchestrationProjectBundle.roles.map(\.id))
        #expect(ids == ["ORCHESTRATOR", "MODULE_AGENT"])
    }

    // MARK: - WO-8 completion condition ② — required markers present as literal strings

    @Test func bundleContainsRequiredMarkerStrings() {
        let roleContent = OrchestrationProjectBundle.roles.map(\.markdown).joined()
        let allContent = ([OrchestrationProjectBundle.claudeMdBody] + OrchestrationProjectBundle.skills.map(\.markdown))
            .joined() + roleContent

        #expect(roleContent.contains("모듈끼리 직접 통신 금지"))
        #expect(roleContent.contains("보고는 파일이 진실"))
        #expect(roleContent.contains("IMPL_BLOCKED"))
        #expect(roleContent.contains("COMMON_MODULE_HANDOFF"))
        #expect(allContent.contains("docs/issues/"))

        // The global-clause invalidation paragraph (design doc §WO-8 step 10) must appear
        // verbatim in CLAUDE.md.
        #expect(OrchestrationProjectBundle.claudeMdBody.contains("## 역할 고정 (전역 규칙보다 우선)"))
        #expect(OrchestrationProjectBundle.claudeMdBody.contains(
            "서브에이전트 호출 도구는 이 세션에서 **차단되어 있다.** 부르려 하지 말 것."
        ))
    }

    // MARK: - WO-8 completion condition ③ — disposed-of subagent ids no longer present

    @Test func subagentsIsEmpty_allSixWereDisposedOf() {
        #expect(OrchestrationProjectBundle.subagents.isEmpty)
        let ids = Set(OrchestrationProjectBundle.subagents.map(\.id))
        for disposed in ["module-implementer", "design-critic", "impact-analyzer", "common-handoff", "issue-analyzer", "log-prober"] {
            #expect(!ids.contains(disposed))
        }
    }

    // MARK: - WO-8 completion condition — docs/sample/ and the Swift bundle stay in sync

    @Test func skillIdsMatchSampleSkillsDirectory() throws {
        let diskIds = try FileManager.default.contentsOfDirectory(atPath: sampleRoot.appendingPathComponent("skills").path)
        #expect(Set(diskIds) == Set(OrchestrationProjectBundle.skills.map(\.id)))
    }

    @Test func roleIdsMatchSampleRolesDirectory() throws {
        let diskFiles = try FileManager.default.contentsOfDirectory(atPath: sampleRoot.appendingPathComponent("roles").path)
        let diskIds = Set(diskFiles.map { ($0 as NSString).deletingPathExtension })
        #expect(diskIds == Set(OrchestrationProjectBundle.roles.map(\.id)))
    }

    @Test func agentsDirectoryIsAbsentOrEmpty_matchingZeroSubagents() throws {
        let agentsDir = sampleRoot.appendingPathComponent("agents")
        guard FileManager.default.fileExists(atPath: agentsDir.path) else { return }
        let entries = try FileManager.default.contentsOfDirectory(atPath: agentsDir.path)
        #expect(entries.isEmpty)
    }

    @Test func claudeMdContentMatchesSampleFile() throws {
        let diskContent = try String(contentsOf: sampleRoot.appendingPathComponent("CLAUDE.md"), encoding: .utf8)
        #expect(diskContent == OrchestrationProjectBundle.claudeMdBody)
    }

    @Test func roleContentMatchesSampleFiles() throws {
        for role in OrchestrationProjectBundle.roles {
            let diskContent = try String(
                contentsOf: sampleRoot.appendingPathComponent("roles/\(role.id).md"), encoding: .utf8
            )
            #expect(diskContent == role.markdown, "role \(role.id) content diverges from docs/sample/roles/\(role.id).md")
        }
    }

    @Test func skillContentMatchesSampleFiles() throws {
        for skill in OrchestrationProjectBundle.skills {
            let diskContent = try String(
                contentsOf: sampleRoot.appendingPathComponent("skills/\(skill.id)/SKILL.md"), encoding: .utf8
            )
            #expect(diskContent == skill.markdown, "skill \(skill.id) content diverges from docs/sample/skills/\(skill.id)/SKILL.md")
        }
    }
}
