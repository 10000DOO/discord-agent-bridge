import Foundation
import Testing
@testable import DiscordAgentBridge

@Suite("TypescriptNodeProfile")
struct TypescriptNodeProfileTests {
    private func tempProjectRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("dab-ts-node-profile-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// discord-agent-bridge repo root — 4 levels up from this test file
    /// (swift/Tests/DiscordAgentBridgeTests/<this file>.swift).
    private func repositoryRoot() -> URL {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<4 { url.deleteLastPathComponent() }
        return url
    }

    /// Copies a real repository TypeScript source file into the fixture at the same
    /// root-relative path, so import/export extraction runs against genuine code rather
    /// than hand-typed samples (WO-7 완료 판정 — "이 저장소의 src/ 일부로 ... 추출 확인").
    private func copyRepoSource(_ relativePath: String, into root: URL) throws -> ProjectFileRecord {
        let source = repositoryRoot().appendingPathComponent(relativePath)
        let dest = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: source, to: dest)
        let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? Int) ?? 0
        return ProjectFileRecord(path: relativePath, sha256: "fixture", size: size, mtimeNs: 0)
    }

    @Test func matches_highScoreWithPackageJsonZeroOtherwise() throws {
        let root = try tempProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let packageJsonFile = ProjectFileRecord(path: "package.json", sha256: "x", size: 2, mtimeNs: 0)
        #expect(TypescriptNodeProfile().matches(root: root, files: [packageJsonFile]) == 90)
        #expect(TypescriptNodeProfile().matches(root: root, files: []) == 0)

        let tsconfigFile = ProjectFileRecord(path: "tsconfig.build.json", sha256: "x", size: 2, mtimeNs: 0)
        #expect(TypescriptNodeProfile().matches(root: root, files: [tsconfigFile]) == 90)

        let tsSourceFile = ProjectFileRecord(path: "src/foo.tsx", sha256: "x", size: 2, mtimeNs: 0)
        #expect(TypescriptNodeProfile().matches(root: root, files: [tsSourceFile]) == 90)
    }

    @Test func discover_extractsWorkspacesAsModules() async throws {
        let root = try tempProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let packageJson = #"{"workspaces": ["packages/*", "apps/*"]}"#
        try packageJson.write(to: root.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        let file = ProjectFileRecord(path: "package.json", sha256: "x", size: packageJson.utf8.count, mtimeNs: 0)

        let result = try await TypescriptNodeProfile().discover(root: root, files: [file])
        #expect(result.modules.map(\.id).sorted() == ["workspace:apps/*", "workspace:packages/*"])
    }

    @Test func discover_extractsImportEdgesAndExportSymbolsFromRealSources() async throws {
        let root = try tempProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let contracts = try copyRepoSource("src/core/contracts.ts", into: root)
        let sessionBridge = try copyRepoSource("src/sidecar/claude/sessionBridge.ts", into: root)

        let result = try await TypescriptNodeProfile().discover(root: root, files: [contracts, sessionBridge])

        // `export interface Capabilities {` / `export type PermMode = ...` in contracts.ts
        #expect(result.symbols.contains { $0.name == "Capabilities" && $0.kind == "interface" && $0.path == "src/core/contracts.ts" })
        #expect(result.symbols.contains { $0.name == "PermMode" && $0.kind == "type" && $0.path == "src/core/contracts.ts" })

        // `import type { PermissionMode } from '@anthropic-ai/claude-agent-sdk';` — bare package specifier passes through as-is
        #expect(result.edges.contains {
            $0.kind == "import" && $0.fromModuleId == "src/core" && $0.toModuleId == "@anthropic-ai/claude-agent-sdk" && $0.path == "src/core/contracts.ts"
        })

        // `import { event, notify, type Envelope } from './protocol.js';` in sessionBridge.ts — relative
        // specifier resolves against the importing file's own directory.
        #expect(result.edges.contains {
            $0.fromModuleId == "src/sidecar/claude" && $0.toModuleId == "src/sidecar/claude/protocol.js"
        })
    }
}
