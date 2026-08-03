import Testing
import Foundation
@testable import DiscordAgentBridge

private func tempProjectRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("dab-rag-generic-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

private func write(_ content: String, at path: String, under root: URL) throws {
    let url = root.appendingPathComponent(path)
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try content.write(to: url, atomically: true, encoding: .utf8)
}

@Suite("GenericFileGraphProfile")
struct GenericFileGraphProfileTests {
    @Test func matchesAlwaysReturnsLowestPositiveFallbackScore() throws {
        let profile = GenericFileGraphProfile()
        #expect(profile.id == "generic-file-graph")
        #expect(profile.matches(root: URL(fileURLWithPath: "/tmp"), files: []) == 1)
        let mixedExtensions: [ProjectFileRecord] = [
            ProjectFileRecord(path: "a.rs", sha256: "", size: 1, mtimeNs: 0),
            ProjectFileRecord(path: "b.py", sha256: "", size: 1, mtimeNs: 0),
            ProjectFileRecord(path: "README", sha256: "", size: 1, mtimeNs: 0),
        ]
        #expect(profile.matches(root: URL(fileURLWithPath: "/tmp"), files: mixedExtensions) == 1)
    }

    @Test func discoverGroupsFilesByDirectoryIntoModules() async throws {
        let root = try tempProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("class Foo {}\n", at: "Sources/A.swift", under: root)
        try write("class Bar {}\n", at: "Sources/Sub/B.swift", under: root)

        let files = [
            ProjectFileRecord(path: "Sources/A.swift", sha256: "", size: 20, mtimeNs: 0),
            ProjectFileRecord(path: "Sources/Sub/B.swift", sha256: "", size: 20, mtimeNs: 0),
        ]
        let discovery = try await GenericFileGraphProfile().discover(root: root, files: files)

        let moduleIds = Set(discovery.modules.map(\.id))
        #expect(moduleIds == ["Sources", "Sources/Sub"])
        let sourcesModule = discovery.modules.first { $0.id == "Sources" }
        #expect(sourcesModule?.paths == ["Sources/A.swift"])
    }

    @Test func discoverExtractsClassAndFunctionSymbolCandidates() async throws {
        let root = try tempProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("class Foo {\n    function bar() {\n    }\n}\n", at: "src/foo.js", under: root)

        let files = [ProjectFileRecord(path: "src/foo.js", sha256: "", size: 30, mtimeNs: 0)]
        let discovery = try await GenericFileGraphProfile().discover(root: root, files: files)

        #expect(discovery.symbols.contains { $0.name == "Foo" && $0.kind == "class" && $0.line == 1 })
        #expect(discovery.symbols.contains { $0.name == "bar" && $0.kind == "function" && $0.line == 2 })
    }

    @Test func discoverRecordsEdgeOnlyWhenImportMatchesAProjectFile() async throws {
        let root = try tempProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("#import \"Bar.h\"\n#import \"Nonexistent.h\"\n", at: "src/Foo.m", under: root)
        try write("// header\n", at: "src/Bar.h", under: root)

        let files = [
            ProjectFileRecord(path: "src/Foo.m", sha256: "", size: 30, mtimeNs: 0),
            ProjectFileRecord(path: "src/Bar.h", sha256: "", size: 10, mtimeNs: 0),
        ]
        let discovery = try await GenericFileGraphProfile().discover(root: root, files: files)

        #expect(discovery.edges.contains { $0.path == "src/Foo.m" && $0.line == 1 && $0.toModuleId == "src" })
        #expect(!discovery.edges.contains { $0.line == 2 })
    }

    @Test func discoverExcludesFilesInDefaultIgnoredDirectories() async throws {
        let root = try tempProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("class Ignored {}\n", at: "node_modules/pkg/index.js", under: root)

        let files = [ProjectFileRecord(path: "node_modules/pkg/index.js", sha256: "", size: 20, mtimeNs: 0)]
        let discovery = try await GenericFileGraphProfile().discover(root: root, files: files)

        #expect(discovery.modules.isEmpty)
        #expect(discovery.symbols.isEmpty)
        #expect(discovery.diagnostics.contains { $0.code == "excludedDir" && $0.path == "node_modules/pkg/index.js" })
    }

    @Test func discoverExcludesFilesDeclaredOverSizeCap() async throws {
        let root = try tempProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        try write("class Big {}\n", at: "src/big.swift", under: root)

        // record.size lies about being oversized — discover() trusts the record, not a re-stat.
        let files = [ProjectFileRecord(path: "src/big.swift", sha256: "", size: 6 * 1024 * 1024, mtimeNs: 0)]
        let discovery = try await GenericFileGraphProfile().discover(root: root, files: files)

        #expect(discovery.modules.isEmpty)
        #expect(discovery.symbols.isEmpty)
        #expect(discovery.diagnostics.contains { $0.code == "excludedLargeFile" })
    }

    @Test func discoverExcludesFilesResolvingOutsideRootViaSymlink() async throws {
        let root = try tempProjectRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let outside = try tempProjectRoot()
        defer { try? FileManager.default.removeItem(at: outside) }
        try write("class Evil {}\n", at: "Evil.swift", under: outside)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("escape"), withDestinationURL: outside
        )

        let files = [ProjectFileRecord(path: "escape/Evil.swift", sha256: "", size: 20, mtimeNs: 0)]
        let discovery = try await GenericFileGraphProfile().discover(root: root, files: files)

        #expect(discovery.modules.isEmpty)
        #expect(discovery.symbols.isEmpty)
        #expect(discovery.diagnostics.contains { $0.code == "excludedSymlinkEscape" })
    }
}
